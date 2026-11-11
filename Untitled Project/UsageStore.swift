import Foundation
import Observation

@MainActor
@Observable
final class UsageStore {
    private static let refreshInterval: Duration = .seconds(5 * 60)
    private static let minimumAgeOnOpen: TimeInterval = 60

    private(set) var providers: [ProviderUsage]
    private(set) var activeConversations: [ActiveConversation]
    private(set) var fridaySnapshot: FridaySnapshot
    private(set) var lastUpdated: Date?
    private(set) var lastConversationsUpdated: Date?
    private(set) var isRefreshing = false

    private let collectors: [any UsageCollector]
    private let conversationCollector: ActiveConversationCollector?
    private let fridayCollector: FridayStateCollector?
    private var refreshLoop: Task<Void, Never>?

    init(
        providers: [ProviderUsage] = ProviderUsage.placeholders,
        activeConversations: [ActiveConversation] = [],
        fridaySnapshot: FridaySnapshot = .empty,
        collectors: [any UsageCollector] = [CodexCollector(), ClaudeCollector(), GeminiCollector()],
        conversationCollector: ActiveConversationCollector? = ActiveConversationCollector(),
        fridayCollector: FridayStateCollector? = FridayStateCollector()
    ) {
        self.providers = providers
        self.activeConversations = activeConversations
        self.fridaySnapshot = fridaySnapshot
        self.collectors = collectors
        self.conversationCollector = conversationCollector
        self.fridayCollector = fridayCollector

        guard !collectors.isEmpty || conversationCollector != nil || fridayCollector != nil else { return }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    var menuBarLabel: String {
        let lowestRemaining = providers
            .filter { $0.sessionState == .active }
            .flatMap(\.limits)
            .map(\.remainingPercentage)
            .min()

        return lowestRemaining.map { "\($0)%" } ?? "—"
    }

    /// Called when the panel opens, so it never shows data older than a minute
    /// without spawning the CLIs on every click. Matches Friday's 60s cache.
    func refreshIfStale() async {
        if let lastConversationsUpdated,
           Date().timeIntervalSince(lastConversationsUpdated) < Self.minimumAgeOnOpen {
            // Local state is fresh (<= 60s).
        } else {
            await refreshLocalState()
        }

        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < Self.minimumAgeOnOpen {
            return
        }
        await refresh()
    }

    func refreshLocalState() async {
        async let conversationsTask = conversationCollector?.fetchActiveConversations()
        async let fridayTask = fridayCollector?.fetchSnapshot()

        if let conversations = await conversationsTask {
            activeConversations = conversations
        }
        if let snapshot = await fridayTask {
            fridaySnapshot = snapshot
        }
        if conversationCollector != nil || fridayCollector != nil {
            lastConversationsUpdated = Date()
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard !collectors.isEmpty || conversationCollector != nil || fridayCollector != nil else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        // Local transcript & state reading finishes in milliseconds; run it
        // immediately so active conversations and Friday state update before slow PTY collectors.
        await refreshLocalState()

        guard !collectors.isEmpty else { return }

        var receivedLiveData = false
        await withTaskGroup(of: (String, Result<ProviderUsage, any Error>).self) { group in
            for collector in collectors {
                group.addTask {
                    do {
                        return (collector.providerID, .success(try await collector.fetchUsage()))
                    } catch {
                        return (collector.providerID, .failure(error))
                    }
                }
            }

            // Apply each result as it arrives, so a fast provider (Codex) does
            // not wait in "Carregando" for the slower terminal-based ones.
            for await (providerID, result) in group {
                receivedLiveData = apply(result, to: providerID) || receivedLiveData
            }
        }

        if receivedLiveData {
            lastUpdated = Date()
        }
    }

    @discardableResult
    private func apply(_ result: Result<ProviderUsage, any Error>, to providerID: String) -> Bool {
        guard let index = providers.firstIndex(where: { $0.id == providerID }) else { return false }

        switch result {
        case .success(let usage):
            providers[index] = usage
            return true
        case .failure(let error):
            // Keep the last valid reading; only replace placeholders.
            if providers[index].sessionState != .active {
                providers[index] = providers[index].unavailable(error.localizedDescription)
            }
            return false
        }
    }
}

nonisolated struct ProviderUsage: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let plan: String
    let icon: ProviderIcon
    let tint: ProviderTint
    let sessionState: SessionState
    let limits: [UsageLimit]

    var unavailableReason: String? {
        guard case .unavailable(let reason) = sessionState else { return nil }
        return reason
    }

    /// Summary card shows the most consumed 5-hour session window (especially
    /// relevant for Gemini, where multiple model groups have separate windows).
    var sessionLimit: UsageLimit? {
        limits
            .filter { $0.window == .session }
            .max { $0.usedPercentage < $1.usedPercentage }
    }

    /// Summary card shows Argon's weekly window for Gemini, or the most
    /// consumed weekly window otherwise.
    var weeklyLimit: UsageLimit? {
        if id == "gemini",
           let argonWeekly = limits.first(where: { $0.id == "gemini-argon-weekly" && $0.window == .weekly }) {
            return argonWeekly
        }

        return limits
            .filter { $0.window == .weekly }
            .max { $0.usedPercentage < $1.usedPercentage }
    }

    func unavailable(_ reason: String) -> ProviderUsage {
        ProviderUsage(
            id: id,
            name: name,
            plan: plan,
            icon: icon,
            tint: tint,
            sessionState: .unavailable(reason),
            limits: []
        )
    }
}

nonisolated enum ProviderIcon: Equatable, Sendable {
    case symbol(String)
    case asset(String)
}

nonisolated enum LimitWindow: Equatable, Sendable {
    case session
    case weekly
}

nonisolated struct UsageLimit: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let detail: String?
    let window: LimitWindow
    let usedPercentage: Int
    let resetsAt: Date?

