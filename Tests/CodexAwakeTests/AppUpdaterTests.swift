import Foundation
import XCTest
@testable import CodexAwake

final class AppUpdaterTests: XCTestCase {
    func testSemanticVersionsCompareNumericallyAndRejectNonCanonicalValues() {
        XCTAssertEqual(AppVersion("v1.4.0"), AppVersion("1.4.0"))
        XCTAssertLessThan(AppVersion("1.9.9")!, AppVersion("1.10.0")!)
        XCTAssertLessThan(AppVersion("1.10.0")!, AppVersion("2.0.0")!)
        XCTAssertNil(AppVersion("1.4"))
        XCTAssertNil(AppVersion("1.04.0"))
        XCTAssertNil(AppVersion("1.4.0-beta.1"))
    }

    func testReleaseCheckFindsOnlyTheExactArchiveAndChecksumAssets() throws {
        let releaseJSON = """
        {
          "tag_name": "v1.4.0",
          "html_url": "https://github.com/stslex/codex-cli-awake/releases/tag/v1.4.0",
          "body": "Native updater",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "Codex-Awake-1.4.0-universal.zip",
              "browser_download_url": "https://github.com/stslex/codex-cli-awake/releases/download/v1.4.0/Codex-Awake-1.4.0-universal.zip"
            },
            {
              "name": "Codex-Awake-1.4.0-universal.zip.sha256",
              "browser_download_url": "https://github.com/stslex/codex-cli-awake/releases/download/v1.4.0/Codex-Awake-1.4.0-universal.zip.sha256"
            }
          ]
        }
        """
        let client = AppUpdateClient(loader: { request in
            XCTAssertEqual(request.url, AppUpdateClient.releasesAPIURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "CodexAwake")
            return AppUpdateHTTPResponse(
                data: Data(releaseJSON.utf8),
                statusCode: 200,
                finalURL: request.url
            )
        })

        let result = try client.check(currentVersion: "1.3.0")

        guard case let .available(release) = result else {
            return XCTFail("Expected an available update")
        }
        XCTAssertEqual(release.version, AppVersion("1.4.0"))
        XCTAssertEqual(release.archiveName, "Codex-Awake-1.4.0-universal.zip")
        XCTAssertEqual(release.releaseNotes, "Native updater")
    }

    func testReleaseCheckTreatsHTTP404AsNoPublishedRelease() throws {
        let client = AppUpdateClient(loader: { request in
            AppUpdateHTTPResponse(data: Data(), statusCode: 404, finalURL: request.url)
        })

        XCTAssertEqual(
            try client.check(currentVersion: "1.4.0"),
            .noPublishedRelease
        )
    }

    func testSameVersionReleaseCanReplaceAnAdHocSourceBuild() throws {
        let releaseJSON = """
        {
          "tag_name": "v1.4.0",
          "html_url": "https://github.com/stslex/codex-cli-awake/releases/tag/v1.4.0",
          "body": null,
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "Codex-Awake-1.4.0-universal.zip",
              "browser_download_url": "https://github.com/stslex/codex-cli-awake/releases/download/v1.4.0/Codex-Awake-1.4.0-universal.zip"
            },
            {
              "name": "Codex-Awake-1.4.0-universal.zip.sha256",
              "browser_download_url": "https://github.com/stslex/codex-cli-awake/releases/download/v1.4.0/Codex-Awake-1.4.0-universal.zip.sha256"
            }
          ]
        }
        """
        let client = AppUpdateClient(loader: { request in
            AppUpdateHTTPResponse(
                data: Data(releaseJSON.utf8),
                statusCode: 200,
                finalURL: request.url
            )
        })

        XCTAssertEqual(
            try client.check(currentVersion: "1.4.0"),
            .upToDate(latestVersion: AppVersion("1.4.0")!)
        )
        guard case .available = try client.check(
            currentVersion: "1.4.0",
            allowSameVersionUpgrade: true
        ) else {
            return XCTFail("Expected the signed same-version release to be installable")
        }
    }

    func testDeveloperIDSignedBuildDoesNotRequestSameVersionMigration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUpdaterTests-\(UUID().uuidString).app", isDirectory: true)
        let signedClient = AppUpdateClient(
            loader: { _ in throw AppUpdateError.invalidReleaseResponse },
            commandRunner: { _, _ in
                CommandResult(
                    terminationStatus: 0,
                    standardOutput: "",
                    standardError: "Authority=Developer ID Application: Example\nTeamIdentifier=TEAMID"
                )
            }
        )
        let adHocClient = AppUpdateClient(
            loader: { _ in throw AppUpdateError.invalidReleaseResponse },
            commandRunner: { _, _ in
                CommandResult(
                    terminationStatus: 0,
                    standardOutput: "",
                    standardError: "Signature=adhoc\nTeamIdentifier=not set"
                )
            }
        )

