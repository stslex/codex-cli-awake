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
}
