import CryptoKit
import Darwin
import Foundation

struct AppVersion: Codable, Comparable, CustomStringConvertible, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let components = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]),
              major >= 0,
              minor >= 0,
              patch >= 0,
              components[0] == Substring(String(major)),
              components[1] == Substring(String(minor)),
              components[2] == Substring(String(patch)) else {
            return nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var description: String {
        "\(major).\(minor).\(patch)"
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct AppUpdateRelease: Equatable {
    let version: AppVersion
    let archiveName: String
    let archiveURL: URL
    let checksumURL: URL
    let releasePageURL: URL
    let releaseNotes: String?
}

enum AppUpdateAvailability: Equatable {
    case noPublishedRelease
    case upToDate(latestVersion: AppVersion)
    case available(AppUpdateRelease)
}

struct AppUpdateCommandStatus: Codable, Equatable {
    enum State: String, Codable {
        case noPublishedRelease = "no-published-release"
        case upToDate = "up-to-date"
        case available
        case error
    }

    let state: State
    let currentVersion: String
    let latestVersion: String?
    let releaseURL: String?
    let detail: String?

    static func make(
        currentVersion: String,
        availability: AppUpdateAvailability
    ) -> AppUpdateCommandStatus {
        switch availability {
        case .noPublishedRelease:
            return AppUpdateCommandStatus(
                state: .noPublishedRelease,
                currentVersion: currentVersion,
                latestVersion: nil,
                releaseURL: nil,
                detail: nil
            )
        case let .upToDate(latestVersion):
            return AppUpdateCommandStatus(
                state: .upToDate,
                currentVersion: currentVersion,
                latestVersion: latestVersion.description,
                releaseURL: nil,
                detail: nil
            )
        case let .available(release):
            return AppUpdateCommandStatus(
                state: .available,
                currentVersion: currentVersion,
                latestVersion: release.version.description,
                releaseURL: release.releasePageURL.absoluteString,
                detail: nil
            )
        }
    }

    static func failure(currentVersion: String, error: Error) -> AppUpdateCommandStatus {
        AppUpdateCommandStatus(
            state: .error,
            currentVersion: currentVersion,
            latestVersion: nil,
            releaseURL: nil,
            detail: error.localizedDescription
        )
    }
}

struct AppUpdateHTTPResponse {
    let data: Data
    let statusCode: Int
    let finalURL: URL?
}

enum AppUpdateError: LocalizedError, Equatable {
    case invalidCurrentVersion(String)
    case invalidReleaseResponse
    case invalidReleaseVersion(String)
    case missingReleaseAsset(String)
    case untrustedReleaseURL(String)
    case requestFailed(Int)
    case responseTooLarge(String)
    case invalidChecksum
    case checksumMismatch
    case archiveExtractionFailed(String)
    case invalidApplicationBundle(String)
    case applicationNotWritable(String)
    case helperLaunchFailed(String)
    case replacementFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidCurrentVersion(version):
            return "The installed app version is invalid: \(version)"
        case .invalidReleaseResponse:
            return "GitHub returned an invalid release response."
        case let .invalidReleaseVersion(version):
            return "The release tag is not a supported version: \(version)"
        case let .missingReleaseAsset(name):
            return "The release is missing \(name)."
        case let .untrustedReleaseURL(url):
            return "The release contains an untrusted download URL: \(url)"
        case let .requestFailed(statusCode):
            return "GitHub returned HTTP \(statusCode)."
        case let .responseTooLarge(name):
            return "The downloaded \(name) is unexpectedly large."
        case .invalidChecksum:
            return "The release checksum file is invalid."
        case .checksumMismatch:
            return "The downloaded update does not match its SHA-256 checksum."
        case let .archiveExtractionFailed(detail):
            return "The update archive could not be extracted: \(detail)"
        case let .invalidApplicationBundle(detail):
            return "The downloaded application failed verification: \(detail)"
        case let .applicationNotWritable(path):
            return "Codex Awake cannot replace the application at \(path). Move it to ~/Applications or update it with the package manager that installed it."
        case let .helperLaunchFailed(detail):
            return "The update installer could not start: \(detail)"
        case let .replacementFailed(detail):
            return "The update could not replace the application: \(detail)"
        }
    }
}

