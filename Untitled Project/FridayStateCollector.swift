import Foundation
import Darwin

// MARK: - Daily Usage Models (friday-usage)

nonisolated struct FridayDailyUsage: Equatable, Sendable {
    let day: String
    let generatedAt: String?
    let novo: Int
    let cacheLido: Int
    let cacheGravado: Int
    let saida: Int
    let totalCostUSD: Double?
    let projects: [FridayProjectUsage]

    var totalTokens: Int {
        novo + cacheLido + cacheGravado + saida
    }

    static let empty = FridayDailyUsage(
        day: "",
        generatedAt: nil,
        novo: 0,
        cacheLido: 0,
        cacheGravado: 0,
        saida: 0,
        totalCostUSD: nil,
        projects: []
    )
}

nonisolated struct FridayProjectUsage: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let novo: Int
    let cacheLido: Int
    let cacheGravado: Int
    let saida: Int
    let costUSD: Double?
    let sessions: [FridaySessionUsage]

    var totalTokens: Int {
        novo + cacheLido + cacheGravado + saida
    }
}

nonisolated struct FridaySessionUsage: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let novo: Int
    let cacheLido: Int
    let cacheGravado: Int
    let saida: Int
    let chamadas: Int
    let costUSD: Double?

    var totalTokens: Int {
        novo + cacheLido + cacheGravado + saida
    }
}

// MARK: - Waiting & Status Models (friday_panel.py)

nonisolated struct FridayWaitingItem: Identifiable, Equatable, Sendable {
    let id: String
    let who: String
    let summary: String
    let detail: String?
    let ageText: String
    let isExplicitStuck: Bool
}

nonisolated struct FridayClosedMailItem: Identifiable, Equatable, Sendable {
    var id: String { recipient }
    let recipient: String
    let unreadCount: Int
}

nonisolated struct FridayBackupStatus: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case running(percent: Double, stage: String, remaining: String, isStalled: Bool)
        case succeeded(agoText: String, addedText: String?, snapshot: String?)
        case failed(agoText: String, reason: String?)
        case neverRun
    }

    let state: State
}

nonisolated struct FridayHealthStatus: Equatable, Sendable {
    let failCount: Int
    let warnCount: Int
    let issues: [String]
    let doctorAgeText: String?
    let testPassed: Bool?
    let testCount: Int
    let testAgeText: String?
}

nonisolated struct FridayScheduledJob: Identifiable, Equatable, Sendable {
    enum JobState: Equatable, Sendable {
        case running
        case ok
        case active
        case failed(String)
        case disabled
    }

    var id: String { label }
    let label: String
    let title: String
    let schedule: String
    let state: JobState
    let lastRunText: String
}

nonisolated struct FridaySnapshot: Equatable, Sendable {
    let dailyUsage: FridayDailyUsage
    let waitingItems: [FridayWaitingItem]
    let closedMail: [FridayClosedMailItem]
    let backup: FridayBackupStatus
    let health: FridayHealthStatus
    let scheduledJobs: [FridayScheduledJob]

    var attentionCount: Int {
        waitingItems.count + health.failCount
    }

    static let empty = FridaySnapshot(
        dailyUsage: .empty,
        waitingItems: [],
        closedMail: [],
        backup: FridayBackupStatus(state: .neverRun),
        health: FridayHealthStatus(
            failCount: 0,
            warnCount: 0,
            issues: [],
            doctorAgeText: nil,
            testPassed: nil,
            testCount: 0,
            testAgeText: nil
        ),
        scheduledJobs: []
    )
}

// MARK: - Collector

