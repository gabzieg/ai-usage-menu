import Foundation
import Darwin

/// Reads quota information for one provider from its locally authenticated CLI.
nonisolated protocol UsageCollector: Sendable {
    var providerID: String { get }
    func fetchUsage() async throws -> ProviderUsage
}

nonisolated enum CollectorError: LocalizedError {
    case executableNotFound(String)
    case terminalUnavailable
    case timedOut
    case unexpectedOutput(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            "\(name) não encontrado"
        case .terminalUnavailable:
            "Não foi possível abrir um terminal"
        case .timedOut:
            "Tempo esgotado"
        case .unexpectedOutput(let detail):
            "Resposta inesperada: \(detail)"
        }
    }
}

nonisolated enum CLIEnvironment {
    private static var home: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Apps launched from Finder or Xcode do not inherit the shell PATH, so the
    /// usual install locations of the CLIs are listed explicitly.
    private static var searchPaths: [String] {
        [
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
    }

    /// Builds a minimal environment instead of inheriting ours. Variables from a
    /// parent session (for example `CLAUDE_CONFIG_DIR`) would otherwise make the
    /// CLI read a different login than the user's own.
    static func make() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]

        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "SHELL"] {
            environment[key] = inherited[key]
        }

        environment["PATH"] = searchPaths.joined(separator: ":")
        environment["LANG"] = "en_US.UTF-8"
        environment["TERM"] = "xterm-256color"
        return environment
    }

    static func executable(named name: String) throws -> URL {
        for directory in searchPaths {
            let path = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(filePath: path)
            }
        }

        throw CollectorError.executableNotFound(name)
    }

    /// A private working directory, so trust prompts and project settings of
    /// the CLIs never touch the user's real projects.
    static func workingDirectory(for provider: String) throws -> URL {
        let directory = URL.applicationSupportDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "UsageWidget")
            .appending(path: provider)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// Small wrapper so a running process can be terminated from a watchdog task.
nonisolated final class ProcessHandle: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }
}

/// Runs an interactive CLI inside a pseudo-terminal and collects what it draws.
/// The methods block, so use this from a background queue only.
nonisolated final class PseudoTerminalSession {
    private let process = Process()
    private let master: Int32
    private let columns: Int
    private let rows: Int
    private var buffer = Data()

    init(
        executable: URL,
        arguments: [String] = [],
        directory: URL,
        environment: [String: String],
        columns: UInt16 = 120,
        rows: UInt16 = 50
    ) throws {
        var master: Int32 = 0
        var slave: Int32 = 0
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)

        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw CollectorError.terminalUnavailable
        }

        self.master = master
        self.columns = Int(columns)
        self.rows = Int(rows)

        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = terminal
        process.standardOutput = terminal
        process.standardError = terminal

        do {
            try process.run()
        } catch {
            Darwin.close(master)
            throw error
        }

        // The child has its own copy; keeping ours open would hide its exit.
        try? terminal.close()
    }

    deinit {
        terminate()
        Darwin.close(master)
    }

    /// Everything the program printed, in order, with control codes removed.
    /// Redrawn lines appear more than once.
    var text: String {
        TerminalText.clean(buffer)
    }

    /// What a real terminal would display right now: cursor moves are applied,
    /// so lines a TUI redraws in place replace the old ones.
    var screen: String {
        TerminalScreen.render(buffer, columns: columns, rows: rows)
    }

    func send(_ input: String) {
        let bytes = Array(input.utf8)
        _ = bytes.withUnsafeBufferPointer { Darwin.write(master, $0.baseAddress, $0.count) }
    }

    /// Reads until `condition` matches the cleaned output or `timeout` passes.
    @discardableResult
    func read(timeout: TimeInterval, until condition: (String) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            guard readAvailable(waitingMilliseconds: 200) else { return false }
            if condition(text) { return true }
        }

        return false
    }

    /// Reads until the program has been silent for `quietPeriod`, which is the
    /// most reliable signal that a TUI finished drawing.
    func readUntilQuiet(_ quietPeriod: TimeInterval, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        var lastOutput = Date()

        while Date() < deadline {
            let previousCount = buffer.count
            guard readAvailable(waitingMilliseconds: 100) else { return }

            if buffer.count != previousCount {
                lastOutput = Date()
            } else if Date().timeIntervalSince(lastOutput) >= quietPeriod {
                return
            }
        }
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    /// Returns false once the program has exited and closed the terminal.
    private func readAvailable(waitingMilliseconds: Int32) -> Bool {
        var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, waitingMilliseconds) > 0 else { return true }

        var chunk = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(master, &chunk, chunk.count)
        guard count > 0 else { return false }

        let data = Data(chunk[0..<count])
        buffer.append(data)

        // Some TUIs wait for the terminal to report the cursor position.
        if data.range(of: Data("\u{1b}[6n".utf8)) != nil {
            send("\u{1b}[1;1R")
        }

        return true
    }
}

