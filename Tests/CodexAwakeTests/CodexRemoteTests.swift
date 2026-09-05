import Foundation
import XCTest
@testable import CodexAwake

final class CodexRemoteTests: XCTestCase {
    private let schemaAndFixtures = """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            name TEXT,
            title TEXT,
            preview TEXT,
            cwd TEXT NOT NULL,
            recency_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            archived INTEGER NOT NULL,
            thread_source TEXT,
            agent_role TEXT,
            source TEXT NOT NULL
        );
        INSERT INTO threads VALUES
            ('cli-user', 'CLI user', '', '', '/cli', 10, 10, 0, 'user', '', 'cli'),
            ('vscode-user', 'Shared daemon user', '', '', '/shared', 20, 20, 0, 'user', '', 'vscode'),
            ('quoted''user', 'Quoted ID user', '', '', '/shared', 25, 25, 0, 'user', '', 'vscode'),
            ('guardian', 'Guardian', '', '', '/shared', 30, 30, 0, 'guardian_review', '', 'vscode'),
            ('subagent', 'Subagent', '', '', '/shared', 40, 40, 0, 'subagent', '', 'vscode'),
            ('archived', 'Archived', '', '', '/shared', 50, 50, 1, 'user', '', 'vscode');
        """

    func testLoadedSessionQueryIncludesUserThreadsFromEveryInteractiveClientSource() throws {
        let query = CodexSessionQuery.loaded(
            threadIDs: ["cli-user", "vscode-user", "quoted'user", "guardian", "subagent", "archived"],
            limit: 6
        )

        let result = CommandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: ["-json", ":memory:", schemaAndFixtures + query]
        )
        let sessions = try JSONDecoder().decode(
            [CodexSession].self,
            from: Data(result.standardOutput.utf8)
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(sessions.map(\.id), ["quoted'user", "vscode-user", "cli-user"])
        XCTAssertEqual(sessions.map(\.displayName), ["Quoted ID user", "Shared daemon user", "CLI user"])
    }

    func testRecentSessionQueryExcludesServiceAndArchivedThreadsWithoutFilteringClientSource() throws {
        let result = CommandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: ["-json", ":memory:", schemaAndFixtures + CodexSessionQuery.recent(limit: 6)]
        )
        let sessions = try JSONDecoder().decode(
            [CodexSession].self,
            from: Data(result.standardOutput.utf8)
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(sessions.map(\.id), ["quoted'user", "vscode-user", "cli-user"])
    }

    func testMenuTitleKeepsProjectVisibleWithinTheWidthBudget() {
        let session = CodexSession(
            id: "session",
            displayName: "Add regression coverage for session loading",
            cwd: "/Users/test/Projects/desktop-tools",
            recencyAt: 1
        )

        let title = CodexSessionMenuPresentation.title(for: session)

        XCTAssertLessThanOrEqual(title.count, 44)
        XCTAssertTrue(title.contains("…"))
        XCTAssertTrue(title.hasSuffix(" · desktop-tools"))
    }

    func testRemoteControlSourceStoreDefaultsToTerminalAndPersistsDesktop() {
        let suiteName = "CodexRemoteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RemoteControlSourceStore(defaults: defaults)

        XCTAssertEqual(store.source, .terminalCLI)

        store.set(.codexDesktop)

        XCTAssertEqual(store.source, .codexDesktop)
    }

    func testDesktopSourceNeverStartsTerminalRemoteControl() {
        var terminalStartCount = 0

        let status = RemoteControlSourceResolver.status(
            for: .codexDesktop,
            terminalStatus: {
                terminalStartCount += 1
                return .checking
            },
            desktopIsRunning: { true }
        )

        XCTAssertEqual(terminalStartCount, 0)
        XCTAssertEqual(status.state, .managed)
        XCTAssertEqual(status.detail, "Managed by Codex Desktop")
    }

    func testTerminalSourceUsesTerminalRemoteStatus() {
        var terminalStartCount = 0

        let status = RemoteControlSourceResolver.status(
            for: .terminalCLI,
            terminalStatus: {
                terminalStartCount += 1
                return RemoteStatus(
                    state: .connected,
                    serverName: "Test Mac",
                    environmentID: "test",
                    detail: nil,
                    configuredEnabled: true
                )
            },
            desktopIsRunning: { XCTFail("Desktop state should not be queried"); return false }
        )

        XCTAssertEqual(terminalStartCount, 1)
        XCTAssertEqual(status.state, .connected)
        XCTAssertEqual(status.serverName, "Test Mac")
    }

    func testStoppingTerminalRemoteControlUsesExplicitStopCommand() {
        let executable = URL(fileURLWithPath: "/test/codex")
        var capturedExecutable: URL?
        var capturedArguments: [String] = []

        let error = CodexRemoteBridge.stopTerminalRemoteControl(
            executable: executable,
            commandRunner: { command, arguments in
                capturedExecutable = command
                capturedArguments = arguments
                return CommandResult(
                    terminationStatus: 0,
                    standardOutput: #"{"status":"disabled"}"#,
                    standardError: ""
                )
            }
        )

        XCTAssertNil(error)
        XCTAssertEqual(capturedExecutable, executable)
        XCTAssertEqual(capturedArguments, ["remote-control", "stop", "--json"])
    }
}
