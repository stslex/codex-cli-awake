import XCTest
@testable import CodexAwake

final class SessionActionsTests: XCTestCase {
    func testProcessParserCapturesExplicitProfileAndSessionID() {
        let sessionID = "01a04c8f-1234-5678-9abc-123456789abc"
        let processList = """
          100 ttys001 /Users/test/.local/bin/codex --remote unix:// --profile workeeper resume \(sessionID)
          101 ?? /Users/test/.local/bin/codex app-server --listen unix://
        """

        let processes = CodexProcessInspector.parse(processList: processList)

        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(processes[0].sessionID, sessionID)
        XCTAssertEqual(processes[0].profile, .named("workeeper"))
    }

    func testProcessParserTreatsMissingProfileAsExplicitDefaultChoice() {
        let processList = "200 ttys002 /opt/homebrew/bin/codex --remote unix:// resume"

        let processes = CodexProcessInspector.parse(processList: processList)

        XCTAssertEqual(processes.map(\.profile), [.defaultProfile])
    }

    func testProcessParserCapturesShortProfileFlag() {
        let processList = "201 ttys002 /opt/homebrew/bin/codex --remote unix:// -p personal resume"

        let processes = CodexProcessInspector.parse(processList: processList)

        XCTAssertEqual(processes.map(\.profile), [.named("personal")])
    }

    func testWorkingDirectoryParserAssociatesEachLsofPathWithItsPID() {
        let output = """
        p100
        fcwd
        n/Users/test/first
        p200
        fcwd
        n/Users/test/second
        """

        XCTAssertEqual(
            CodexProcessInspector.parseWorkingDirectories(output: output),
            [100: "/Users/test/first", 200: "/Users/test/second"]
        )
    }

    func testProfileResolutionCombinesExplicitAndSingleAnonymousProcesses() {
        let explicitID = "01a04c8f-1234-5678-9abc-123456789abc"
        let anonymousID = "01a0490f-1234-5678-9abc-123456789abc"
        let processes = [
            InteractiveCodexProcess(
                pid: 100,
                tty: "ttys001",
                command: "codex --profile workeeper resume \(explicitID)",
                sessionID: explicitID,
                profile: .named("workeeper")
            ),
            InteractiveCodexProcess(
                pid: 101,
                tty: "ttys002",
                command: "codex --profile workeeper resume",
                sessionID: nil,
                profile: .named("workeeper")
            )
        ]

        let resolved = CodexProcessInspector.resolvedProfiles(
            activeSessionIDs: [explicitID, anonymousID],
            processes: processes
        )

        XCTAssertEqual(resolved[explicitID], .named("workeeper"))
        XCTAssertEqual(resolved[anonymousID], .named("workeeper"))
    }

    func testAmbiguousAnonymousProfilesAreNotGuessed() {
        let firstID = "01a04c8f-1234-5678-9abc-123456789abc"
        let secondID = "01a0490f-1234-5678-9abc-123456789abc"
        let processes = [
            InteractiveCodexProcess(pid: 1, tty: "ttys001", command: "codex", sessionID: nil, profile: .named("one")),
            InteractiveCodexProcess(pid: 2, tty: "ttys002", command: "codex", sessionID: nil, profile: .named("two"))
        ]

        let resolved = CodexProcessInspector.resolvedProfiles(
            activeSessionIDs: [firstID, secondID],
            processes: processes
        )

        XCTAssertTrue(resolved.isEmpty)
    }

    func testProcessResolutionMatchesExplicitSessionID() {
        let sessionID = "01a04c8f-1234-5678-9abc-123456789abc"
        let process = InteractiveCodexProcess(
            pid: 100,
            tty: "ttys001",
            command: "codex resume \(sessionID)",
            sessionID: sessionID,
            profile: .named("workeeper")
        )

        let resolved = CodexProcessInspector.resolvedProcesses(
            activeSessionIDs: [sessionID],
            processes: [process]
        )

        XCTAssertEqual(resolved[sessionID], process)
    }

