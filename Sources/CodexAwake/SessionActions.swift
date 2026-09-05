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
    let workingDirectory: String?
    let sessionID: String?
    let profile: SessionProfile

    init(
        pid: Int,
        tty: String,
        command: String,
        workingDirectory: String? = nil,
        sessionID: String?,
        profile: SessionProfile
    ) {
        self.pid = pid
        self.tty = tty
        self.command = command
        self.workingDirectory = workingDirectory
        self.sessionID = sessionID
        self.profile = profile
    }

    func withWorkingDirectory(_ workingDirectory: String?) -> InteractiveCodexProcess {
        InteractiveCodexProcess(
            pid: pid,
            tty: tty,
            command: command,
            workingDirectory: workingDirectory,
            sessionID: sessionID,
            profile: profile
        )
    }
}

enum CodexProcessInspector {
    private static let sessionIDPattern = try? NSRegularExpression(
        pattern: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#,
        options: [.caseInsensitive]
    )

    static func liveProcesses(includeWorkingDirectories: Bool = false) -> [InteractiveCodexProcess] {
        let result = CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,tty=,command="]
        )
        guard result.terminationStatus == 0 else { return [] }
        let processes = parse(processList: result.standardOutput)
        guard includeWorkingDirectories, !processes.isEmpty else { return processes }

        let directories = workingDirectories(for: processes.map(\.pid))
        return processes.map { process in
            process.withWorkingDirectory(directories[process.pid])
        }
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

    static func resolvedProcesses(
        activeSessionIDs: [String],
        processes: [InteractiveCodexProcess]
    ) -> [String: InteractiveCodexProcess] {
        let activeIDs = Set(activeSessionIDs)
        var result: [String: InteractiveCodexProcess] = [:]

        for process in processes {
            guard let sessionID = process.sessionID,
                  activeIDs.contains(sessionID),
                  result[sessionID] == nil else {
                continue
            }
            result[sessionID] = process
        }

        let unresolvedIDs = activeSessionIDs.filter { result[$0] == nil }
        let anonymousProcesses = processes.filter { $0.sessionID == nil }
        guard unresolvedIDs.count == 1,
              anonymousProcesses.count == 1,
              let sessionID = unresolvedIDs.first,
              let process = anonymousProcesses.first else {
            return result
        }

        result[sessionID] = process
        return result
    }

    static func resolvedSessionProcesses(
        sessions: [CodexSession],
        processes: [InteractiveCodexProcess]
    ) -> [String: InteractiveCodexProcess] {
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let sessionsByRecency = sessions.sorted {
            if $0.recencyAt == $1.recencyAt { return $0.id > $1.id }
            return $0.recencyAt > $1.recencyAt
        }
        var unresolvedSessionIDs = Set(sessions.map(\.id))
        var resolved: [String: InteractiveCodexProcess] = [:]
        var assignedProcessIDs = Set<Int>()

        for process in processes {
            guard let sessionID = process.sessionID,
                  sessionsByID[sessionID] != nil,
                  unresolvedSessionIDs.contains(sessionID) else {
                continue
            }
            resolved[sessionID] = process
            unresolvedSessionIDs.remove(sessionID)
            assignedProcessIDs.insert(process.pid)
        }

        for process in processes where process.sessionID == nil {
            guard let processDirectory = process.workingDirectory else { continue }
            let normalizedProcessDirectory = normalizedPath(processDirectory)
            guard let session = sessionsByRecency.first(where: {
                unresolvedSessionIDs.contains($0.id)
                    && normalizedPath($0.cwd) == normalizedProcessDirectory
            }) else {
                continue
            }
            resolved[session.id] = process
            unresolvedSessionIDs.remove(session.id)
            assignedProcessIDs.insert(process.pid)
        }

        let remainingSessions = sessionsByRecency.filter { unresolvedSessionIDs.contains($0.id) }
        let remainingProcesses = processes.filter {
            $0.sessionID == nil && !assignedProcessIDs.contains($0.pid)
        }
        if remainingSessions.count == 1,
           remainingProcesses.count == 1,
           let session = remainingSessions.first,
           let process = remainingProcesses.first,
           process.workingDirectory == nil {
            resolved[session.id] = process
        }

        return resolved
    }

