import Foundation

/// Reads Claude limits from the `/usage` screen of Claude Code. The CLI runs
/// in a pseudo-terminal; only the slash command is typed, never a prompt, so no
/// tokens are spent.
nonisolated struct ClaudeCollector: UsageCollector {
    let providerID = "claude"

    @concurrent
    func fetchUsage() async throws -> ProviderUsage {
        let executable = try CLIEnvironment.executable(named: "claude")
        let directory = try CLIEnvironment.workingDirectory(for: providerID)

        // The terminal session blocks while it waits for output, so it runs on
        // a dispatch queue instead of occupying a Swift concurrency thread.
        let screen = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    try Self.captureUsageScreen(executable: executable, directory: directory)
                })
            }
        }

        return try ClaudeUsageParser.makeUsage(from: screen, now: .now)
    }

    private static func captureUsageScreen(executable: URL, directory: URL) throws -> String {
        let session = try PseudoTerminalSession(
            executable: executable,
            directory: directory,
            environment: CLIEnvironment.make()
        )
        defer { session.terminate() }

        session.readUntilQuiet(1.5, timeout: 20)

        // First run in the private folder: the highlighted default is
        // "No, exit", so move down to "Yes, I trust this folder".
        if session.text.contains("trust this folder") {
            session.send("\u{1b}[B")
            Thread.sleep(forTimeInterval: 0.3)
            session.send("\r")
            session.readUntilQuiet(1.5, timeout: 20)
        }

        session.send("/usage")
        Thread.sleep(forTimeInterval: 0.5)
        session.send("\r")

        let loaded = session.read(timeout: 20) { text in
            ClaudeUsageParser.limits(in: text, now: .now).contains { $0.id == "claude-weekly" }
        }
        guard loaded else { throw CollectorError.timedOut }

        // Model-specific weekly rows are drawn right after the general one.
        session.readUntilQuiet(1, timeout: 4)
        session.send("\u{1b}")
        return session.text
    }
}

nonisolated enum ClaudeUsageParser {
    // Spacing in terminal output is unreliable, hence the generous `\s*`.
    // Example: "Current week (all models)███ 6%usedResets Oct 23 at 3am (America/Sao_Paulo)"
    private static let limitPattern = try! NSRegularExpression(
        pattern: #"Current\s*(session|week\s*\(([^)]*)\))[^%\n]*?(\d{1,3})\s*%\s*used\s*(?:Resets\s*([^(\n]+?)\s*\(([A-Za-z0-9_/+\-]+)\))?"#,
        options: [.caseInsensitive]
    )

    private static let resetPattern = try! NSRegularExpression(
        pattern: #"^(?:([A-Za-z]{3})[a-z]*\.?\s*(\d{1,2})(?:,\s*\d{4})?\s*(?:at|,)?\s*)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)$"#,
        options: [.caseInsensitive]
    )

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    static func makeUsage(from screen: String, now: Date) throws -> ProviderUsage {
        let limits = limits(in: screen, now: now)
        guard limits.contains(where: { $0.id == "claude-session" }) else {
            throw CollectorError.unexpectedOutput("tela de /usage sem a sessão atual")
        }

        let plan: String =
            if screen.contains("Claude Max") { "Max" }
            else if screen.contains("Claude Pro") { "Pro" }
            else { "Assinatura" }

        return ProviderUsage(
            id: "claude",
            name: "Claude",
            plan: plan,
            symbolName: "brain.head.profile.fill",
            tint: .orange,
            sessionState: .active,
            limits: limits
        )
    }

    /// Session first and the all-models week second, as the cards expect;
    /// model-specific weeks follow for the Models tab.
    static func limits(in screen: String, now: Date) -> [UsageLimit] {
        let range = NSRange(screen.startIndex..., in: screen)
        var latest: [String: UsageLimit] = [:]

        // The screen is redrawn several times; later matches are the freshest.
        for match in limitPattern.matches(in: screen, range: range) {
            guard let percentage = capture(3, of: match, in: screen).flatMap({ Int($0) }) else { continue }

            let scope = capture(2, of: match, in: screen)?
                .lowercased()
                .replacingOccurrences(of: " only", with: "")
                .trimmingCharacters(in: .whitespaces)
            let resetsAt = resetDate(
                text: capture(4, of: match, in: screen),
                timeZone: capture(5, of: match, in: screen),
                now: now
            )

            let limit: UsageLimit
            switch scope {
            case nil:
                limit = UsageLimit(id: "claude-session", name: "Sessão de 5 horas", detail: nil, usedPercentage: percentage, resetsAt: resetsAt)
            case "all models"?:
                limit = UsageLimit(id: "claude-weekly", name: "Todos os modelos", detail: "Semanal", usedPercentage: percentage, resetsAt: resetsAt)
            case let model?:
                limit = UsageLimit(id: "claude-weekly-\(model)", name: model.capitalized, detail: "Semanal", usedPercentage: percentage, resetsAt: resetsAt)
            }

            latest[limit.id] = limit
        }

        let ordered = ["claude-session", "claude-weekly"].compactMap { latest.removeValue(forKey: $0) }
        return ordered + latest.values.sorted { $0.name < $1.name }
    }

    /// Accepts "5:10pm", "3am", "Oct 23 at 3am" and "Oct 23, 3:30pm".
    static func resetDate(text: String?, timeZone identifier: String?, now: Date) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces),
              let match = resetPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              var hour = capture(3, of: match, in: text).flatMap({ Int($0) }) else { return nil }

        let minute = capture(4, of: match, in: text).flatMap { Int($0) } ?? 0
        let isPM = capture(5, of: match, in: text)?.lowercased() == "pm"
        if hour == 12 { hour = 0 }
        if isPM { hour += 12 }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = identifier.flatMap(TimeZone.init(identifier:)) ?? .current

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute

        let monthName = capture(1, of: match, in: text)?.lowercased()
        if let monthName, let month = months.firstIndex(of: monthName) {
            components.month = month + 1
            components.day = capture(2, of: match, in: text).flatMap { Int($0) }
        }

        guard let date = calendar.date(from: components) else { return nil }

        // Without a date the reset is the next occurrence of that time; with a
        // date in the past it belongs to next year (December → January).
        if monthName == nil, date < now {
            return calendar.date(byAdding: .day, value: 1, to: date)
        }
        if monthName != nil, date < now.addingTimeInterval(-86_400) {
            return calendar.date(byAdding: .year, value: 1, to: date)
        }
        return date
    }

    private static func capture(_ index: Int, of match: NSTextCheckingResult, in text: String) -> String? {
        Range(match.range(at: index), in: text).map { String(text[$0]) }
    }
}