    func testProcessResolutionMatchesOnlyRemainingAnonymousProcess() {
        let explicitID = "01a04c8f-1234-5678-9abc-123456789abc"
        let anonymousID = "01a0490f-1234-5678-9abc-123456789abc"
        let explicit = InteractiveCodexProcess(
            pid: 100,
            tty: "ttys001",
            command: "codex resume \(explicitID)",
            sessionID: explicitID,
            profile: .named("workeeper")
        )
        let anonymous = InteractiveCodexProcess(
            pid: 101,
            tty: "ttys002",
            command: "codex resume",
            sessionID: nil,
            profile: .named("workeeper")
        )

        let resolved = CodexProcessInspector.resolvedProcesses(
            activeSessionIDs: [explicitID, anonymousID],
            processes: [anonymous, explicit]
        )

        XCTAssertEqual(resolved[explicitID], explicit)
        XCTAssertEqual(resolved[anonymousID], anonymous)
    }

    func testProcessResolutionDoesNotGuessBetweenAnonymousProcesses() {
        let processes = [
            InteractiveCodexProcess(pid: 1, tty: "ttys001", command: "codex", sessionID: nil, profile: .defaultProfile),
            InteractiveCodexProcess(pid: 2, tty: "ttys002", command: "codex", sessionID: nil, profile: .defaultProfile)
        ]

        let resolved = CodexProcessInspector.resolvedProcesses(
            activeSessionIDs: ["one", "two"],
            processes: processes
        )

        XCTAssertTrue(resolved.isEmpty)
    }

    func testSessionProcessResolutionUsesCwdAndKeepsOlderLoadedThreadInactive() {
        let sessions = [
            CodexSession(id: "new-shared", displayName: "New", cwd: "/projects/shared", recencyAt: 30),
            CodexSession(id: "other", displayName: "Other", cwd: "/projects/other", recencyAt: 20),
            CodexSession(id: "old-shared", displayName: "Old", cwd: "/projects/shared", recencyAt: 10)
        ]
        let processes = [
            InteractiveCodexProcess(
                pid: 100,
                tty: "ttys001",
                command: "codex",
                workingDirectory: "/projects/shared",
                sessionID: nil,
                profile: .defaultProfile
            ),
            InteractiveCodexProcess(
                pid: 200,
                tty: "ttys002",
                command: "codex",
                workingDirectory: "/projects/other",
                sessionID: nil,
                profile: .named("workeeper")
            )
        ]

        let resolved = CodexProcessInspector.resolvedSessionProcesses(
            sessions: sessions,
            processes: processes
        )

        XCTAssertEqual(Set(resolved.keys), ["new-shared", "other"])
        XCTAssertEqual(resolved["new-shared"]?.pid, 100)
        XCTAssertEqual(resolved["other"]?.pid, 200)
        XCTAssertNil(resolved["old-shared"])
    }

    func testResumeArgumentsPreserveNamedProfile() {
        let arguments = CodexSessionCommand.arguments(
            action: .resume,
            sessionID: "thread-id",
            profile: .named("workeeper")
        )

        XCTAssertEqual(
            arguments,
            ["--remote", "unix://", "--profile", "workeeper", "resume", "thread-id"]
        )
    }

    func testDefaultProfileOmitsProfileFlag() {
        let arguments = CodexSessionCommand.arguments(
            action: .fork,
            sessionID: "thread-id",
            profile: .defaultProfile
        )

        XCTAssertEqual(arguments, ["--remote", "unix://", "fork", "thread-id"])
    }

    func testRejoinUsesSharedAppServerResumeCommand() {
        let arguments = CodexSessionCommand.arguments(
            action: .rejoin,
            sessionID: "thread-id",
            profile: .named("workeeper")
        )

        XCTAssertEqual(
            arguments,
            ["--remote", "unix://", "--profile", "workeeper", "resume", "thread-id"]
        )
        XCTAssertEqual(SessionTerminalAction.rejoin.confirmationTitle, "Rejoin")
        XCTAssertEqual(
            SessionTerminalAction.rejoin.launchTerminal(rejoinTerminal: .ghostty),
            .ghostty
        )
        XCTAssertEqual(
            SessionTerminalAction.resume.launchTerminal(rejoinTerminal: .ghostty),
            .appleTerminal
        )
        XCTAssertEqual(
            SessionTerminalAction.fork.launchTerminal(rejoinTerminal: .iTerm2),
            .appleTerminal
        )
    }