    static func parseWorkingDirectories(output: String) -> [Int: String] {
        var currentPID: Int?
        var result: [Int: String] = [:]

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())
            switch marker {
            case "p":
                currentPID = Int(value)
            case "n":
                if let currentPID, !value.isEmpty {
                    result[currentPID] = value
                }
            default:
                continue
            }
        }
        return result
    }

    private static func workingDirectories(for processIDs: [Int]) -> [Int: String] {
        guard !processIDs.isEmpty else { return [:] }
        let result = CommandRunner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: [
                "-nP", "-a", "-d", "cwd", "-F", "pn", "-p",
                processIDs.map(String.init).joined(separator: ",")
            ]
        )
        return parseWorkingDirectories(output: result.standardOutput)
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
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

enum SessionTerminalAction {
    case resume
    case rejoin
    case fork

    var commandName: String {
        switch self {
        case .resume, .rejoin:
            return "resume"
        case .fork:
            return "fork"
        }
    }

    var confirmationTitle: String {
        switch self {
        case .resume:
            return "Resume"
        case .rejoin:
            return "Rejoin"
        case .fork:
            return "Fork"
        }
    }

    func launchTerminal(rejoinTerminal: TerminalProgram) -> TerminalProgram {
        switch self {
        case .rejoin:
            return rejoinTerminal
        case .resume, .fork:
            return .appleTerminal
        }
    }
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
        arguments += [action.commandName, sessionID]
        return arguments
    }

    static func terminalScript(
        executablePath: String,
        arguments: [String],
        workingDirectory: String
    ) -> String {
        let command = ([executablePath] + arguments)
            .map(ShellEscaping.singleQuoted)
            .joined(separator: " ")
        return "cd -- \(ShellEscaping.singleQuoted(workingDirectory)) && exec \(command)"
    }
}

enum ShellEscaping {
    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

enum TerminalProgram: String, CaseIterable, Hashable {
    case ghostty
    case appleTerminal
    case iTerm2
    case unknown

    static let selectablePrograms: [TerminalProgram] = [.ghostty, .appleTerminal, .iTerm2]

    var displayName: String {
        switch self {
        case .ghostty:
            return "Ghostty"
        case .appleTerminal:
            return "Terminal"
        case .iTerm2:
            return "iTerm2"
        case .unknown:
            return "Unknown Terminal"
        }
    }

    var selectionTag: Int {
        switch self {
        case .ghostty:
            return 0
        case .appleTerminal:
            return 1
        case .iTerm2:
            return 2
        case .unknown:
            return -1
        }
    }

    init?(selectionTag: Int) {
        guard let program = Self.selectablePrograms.first(where: { $0.selectionTag == selectionTag }) else {
            return nil
        }
        self = program
    }

    static func detect(in processEnvironment: String) -> TerminalProgram {
        if processEnvironment.contains("TERM_PROGRAM=ghostty") {
            return .ghostty
        }
        if processEnvironment.contains("TERM_PROGRAM=Apple_Terminal") {
            return .appleTerminal
        }
        if processEnvironment.contains("TERM_PROGRAM=iTerm.app") {
            return .iTerm2
        }
        return .unknown
    }
}

final class RejoinTerminalStore {
    private static let defaultsKey = "rejoinTerminal"
    private let defaults: UserDefaults
    private let defaultProgram: TerminalProgram

    init(
        defaults: UserDefaults = .standard,
        defaultProgram: TerminalProgram = .appleTerminal
    ) {
        self.defaults = defaults
        self.defaultProgram = defaultProgram
    }

    var program: TerminalProgram {
        guard let storedValue = defaults.string(forKey: Self.defaultsKey),
              let storedProgram = TerminalProgram(rawValue: storedValue),
              TerminalProgram.selectablePrograms.contains(storedProgram) else {
            return defaultProgram
        }
        return storedProgram
    }

