import Foundation

enum RemoteConnectionState: String, Codable {
    case checking
    case disabled
    case connecting
    case connected
    case errored
    case unavailable
}

struct RemoteStatus: Codable {
    let state: RemoteConnectionState
    let serverName: String?
    let environmentID: String?
    let detail: String?
    let configuredEnabled: Bool

    static let checking = RemoteStatus(
        state: .checking,
        serverName: nil,
        environmentID: nil,
        detail: nil,
        configuredEnabled: true
    )
}

struct CodexSession: Codable {
    let id: String
    let displayName: String
    let cwd: String
    let recencyAt: Int64

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case cwd
        case recencyAt = "recency_at"
    }
}

private struct RemoteStartResponse: Decodable {
    let status: String
    let serverName: String?
    let environmentId: String?
    let timedOut: Bool?
}

private struct CommandResult {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String

    var combinedOutput: String {
        [standardOutput, standardError]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

private enum CommandRunner {
    static func run(executable: URL, arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            return CommandResult(
                terminationStatus: -1,
                standardOutput: "",
                standardError: error.localizedDescription
            )
        }

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(
            terminationStatus: process.terminationStatus,
            standardOutput: String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            standardError: String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}

enum CodexRemoteBridge {
    private static let fileManager = FileManager.default

    private static var codexBinary: URL? {
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/codex"),
            home.appendingPathComponent(".codex/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex")
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static var stateDatabaseURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite")
    }

    static func ensureRemoteStarted() -> RemoteStatus {
        guard let codexBinary else {
            return RemoteStatus(
                state: .unavailable,
                serverName: nil,
                environmentID: nil,
                detail: "Codex CLI was not found",
                configuredEnabled: true
            )
        }

        let result = CommandRunner.run(
            executable: codexBinary,
            arguments: ["remote-control", "start", "--json"]
        )

        if let data = result.standardOutput.data(using: .utf8),
           let response = try? JSONDecoder().decode(RemoteStartResponse.self, from: data),
           let state = RemoteConnectionState(rawValue: response.status) {
            let detail = response.timedOut == true ? "Connection timed out" : nil
            return RemoteStatus(
                state: state,
                serverName: response.serverName,
                environmentID: response.environmentId,
                detail: detail,
                configuredEnabled: true
            )
        }

        return RemoteStatus(
            state: .errored,
            serverName: nil,
            environmentID: nil,
            detail: friendlyRemoteError(result.combinedOutput),
            configuredEnabled: true
        )
    }

    static func recentSessions(limit: Int = 6) -> [CodexSession] {
        guard fileManager.fileExists(atPath: stateDatabaseURL.path) else { return [] }

        let safeLimit = min(max(limit, 1), 20)
        let query = """
        SELECT
            id,
            CASE
                WHEN trim(COALESCE(name, '')) <> '' THEN substr(replace(replace(name, char(10), ' '), char(13), ' '), 1, 80)
                WHEN trim(COALESCE(title, '')) <> '' THEN substr(replace(replace(title, char(10), ' '), char(13), ' '), 1, 80)
                WHEN trim(COALESCE(preview, '')) <> '' THEN substr(replace(replace(preview, char(10), ' '), char(13), ' '), 1, 80)
                ELSE substr(id, 1, 8)
            END AS display_name,
            cwd,
            CASE WHEN recency_at > 0 THEN recency_at ELSE updated_at END AS recency_at
        FROM threads
        WHERE archived = 0
          AND source = 'cli'
          AND (
              trim(COALESCE(name, '')) <> ''
              OR trim(COALESCE(title, '')) <> ''
              OR trim(COALESCE(preview, '')) <> ''
          )
        ORDER BY recency_at DESC, id DESC
        LIMIT \(safeLimit);
        """

        let result = CommandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: ["-readonly", "-json", stateDatabaseURL.path, query]
        )
        guard result.terminationStatus == 0,
              let data = result.standardOutput.data(using: .utf8),
              let sessions = try? JSONDecoder().decode([CodexSession].self, from: data) else {
            return []
        }
        return sessions
    }

    static func activeSessions(limit: Int = 6) -> [CodexSession] {
        guard fileManager.fileExists(atPath: stateDatabaseURL.path) else { return [] }

        let threadIDs = activeThreadIDs()
        guard !threadIDs.isEmpty else { return [] }

        let safeLimit = min(max(limit, 1), 20)
        let quotedIDs = threadIDs.map { "'\($0)'" }.joined(separator: ",")
        let query = """
        SELECT
            id,
            CASE
                WHEN trim(COALESCE(name, '')) <> '' THEN substr(replace(replace(name, char(10), ' '), char(13), ' '), 1, 80)
                WHEN trim(COALESCE(title, '')) <> '' THEN substr(replace(replace(title, char(10), ' '), char(13), ' '), 1, 80)
                WHEN trim(COALESCE(preview, '')) <> '' THEN substr(replace(replace(preview, char(10), ' '), char(13), ' '), 1, 80)
                ELSE substr(id, 1, 8)
            END AS display_name,
            cwd,
            CASE WHEN recency_at > 0 THEN recency_at ELSE updated_at END AS recency_at
        FROM threads
        WHERE id IN (\(quotedIDs))
          AND archived = 0
          AND COALESCE(thread_source, 'user') = 'user'
          AND trim(COALESCE(agent_role, '')) = ''
        ORDER BY recency_at DESC, id DESC
        LIMIT \(safeLimit);
        """

        let result = CommandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: ["-readonly", "-json", stateDatabaseURL.path, query]
        )
        guard result.terminationStatus == 0,
              let data = result.standardOutput.data(using: .utf8),
              let sessions = try? JSONDecoder().decode([CodexSession].self, from: data) else {
            return []
        }
        return sessions
    }

    private static func activeThreadIDs() -> [String] {
        let processList = CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,command="]
        )
        guard processList.terminationStatus == 0 else { return [] }

        let appServerPIDs = processList.standardOutput
            .split(separator: "\n")
            .compactMap { row -> Int? in
                let fields = row.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
                guard fields.count == 2,
                      let pid = Int(fields[0]) else {
                    return nil
                }
                let command = String(fields[1])
                guard command.contains(" app-server "),
                      command.contains("--listen unix://") else {
                    return nil
                }
                return pid
            }

        let pattern = #"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }

        var threadIDs = Set<String>()
        for pid in appServerPIDs {
            let openFiles = CommandRunner.run(
                executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
                arguments: ["-nP", "-p", String(pid)]
            )
            guard openFiles.terminationStatus == 0 else { continue }

            let output = openFiles.standardOutput
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            for match in expression.matches(in: output, range: range) {
                guard let captureRange = Range(match.range(at: 1), in: output) else { continue }
                threadIDs.insert(String(output[captureRange]))
            }
        }

        return threadIDs.sorted()
    }

    private static func friendlyRemoteError(_ output: String) -> String {
        let lowercased = output.lowercased()
        if lowercased.contains("already online") || lowercased.contains("another app") {
            return "Another app owns Remote Control"
        }
        if lowercased.contains("connection is errored") {
            if chatGPTDesktopIsRunning() {
                return "Connection failed; ChatGPT Desktop may own Remote"
            }
            return "Remote connection failed"
        }
        if lowercased.contains("operation not permitted") {
            return "Permission denied while contacting Codex"
        }

        let firstLine = output
            .split(separator: "\n")
            .map(String.init)
            .first { !$0.hasPrefix("WARNING:") && !$0.isEmpty }
        return firstLine ?? "Remote Control command failed"
    }

    private static func chatGPTDesktopIsRunning() -> Bool {
        let result = CommandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/pgrep"),
            arguments: ["-f", "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"]
        )
        return result.terminationStatus == 0
    }
}