private struct GitHubReleaseResponse: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        private enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case draft
        case prerelease
        case assets
    }
}

final class AppUpdateClient: @unchecked Sendable {
    typealias Loader = (URLRequest) throws -> AppUpdateHTTPResponse

    static let repository = "stslex/codex-cli-awake"
    static let releasesAPIURL = URL(
        string: "https://api.github.com/repos/\(repository)/releases/latest"
    )!
    static let bundleIdentifier = "com.stslex.CodexAwake"
    static let applicationName = "Codex Awake.app"

    static func currentVersion(bundle: Bundle = .main) -> String {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private static let maximumArchiveSize = 100 * 1_024 * 1_024
    private static let maximumMetadataSize = 1 * 1_024 * 1_024

    private let loader: Loader
    private let fileManager: FileManager
    private let commandRunner: (URL, [String]) -> CommandResult

    init(
        loader: @escaping Loader = AppUpdateClient.liveLoad,
        fileManager: FileManager = .default,
        commandRunner: @escaping (URL, [String]) -> CommandResult = CommandRunner.run
    ) {
        self.loader = loader
        self.fileManager = fileManager
        self.commandRunner = commandRunner
    }

    func check(
        currentVersion value: String,
        allowSameVersionUpgrade: Bool = false
    ) throws -> AppUpdateAvailability {
        guard let currentVersion = AppVersion(value) else {
            throw AppUpdateError.invalidCurrentVersion(value)
        }

        let response = try loader(Self.request(url: Self.releasesAPIURL))
        try Self.validateAPIResponseURL(response.finalURL)
        if response.statusCode == 404 {
            return .noPublishedRelease
        }
        guard response.statusCode == 200 else {
            throw AppUpdateError.requestFailed(response.statusCode)
        }
        guard response.data.count <= Self.maximumMetadataSize,
              let release = try? JSONDecoder().decode(GitHubReleaseResponse.self, from: response.data),
              !release.draft,
              !release.prerelease else {
            throw AppUpdateError.invalidReleaseResponse
        }
        guard let version = AppVersion(release.tagName) else {
            throw AppUpdateError.invalidReleaseVersion(release.tagName)
        }

        try Self.validateReleasePageURL(release.htmlURL, version: version)
        if version < currentVersion || (version == currentVersion && !allowSameVersionUpgrade) {
            return .upToDate(latestVersion: version)
        }

        let archiveName = Self.archiveName(version: version)
        let checksumName = archiveName + ".sha256"
        guard let archive = release.assets.first(where: { $0.name == archiveName }) else {
            throw AppUpdateError.missingReleaseAsset(archiveName)
        }
        guard let checksum = release.assets.first(where: { $0.name == checksumName }) else {
            throw AppUpdateError.missingReleaseAsset(checksumName)
        }
        try Self.validateAssetURL(archive.browserDownloadURL, name: archiveName, version: version)
        try Self.validateAssetURL(checksum.browserDownloadURL, name: checksumName, version: version)

        return .available(
            AppUpdateRelease(
                version: version,
                archiveName: archiveName,
                archiveURL: archive.browserDownloadURL,
                checksumURL: checksum.browserDownloadURL,
                releasePageURL: release.htmlURL,
                releaseNotes: release.body?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )
    }

    func prepare(
        release: AppUpdateRelease,
        replacing targetBundleURL: URL
    ) throws -> PreparedAppUpdate {
        let targetBundleURL = targetBundleURL.standardizedFileURL
        guard targetBundleURL.pathExtension == "app",
              targetBundleURL.lastPathComponent == Self.applicationName else {
            throw AppUpdateError.invalidApplicationBundle("the running bundle path is not \(Self.applicationName)")
        }

        let targetParent = targetBundleURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: targetParent.path) else {
            throw AppUpdateError.applicationNotWritable(targetBundleURL.path)
        }

        let archiveResponse = try loader(Self.request(url: release.archiveURL))
        try Self.validateDownloadResponseURL(archiveResponse.finalURL)
        guard archiveResponse.statusCode == 200 else {
            throw AppUpdateError.requestFailed(archiveResponse.statusCode)
        }
        guard archiveResponse.data.count <= Self.maximumArchiveSize else {
            throw AppUpdateError.responseTooLarge("archive")
        }

        let checksumResponse = try loader(Self.request(url: release.checksumURL))
        try Self.validateDownloadResponseURL(checksumResponse.finalURL)
        guard checksumResponse.statusCode == 200 else {
            throw AppUpdateError.requestFailed(checksumResponse.statusCode)
        }
        guard checksumResponse.data.count <= 4_096 else {
            throw AppUpdateError.responseTooLarge("checksum")
        }

        let expectedChecksum = try Self.expectedChecksum(
            checksumResponse.data,
            archiveName: release.archiveName
        )
        guard Self.sha256(archiveResponse.data) == expectedChecksum else {
            throw AppUpdateError.checksumMismatch
        }

        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("CodexAwakeUpdate-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let archiveURL = temporaryRoot.appendingPathComponent(release.archiveName)
        let extractionURL = temporaryRoot.appendingPathComponent("extracted", isDirectory: true)
        try archiveResponse.data.write(to: archiveURL, options: .atomic)
        try fileManager.createDirectory(at: extractionURL, withIntermediateDirectories: true)

        let extraction = commandRunner(
            URL(fileURLWithPath: "/usr/bin/ditto"),
            ["-x", "-k", archiveURL.path, extractionURL.path]
        )
        guard extraction.terminationStatus == 0 else {
            throw AppUpdateError.archiveExtractionFailed(extraction.combinedOutput)
        }

        let extractedBundleURL = extractionURL.appendingPathComponent(Self.applicationName)
        try validateApplication(at: extractedBundleURL, expectedVersion: release.version)

        let stagedBundleURL = targetParent.appendingPathComponent(
            ".Codex-Awake-update-\(UUID().uuidString).app",
            isDirectory: true
        )
        let copy = commandRunner(
            URL(fileURLWithPath: "/usr/bin/ditto"),
            [extractedBundleURL.path, stagedBundleURL.path]
        )
        guard copy.terminationStatus == 0 else {
            try? fileManager.removeItem(at: stagedBundleURL)
            throw AppUpdateError.applicationNotWritable(targetBundleURL.path)
        }

        do {
            try validateApplication(at: stagedBundleURL, expectedVersion: release.version)
        } catch {
            try? fileManager.removeItem(at: stagedBundleURL)
            throw error
        }

        return PreparedAppUpdate(
            version: release.version,
            stagedBundleURL: stagedBundleURL,
            targetBundleURL: targetBundleURL
        )
    }

    func launchInstaller(for update: PreparedAppUpdate, waitingFor processID: Int32) throws {
        let executableURL = update.stagedBundleURL
            .appendingPathComponent("Contents/MacOS/CodexAwake")
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw AppUpdateError.helperLaunchFailed("the staged executable is missing")
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--apply-update",
            "--wait-pid", String(processID),
            "--source-app", update.stagedBundleURL.path,
            "--target-app", update.targetBundleURL.path,
            "--expected-version", update.version.description
        ]

        do {
            try process.run()
        } catch {
            try? fileManager.removeItem(at: update.stagedBundleURL)
            throw AppUpdateError.helperLaunchFailed(error.localizedDescription)
        }
    }

    func validateApplication(at bundleURL: URL, expectedVersion: AppVersion) throws {
        guard let bundle = Bundle(url: bundleURL),
              bundle.bundleIdentifier == Self.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == expectedVersion.description,
              let executableURL = bundle.executableURL,
              fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw AppUpdateError.invalidApplicationBundle("bundle identifier, version, or executable is invalid")
        }

        let signature = commandRunner(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            ["--verify", "--deep", "--strict", "--verbose=2", bundleURL.path]
        )
        guard signature.terminationStatus == 0 else {
            throw AppUpdateError.invalidApplicationBundle(
                signature.combinedOutput.isEmpty ? "code signature verification failed" : signature.combinedOutput
            )
        }

        let gatekeeper = commandRunner(
            URL(fileURLWithPath: "/usr/sbin/spctl"),
            ["--assess", "--type", "execute", "--verbose=4", bundleURL.path]
        )
        guard gatekeeper.terminationStatus == 0 else {
            throw AppUpdateError.invalidApplicationBundle(
                gatekeeper.combinedOutput.isEmpty ? "Gatekeeper rejected the app" : gatekeeper.combinedOutput
            )
        }
    }

