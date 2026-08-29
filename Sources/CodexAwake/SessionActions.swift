import Foundation

enum SessionProfile: Equatable {
    case defaultProfile
    case named(String)

    var displayName: String {
        switch self {
        case .defaultProfile:
            return "Default (no --profile)"
        case let .named(name):
            return name
        }
    }

    var storedValue: String {
        switch self {
        case .defaultProfile:
            return "v1:default"
        case let .named(name):
            return "v1:named:\(name)"
        }
    }

    init?(storedValue: String) {
        if storedValue == "v1:default" {
            self = .defaultProfile
            return
        }

        let prefix = "v1:named:"
        guard storedValue.hasPrefix(prefix) else { return nil }
        let name = String(storedValue.dropFirst(prefix.count))
        guard !name.isEmpty else { return nil }
        self = .named(name)
    }
}

final class SessionProfileStore {
    private static let defaultsKey = "sessionProfiles"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func profile(for sessionID: String) -> SessionProfile? {
        guard let storedValue = storedProfiles()[sessionID] else { return nil }
        return SessionProfile(storedValue: storedValue)
    }

    func set(_ profile: SessionProfile, for sessionID: String) {
        var profiles = storedProfiles()
        profiles[sessionID] = profile.storedValue
        defaults.set(profiles, forKey: Self.defaultsKey)
    }

    private func storedProfiles() -> [String: String] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }
}

struct InteractiveCodexProcess: Equatable {
    let pid: Int
    let tty: String
    let command: String
    let sessionID: String?
    let profile: SessionProfile
}

enum CodexProcessInspector {
    private static let sessionIDPattern = try? NSRegularExpression(
        pattern: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#,
        options: [.caseInsensitive]
    )

    static func liveProcesses() -> [InteractiveCodexProcess] {
        let result = CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,tty=,command="]
        )
        guard result.terminationStatus == 0 else { return [] }
        return parse(processList: result.standardOutput)
    }

    static func parse(processList: String) -> [InteractiveCodexProcess] {
        processList.split(separator: "\n").compactMap { row in
            let fields = row.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3,
                  let pid = Int(fields[0]) else {
                return nil
            }

            let tty = String(fields[1])
            let command = String(fields[2])
            guard isInteractiveCodexProcess(tty: tty, command: command) else {
                return nil
            }

            return InteractiveCodexProcess(
                pid: pid,
                tty: tty,
                command: command,
                sessionID: sessionID(in: command),
                profile: profile(in: command)
            )
        }
    }

    static func resolvedProfiles(
        activeSessionIDs: [String],
        processes: [InteractiveCodexProcess]
    ) -> [String: SessionProfile] {
        let activeIDs = Set(activeSessionIDs)
        var result: [String: SessionProfile] = [:]
        var anonymousProfiles: [SessionProfile] = []

        for process in processes {
            if let sessionID = process.sessionID, activeIDs.contains(sessionID) {
                result[sessionID] = process.profile
            } else if process.sessionID == nil {
                anonymousProfiles.append(process.profile)
            }
        }

        let unresolvedIDs = activeSessionIDs.filter { result[$0] == nil }
        guard !unresolvedIDs.isEmpty,
              unresolvedIDs.count == anonymousProfiles.count else {
            return result
        }

        if unresolvedIDs.count == 1, let profile = anonymousProfiles.first {
            result[unresolvedIDs[0]] = profile
            return result
        }

        guard let sharedProfile = anonymousProfiles.first,
              anonymousProfiles.allSatisfy({ $0 == sharedProfile }) else {
            return result
        }
        for sessionID in unresolvedIDs {
            result[sessionID] = sharedProfile
        }
        return result
    }

    private static func isInteractiveCodexProcess(tty: String, command: String) -> Bool {
        guard let executable = command.split(whereSeparator: { $0.isWhitespace }).first else {
            return false
        }

        let executableName = URL(fileURLWithPath: String(executable)).lastPathComponent
        guard executableName == "codex" else { return false }

        let lowercased = command.lowercased()
        let excludedFragments = [
            "/applications/chatgpt.app/contents/resources/codex",
            " app-server",
            " remote-control",
            " codex-code-mode-host",
            " mcp-server",
            " completion",
            " sandbox",
            " review",
            " exec"
        ]
        guard !excludedFragments.contains(where: lowercased.contains) else { return false }

        let hasInteractiveTTY = tty != "??" && tty != "?" && tty != "-"
        let isRemoteTUI = lowercased.contains("--remote") && lowercased.contains("unix://")
        return hasInteractiveTTY || isRemoteTUI
    }

    private static func profile(in command: String) -> SessionProfile {
        let arguments = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for (index, argument) in arguments.enumerated() {
            if (argument == "--profile" || argument == "-p"),
               arguments.indices.contains(index + 1) {
                return .named(arguments[index + 1])
            }
            if argument.hasPrefix("--profile=") {
                let name = String(argument.dropFirst("--profile=".count))
                if !name.isEmpty { return .named(name) }
            }
            if argument.hasPrefix("-p=") {
                let name = String(argument.dropFirst("-p=".count))
                if !name.isEmpty { return .named(name) }
            }
        }
        return .defaultProfile
    }

    private static func sessionID(in command: String) -> String? {
        guard let expression = sessionIDPattern else { return nil }
        let range = NSRange(command.startIndex..<command.endIndex, in: command)
        guard let match = expression.firstMatch(in: command, range: range),
              let matchRange = Range(match.range, in: command) else {
            return nil
        }
        return String(command[matchRange]).lowercased()
    }
}

enum SessionTerminalAction: String {
    case resume
    case fork
}

enum CodexSessionCommand {
    static func arguments(
        action: SessionTerminalAction,
        sessionID: String,
        profile: SessionProfile
    ) -> [String] {
        var arguments = ["--remote", "unix://"]
        if case let .named(name) = profile {
            arguments += ["--profile", name]
        }
        arguments += [action.rawValue, sessionID]
        return arguments
    }

    static func terminalScript(
        executablePath: String,
        arguments: [String],
        workingDirectory: String
    ) -> String {
        let command = ([executablePath] + arguments)
            .map(shellQuote)
            .joined(separator: " ")
        return "cd -- \(shellQuote(workingDirectory)) && exec \(command)"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

enum TerminalLauncher {
    static func launch(script: String) -> CommandResult {
        let appleScript = """
        tell application "Terminal"
            activate
            do script \(appleScriptString(script))
        end tell
        """
        return CommandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", appleScript]
        )
    }

    private static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
}