    func set(_ program: TerminalProgram) {
        guard TerminalProgram.selectablePrograms.contains(program) else { return }
        defaults.set(program.rawValue, forKey: Self.defaultsKey)
    }
}

enum TerminalFocusOutcome: Equatable {
    case focused
    case surfaceUnavailable(String)
    case failed(String)
}

enum TerminalSessionFocuser {
    private static let appleTerminalSurfaceUnavailableMessage =
        "The Terminal tab for this Codex session is no longer open."
    private static let ghosttySurfaceUnavailableMessage =
        "The Ghostty surface for this Codex session is no longer open."
    private static let iTermSurfaceUnavailableMessage =
        "The iTerm2 session for this Codex session is no longer open."

    typealias Runner = (URL, [String]) -> CommandResult
    typealias TerminalWriter = (String, String) -> String?

    static func focus(
        process: InteractiveCodexProcess,
        sessionID: String,
        sessionName: String,
        runner: Runner = CommandRunner.run,
        terminalWriter: TerminalWriter = writeToTerminal
    ) -> TerminalFocusOutcome {
        guard let ttyPath = ttyDevicePath(process.tty) else {
            return .failed("The active Codex process does not have a valid TTY.")
        }

        let environment = runner(
            URL(fileURLWithPath: "/bin/ps"),
            ["eww", "-p", String(process.pid), "-o", "command="]
        )
        guard environment.terminationStatus == 0 else {
            return .failed(
                environment.combinedOutput.isEmpty
                    ? "The terminal app for this Codex process could not be identified."
                    : environment.combinedOutput
            )
        }

        switch TerminalProgram.detect(in: environment.standardOutput) {
        case .ghostty:
            return classify(
                focusGhostty(
                    ttyPath: ttyPath,
                    sessionID: sessionID,
                    sessionName: sessionName,
                    runner: runner,
                    terminalWriter: terminalWriter
                ),
                surfaceUnavailableMessage: ghosttySurfaceUnavailableMessage
            )
        case .appleTerminal:
            return classify(
                runner(
                    URL(fileURLWithPath: "/usr/bin/osascript"),
                    ["-e", appleTerminalFocusScript(ttyPath: ttyPath)]
                ),
                surfaceUnavailableMessage: appleTerminalSurfaceUnavailableMessage
            )
        case .iTerm2:
            return classify(
                runner(
                    URL(fileURLWithPath: "/usr/bin/osascript"),
                    ["-e", iTermFocusScript(ttyPath: ttyPath)]
                ),
                surfaceUnavailableMessage: iTermSurfaceUnavailableMessage
            )
        case .unknown:
            return .failed("The active session's terminal app is not supported yet.")
        }
    }

    static func appleTerminalFocusScript(ttyPath: String) -> String {
        let tty = AppleScriptEscaping.stringLiteral(ttyPath)
        return """
        tell application "Terminal"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    if tty of terminalTab is \(tty) then
                        set selected tab of terminalWindow to terminalTab
                        set index of terminalWindow to 1
                        activate
                        return "focused"
                    end if
                end repeat
            end repeat
            error "(appleTerminalSurfaceUnavailableMessage)" number 1
        end tell
        """
    }

    static func ghosttyFocusScript(marker: String) -> String {
        let title = AppleScriptEscaping.stringLiteral(marker)
        return """
        tell application "Ghostty"
            repeat 20 times
                set matches to every terminal whose name is \(title)
                if (count of matches) is 1 then
                    focus item 1 of matches
                    return "focused"
                end if
                delay 0.025
            end repeat
            error "(ghosttySurfaceUnavailableMessage)" number 1
        end tell
        """
    }

    static func iTermFocusScript(ttyPath: String) -> String {
        let tty = AppleScriptEscaping.stringLiteral(ttyPath)
        return """
        tell application "iTerm2"
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    repeat with terminalSession in sessions of terminalTab
                        if tty of terminalSession is \(tty) then
                            select terminalTab
                            select terminalSession
                            activate
                            return "focused"
                        end if
                    end repeat
                end repeat
            end repeat
            error "(iTermSurfaceUnavailableMessage)" number 1
        end tell
        """
    }

    static func titleProbeSequence(marker: String) -> String {
        let safeMarker = marker.unicodeScalars.filter { scalar in
            scalar.value != 0x07 && scalar.value != 0x1B
        }
        return "\u{1B}[22;2t\u{1B}]2;\(String(String.UnicodeScalarView(safeMarker)))\u{07}"
    }