    var remainingPercentage: Int {
        max(100 - usedPercentage, 0)
    }

    var fraction: Double {
        min(max(Double(usedPercentage) / 100, 0), 1)
    }
}

nonisolated enum SessionState: Equatable, Sendable {
    case active
    case unavailable(String)

    var label: String {
        switch self {
        case .active:
            "Sessão ativa"
        case .unavailable:
            "Indisponível"
        }
    }
}

nonisolated enum ProviderTint: Equatable, Sendable {
    case gray
    case orange
    case blue
}

nonisolated extension ProviderUsage {
    /// Shown until the first reading arrives.
    static let placeholders: [ProviderUsage] = [
        ProviderUsage(id: "codex", name: "Codex", plan: "ChatGPT", icon: .symbol("terminal.fill"), tint: .gray, sessionState: .unavailable("Carregando"), limits: []),
        ProviderUsage(id: "claude", name: "Claude", plan: "Pro / Max", icon: .asset("ClaudeIcon"), tint: .orange, sessionState: .unavailable("Carregando"), limits: []),
        ProviderUsage(id: "gemini", name: "Gemini", plan: "Google AI Pro", icon: .symbol("sparkle"), tint: .blue, sessionState: .unavailable("Carregando"), limits: [])
    ]

    static let previewData: [ProviderUsage] = {
        let now = Date()

        return [
            ProviderUsage(
                id: "codex",
                name: "Codex",
                plan: "ChatGPT",
                icon: .symbol("terminal.fill"),
                tint: .gray,
                sessionState: .active,
                limits: [
                    UsageLimit(
                        id: "codex-session",
                        name: "Sessão de 5 horas",
                        detail: nil,
                        window: .session,
                        usedPercentage: 34,
                        resetsAt: now.addingTimeInterval(2 * 60 * 60 + 18 * 60)
                    ),
                    UsageLimit(
                        id: "codex-weekly",
                        name: "Limite semanal",
                        detail: nil,
                        window: .weekly,
                        usedPercentage: 61,
                        resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60 + 7 * 60 * 60)
                    )
                ]
            ),
            ProviderUsage(
                id: "claude",
                name: "Claude",
                plan: "Pro / Max",
                icon: .asset("ClaudeIcon"),
                tint: .orange,
                sessionState: .active,
                limits: [
                    UsageLimit(
                        id: "claude-session",
                        name: "Sessão de 5 horas",
                        detail: nil,
                        window: .session,
                        usedPercentage: 52,
                        resetsAt: now.addingTimeInterval(54 * 60)
                    ),
                    UsageLimit(
                        id: "claude-weekly",
                        name: "Todos os modelos",
                        detail: "Semanal",
                        window: .weekly,
                        usedPercentage: 27,
                        resetsAt: now.addingTimeInterval(5 * 24 * 60 * 60)
                    )
                ]
            ),
            ProviderUsage(
                id: "gemini",
                name: "Gemini",
                plan: "Google AI Pro",
                icon: .symbol("sparkle"),
                tint: .blue,
                sessionState: .active,
                limits: [
                    UsageLimit(
                        id: "gemini-argon-weekly",
                        name: "Argon",
                        detail: "Semanal",
                        window: .weekly,
                        usedPercentage: 84,
                        resetsAt: now.addingTimeInterval(46 * 60 * 60 + 47 * 60)
                    ),
                    UsageLimit(
                        id: "gemini-flash-session",
                        name: "Flash",
                        detail: "Sessão de 5 horas",
                        window: .session,
                        usedPercentage: 0,
                        resetsAt: nil
                    ),
                    UsageLimit(
                        id: "gemini-flash-weekly",
                        name: "Flash",
                        detail: "Semanal",
                        window: .weekly,
                        usedPercentage: 1,
                        resetsAt: now.addingTimeInterval(51 * 60 * 60 + 44 * 60)
                    ),
                    UsageLimit(
                        id: "gemini-claude-gpt-session",
                        name: "Claude e GPT",
                        detail: "Sessão de 5 horas",
                        window: .session,
                        usedPercentage: 80,
                        resetsAt: now.addingTimeInterval(4 * 60 * 60 + 24 * 60)
                    ),
                    UsageLimit(
                        id: "gemini-claude-gpt-weekly",
                        name: "Claude e GPT",
                        detail: "Semanal",
                        window: .weekly,
                        usedPercentage: 41,
                        resetsAt: now.addingTimeInterval(167 * 60 * 60 + 24 * 60)
                    )
                ]
            )
        ]
    }()
}