    func testTerminalScriptQuotesEveryShellArgument() {
        let script = CodexSessionCommand.terminalScript(
            executablePath: "/Users/test/bin/codex",
            arguments: ["--profile", "team's profile", "resume", "thread-id"],
            workingDirectory: "/Users/test/Project's Folder"
        )

        XCTAssertEqual(
            script,
            "cd -- '/Users/test/Project'\"'\"'s Folder' && exec '/Users/test/bin/codex' '--profile' 'team'\"'\"'s profile' 'resume' 'thread-id'"
        )
    }

    func testProfileStoreDistinguishesDefaultFromUnknown() {
        let suiteName = "SessionActionsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SessionProfileStore(defaults: defaults)

        XCTAssertNil(store.profile(for: "thread"))
        store.set(.defaultProfile, for: "thread")
        XCTAssertEqual(store.profile(for: "thread"), .defaultProfile)
        store.set(.named("workeeper"), for: "thread")
        XCTAssertEqual(store.profile(for: "thread"), .named("workeeper"))
    }

    func testRejoinTerminalStorePersistsOnlySelectablePrograms() {
        let suiteName = "SessionActionsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RejoinTerminalStore(defaults: defaults)

        XCTAssertEqual(store.program, .appleTerminal)
        store.set(.ghostty)
        XCTAssertEqual(store.program, .ghostty)
        store.set(.unknown)
        XCTAssertEqual(store.program, .ghostty)
    }

    func testSelectableTerminalTagsRoundTrip() {
        for terminal in TerminalProgram.selectablePrograms {
            XCTAssertEqual(TerminalProgram(selectionTag: terminal.selectionTag), terminal)
        }
        XCTAssertNil(TerminalProgram(selectionTag: -1))
    }

    func testGhosttyLauncherCreatesConfiguredTab() {
        let script = "cd -- '/tmp' && exec '/bin/echo' 'hello'"
        let appleScript = TerminalLauncher.ghosttyLaunchScript(script: script)

        XCTAssertTrue(appleScript.contains("tell application \"Ghostty\""))
        XCTAssertTrue(appleScript.contains("new surface configuration"))
        XCTAssertTrue(appleScript.contains("new tab in launchWindow"))
        XCTAssertTrue(appleScript.contains("wait after command:true"))
        XCTAssertTrue(appleScript.contains("/bin/zsh -lc"))
        XCTAssertFalse(appleScript.contains("shell:cd"))
        XCTAssertEqual(
            TerminalLauncher.ghosttyCommand(script: script),
            "/bin/zsh -lc 'cd -- '\"'\"'/tmp'\"'\"' && exec '\"'\"'/bin/echo'\"'\"' '\"'\"'hello'\"'\"''"
        )
    }

    func testTerminalLaunchersTargetTheSelectedApplication() {
        let script = "exec '/bin/true'"

        XCTAssertTrue(
            TerminalLauncher.appleTerminalLaunchScript(script: script)
                .contains("tell application \"Terminal\"")
        )
        XCTAssertTrue(
            TerminalLauncher.iTermLaunchScript(script: script)
                .contains("tell application \"iTerm2\"")
        )
    }

    func testTerminalProgramDetectionUsesProcessEnvironment() {
        XCTAssertEqual(
            TerminalProgram.detect(in: "codex TERM_PROGRAM=ghostty TERM=xterm-ghostty"),
            .ghostty
        )
        XCTAssertEqual(
            TerminalProgram.detect(in: "codex TERM_PROGRAM=Apple_Terminal"),
            .appleTerminal
        )
        XCTAssertEqual(
            TerminalProgram.detect(in: "codex TERM_PROGRAM=iTerm.app"),
            .iTerm2
        )
        XCTAssertEqual(TerminalProgram.detect(in: "codex TERM=xterm-256color"), .unknown)
    }