        XCTAssertFalse(signedClient.requiresSignedReleaseMigration(at: root))
        XCTAssertTrue(adHocClient.requiresSignedReleaseMigration(at: root))
    }

    func testReleaseCheckRejectsAssetOutsideTheConfiguredRepository() {
        let releaseJSON = """
        {
          "tag_name": "v1.4.0",
          "html_url": "https://github.com/stslex/codex-cli-awake/releases/tag/v1.4.0",
          "body": null,
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "Codex-Awake-1.4.0-universal.zip",
              "browser_download_url": "https://example.com/Codex-Awake-1.4.0-universal.zip"
            },
            {
              "name": "Codex-Awake-1.4.0-universal.zip.sha256",
              "browser_download_url": "https://github.com/stslex/codex-cli-awake/releases/download/v1.4.0/Codex-Awake-1.4.0-universal.zip.sha256"
            }
          ]
        }
        """
        let client = AppUpdateClient(loader: { request in
            AppUpdateHTTPResponse(
                data: Data(releaseJSON.utf8),
                statusCode: 200,
                finalURL: request.url
            )
        })

        XCTAssertThrowsError(try client.check(currentVersion: "1.3.0")) { error in
            guard case AppUpdateError.untrustedReleaseURL = error else {
                return XCTFail("Expected an untrusted URL error, got \(error)")
            }
        }
    }

    func testChecksumMustMatchTheNamedArchive() throws {
        let archive = Data("archive".utf8)
        let checksum = AppUpdateClient.sha256(archive)
        let checksumFile = Data("\(checksum)  Codex-Awake-1.4.0-universal.zip\n".utf8)

        XCTAssertEqual(
            try AppUpdateClient.expectedChecksum(
                checksumFile,
                archiveName: "Codex-Awake-1.4.0-universal.zip"
            ),
            checksum
        )
        XCTAssertThrowsError(
            try AppUpdateClient.expectedChecksum(
                checksumFile,
                archiveName: "Codex-Awake-1.5.0-universal.zip"
            )
        )
    }

    func testApplyRequestRequiresAllTypedArguments() {
        let request = AppUpdateApplyRequest(arguments: [
            "/path/CodexAwake",
            "--apply-update",
            "--wait-pid", "123",
            "--source-app", "/tmp/.Codex-Awake-update-id.app",
            "--target-app", "/tmp/Codex Awake.app",
            "--expected-version", "1.4.0"
        ])

        XCTAssertEqual(request?.waitPID, 123)
        XCTAssertEqual(request?.expectedVersion, AppVersion("1.4.0"))
        XCTAssertNil(AppUpdateApplyRequest(arguments: ["CodexAwake", "--apply-update"]))
    }

    func testPrepareRejectsArchiveWhoseBytesDoNotMatchChecksum() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUpdaterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("Codex Awake.app", isDirectory: true)
        try makeBundle(at: target, version: "1.3.0")

        let version = AppVersion("1.4.0")!
        let archiveName = AppUpdateClient.archiveName(version: version)
        let archiveURL = URL(
            string: "https://github.com/stslex/codex-cli-awake/releases/download/v1.4.0/\(archiveName)"
        )!
        let checksumURL = archiveURL.appendingPathExtension("sha256")
        let expected = AppUpdateClient.sha256(Data("expected archive".utf8))
        let release = AppUpdateRelease(
            version: version,
            archiveName: archiveName,
            archiveURL: archiveURL,
            checksumURL: checksumURL,
            releasePageURL: URL(
                string: "https://github.com/stslex/codex-cli-awake/releases/tag/v1.4.0"
            )!,
            releaseNotes: nil
        )
        let client = AppUpdateClient(
            loader: { request in
                if request.url == archiveURL {
                    return AppUpdateHTTPResponse(
                        data: Data("tampered archive".utf8),
                        statusCode: 200,
                        finalURL: archiveURL
                    )
                }
                return AppUpdateHTTPResponse(
                    data: Data("\(expected)  \(archiveName)\n".utf8),
                    statusCode: 200,
                    finalURL: checksumURL
                )
            },
            commandRunner: { _, _ in
                XCTFail("No command should run before checksum verification")
                return CommandResult(terminationStatus: 1, standardOutput: "", standardError: "")
            }
        )

        XCTAssertThrowsError(try client.prepare(release: release, replacing: target)) { error in
            XCTAssertEqual(error as? AppUpdateError, .checksumMismatch)
        }
    }

    func testHelperReplacesTheBundleAndRemovesTheBackup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUpdaterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let target = root.appendingPathComponent("Codex Awake.app", isDirectory: true)
        let source = root.appendingPathComponent(".Codex-Awake-update-test.app", isDirectory: true)
        try makeBundle(at: target, version: "1.3.0")
        try makeBundle(at: source, version: "1.4.0")

        let request = AppUpdateApplyRequest(arguments: [
            "CodexAwake",
            "--apply-update",
            "--wait-pid", "123",
            "--source-app", source.path,
            "--target-app", target.path,
            "--expected-version", "1.4.0"
        ])!
        let success = CommandResult(
            terminationStatus: 0,
            standardOutput: "",
            standardError: ""
        )

        let result = AppUpdateHelper.apply(
            request,
            processIsRunning: { _ in false },
            commandRunner: { _, _ in success },
            logger: { _ in }
        )

        XCTAssertEqual(result, EXIT_SUCCESS)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let installedInfoData = try Data(
            contentsOf: target.appendingPathComponent("Contents/Info.plist")
        )
        let installedInfo = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: installedInfoData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(
            installedInfo["CFBundleShortVersionString"] as? String,
            "1.4.0"
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .allSatisfy { !$0.hasPrefix(".Codex-Awake-backup-") }
        )
    }

    func testHelperRestoresThePreviousBundleWhenRelaunchFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUpdaterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let target = root.appendingPathComponent("Codex Awake.app", isDirectory: true)
        let source = root.appendingPathComponent(".Codex-Awake-update-test.app", isDirectory: true)
        try makeBundle(at: target, version: "1.3.0")
        try makeBundle(at: source, version: "1.4.0")
        let request = AppUpdateApplyRequest(arguments: [
            "CodexAwake",
            "--apply-update",
            "--wait-pid", "123",
            "--source-app", source.path,
            "--target-app", target.path,
            "--expected-version", "1.4.0"
        ])!

        var openCalls = 0
        let result = AppUpdateHelper.apply(
            request,
            processIsRunning: { _ in false },
            commandRunner: { executable, _ in
                if executable.path == "/usr/bin/open" {
                    openCalls += 1
                    if openCalls == 1 {
                        return CommandResult(
                            terminationStatus: 1,
                            standardOutput: "",
                            standardError: "launch failed"
                        )
                    }
                }
                return CommandResult(
                    terminationStatus: 0,
                    standardOutput: "",
                    standardError: ""
                )
            },
            logger: { _ in }
        )

        XCTAssertEqual(result, EXIT_FAILURE)
        XCTAssertEqual(try bundleVersion(at: target), "1.3.0")
        XCTAssertEqual(openCalls, 2)
    }

    func testHelperRelaunchesCurrentBundleWhenFinalVerificationFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUpdaterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let target = root.appendingPathComponent("Codex Awake.app", isDirectory: true)
        let source = root.appendingPathComponent(".Codex-Awake-update-test.app", isDirectory: true)
        try makeBundle(at: target, version: "1.3.0")
        try makeBundle(at: source, version: "1.4.0")
        let request = AppUpdateApplyRequest(arguments: [
            "CodexAwake",
            "--apply-update",
            "--wait-pid", "123",
            "--source-app", source.path,
            "--target-app", target.path,
            "--expected-version", "1.4.0"
        ])!

        var openedTarget = false
        let result = AppUpdateHelper.apply(
            request,
            processIsRunning: { _ in false },
            commandRunner: { executable, _ in
                if executable.path == "/usr/bin/open" {
                    openedTarget = true
                    return CommandResult(terminationStatus: 0, standardOutput: "", standardError: "")
                }
                return CommandResult(
                    terminationStatus: 1,
                    standardOutput: "",
                    standardError: "signature rejected"
                )
            },
            logger: { _ in }
        )

        XCTAssertEqual(result, EXIT_FAILURE)
        XCTAssertTrue(openedTarget)
        XCTAssertEqual(try bundleVersion(at: target), "1.3.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    private func makeBundle(at url: URL, version: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let executableDirectory = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        let executable = executableDirectory.appendingPathComponent("CodexAwake")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let info: [String: Any] = [
            "CFBundleIdentifier": AppUpdateClient.bundleIdentifier,
            "CFBundleExecutable": "CodexAwake",
            "CFBundleName": "Codex Awake",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "1"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func bundleVersion(at url: URL) throws -> String {
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        return try XCTUnwrap(info["CFBundleShortVersionString"] as? String)
    }
}