    func requiresSignedReleaseMigration(at bundleURL: URL) -> Bool {
        guard bundleURL.pathExtension == "app" else { return false }
        let signature = commandRunner(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            ["-d", "--verbose=4", bundleURL.path]
        )
        return signature.terminationStatus != 0
            || !signature.combinedOutput.contains("Authority=Developer ID Application:")
    }

    static func archiveName(version: AppVersion) -> String {
        "Codex-Awake-\(version)-universal.zip"
    }

    static func expectedChecksum(_ data: Data, archiveName: String) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AppUpdateError.invalidChecksum
        }

        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2 else { continue }
            let checksum = String(fields[0]).lowercased()
            let filename = String(fields.last!).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if filename == archiveName,
               checksum.count == 64,
               checksum.allSatisfy({ $0.isHexDigit }) {
                return checksum
            }
        }
        throw AppUpdateError.invalidChecksum
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("CodexAwake", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    private static func validateReleasePageURL(_ url: URL, version: AppVersion) throws {
        guard url.scheme == "https",
              url.host == "github.com",
              url.path == "/\(repository)/releases/tag/v\(version)" else {
            throw AppUpdateError.untrustedReleaseURL(url.absoluteString)
        }
    }

    private static func validateAssetURL(_ url: URL, name: String, version: AppVersion) throws {
        guard url.scheme == "https",
              url.host == "github.com",
              url.path == "/\(repository)/releases/download/v\(version)/\(name)" else {
            throw AppUpdateError.untrustedReleaseURL(url.absoluteString)
        }
    }

    private static func validateAPIResponseURL(_ url: URL?) throws {
        guard let url,
              url.scheme == "https",
              url.host == "api.github.com",
              url.path == "/repos/\(repository)/releases/latest" else {
            throw AppUpdateError.untrustedReleaseURL(url?.absoluteString ?? "missing URL")
        }
    }

    private static func validateDownloadResponseURL(_ url: URL?) throws {
        let allowedHosts = [
            "github.com",
            "release-assets.githubusercontent.com",
            "objects.githubusercontent.com"
        ]
        guard let url,
              url.scheme == "https",
              let host = url.host,
              allowedHosts.contains(host) else {
            throw AppUpdateError.untrustedReleaseURL(url?.absoluteString ?? "missing URL")
        }
    }

    private static func liveLoad(_ request: URLRequest) throws -> AppUpdateHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration)
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedResult<AppUpdateHTTPResponse>()

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result.set(.failure(error))
                return
            }
            guard let response = response as? HTTPURLResponse,
                  let data else {
                result.set(.failure(AppUpdateError.invalidReleaseResponse))
                return
            }
            result.set(
                .success(
                    AppUpdateHTTPResponse(
                        data: data,
                        statusCode: response.statusCode,
                        finalURL: response.url
                    )
                )
            )
        }
        task.resume()

        guard semaphore.wait(timeout: .now() + 120) == .success else {
            task.cancel()
            session.invalidateAndCancel()
            throw URLError(.timedOut)
        }
        session.finishTasksAndInvalidate()
        return try result.get()
    }
}

