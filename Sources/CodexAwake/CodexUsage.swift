import Foundation

struct CodexUsageWindow: Codable, Equatable {
    let usedPercent: Int
    let windowDurationMins: Int64?
    let resetsAt: Int64?

    var remainingPercent: Int {
        100 - min(max(usedPercent, 0), 100)
    }

    var displayName: String {
        guard let windowDurationMins else { return "Window" }
        switch windowDurationMins {
        case 300:
            return "5h"
        case 10_080:
            return "Weekly"
        default:
            if windowDurationMins.isMultiple(of: 1_440) {
                return "\(windowDurationMins / 1_440)d"
            }
            if windowDurationMins.isMultiple(of: 60) {
                return "\(windowDurationMins / 60)h"
            }
            return "\(windowDurationMins)m"
        }
    }
}

struct CodexUsageCredits: Codable, Equatable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

struct CodexUsageLimit: Codable, Equatable {
    let limitID: String?
    let limitName: String?
    let primary: CodexUsageWindow?
    let secondary: CodexUsageWindow?
    let credits: CodexUsageCredits?
    let planType: String?
    let rateLimitReachedType: String?

    private enum CodingKeys: String, CodingKey {
        case limitID = "limitId"
        case limitName
        case primary
        case secondary
        case credits
        case planType
        case rateLimitReachedType
    }

    var displayName: String {
        if let limitName, !limitName.isEmpty {
            return limitName
        }
        guard let limitID, !limitID.isEmpty, limitID != "codex" else {
            return "Codex"
        }
        return limitID
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    var windows: [CodexUsageWindow] {
        [primary, secondary].compactMap { $0 }
    }

    func withFallbackID(_ fallbackID: String) -> CodexUsageLimit {
        CodexUsageLimit(
            limitID: limitID ?? fallbackID,
            limitName: limitName,
            primary: primary,
            secondary: secondary,
            credits: credits,
            planType: planType,
            rateLimitReachedType: rateLimitReachedType
        )
    }
}

struct CodexUsageSnapshot: Codable, Equatable {
    let limits: [CodexUsageLimit]
    let availableResetCredits: Int
}

struct CodexUsageMenuItemPresentation: Equatable {
    let title: String
    let symbolName: String
    let details: [CodexUsageMenuDetailPresentation]
}

struct CodexUsageMenuDetailPresentation: Equatable {
    let title: String
    let symbolName: String
}

enum CodexUsageMenuPresentation {
    static func make(snapshot: CodexUsageSnapshot) -> [CodexUsageMenuItemPresentation] {
        snapshot.limits.compactMap { limit in
            guard !limit.windows.isEmpty else { return nil }

            let constrainedWindow = limit.windows.min {
                $0.remainingPercent < $1.remainingPercent
            } ?? limit.windows[0]
            let minimumRemaining = constrainedWindow.remainingPercent
            let symbolName = minimumRemaining <= 10
                ? "exclamationmark.triangle.fill"
                : "chart.bar.xaxis"

            var details: [CodexUsageMenuDetailPresentation] = []
            for window in limit.windows {
                details.append(CodexUsageMenuDetailPresentation(
                    title: windowDetailTitle(window),
                    symbolName: "clock"
                ))
            }
            if let planType = limit.planType {
                details.append(
                    CodexUsageMenuDetailPresentation(
                        title: "Plan · \(planType.replacingOccurrences(of: "_", with: " ").capitalized)",
                        symbolName: "person.crop.circle"
                    )
                )
            }
            if let credits = limit.credits {
                if credits.unlimited {
                    details.append(
                        CodexUsageMenuDetailPresentation(
                            title: "Credits · Unlimited",
                            symbolName: "infinity"
                        )
                    )
                } else if credits.hasCredits, let balance = credits.balance {
                    details.append(
                        CodexUsageMenuDetailPresentation(
                            title: "Credits · \(balance)",
                            symbolName: "creditcard"
                        )
                    )
                }
            }
            if snapshot.availableResetCredits > 0, limit.limitID == "codex" {
                let noun = snapshot.availableResetCredits == 1 ? "reset" : "resets"
                details.append(
                    CodexUsageMenuDetailPresentation(
                        title: "\(snapshot.availableResetCredits) limit \(noun) available",
                        symbolName: "arrow.counterclockwise.circle"
                    )
                )
            }

            return CodexUsageMenuItemPresentation(
                title: "\(limit.displayName) · \(constrainedWindow.displayName) \(minimumRemaining)% left",
                symbolName: symbolName,
                details: details
            )
        }
    }

    private static func windowDetailTitle(_ window: CodexUsageWindow) -> String {
        var title = "\(window.displayName) · \(window.remainingPercent)% left"
        guard let resetsAt = window.resetsAt else { return title }

        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d, h:mm a")
        let resetDate = Date(timeIntervalSince1970: TimeInterval(resetsAt))
        title += " · resets \(formatter.string(from: resetDate))"
        return title
    }
}

enum CodexUsageError: LocalizedError, Equatable {
    case codexNotFound
    case launchFailed(String)
    case requestFailed(String)
    case appServerExited(Int32)
    case timedOut
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "Codex CLI was not found"
        case let .launchFailed(detail):
            return "Could not launch Codex: \(detail)"
        case let .requestFailed(detail):
            return detail
        case let .appServerExited(status):
            return "Codex app server exited with status \(status)"
        case .timedOut:
            return "Codex usage request timed out"
        case .invalidResponse:
            return "Codex returned an invalid usage response"
        }
    }
}