nonisolated enum TerminalText {
    private static let cursorMoves = try! NSRegularExpression(pattern: "\u{1b}\\[(\\d*)([CG])")
    private static let controlSequences = try! NSRegularExpression(
        pattern: "\u{1b}\\[[0-9;?<>=]*[ -/]*[@-~]|\u{1b}[\\]P_][^\u{07}\u{1b}]*(?:\u{07}|\u{1b}\\\\)|\u{1b}[()][A-Za-z0-9]|\u{1b}[=>78]"
    )

    /// Turns raw terminal output into plain text. Horizontal cursor moves become
    /// spaces, because TUIs often use them instead of printing blanks: Claude
    /// Code, for example, places each word with "ESC[<column>G".
    static func clean(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)

        let matches = cursorMoves.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text),
                  let countRange = Range(match.range(at: 1), in: text),
                  let kindRange = Range(match.range(at: 2), in: text) else { continue }
            // Relative moves keep their width; absolute columns become one space.
            let count = text[kindRange] == "C" ? (Int(text[countRange]) ?? 1) : 1
            text.replaceSubrange(range, with: String(repeating: " ", count: min(count, 200)))
        }

        text = controlSequences.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
        return text.replacingOccurrences(of: "\r", with: "")
    }
}

/// A minimal terminal emulator: it replays output onto a grid of cells and
/// returns what would be on screen. Needed for TUIs that redraw by moving the
/// cursor up and overwriting lines (Antigravity does), where a flat transcript
/// mixes old and new frames. Colors and modes are ignored; wide characters are
/// treated as one cell, which is fine for reading text.
nonisolated enum TerminalScreen {
    static func render(_ data: Data, columns: Int, rows: Int) -> String {
        let blank = [Character](repeating: " ", count: columns)
        var grid = Array(repeating: blank, count: rows)
        var row = 0
        var column = 0

        let scalars = Array(String(decoding: data, as: UTF8.self).unicodeScalars)
        var index = 0

        func lineFeed() {
            if row == rows - 1 {
                grid.removeFirst()
                grid.append(blank)
            } else {
                row += 1
            }
        }

        func erase(row target: Int, from start: Int, to end: Int) {
            guard start < end else { return }
            for cell in start..<end { grid[target][cell] = " " }
        }

        while index < scalars.count {
            let scalar = scalars[index]

            switch scalar {
            case "\u{1b}":
                index += 1
                guard index < scalars.count else { break }
                let kind = scalars[index]

                if kind == "[" {
                    // CSI: parameter bytes, then one final byte in @…~.
                    var parameters = ""
                    index += 1
                    while index < scalars.count, !(0x40...0x7E).contains(scalars[index].value) {
                        parameters.unicodeScalars.append(scalars[index])
                        index += 1
                    }
                    guard index < scalars.count else { break }

                    let final = scalars[index]
                    let isPrivate = parameters.first.map { "?<>=".contains($0) } ?? false
                    let numbers = parameters
                        .trimmingCharacters(in: CharacterSet(charactersIn: "?<>="))
                        .split(separator: ";", omittingEmptySubsequences: false)
                        .map { Int($0) }
                    let first = numbers.first.flatMap { $0 }
                    let count = max(first ?? 1, 1)

                    if isPrivate {
                        // Switching to or from the alternate screen starts clean.
                        if (final == "h" || final == "l"), parameters.contains("1049") {
                            grid = Array(repeating: blank, count: rows)
                            row = 0
                            column = 0
                        }
                        break
                    }

                    switch final {
                    case "A": row = max(row - count, 0)
                    case "B": row = min(row + count, rows - 1)
                    case "C": column = min(column + count, columns - 1)
                    case "D": column = max(column - count, 0)
                    case "G": column = min(count - 1, columns - 1)
                    case "H", "f":
                        row = min(count - 1, rows - 1)
                        let target = numbers.count > 1 ? (numbers[1] ?? 1) : 1
                        column = min(max(target, 1) - 1, columns - 1)
                    case "K":
                        switch first ?? 0 {
                        case 0: erase(row: row, from: column, to: columns)
                        case 1: erase(row: row, from: 0, to: min(column + 1, columns))
                        default: erase(row: row, from: 0, to: columns)
                        }
                    case "J":
                        switch first ?? 0 {
                        case 0:
                            erase(row: row, from: column, to: columns)
                            for target in (row + 1)..<rows { grid[target] = blank }
                        case 1:
                            for target in 0..<row { grid[target] = blank }
                            erase(row: row, from: 0, to: min(column + 1, columns))
                        default:
                            grid = Array(repeating: blank, count: rows)
                        }
                    default:
                        break
                    }
                } else if kind == "]" || kind == "P" || kind == "_" {
                    // String commands end with BEL or ESC \.
                    index += 1
                    while index < scalars.count {
                        if scalars[index] == "\u{07}" { break }
                        if scalars[index] == "\u{1b}", index + 1 < scalars.count, scalars[index + 1] == "\\" {
                            index += 1
                            break
                        }
                        index += 1
                    }
                } else if kind == "(" || kind == ")" {
                    index += 1 // Character set designation: skip its argument.
                }

            case "\r":
                column = 0
            case "\n":
                lineFeed()
            case "\u{08}":
                column = max(column - 1, 0)
            case "\t":
                column = min((column / 8 + 1) * 8, columns - 1)
            default:
                guard scalar.value >= 0x20, scalar.value != 0x7F else { break }
                if column >= columns {
                    column = 0
                    lineFeed()
                }
                grid[row][column] = Character(scalar)
                column += 1
            }

            index += 1
        }

        return grid
            .map { line in
                var text = String(line)
                while text.last == " " { text.removeLast() }
                return text
            }
            .joined(separator: "\n")
    }
}