private final class LockedResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, Error>?

    func set(_ value: Result<Value, Error>) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() throws -> Value {
        lock.lock()
        let value = self.value
        lock.unlock()
        guard let value else { throw AppUpdateError.invalidReleaseResponse }
        return try value.get()
    }
}

struct PreparedAppUpdate: Equatable {
    let version: AppVersion
    let stagedBundleURL: URL
    let targetBundleURL: URL
}

struct AppUpdateApplyRequest: Equatable {
    let waitPID: Int32
    let sourceBundleURL: URL
    let targetBundleURL: URL
    let expectedVersion: AppVersion

    init?(arguments: [String]) {
        guard let commandIndex = arguments.firstIndex(of: "--apply-update") else { return nil }
        let options = Array(arguments.suffix(from: arguments.index(after: commandIndex)))

        func value(after flag: String) -> String? {
            guard let index = options.firstIndex(of: flag),
                  options.indices.contains(index + 1) else {
                return nil
            }
            return options[index + 1]
        }

        guard let pidValue = value(after: "--wait-pid"),
              let waitPID = Int32(pidValue),
              waitPID > 0,
              let sourcePath = value(after: "--source-app"),
              let targetPath = value(after: "--target-app"),
              let expectedVersionValue = value(after: "--expected-version"),
              let expectedVersion = AppVersion(expectedVersionValue) else {
            return nil
        }

        self.waitPID = waitPID
        self.sourceBundleURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
        self.targetBundleURL = URL(fileURLWithPath: targetPath).standardizedFileURL
        self.expectedVersion = expectedVersion
    }
}