    static let restoreTitleSequence = "\u{1B}[23;2t"

    private static func focusGhostty(
        ttyPath: String,
        sessionID: String,
        sessionName: String,
        runner: Runner,
        terminalWriter: TerminalWriter
    ) -> CommandResult {
        let compactName = sessionName
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .prefix(48)
        let marker = "Codex Awake · \(compactName) · \(sessionID.prefix(8)) · \(UUID().uuidString)"

        if let error = terminalWriter(ttyPath, titleProbeSequence(marker: marker)) {
            return commandFailure("Ghostty could not be addressed through \(ttyPath): \(error)")
        }
        defer { _ = terminalWriter(ttyPath, restoreTitleSequence) }

        return runner(
            URL(fileURLWithPath: "/usr/bin/osascript"),
            ["-e", ghosttyFocusScript(marker: marker)]
        )
    }

    private static func classify(
        _ result: CommandResult,
        surfaceUnavailableMessage: String
    ) -> TerminalFocusOutcome {
        guard result.terminationStatus != 0 else { return .focused }

        let message = result.combinedOutput.isEmpty
            ? "The terminal for this Codex session could not be focused."
            : result.combinedOutput
        if message.contains(surfaceUnavailableMessage) {
            return .surfaceUnavailable(message)
        }
        return .failed(message)
    }

    private static func ttyDevicePath(_ tty: String) -> String? {
        let name = tty.hasPrefix("/dev/") ? String(tty.dropFirst("/dev/".count)) : tty
        guard name.hasPrefix("tty"),
              !name.isEmpty,
              name.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "_" || $0 == "-"
              }) else {
            return nil
        }
        return "/dev/\(name)"
    }

    private static func writeToTerminal(path: String, sequence: String) -> String? {
        guard let data = sequence.data(using: .utf8),
              let handle = FileHandle(forWritingAtPath: path) else {
            return "the TTY could not be opened"
        }
        do {
            try handle.write(contentsOf: data)
            try handle.close()
            return nil
        } catch {
            try? handle.close()
            return error.localizedDescription
        }
    }

    private static func commandFailure(_ message: String) -> CommandResult {
        CommandResult(
            terminationStatus: 1,
            standardOutput: "",
            standardError: message
        )
    }
}

enum AppleScriptEscaping {
    static func stringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
}

enum TerminalLauncher {
    static func launch(script: String, terminal: TerminalProgram) -> CommandResult {
        let appleScript: String
        switch terminal {
        case .ghostty:
            appleScript = ghosttyLaunchScript(script: script)
        case .appleTerminal:
            appleScript = appleTerminalLaunchScript(script: script)
        case .iTerm2:
            appleScript = iTermLaunchScript(script: script)
        case .unknown:
            return CommandResult(
                terminationStatus: 1,
                standardOutput: "",
                standardError: "Choose a supported default terminal for Rejoin."
            )
        }

        return CommandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", appleScript]
        )
    }

    static func appleTerminalLaunchScript(script: String) -> String {
        """
        tell application "Terminal"
            activate
            do script \(AppleScriptEscaping.stringLiteral(script))
        end tell
        """
    }

    static func ghosttyLaunchScript(script: String) -> String {
        let command = AppleScriptEscaping.stringLiteral(ghosttyCommand(script: script))
        return """
        tell application "Ghostty"
            set launchConfiguration to new surface configuration from {command:\(command), wait after command:true}
            if (count of windows) is 0 then
                set launchWindow to new window with configuration launchConfiguration
            else
                set launchWindow to front window
                set launchTab to new tab in launchWindow with configuration launchConfiguration
                select tab launchTab
            end if
            activate window launchWindow
            return "launched"
        end tell
        """
    }

    static func ghosttyCommand(script: String) -> String {
        "/bin/zsh -lc \(ShellEscaping.singleQuoted(script))"
    }

    static func iTermLaunchScript(script: String) -> String {
        let command = AppleScriptEscaping.stringLiteral(script)
        return """
        tell application "iTerm2"
            activate
            if (count of windows) is 0 then
                create window with default profile command \(command)
            else
                tell current window to create tab with default profile command \(command)
            end if
            return "launched"
        end tell
        """
    }
}
