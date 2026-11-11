import Foundation
import Darwin

/// Represents an open CLI conversation detected via Friday's and Claude Code's
/// live session registries, along with its current context window token count.
nonisolated struct ActiveConversation: Identifiable, Equatable, Sendable {
    static let softLimit = 300_000
    static let hardLimit = 500_000

    let id: String
    let name: String
    let providerID: String
    let providerName: String
    let icon: ProviderIcon
    let tint: ProviderTint
    let contextTokens: Int?
    let modelContextWindow: Int?

    enum StatusLevel: Equatable, Sendable {
        case normal
        case softWarning
        case hardLimit
    }

    var statusLevel: StatusLevel {
        guard let contextTokens else { return .normal }
        if contextTokens >= Self.hardLimit {
            return .hardLimit
        }
        if contextTokens >= Self.softLimit {
            return .softWarning
        }
        return .normal
    }

    /// Progress relative to the 500k hard context ceiling defined in Friday.
    var fractionOfHardLimit: Double {
        guard let contextTokens else { return 0 }
        return min(max(Double(contextTokens) / Double(Self.hardLimit), 0), 1)
    }

    var statusDetail: String {
        guard let contextTokens else { return "Sem leitura de contexto" }
        switch statusLevel {
        case .hardLimit:
            return "Acima do teto de 500 mil (compactação imediata)"
        case .softWarning:
            return "Acima de 300 mil (compactar na troca)"
        case .normal:
            let remainingToSoft = max(Self.softLimit - contextTokens, 0)
            return "\(Self.formatTokens(remainingToSoft)) até 300 mil"
        }
    }

    var formattedTokens: String {
        guard let contextTokens else { return "—" }
        return Self.formatTokens(contextTokens)
    }

    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000
            return String(format: "%.1fM", millions)
        }
        if count >= 1_000 {
            let thousands = Int((Double(count) / 1_000).rounded())
            return "\(thousands) mil"
        }
        return "\(count)"
    }
}