private struct CodexRateLimitResetCredits: Decodable {
    let availableCount: Int
}

private struct CodexRateLimitsResult: Decodable {
    let rateLimits: CodexUsageLimit
    let rateLimitsByLimitID: [String: CodexUsageLimit]?
    let rateLimitResetCredits: CodexRateLimitResetCredits?

    private enum CodingKeys: String, CodingKey {
        case rateLimits
        case rateLimitsByLimitID = "rateLimitsByLimitId"
        case rateLimitResetCredits
    }

    var snapshot: CodexUsageSnapshot {
        var limitsByID: [String: CodexUsageLimit] = [:]
        for (fallbackID, limit) in rateLimitsByLimitID ?? [:] {
            let resolvedLimit = limit.withFallbackID(fallbackID)
            limitsByID[resolvedLimit.limitID ?? fallbackID] = resolvedLimit
        }

        let fallbackID = rateLimits.limitID ?? "codex"
        if limitsByID[fallbackID] == nil {
            limitsByID[fallbackID] = rateLimits.withFallbackID(fallbackID)
        }

        let limits = limitsByID.values.sorted { left, right in
            if left.limitID == "codex" { return right.limitID != "codex" }
            if right.limitID == "codex" { return false }
            return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
        return CodexUsageSnapshot(
            limits: limits,
            availableResetCredits: rateLimitResetCredits?.availableCount ?? 0
        )
    }
}

private struct CodexRPCError: Decodable {
    let message: String
}

private struct CodexRateLimitsEnvelope: Decodable {
    let id: Int?
    let result: CodexRateLimitsResult?
    let error: CodexRPCError?
}

enum CodexUsageResponseParser {
    static func parseResponseLine(
        _ data: Data,
        requestID: Int = 2
    ) throws -> CodexUsageSnapshot? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseID = object["id"] as? Int,
              responseID == requestID else {
            return nil
        }

        guard let envelope = try? JSONDecoder().decode(CodexRateLimitsEnvelope.self, from: data) else {
            throw CodexUsageError.invalidResponse
        }
        if let error = envelope.error {
            throw CodexUsageError.requestFailed(error.message)
        }
        guard let result = envelope.result else {
            throw CodexUsageError.invalidResponse
        }
        return result.snapshot
    }
}

private final class CodexUsageResponseCollector {
    let semaphore = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var buffer = Data()
    private var outcome: Result<CodexUsageSnapshot, Error>?

    func append(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            if line.last == 0x0D {
                line.removeLast()
            }
            if !line.isEmpty {
                lines.append(line)
            }
        }
        lock.unlock()

        for line in lines {
            do {
                if let snapshot = try CodexUsageResponseParser.parseResponseLine(line) {
                    complete(.success(snapshot))
                }
            } catch {
                complete(.failure(error))
            }
        }
    }

    func processExited(status: Int32) {
        complete(.failure(CodexUsageError.appServerExited(status)))
    }

    func takeOutcome() -> Result<CodexUsageSnapshot, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }

    private func complete(_ newOutcome: Result<CodexUsageSnapshot, Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = newOutcome
        lock.unlock()
        semaphore.signal()
    }
}

enum CodexUsageBridge {
    static func fetch(timeout: TimeInterval = 10) throws -> CodexUsageSnapshot {
        guard let codexExecutable = CodexRemoteBridge.codexExecutableURL else {
            throw CodexUsageError.codexNotFound
        }

        let process = Process()
        process.executableURL = codexExecutable
        process.arguments = ["app-server", "--stdio"]

        let standardInput = Pipe()
        let standardOutput = Pipe()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice

        let collector = CodexUsageResponseCollector()
        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }
        process.terminationHandler = { finishedProcess in
            collector.processExited(status: finishedProcess.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            throw CodexUsageError.launchFailed(error.localizedDescription)
        }

        let request = """
        {"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-awake","title":"Codex Awake","version":"1.0"},"capabilities":{"experimentalApi":true}}}
        {"method":"initialized"}
        {"id":2,"method":"account/rateLimits/read"}

        """

        do {
            try standardInput.fileHandleForWriting.write(contentsOf: Data(request.utf8))
        } catch {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            throw CodexUsageError.requestFailed(error.localizedDescription)
        }

        let waitResult = collector.semaphore.wait(timeout: .now() + timeout)
        standardOutput.fileHandleForReading.readabilityHandler = nil
        try? standardInput.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }

        guard waitResult == .success else {
            throw CodexUsageError.timedOut
        }
        guard let outcome = collector.takeOutcome() else {
            throw CodexUsageError.invalidResponse
        }
        return try outcome.get()
    }
}
