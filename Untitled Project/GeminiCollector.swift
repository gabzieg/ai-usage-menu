import Foundation

/// Reads the Google AI Pro quota from the `/quota` screen of the Antigravity
/// CLI (`agy`). Google no longer accepts Gemini CLI sign-ins for personal
/// subscriptions, so Antigravity is the supported client. Only the slash
/// command is typed, never a prompt.
nonisolated struct GeminiCollector: UsageCollector {
    let providerID = "gemini"

    @concurrent
    func fetchUsage() async throws -> ProviderUsage {
        let executable = try CLIEnvironment.executable(named: "agy")
        let directory = try CLIEnvironment.workingDirectory(for: providerID)

        let screen = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    // agy is usually ready in 2–3 s but occasionally stalls at
                    // startup; a fresh process is faster than waiting it out.
                    do {
                        return try Self.captureQuotaScreen(executable: executable, directory: directory)
                    } catch is CollectorError {
                        return try Self.captureQuotaScreen(executable: executable, directory: directory)
                    }
                })
            }
        }

        return try GeminiQuotaParser.makeUsage(from: screen, now: .now)
    }

    private static func captureQuotaScreen(executable: URL, directory: URL) throws -> String {
        // Tall enough for every quota group to fit without scrolling.
        let session = try PseudoTerminalSession(
            executable: executable,
            directory: directory,
            environment: CLIEnvironment.make(),
            rows: 200
        )
        defer { session.terminate() }

        // Startup shows a "Signing in…" spinner before the prompt appears.
        let isReady: (String) -> Bool = { $0.contains("for shortcuts") }
        session.read(timeout: 15) { isReady($0) || $0.contains("trust the contents") }

        // First run in the private folder. Unlike Claude Code, "Yes" is already
        // highlighted; confirm only when that is really the selected option.
        if !isReady(session.text), session.text.contains("trust the contents") {
            guard session.text.contains("> Yes, I trust this folder") else {
                throw CollectorError.unexpectedOutput("pergunta de confiança do Antigravity em formato desconhecido")
            }
            session.send("\r")
            session.read(timeout: 15, until: isReady)
        }

        guard isReady(session.text) else {
            throw CollectorError.unexpectedOutput("Antigravity não iniciou; verifique o login no agy")
        }
        session.readUntilQuiet(0.3, timeout: 3)

        // The short pause lets the command palette filter before Enter.
        session.send("/quota")
        Thread.sleep(forTimeInterval: 0.25)
        session.send("\r")

        guard session.read(timeout: 10, until: { $0.contains("Models & Quota") }) else {
            throw CollectorError.timedOut
        }

        // The explanatory footer is drawn after the last group, so seeing it
        // means the screen is complete. If it ever disappears, the timeout
        // still returns whatever was drawn.
        session.read(timeout: 8) { text in
            guard let start = text.range(of: "Models & Quota", options: .backwards) else { return false }
            return text[start.upperBound...].contains("Within each group")
        }

        // agy redraws parts of this screen in place, so the flat transcript can
        // interleave old and new lines; parse the emulated screen instead.
        let screen = session.screen
        session.send("\u{1b}")
        return screen
    }
}