/// Replicates `friday_context.py` in Swift: inspects live PIDs in
/// `~/.local/state/friday-sessions/*.json` (Codex) and `~/.claude/sessions/*.json`
/// (Claude Code), then reads at most the last 3 MB of each transcript to extract
/// the current context size without invoking any model or network call.
nonisolated struct ActiveConversationCollector: Sendable {
    static let tailByteCount = 3_000_000

    let fridaySessionsURL: URL
    let claudeSessionsURL: URL
    let claudeProjectsURL: URL
    let codexSessionsURL: URL

    init(
        fridaySessionsURL: URL? = nil,
        claudeSessionsURL: URL? = nil,
        claudeProjectsURL: URL? = nil,
        codexSessionsURL: URL? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment

        self.fridaySessionsURL = fridaySessionsURL
            ?? env["FRIDAY_SESSIONS_DIR"].map { URL(filePath: $0) }
            ?? home.appending(path: ".local/state/friday-sessions")
        self.claudeSessionsURL = claudeSessionsURL
            ?? env["FRIDAY_CLAUDE_SESSIONS_DIR"].map { URL(filePath: $0) }
            ?? home.appending(path: ".claude/sessions")
        self.claudeProjectsURL = claudeProjectsURL
            ?? env["FRIDAY_CLAUDE_PROJECTS_DIR"].map { URL(filePath: $0) }
            ?? home.appending(path: ".claude/projects")
        self.codexSessionsURL = codexSessionsURL
            ?? env["FRIDAY_CODEX_SESSIONS_DIR"].map { URL(filePath: $0) }
            ?? home.appending(path: ".codex/sessions")
    }

    @concurrent
    func fetchActiveConversations() async -> [ActiveConversation] {
        let sessions = openSessions()
        var conversations: [ActiveConversation] = []
        conversations.reserveCapacity(sessions.count)

        for session in sessions {
            let (tokens, window) = Self.contextOfTranscript(
                at: session.transcriptURL,
                tool: session.tool
            )

            switch session.tool {
            case .codex:
                conversations.append(
                    ActiveConversation(
                        id: session.transcriptURL.path,
                        name: session.name,
                        providerID: "codex",
                        providerName: "Codex",
                        icon: .symbol("terminal.fill"),
                        tint: .gray,
                        contextTokens: tokens,
                        modelContextWindow: window
                    )
                )
            case .claude:
                conversations.append(
                    ActiveConversation(
                        id: session.transcriptURL.path,
                        name: session.name,
                        providerID: "claude",
                        providerName: "Claude",
                        icon: .asset("ClaudeIcon"),
                        tint: .orange,
                        contextTokens: tokens,
                        modelContextWindow: window
                    )
                )
            }
        }

        return conversations.sorted { ($0.contextTokens ?? 0) > ($1.contextTokens ?? 0) }
    }

    // MARK: - Open Session Discovery

    enum Tool: String, Sendable {
        case codex
        case claude
    }

    struct OpenSession: Sendable {
        let name: String
        let tool: Tool
        let transcriptURL: URL
    }

    func openSessions(isProcessAlive: (Int32) -> Bool = Self.isProcessAlive) -> [OpenSession] {
        var results: [OpenSession] = []
        var seenPaths: Set<String> = []

        for fileURL in Self.jsonFiles(in: fridaySessionsURL) {
            guard let record = Self.loadJSONDictionary(at: fileURL),
                  let pid = Self.extractPID(from: record["pid"]),
                  isProcessAlive(pid),
                  record["tool"] as? String == "codex",
                  let conversationID = record["conversation_id"] as? String,
                  !conversationID.isEmpty,
                  let rolloutURL = codexRollout(for: conversationID) else {
                continue
            }

            let canonicalPath = rolloutURL.standardizedFileURL.path
            guard seenPaths.insert(canonicalPath).inserted else { continue }

            let rawName = (record["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (rawName?.isEmpty == false) ? rawName! : "sem nome"
            results.append(OpenSession(name: name, tool: .codex, transcriptURL: rolloutURL))
        }

        for fileURL in Self.jsonFiles(in: claudeSessionsURL) {
            guard let record = Self.loadJSONDictionary(at: fileURL),
                  let pid = Self.extractPID(from: record["pid"]),
                  isProcessAlive(pid),
                  let sessionID = record["sessionId"] as? String,
                  !sessionID.isEmpty,
                  let transcriptURL = claudeTranscript(for: sessionID) else {
                continue
            }

            let canonicalPath = transcriptURL.standardizedFileURL.path
            guard seenPaths.insert(canonicalPath).inserted else { continue }

            let rawName = (record["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackName = "sem nome \(sessionID.prefix(8))"
            let name = (rawName?.isEmpty == false) ? rawName! : fallbackName
            results.append(OpenSession(name: name, tool: .claude, transcriptURL: transcriptURL))
        }

        return results
    }

    static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return Darwin.kill(pid, 0) == 0
    }

    private static func extractPID(from value: Any?) -> Int32? {
        if let intValue = value as? Int, let pid = Int32(exactly: intValue) {
            return pid
        }
        if let number = value as? NSNumber {
            return Int32(exactly: number.intValue)
        }
        if let string = value as? String, let pid = Int32(string) {
            return pid
        }
        return nil
    }

    private static func jsonFiles(in directory: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func loadJSONDictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func codexRollout(for conversationID: String) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: codexSessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let suffix = "\(conversationID).jsonl"
        var newestURL: URL?
        var newestDate: Date = .distantPast

        for case let fileURL as URL in enumerator {
            let filename = fileURL.lastPathComponent
            guard filename.hasPrefix("rollout-"), filename.hasSuffix(suffix) else { continue }
            let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if newestURL == nil || mtime >= newestDate {
                newestURL = fileURL
                newestDate = mtime
            }
        }

        return newestURL
    }

    private func claudeTranscript(for sessionID: String) -> URL? {
        guard let projectDirectories = try? FileManager.default.contentsOfDirectory(
            at: claudeProjectsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let targetFilename = "\(sessionID).jsonl"
        var newestURL: URL?
        var newestDate: Date = .distantPast

        for directory in projectDirectories {
            let candidate = directory.appending(path: targetFilename)
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            let mtime = (try? candidate.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if newestURL == nil || mtime >= newestDate {
                newestURL = candidate
                newestDate = mtime
            }
        }

        return newestURL
    }

    // MARK: - Tail Transcript Parsing

    static func contextOfTranscript(
        at url: URL,
        tool: Tool,
        maxTailBytes: Int = tailByteCount
    ) -> (tokens: Int?, window: Int?) {
        guard let lines = tailLines(at: url, maxBytes: maxTailBytes) else {
            return (nil, nil)
        }
        return contextOfLines(lines, tool: tool)
    }

    static func contextOfLines(
        _ lines: [Substring],
        tool: Tool
    ) -> (tokens: Int?, window: Int?) {
        switch tool {
        case .codex:
            var latestTokens: Int?
            var latestWindow: Int?

            for line in lines.reversed() {
                guard line.contains("input_tokens"),
                      let data = String(line).data(using: .utf8),
                      let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let usage = codexUsage(from: entry) else {
                    continue
                }

                if latestTokens == nil {
                    latestTokens = usage.tokens
                }
                if latestWindow == nil, let window = usage.window {
                    latestWindow = window
                }
                if latestTokens != nil && latestWindow != nil {
                    break
                }
            }

            return (latestTokens, latestWindow)

        case .claude:
            for line in lines.reversed() {
                guard line.contains("\"assistant\""),
                      line.contains("\"usage\""),
                      let data = String(line).data(using: .utf8),
                      let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tokens = claudeUsage(from: entry) else {
                    continue
                }
                return (tokens, nil)
            }

            return (nil, nil)
        }
    }

    private static func tailLines(at url: URL, maxBytes: Int) -> [Substring]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let totalSize = try? handle.seekToEnd() else { return nil }
        let startOffset = totalSize > UInt64(maxBytes) ? totalSize - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: startOffset)

        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        var rawLines = text.split(separator: "\n", omittingEmptySubsequences: false)

        // Match friday_context.py (`if total > size: lines = lines[1:]`):
        // drop the first fragment when seeking into the middle of the file.
        if startOffset > 0, !rawLines.isEmpty {
            rawLines.removeFirst()
        }

        return rawLines.filter { !$0.isEmpty }
    }

    private static func codexUsage(from entry: [String: Any]) -> (tokens: Int, window: Int?)? {
        let type = entry["type"] as? String
        let payload = entry["payload"] as? [String: Any] ?? [:]

        if type == "token_usage_record",
           let usage = payload["usage"] as? [String: Any],
           let inputTokens = intValue(usage["input_tokens"]) {
            return (inputTokens, nil)
        }

        if type == "event_msg",
           payload["type"] as? String == "token_count",
           let info = payload["info"] as? [String: Any],
           let lastUsage = info["last_token_usage"] as? [String: Any],
           let inputTokens = intValue(lastUsage["input_tokens"]) {
            return (inputTokens, intValue(info["model_context_window"]))
        }

        return nil
    }

    private static func claudeUsage(from entry: [String: Any]) -> Int? {
        guard entry["type"] as? String == "assistant",
              let message = entry["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else {
            return nil
        }

        let input = intValue(usage["input_tokens"]) ?? 0
        let cacheRead = intValue(usage["cache_read_input_tokens"]) ?? 0
        let cacheCreation = intValue(usage["cache_creation_input_tokens"]) ?? 0
        return input + cacheRead + cacheCreation
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let int = raw as? Int { return int }
        if let number = raw as? NSNumber { return number.intValue }
        return nil
    }
}

nonisolated extension ActiveConversation {
    static let previewData: [ActiveConversation] = [
        ActiveConversation(
            id: "preview-codex-lead",
            name: "lead",
            providerID: "codex",
            providerName: "Codex",
            icon: .symbol("terminal.fill"),
            tint: .gray,
            contextTokens: 342_000,
            modelContextWindow: 1_000_000
        ),
        ActiveConversation(
            id: "preview-claude-dev",
            name: "ai-usage-menu",
            providerID: "claude",
            providerName: "Claude",
            icon: .asset("ClaudeIcon"),
            tint: .orange,
            contextTokens: 128_400,
            modelContextWindow: nil
        )
    ]
}
