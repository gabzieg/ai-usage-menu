import Foundation
import Observation

@MainActor
@Observable
final class UsageStore {
    private static let refreshInterval: Duration = .seconds(5 * 60)
    private static let minimumAgeOnOpen: TimeInterval = 60

    private(set) var providers: [ProviderUsage]
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false

    private let collectors: [any UsageCollector]
    private var refreshLoop: Task<Void, Never>?

    init(
        providers: [ProviderUsage] = ProviderUsage.placeholders,
        collectors: [any UsageCollector] = [CodexCollector(), ClaudeCollector(), GeminiCollector()]
    ) {
        self.providers = providers
        self.collectors = collectors

        guard !collectors.isEmpty else { return }
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
    /// without spawning the CLIs on every click.
    func refreshIfStale() async {
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < Self.minimumAgeOnOpen {
            return
        }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing, !collectors.isEmpty else { return }

        isRefreshing = true
        defer { isRefreshing = false }

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
    let symbolName: String
    let tint: ProviderTint
    let sessionState: SessionState
    let limits: [UsageLimit]

    var unavailableReason: String? {
        guard case .unavailable(let reason) = sessionState else { return nil }
        return reason
    }

    // Limits are found by id ("<provider>-session", "<provider>-weekly")
    // instead of position, so a provider may lack one of them (Gemini's
    // Argon group, for example, has only a weekly window).
    var sessionLimit: UsageLimit? {
        limits.first { $0.id == "\(id)-session" }
    }

    var weeklyLimit: UsageLimit? {
        limits.first { $0.id == "\(id)-weekly" }
    }

    /// Everything that is not the main session or week: the Models tab.
    var modelLimits: [UsageLimit] {
        limits.filter { $0.id != "\(id)-session" && $0.id != "\(id)-weekly" }
    }

    func unavailable(_ reason: String) -> ProviderUsage {
        ProviderUsage(
            id: id,
            name: name,
            plan: plan,
            symbolName: symbolName,
            tint: tint,
            sessionState: .unavailable(reason),
            limits: []
        )
    }
}

nonisolated struct UsageLimit: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let detail: String?
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
        ProviderUsage(id: "codex", name: "Codex", plan: "ChatGPT", symbolName: "terminal.fill", tint: .gray, sessionState: .unavailable("Carregando"), limits: []),
        ProviderUsage(id: "claude", name: "Claude", plan: "Pro / Max", symbolName: "brain.head.profile.fill", tint: .orange, sessionState: .unavailable("Carregando"), limits: []),
        ProviderUsage(id: "gemini", name: "Gemini", plan: "Google AI Pro", symbolName: "sparkle", tint: .blue, sessionState: .unavailable("Carregando"), limits: [])
    ]


    static let previewData: [ProviderUsage] = {
        let now = Date()

        return [
            ProviderUsage(
                id: "codex",
                name: "Codex",
                plan: "ChatGPT",
                symbolName: "terminal.fill",
                tint: .gray,
                sessionState: .active,
                limits: [
                    UsageLimit(
                        id: "codex-session",
                        name: "Sessão de 5 horas",
                        detail: nil,
                        usedPercentage: 34,
                        resetsAt: now.addingTimeInterval(2 * 60 * 60 + 18 * 60)
                    ),
                    UsageLimit(
                        id: "codex-weekly",
                        name: "Limite semanal",
                        detail: nil,
                        usedPercentage: 61,
                        resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60 + 7 * 60 * 60)
                    )
                ]
            ),
            ProviderUsage(
                id: "claude",
                name: "Claude",
                plan: "Pro / Max",
                symbolName: "brain.head.profile.fill",
                tint: .orange,
                sessionState: .active,
                limits: [
                    UsageLimit(
                        id: "claude-session",
                        name: "Sessão de 5 horas",
                        detail: nil,
                        usedPercentage: 52,
                        resetsAt: now.addingTimeInterval(54 * 60)
                    ),
                    UsageLimit(
                        id: "claude-weekly",
                        name: "Todos os modelos",
                        detail: "Semanal",
                        usedPercentage: 27,
                        resetsAt: now.addingTimeInterval(5 * 24 * 60 * 60)
                    ),
                    UsageLimit(
                        id: "claude-sonnet",
                        name: "Sonnet",
                        detail: "Semanal",
                        usedPercentage: 18,
                        resetsAt: now.addingTimeInterval(5 * 24 * 60 * 60)
                    )
                ]
            ),
            ProviderUsage(
                id: "gemini",
                name: "Gemini",
                plan: "Google",
                symbolName: "sparkle",
                tint: .blue,
                sessionState: .active,
                limits: [
                    UsageLimit(
                        id: "gemini-session",
                        name: "Sessão",
                        detail: "Janela atual",
                        usedPercentage: 29,
                        resetsAt: now.addingTimeInterval(3 * 60 * 60 + 12 * 60)
                    ),
                    UsageLimit(
                        id: "gemini-weekly",
                        name: "Limite semanal",
                        detail: "Todos os modelos",
                        usedPercentage: 38,
                        resetsAt: now.addingTimeInterval(4 * 24 * 60 * 60)
                    ),
                    UsageLimit(
                        id: "gemini-pro",
                        name: "Gemini Pro",
                        detail: "Solicitações",
                        usedPercentage: 46,
                        resetsAt: now.addingTimeInterval(11 * 60 * 60)
                    ),
                    UsageLimit(
                        id: "gemini-flash",
                        name: "Gemini Flash",
                        detail: "Solicitações",
                        usedPercentage: 12,
                        resetsAt: now.addingTimeInterval(11 * 60 * 60)
                    ),
                    UsageLimit(
                        id: "gemini-context",
                        name: "Contexto",
                        detail: "Tokens",
                        usedPercentage: 8,
                        resetsAt: now.addingTimeInterval(11 * 60 * 60)
                    ),
                    UsageLimit(
                        id: "gemini-grounding",
                        name: "Grounding",
                        detail: "Consultas",
                        usedPercentage: 71,
                        resetsAt: now.addingTimeInterval(11 * 60 * 60)
                    )
                ]
            )
        ]
    }()
}