nonisolated enum GeminiQuotaParser {
    private struct Entry {
        let group: String
        let label: String
        let remaining: Double
        let resetsAt: Date?
    }

    private static let percentPattern = try! NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)\s*%"#)
    private static let durationPattern = try! NSRegularExpression(pattern: #"(\d+)\s*(d|h|m|s)"#)
    private static let mainGroup = "GEMINI MODELS"

    static func makeUsage(from screen: String, now: Date) throws -> ProviderUsage {
        let entries = entries(in: screen, now: now)
        guard !entries.isEmpty else {
            throw CollectorError.unexpectedOutput("tela de /quota sem grupos de cota")
        }

        // The card features the most consumed group, so it reflects what is
        // actually being used (the Xcode agent, for instance, runs on Argon).
        // Ties, including "nothing used yet", fall back to the Gemini group.
        let featured = featuredGroup(in: entries)
        let featuredName = displayName(forGroup: featured)

        var limits: [UsageLimit] = []
        for entry in entries where entry.group == featured {
            limits.append(
                isFiveHour(entry.label)
                    ? limit(from: entry, id: "gemini-session", name: "Sessão de 5 horas", detail: featuredName)
                    : limit(from: entry, id: "gemini-weekly", name: "Limite semanal", detail: featuredName)
            )
        }

        // The other groups go to the Models tab.
        for entry in entries where entry.group != featured {
            let kind = isFiveHour(entry.label) ? "5 horas" : "Semanal"
            limits.append(
                limit(
                    from: entry,
                    id: "gemini-\(entry.group.lowercased().replacingOccurrences(of: " ", with: "-"))-\(kind)",
                    name: displayName(forGroup: entry.group),
                    detail: kind
                )
            )
        }

        let plan = screen.contains("Google AI Ultra") ? "Google AI Ultra"
            : screen.contains("Google AI Pro") ? "Google AI Pro"
            : "Google"

        return ProviderUsage(
            id: "gemini",
            name: "Gemini",
            plan: plan,
            symbolName: "sparkle",
            tint: .blue,
            sessionState: .active,
            limits: limits
        )
    }

    /// Walks the last `/quota` screen line by line: an all-caps line opens a
    /// group, a line mentioning "Limit" names a window and the next percentage
    /// is what remains. "Refreshes in …" may share the percentage line or come on
    /// any line before the next window, so every line in between is checked.
    private static func entries(in screen: String, now: Date) -> [Entry] {
        guard let start = screen.range(of: "Models & Quota", options: .backwards) else { return [] }

        let lines = screen[start.upperBound...]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var entries: [Entry] = []
        var group: String?
        var label: String?
        var remaining: Double?
        var resetsAt: Date?

        func flush() {
            if let group, let label, let remaining {
                entries.append(Entry(group: group, label: label, remaining: remaining, resetsAt: resetsAt))
            }
            label = nil
            remaining = nil
            resetsAt = nil
        }

        for line in lines {
            if isGroupHeader(line) {
                flush()
                group = line
            } else if line.contains("Limit"), !line.contains("%") {
                flush()
                label = line
            } else if label != nil, remaining == nil, let value = percentage(in: line) {
                remaining = value
                resetsAt = resetDate(in: line, now: now)
            } else if remaining != nil, resetsAt == nil {
                resetsAt = resetDate(in: line, now: now)
            }
        }
        flush()

        return entries
    }

    private static func limit(from entry: Entry, id: String, name: String, detail: String?) -> UsageLimit {
        UsageLimit(
            id: id,
            name: name,
            detail: detail,
            usedPercentage: Int((100 - entry.remaining).rounded()),
            resetsAt: entry.resetsAt
        )
    }

    private static func isFiveHour(_ label: String) -> Bool {
        label.localizedCaseInsensitiveContains("five hour") || label.localizedCaseInsensitiveContains("5-hour")
    }

    private static func isGroupHeader(_ line: String) -> Bool {
        line.count >= 4
            && line.uppercased() == line
            && line.contains(where: \.isLetter)
            && line.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " }
    }

    private static func featuredGroup(in entries: [Entry]) -> String {
        var highestUse: [String: Double] = [:]
        var order: [String] = []

        for entry in entries {
            if highestUse[entry.group] == nil { order.append(entry.group) }
            highestUse[entry.group] = max(highestUse[entry.group] ?? 0, 100 - entry.remaining)
        }

        // On ties the Gemini group wins, then screen order: `max(by:)` keeps
        // the first of equal elements.
        let candidates = order.filter { $0 == mainGroup } + order.filter { $0 != mainGroup }
        return candidates.max { (highestUse[$0] ?? 0) < (highestUse[$1] ?? 0) } ?? mainGroup
    }

    /// "GEMINI MODELS" → "Gemini Flash e Pro", "CLAUDE AND GPT MODELS" →
    /// "Claude e GPT", "GEMINI 4 ARGON" → "Gemini 4 Argon".
    private static func displayName(forGroup group: String) -> String {
        if group == mainGroup { return "Gemini Flash e Pro" }
        return group
            .replacingOccurrences(of: " MODELS", with: "")
            .split(separator: " ")
            .map { word in
                switch word {
                case "GPT", "OSS": String(word)
                case "AND": "e"
                default: word.capitalized
                }
            }
            .joined(separator: " ")
    }

    private static func percentage(in line: String) -> Double? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = percentPattern.firstMatch(in: line, range: range),
              let valueRange = Range(match.range(at: 1), in: line) else { return nil }
        return Double(line[valueRange])
    }

    /// Reads "Refreshes in 167h 22m" (what `/quota` shows) or "resets in 3d 4h".
    private static func resetDate(in line: String, now: Date) -> Date? {
        guard let marker = line.range(of: "refreshes in", options: .caseInsensitive)
                ?? line.range(of: "resets in", options: .caseInsensitive) else { return nil }

        let text = String(line[marker.upperBound...])
        let units: [String: TimeInterval] = ["d": 86_400, "h": 3_600, "m": 60, "s": 1]
        var seconds: TimeInterval = 0

        for match in durationPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let valueRange = Range(match.range(at: 1), in: text),
                  let unitRange = Range(match.range(at: 2), in: text),
                  let value = Double(text[valueRange]),
                  let unit = units[String(text[unitRange])] else { continue }
            seconds += value * unit
        }

        return seconds > 0 ? now.addingTimeInterval(seconds) : nil
    }
}