/// Reads Friday's local state files (`~/.local/state/friday-*` and `~/Library/Logs/friday-*.state`)
/// strictly from disk without invoking any model or network request.
nonisolated struct FridayStateCollector: Sendable {
    private static let parkedMailSeconds: TimeInterval = 1_800
    private static let lostBackupSeconds: TimeInterval = 60

    private static let knownJobTitles: [String: String] = [
        "com.gbz.friday-sync": "Sync do Friday para o GitHub",
        "com.gbz.friday-backup": "Backup criptografado no Drive",
        "com.gbz.friday-weekly": "Semanal: mutação dos projetos",
        "com.gbz.friday-watch": "Vigia dos projetos",
        "com.gbz.friday-pages": "Painel web do Friday",
        "com.gbz.friday-usage": "Consumo do Codex e do Claude",
        "com.gbz.colima": "Colima: Docker dos projetos"
    ]

    let homeURL: URL
    let stateRootURL: URL
    let logsURL: URL
    let launchAgentsURL: URL
    let fridayRootURL: URL

    init(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.homeURL = homeURL
        self.stateRootURL = homeURL.appending(path: ".local/state")
        self.logsURL = homeURL.appending(path: "Library/Logs")
        self.launchAgentsURL = homeURL.appending(path: "Library/LaunchAgents")
        self.fridayRootURL = homeURL.appending(path: "Friday")
    }

    @concurrent
    func fetchSnapshot(now: Date = .now) async -> FridaySnapshot {
        let nowTimestamp = now.timeIntervalSince1970
        let dailyUsage = readDailyUsage(now: now)
        let (waitingItems, closedMail) = readWaitingFacts(nowTimestamp: nowTimestamp)
        let backup = readBackupStatus(nowTimestamp: nowTimestamp)
        let health = readHealthStatus(nowTimestamp: nowTimestamp)
        let isBackupRunning: Bool = {
            if case .running(_, _, _, let stalled) = backup.state {
                return !stalled
            }
            return false
        }()
        let scheduledJobs = readScheduledJobs(nowTimestamp: nowTimestamp, isBackupRunning: isBackupRunning)

        return FridaySnapshot(
            dailyUsage: dailyUsage,
            waitingItems: waitingItems,
            closedMail: closedMail,
            backup: backup,
            health: health,
            scheduledJobs: scheduledJobs
        )
    }

    // MARK: - 1. Daily Usage (~/.local/state/friday-usage/usage.json)

    private func readDailyUsage(now: Date) -> FridayDailyUsage {
        let usageFileURL = stateRootURL.appending(path: "friday-usage/usage.json")
        guard let root = Self.loadJSON(at: usageFileURL) as? [String: Any],
              let daysDict = root["days"] as? [String: Any],
              !daysDict.isEmpty else {
            return .empty
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let todayKey = formatter.string(from: now)

        // Show today's usage if present; otherwise fall back to the most recent recorded day.
        let targetDay: String
        if daysDict[todayKey] != nil {
            targetDay = todayKey
        } else if let latestDay = daysDict.keys.max() {
            targetDay = latestDay
        } else {
            return .empty
        }

        guard let projectsDict = daysDict[targetDay] as? [String: Any] else {
            return .empty
        }

        var projects: [FridayProjectUsage] = []
        var grandNovo = 0
        var grandCacheLido = 0
        var grandCacheGravado = 0
        var grandSaida = 0
        var grandCost: Double?

        for (projectName, rawSessions) in projectsDict {
            guard let sessionsDict = rawSessions as? [String: Any] else { continue }

            var sessions: [FridaySessionUsage] = []
            var projNovo = 0
            var projCacheLido = 0
            var projCacheGravado = 0
            var projSaida = 0
            var projCost: Double?

            for (sessionName, rawMetrics) in sessionsDict {
                guard let metrics = rawMetrics as? [String: Any] else { continue }
                let novo = Self.intValue(metrics["novo"]) ?? 0
                let cacheLido = Self.intValue(metrics["cache_lido"]) ?? 0
                let cacheGravado = Self.intValue(metrics["cache_gravado"]) ?? 0
                let saida = Self.intValue(metrics["saida"]) ?? 0
                let chamadas = Self.intValue(metrics["chamadas"]) ?? 0
                let cost = Self.doubleValue(metrics["custo_usd_declarado"])

                projNovo += novo
                projCacheLido += cacheLido
                projCacheGravado += cacheGravado
                projSaida += saida
                if let cost {
                    projCost = (projCost ?? 0) + cost
                }

                sessions.append(
                    FridaySessionUsage(
                        name: sessionName,
                        novo: novo,
                        cacheLido: cacheLido,
                        cacheGravado: cacheGravado,
                        saida: saida,
                        chamadas: chamadas,
                        costUSD: cost
                    )
                )
            }

            sessions.sort { $0.totalTokens > $1.totalTokens }

            grandNovo += projNovo
            grandCacheLido += projCacheLido
            grandCacheGravado += projCacheGravado
            grandSaida += projSaida
            if let projCost {
                grandCost = (grandCost ?? 0) + projCost
            }

            projects.append(
                FridayProjectUsage(
                    name: projectName,
                    novo: projNovo,
                    cacheLido: projCacheLido,
                    cacheGravado: projCacheGravado,
                    saida: projSaida,
                    costUSD: projCost,
                    sessions: sessions
                )
            )
        }

        projects.sort { $0.totalTokens > $1.totalTokens }

        return FridayDailyUsage(
            day: targetDay,
            generatedAt: root["gerado_em"] as? String,
            novo: grandNovo,
            cacheLido: grandCacheLido,
            cacheGravado: grandCacheGravado,
            saida: grandSaida,
            totalCostUSD: grandCost,
            projects: projects
        )
    }

    // MARK: - 2. Waiting Facts (~/.local/state/friday-pending & friday-mail)

    private func readWaitingFacts(nowTimestamp: TimeInterval) -> ([FridayWaitingItem], [FridayClosedMailItem]) {
        let pendingDir = stateRootURL.appending(path: "friday-pending")
        var asksByWho: [String: (at: TimeInterval, text: String?, stuck: Bool)] = [:]

        for fileURL in Self.jsonFiles(in: pendingDir) {
            guard let record = Self.loadJSON(at: fileURL) as? [String: Any] else { continue }
            let at = Self.doubleValue(record["at"]) ?? 0

            // Check if the conversation moved on after the pending prompt.
            if let transcriptPath = record["transcript"] as? String,
               !transcriptPath.isEmpty,
               let attrs = try? FileManager.default.attributesOfItem(atPath: transcriptPath),
               let mtime = attrs[.modificationDate] as? Date,
               mtime.timeIntervalSince1970 > at + 30 {
                continue
            }

            if nowTimestamp - at > 7 * 86_400 {
                continue
            }

            let who = (record["name"] as? String)
                ?? (record["project"] as? String)
                ?? (record["tool"] as? String)
                ?? "?"
            let rawText = (record["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let stuck = (record["explicit"] as? Bool) ?? false

            if let existing = asksByWho[who], existing.at > at {
                continue
            }
            asksByWho[who] = (at: at, text: rawText, stuck: stuck)
        }

        var items: [FridayWaitingItem] = asksByWho
            .sorted { $0.value.at < $1.value.at }
            .map { who, info in
                FridayWaitingItem(
                    id: "pending-\(who)",
                    who: who,
                    summary: info.stuck ? "Travada esperando você" : "Parou (sem pedido explícito)",
                    detail: info.text.flatMap { $0.isEmpty ? nil : String($0.prefix(240)) },
                    ageText: "há \(Self.agoText(nowTimestamp - info.at))",
                    isExplicitStuck: info.stuck
                )
            }

        let liveSessionNames = openFridaySessionNames()
        let mailDir = stateRootURL.appending(path: "friday-mail")
        var closedMail: [FridayClosedMailItem] = []

        if let recipientDirs = try? FileManager.default.contentsOfDirectory(
            at: mailDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for recipientDir in recipientDirs {
                let newDir = recipientDir.appending(path: "new")
                let messageFiles = Self.jsonFiles(in: newDir)
                guard !messageFiles.isEmpty else { continue }

                var oldestAt = nowTimestamp
                var validCount = 0
                for msgURL in messageFiles {
                    guard let msg = Self.loadJSON(at: msgURL) as? [String: Any] else { continue }
                    validCount += 1
                    let msgAt = Self.doubleValue(msg["at"]) ?? nowTimestamp
                    oldestAt = min(oldestAt, msgAt)
                }

                guard validCount > 0 else { continue }
                let recipient = recipientDir.lastPathComponent
                let isLive = liveSessionNames.contains(recipient)

                if isLive, nowTimestamp - oldestAt > Self.parkedMailSeconds {
                    items.append(
                        FridayWaitingItem(
                            id: "mail-\(recipient)",
                            who: recipient,
                            summary: "Aberta com \(validCount) mensagem(ns) sem ler",
                            detail: "Pode ter esquecido a espera do correio.",
                            ageText: "há \(Self.agoText(nowTimestamp - oldestAt))",
                            isExplicitStuck: true
                        )
                    )
                } else if !isLive {
                    closedMail.append(
                        FridayClosedMailItem(recipient: recipient, unreadCount: validCount)
                    )
                }
            }
        }

        closedMail.sort { $0.recipient < $1.recipient }
        return (items, closedMail)
    }

    private func openFridaySessionNames() -> Set<String> {
        let sessionsDir = stateRootURL.appending(path: "friday-sessions")
        var names: Set<String> = []

        for fileURL in Self.jsonFiles(in: sessionsDir) {
            guard let record = Self.loadJSON(at: fileURL) as? [String: Any],
                  let name = record["name"] as? String,
                  !name.isEmpty,
                  let pid = Self.intValue(record["pid"]),
                  pid > 0,
                  Darwin.kill(Int32(pid), 0) == 0 else {
                continue
            }
            names.insert(name)
        }

        return names
    }

    // MARK: - 3. Backup Status

    private func readBackupStatus(nowTimestamp: TimeInterval) -> FridayBackupStatus {
        let progressURL = ProcessInfo.processInfo.environment["FRIDAY_BACKUP_PROGRESS"]
            .map { URL(filePath: $0) }
            ?? fridayRootURL.appending(path: "local/pages/backup-drive.json")
        let stateURL = logsURL.appending(path: "friday-backup.state")

        let progress = Self.loadJSON(at: progressURL) as? [String: Any] ?? [:]
        let state = Self.loadJSON(at: stateURL) as? [String: Any] ?? [:]

        if let fase = progress["fase"] as? String, fase != "fim" {
            let pct = min(max(Self.doubleValue(progress["pct"]) ?? 0, 0), 1) * 100
            let stage: String = switch fase {
            case "arquivos": "arquivos"
            case "bancos": "bancos de dev"
            case "limpeza": "limpeza semanal"
            default: fase
            }

            let remaining: String
            if (Self.doubleValue(progress["pct"]) ?? 0) >= 0.995 {
                remaining = "finalizando"
            } else if let rest = Self.doubleValue(progress["restante"]), rest > 0, rest < 30 * 86_400 {
                remaining = "~\(Self.agoText(rest))"
            } else {
                remaining = "calculando"
            }

            let lastBeat = Self.doubleValue(progress["at"]) ?? 0
            let isStalled = (nowTimestamp - lastBeat) > Self.lostBackupSeconds

            return FridayBackupStatus(
                state: .running(
                    percent: pct,
                    stage: stage,
                    remaining: remaining,
                    isStalled: isStalled
                )
            )
        }

        if !state.isEmpty {
            let isOK = (state["result"] as? String) == "ok"
            let at = Self.doubleValue(state["at"]) ?? nowTimestamp
            let ago = "há \(Self.agoText(nowTimestamp - at))"
            if isOK {
                let addedBytes = Self.doubleValue(state["added"]) ?? 0
                let addedGB = String(format: "%.1f GB", addedBytes / (1_024 * 1_024 * 1_024))
                    .replacingOccurrences(of: ".", with: ",")
                let snapshot = state["snapshot"] as? String
                return FridayBackupStatus(state: .succeeded(agoText: ago, addedText: addedGB, snapshot: snapshot))
            } else {
                let reason = state["reason"] as? String
                return FridayBackupStatus(state: .failed(agoText: ago, reason: reason))
            }
        }

        return FridayBackupStatus(state: .neverRun)
    }

    // MARK: - 4. Health Status (friday-doctor.state & friday-test.state)

    private func readHealthStatus(nowTimestamp: TimeInterval) -> FridayHealthStatus {
        let doctorURL = logsURL.appending(path: "friday-doctor.state")
        let doctor = Self.loadJSON(at: doctorURL) as? [String: Any] ?? [:]
        let keysDict = doctor["keys"] as? [String: String] ?? [:]

        let rawIssues = keysDict.values.sorted { lhs, rhs in
            let lhsFail = lhs.hasPrefix("FAIL")
            let rhsFail = rhs.hasPrefix("FAIL")
            if lhsFail != rhsFail { return lhsFail && !rhsFail }
            return lhs < rhs
        }

        let failCount = rawIssues.filter { $0.hasPrefix("FAIL") }.count
        let warnCount = rawIssues.count - failCount
        let cleanedIssues = rawIssues.map { line -> String in
            line.replacingOccurrences(
                of: #"^(FAIL|WARN)\s+\d+\s+"#,
                with: "",
                options: .regularExpression
            )
        }

        var doctorAgeText: String?
        if let attrs = try? FileManager.default.attributesOfItem(atPath: doctorURL.path),
           let mtime = attrs[.modificationDate] as? Date {
            doctorAgeText = "há \(Self.agoText(nowTimestamp - mtime.timeIntervalSince1970))"
        }

        let testURL = logsURL.appending(path: "friday-test.state")
        let test = Self.loadJSON(at: testURL) as? [String: Any] ?? [:]
        let testPassed: Bool? = test["result"].map { ($0 as? String) == "ok" }
        let testCount = Self.intValue(test["ran"]) ?? 0
        let testAgeText: String? = Self.doubleValue(test["at"]).map {
            "há \(Self.agoText(nowTimestamp - $0))"
        }

        return FridayHealthStatus(
            failCount: failCount,
            warnCount: warnCount,
            issues: cleanedIssues,
            doctorAgeText: doctorAgeText,
            testPassed: testPassed,
            testCount: testCount,
            testAgeText: testAgeText
        )
    }

    // MARK: - 5. Scheduled Jobs (LaunchAgents & launchctl)

    private func readScheduledJobs(nowTimestamp: TimeInterval, isBackupRunning: Bool) -> [FridayScheduledJob] {
        let loadedJobs = Self.launchctlJobs()
        let stateFiles: [String: URL] = [
            "com.gbz.friday-sync": logsURL.appending(path: "friday-sync.state"),
            "com.gbz.friday-backup": logsURL.appending(path: "friday-backup.state"),
            "com.gbz.friday-weekly": stateRootURL.appending(path: "friday-weekly/state.json")
        ]

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: launchAgentsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let plists = urls
            .filter { $0.lastPathComponent.hasPrefix("com.gbz.") && $0.pathExtension == "plist" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var jobs: [FridayScheduledJob] = []

        for plistURL in plists {
            guard let data = try? Data(contentsOf: plistURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                continue
            }

            let label = (plist["Label"] as? String) ?? plistURL.deletingPathExtension().lastPathComponent
            let title = Self.knownJobTitles[label] ?? label
            let schedule = Self.scheduleDescription(for: label, plist: plist)

            let launchInfo = loadedJobs[label]
            let pid = launchInfo?.pid ?? "-"
            let exitCode = launchInfo?.exitCode

            let stateDict = stateFiles[label].flatMap { Self.loadJSON(at: $0) as? [String: Any] } ?? [:]
            var result = stateDict["result"] as? String
            if label == "com.gbz.friday-weekly", stateDict["at"] != nil {
                let subjobs = stateDict["jobs"] as? [[String: Any]] ?? []
                result = subjobs.allSatisfy { (Self.intValue($0["exit"]) ?? -1) == 0 } ? "ok" : "fail"
            }

            let isRunning = (pid != "-" && !pid.isEmpty) || (label == "com.gbz.friday-backup" && isBackupRunning)
            let state: FridayScheduledJob.JobState
            if isRunning {
                state = .running
            } else if launchInfo == nil {
                state = .disabled
            } else if let exitCode, exitCode != "0", stateDict.isEmpty {
                state = .failed("saiu \(exitCode)")
            } else if stateDict["at"] != nil {
                state = (result == "ok") ? .ok : .failed("falhou")
            } else {
                state = .active
            }

            let lastRunText: String
            if let at = Self.doubleValue(stateDict["at"]) {
                lastRunText = "há \(Self.agoText(nowTimestamp - at))"
            } else {
                lastRunText = "—"
            }

            jobs.append(
                FridayScheduledJob(
                    label: label,
                    title: title,
                    schedule: schedule,
                    state: state,
                    lastRunText: lastRunText
                )
            )
        }

        return jobs
    }

    private static func scheduleDescription(for label: String, plist: [String: Any]) -> String {
        if label == "com.gbz.friday-weekly" {
            return "domingo de madrugada"
        }
        if (plist["KeepAlive"] as? Bool) == true || plist["KeepAlive"] is [String: Any] {
            return "sempre ligado"
        }
        if let cal = plist["StartCalendarInterval"] {
            let first: [String: Any]? = (cal as? [[String: Any]])?.first ?? (cal as? [String: Any])
            if let first {
                let hour = intValue(first["Hour"]) ?? 0
                let minute = intValue(first["Minute"]) ?? 0
                return String(format: "todo dia %02d:%02d", hour, minute)
            }
        }
        if let interval = intValue(plist["StartInterval"]) {
            if interval >= 3_600 {
                return "a cada \(interval / 3_600) h"
            }
            return "a cada \(max(1, interval / 60)) min"
        }
        return "ao entrar"
    }

    private static func launchctlJobs() -> [String: (pid: String, exitCode: String?)] {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            var result: [String: (pid: String, exitCode: String?)] = [:]

            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count == 3 else { continue }
                let label = String(parts[2])
                guard label.hasPrefix("com.gbz.") else { continue }
                result[label] = (pid: String(parts[0]), exitCode: String(parts[1]))
            }
            return result
        } catch {
            return [:]
        }
    }

    // MARK: - Helpers

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

    private static func loadJSON(at url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let int = raw as? Int { return int }
        if let number = raw as? NSNumber { return number.intValue }
        if let str = raw as? String, let int = Int(str) { return int }
        return nil
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        if let dbl = raw as? Double { return dbl }
        if let int = raw as? Int { return Double(int) }
        if let number = raw as? NSNumber { return number.doubleValue }
        if let str = raw as? String, let dbl = Double(str) { return dbl }
        return nil
    }

    static func agoText(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s) s" }
        if s < 3_600 { return "\(s / 60) min" }
        if s < 86_400 {
            return String(format: "%d h %02d", s / 3_600, (s % 3_600) / 60)
        }
        return "\(s / 86_400) d \((s % 86_400) / 3_600) h"
    }
}

// MARK: - Preview Data

nonisolated extension FridaySnapshot {
    static let previewData = FridaySnapshot(
        dailyUsage: FridayDailyUsage(
            day: "2026-11-10",
            generatedAt: "2026-11-10T16:30:00-03:00",
            novo: 142_000,
            cacheLido: 2_840_000,
            cacheGravado: 310_000,
            saida: 58_000,
            totalCostUSD: 4.85,
            projects: [
                FridayProjectUsage(
                    name: "Friday",
                    novo: 98_000,
                    cacheLido: 2_100_000,
                    cacheGravado: 210_000,
                    saida: 41_000,
                    costUSD: 3.40,
                    sessions: [
                        FridaySessionUsage(
                            name: "lead (codex)",
                            novo: 64_000,
                            cacheLido: 1_500_000,
                            cacheGravado: 120_000,
                            saida: 28_000,
                            chamadas: 18,
                            costUSD: nil
                        ),
                        FridaySessionUsage(
                            name: "friday (claude)",
                            novo: 34_000,
                            cacheLido: 600_000,
                            cacheGravado: 90_000,
                            saida: 13_000,
                            chamadas: 11,
                            costUSD: 3.40
                        )
                    ]
                ),
                FridayProjectUsage(
                    name: "ai-usage-menu",
                    novo: 44_000,
                    cacheLido: 740_000,
                    cacheGravado: 100_000,
                    saida: 17_000,
                    costUSD: 1.45,
                    sessions: [
                        FridaySessionUsage(
                            name: "dev (claude)",
                            novo: 44_000,
                            cacheLido: 740_000,
                            cacheGravado: 100_000,
                            saida: 17_000,
                            chamadas: 9,
                            costUSD: 1.45
                        )
                    ]
                )
            ]
        ),
        waitingItems: [
            FridayWaitingItem(
                id: "pending-lead",
                who: "lead",
                summary: "Travada esperando você",
                detail: "Aprovar plano de migração da v2 antes de rodar a fila.",
                ageText: "há 14 min",
                isExplicitStuck: true
            )
        ],
        closedMail: [
            FridayClosedMailItem(recipient: "reviewer", unreadCount: 2)
        ],
        backup: FridayBackupStatus(
            state: .succeeded(agoText: "há 2 h 15", addedText: "1,4 GB", snapshot: "a81f902c")
        ),
        health: FridayHealthStatus(
            failCount: 0,
            warnCount: 0,
            issues: [],
            doctorAgeText: "há 12 min",
            testPassed: true,
            testCount: 42,
            testAgeText: "há 1 h 05"
        ),
        scheduledJobs: [
            FridayScheduledJob(
                label: "com.gbz.friday-usage",
                title: "Consumo do Codex e do Claude",
                schedule: "a cada 30 min",
                state: .active,
                lastRunText: "—"
            ),
            FridayScheduledJob(
                label: "com.gbz.friday-backup",
                title: "Backup criptografado no Drive",
                schedule: "todo dia 03:00",
                state: .ok,
                lastRunText: "há 2 h 15"
            ),
            FridayScheduledJob(
                label: "com.gbz.friday-watch",
                title: "Vigia dos projetos",
                schedule: "a cada 5 min",
                state: .active,
                lastRunText: "—"
            )
        ]
    )
}
