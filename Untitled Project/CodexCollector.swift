import Foundation

/// Reads Codex limits through `codex app-server` and its read-only
/// `account/rateLimits/read` method. No prompt is sent to the model.
nonisolated struct CodexCollector: UsageCollector {
    let providerID = "codex"

    private static let requests = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"usage-widget","version":"1.0"}}}"#,
        #"{"jsonrpc":"2.0","method":"initialized"}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}"#
    ]

    @concurrent
    func fetchUsage() async throws -> ProviderUsage {
        let process = Process()
        process.executableURL = try CLIEnvironment.executable(named: "codex")
        process.arguments = ["app-server"]
        process.environment = CLIEnvironment.make()
        process.currentDirectoryURL = try CLIEnvironment.workingDirectory(for: providerID)

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()

        // Terminating the server closes its output, which also ends the read
        // loop below if the response never arrives.
        let handle = ProcessHandle(process)
        let watchdog = Task {
            try await Task.sleep(for: .seconds(15))
            handle.terminate()
        }
        defer {
            watchdog.cancel()
            handle.terminate()
        }

        let payload = Self.requests.joined(separator: "\n") + "\n"
        try input.fileHandleForWriting.write(contentsOf: Data(payload.utf8))

        let decoder = JSONDecoder()
        for try await line in output.fileHandleForReading.bytes.lines {
            guard let message = try? decoder.decode(Message.self, from: Data(line.utf8)),
                  message.id == 2 else { continue }

            guard let result = message.result else {
                throw CollectorError.unexpectedOutput(message.error?.message ?? "sem limites")
            }

            return Self.makeUsage(from: result)
        }

        throw CollectorError.timedOut
    }

    private static func makeUsage(from result: RateLimitsResult) -> ProviderUsage {
        let main = result.rateLimits
        var limits = windows(of: main).map { window, slot in
            UsageLimit(
                id: slot == "primary" ? "codex-session" : "codex-weekly",
                name: windowName(minutes: window.windowDurationMins) ?? (slot == "primary" ? "Sessão" : "Semanal"),
                detail: nil,
                usedPercentage: Int(window.usedPercent.rounded()),
                resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) }
            )
        }

        // Model-specific limits, when the account has them, go to the Models tab.
        let extras = (result.rateLimitsByLimitId ?? [:])
            .filter { $0.key != main.limitId }
            .sorted { $0.key < $1.key }

        for (limitID, snapshot) in extras {
            for (window, slot) in windows(of: snapshot) {
                limits.append(
                    UsageLimit(
                        id: "codex-\(limitID)-\(slot)",
                        name: snapshot.limitName ?? limitID,
                        detail: windowName(minutes: window.windowDurationMins),
                        usedPercentage: Int(window.usedPercent.rounded()),
                        resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) }
                    )
                )
            }
        }

        return ProviderUsage(
            id: "codex",
            name: "Codex",
            plan: main.planType.map { "ChatGPT \($0.capitalized)" } ?? "ChatGPT",
            symbolName: "terminal.fill",
            tint: .gray,
            sessionState: .active,
            limits: limits
        )
    }

    private static func windows(of snapshot: Snapshot) -> [(Window, String)] {
        [(snapshot.primary, "primary"), (snapshot.secondary, "secondary")]
            .compactMap { window, slot in window.map { ($0, slot) } }
    }

    private static func windowName(minutes: Int?) -> String? {
        switch minutes {
        case 300:
            "Sessão de 5 horas"
        case 10_080:
            "Limite semanal"
        case let minutes? where minutes % 1_440 == 0:
            "Janela de \(minutes / 1_440) dias"
        case let minutes? where minutes % 60 == 0:
            "Janela de \(minutes / 60) horas"
        default:
            nil
        }
    }
}

// MARK: - App server messages

private nonisolated struct Message: Decodable {
    let id: Int?
    let result: RateLimitsResult?
    let error: RPCError?
}

private nonisolated struct RPCError: Decodable {
    let message: String
}

private nonisolated struct RateLimitsResult: Decodable {
    let rateLimits: Snapshot
    let rateLimitsByLimitId: [String: Snapshot]?
}

private nonisolated struct Snapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: Window?
    let secondary: Window?
    let planType: String?
}

private nonisolated struct Window: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?
}