    func testGhosttyFocusScriptTargetsUniqueTemporaryTitle() {
        let script = TerminalSessionFocuser.ghosttyFocusScript(marker: "Focus \"thread\"")

        XCTAssertTrue(script.contains("every terminal whose name is \"Focus \\\"thread\\\"\""))
        XCTAssertTrue(script.contains("focus item 1 of matches"))
        XCTAssertTrue(script.contains("delay 0.025"))
    }

    func testAppleTerminalFocusScriptTargetsExactTTY() {
        let script = TerminalSessionFocuser.appleTerminalFocusScript(ttyPath: "/dev/ttys001")

        XCTAssertTrue(script.contains("if tty of terminalTab is \"/dev/ttys001\""))
        XCTAssertTrue(script.contains("set selected tab of terminalWindow to terminalTab"))
        XCTAssertTrue(script.contains("activate"))
    }

    func testGhosttyTitleProbePushesAndRestoresTitle() {
        let sequence = TerminalSessionFocuser.titleProbeSequence(marker: "thread\u{07}\u{1B}")

        XCTAssertTrue(sequence.hasPrefix("\u{1B}[22;2t\u{1B}]2;"))
        XCTAssertTrue(sequence.hasSuffix("\u{07}"))
        XCTAssertFalse(sequence.dropFirst("\u{1B}[22;2t\u{1B}]2;".count).dropLast().contains("\u{07}"))
        XCTAssertFalse(sequence.dropFirst("\u{1B}[22;2t\u{1B}]2;".count).dropLast().contains("\u{1B}"))
        XCTAssertEqual(TerminalSessionFocuser.restoreTitleSequence, "\u{1B}[23;2t")
    }

    func testMissingGhosttySurfaceProducesRejoinOutcomeAndRestoresTitle() {
        let process = InteractiveCodexProcess(
            pid: 100,
            tty: "ttys001",
            command: "codex",
            sessionID: "thread-id",
            profile: .named("workeeper")
        )
        let error = "execution error: The Ghostty surface for this Codex session is no longer open. (-2700)"
        var terminalWrites: [(String, String)] = []

        let outcome = TerminalSessionFocuser.focus(
            process: process,
            sessionID: "thread-id",
            sessionName: "Active session",
            runner: { executable, arguments in
                if executable.path == "/bin/ps" {
                    return CommandResult(
                        terminationStatus: 0,
                        standardOutput: "TERM_PROGRAM=ghostty",
                        standardError: ""
                    )
                }
                XCTAssertEqual(executable.path, "/usr/bin/osascript")
                XCTAssertEqual(arguments.first, "-e")
                return CommandResult(
                    terminationStatus: 1,
                    standardOutput: "",
                    standardError: error
                )
            },
            terminalWriter: { path, sequence in
                terminalWrites.append((path, sequence))
                return nil
            }
        )

        XCTAssertEqual(outcome, .surfaceUnavailable(error))
        XCTAssertEqual(terminalWrites.map(\.0), ["/dev/ttys001", "/dev/ttys001"])
        XCTAssertTrue(terminalWrites[0].1.hasPrefix("\u{1B}[22;2t\u{1B}]2;"))
        XCTAssertEqual(terminalWrites[1].1, TerminalSessionFocuser.restoreTitleSequence)
    }

    func testGhosttyAutomationFailureDoesNotOfferRejoin() {
        let process = InteractiveCodexProcess(
            pid: 100,
            tty: "ttys001",
            command: "codex",
            sessionID: "thread-id",
            profile: .defaultProfile
        )
        let error = "Not authorized to send Apple events to Ghostty. (-1743)"

        let outcome = TerminalSessionFocuser.focus(
            process: process,
            sessionID: "thread-id",
            sessionName: "Active session",
            runner: { executable, _ in
                if executable.path == "/bin/ps" {
                    return CommandResult(
                        terminationStatus: 0,
                        standardOutput: "TERM_PROGRAM=ghostty",
                        standardError: ""
                    )
                }
                return CommandResult(
                    terminationStatus: 1,
                    standardOutput: "",
                    standardError: error
                )
            },
            terminalWriter: { _, _ in nil }
        )

        XCTAssertEqual(outcome, .failed(error))
    }
}