enum AppUpdateHelper {
    static func apply(
        _ request: AppUpdateApplyRequest,
        fileManager: FileManager = .default,
        processIsRunning: (Int32) -> Bool = defaultProcessIsRunning,
        commandRunner: @escaping (URL, [String]) -> CommandResult = CommandRunner.run,
        logger: (String) -> Void = log
    ) -> Int32 {
        let source = request.sourceBundleURL
        let target = request.targetBundleURL
        let parent = target.deletingLastPathComponent()
        guard source.deletingLastPathComponent() == parent,
              source.lastPathComponent.hasPrefix(".Codex-Awake-update-"),
              source.pathExtension == "app",
              target.lastPathComponent == AppUpdateClient.applicationName else {
            logger("Rejected unsafe update paths: \(source.path) -> \(target.path)")
            return EXIT_FAILURE
        }

        let deadline = Date().addingTimeInterval(30)
        while processIsRunning(request.waitPID) && Date() < deadline {
            usleep(100_000)
        }
        guard !processIsRunning(request.waitPID) else {
            logger("Timed out waiting for process \(request.waitPID).")
            try? fileManager.removeItem(at: source)
            return EXIT_FAILURE
        }

        guard let existingBundle = Bundle(url: target),
              existingBundle.bundleIdentifier == AppUpdateClient.bundleIdentifier else {
            logger("The target is not an existing Codex Awake application: \(target.path)")
            try? fileManager.removeItem(at: source)
            return EXIT_FAILURE
        }

        do {
            let validator = AppUpdateClient(
                loader: { _ in throw AppUpdateError.invalidReleaseResponse },
                fileManager: fileManager,
                commandRunner: commandRunner
            )
            try validator.validateApplication(
                at: source,
                expectedVersion: request.expectedVersion
            )
        } catch {
            logger("The staged update failed final verification: \(error.localizedDescription)")
            try? fileManager.removeItem(at: source)
            _ = commandRunner(URL(fileURLWithPath: "/usr/bin/open"), ["-g", target.path])
            return EXIT_FAILURE
        }

        let backup = parent.appendingPathComponent(
            ".Codex-Awake-backup-\(UUID().uuidString).app",
            isDirectory: true
        )
        var movedOriginal = false
        do {
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.moveItem(at: target, to: backup)
                movedOriginal = true
            }
            try fileManager.moveItem(at: source, to: target)

            let launch = commandRunner(
                URL(fileURLWithPath: "/usr/bin/open"),
                ["-g", target.path]
            )
            guard launch.terminationStatus == 0 else {
                throw AppUpdateError.replacementFailed(
                    launch.combinedOutput.isEmpty ? "the updated app could not relaunch" : launch.combinedOutput
                )
            }

            if movedOriginal {
                try? fileManager.removeItem(at: backup)
            }
            logger("Installed Codex Awake \(request.expectedVersion).")
            return EXIT_SUCCESS
        } catch {
            let failedUpdate = parent.appendingPathComponent(
                ".Codex-Awake-failed-\(UUID().uuidString).app",
                isDirectory: true
            )
            if fileManager.fileExists(atPath: target.path) {
                try? fileManager.moveItem(at: target, to: failedUpdate)
            }
            if movedOriginal,
               fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: target)
                _ = commandRunner(URL(fileURLWithPath: "/usr/bin/open"), ["-g", target.path])
            }
            try? fileManager.removeItem(at: failedUpdate)
            try? fileManager.removeItem(at: source)
            logger("Update replacement failed: \(error.localizedDescription)")
            return EXIT_FAILURE
        }
    }

    private static func defaultProcessIsRunning(_ processID: Int32) -> Bool {
        if kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        let fileManager = FileManager.default
        let logDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Codex Awake", isDirectory: true)
        let logURL = logDirectory.appendingPathComponent("update.log")
        try? fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        if let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }
}
