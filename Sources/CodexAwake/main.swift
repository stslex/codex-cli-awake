import AppKit
import Foundation
import IOKit.pwr_mgt

private let maximumVisibleSessions = 6

private enum AwakeMode: String, CaseIterable {
    case on
    case off
    case activeSession = "active-session"

    var title: String {
        switch self {
        case .on: return "On"
        case .off: return "Off"
        case .activeSession: return "On active session"
        }
    }

    var tag: Int {
        switch self {
        case .on: return 0
        case .off: return 1
        case .activeSession: return 2
        }
    }

    init?(tag: Int) {
        switch tag {
        case 0: self = .on
        case 1: self = .off
        case 2: self = .activeSession
        default: return nil
        }
    }
}

private final class SleepAssertion {
    private var assertionID = IOPMAssertionID(0)
    private(set) var isHeld = false
    private(set) var lastError: String?

    func setHeld(_ shouldHold: Bool) {
        guard shouldHold != isHeld else { return }

        if shouldHold {
            var newAssertionID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Codex Awake menu-bar mode" as CFString,
                &newAssertionID
            )

            guard result == kIOReturnSuccess else {
                lastError = "could not create power assertion (\(result))"
                return
            }

            assertionID = newAssertionID
            isHeld = true
            lastError = nil
        } else {
            let result = IOPMAssertionRelease(assertionID)
            if result != kIOReturnSuccess {
                lastError = "could not release power assertion (\(result))"
                return
            }

            assertionID = IOPMAssertionID(0)
            isHeld = false
            lastError = nil
        }
    }

    deinit {
        if isHeld {
            IOPMAssertionRelease(assertionID)
        }
    }
}

private enum CodexSessionDetector {
    static func activeSessionCount() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,tty=,command="]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else {
                return 0
            }

            return text.split(separator: "\n").reduce(into: 0) { count, row in
                let fields = row.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
                guard fields.count == 3,
                      let pid = Int(fields[0]),
                      pid != ProcessInfo.processInfo.processIdentifier else {
                    return
                }

                let tty = String(fields[1])
                let command = String(fields[2])
                guard isInteractiveCodexProcess(tty: tty, command: command) else {
                    return
                }
                count += 1
            }
        } catch {
            return 0
        }
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
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let defaultsKey = "awakeMode"

    private let statusItem = NSStatusBar.system.statusItem(withLength: 22)
    private let menu = NSMenu()
    private let remoteStatusItem = NSMenuItem(title: "Checking connection…", action: nil, keyEquivalent: "")
    private let remoteStartItem = NSMenuItem(title: "Start / Reconnect Remote Control", action: nil, keyEquivalent: "")
    private let recentSessionsItem = NSMenuItem(title: "Recent Sessions", action: nil, keyEquivalent: "")
    private let recentSessionsMenu = NSMenu(title: "Recent Sessions")
    private let awakeStatusItem = NSMenuItem(title: "Checking Codex sessions…", action: nil, keyEquivalent: "")
    private let assertion = SleepAssertion()
    private let detectorQueue = DispatchQueue(label: "com.stslex.CodexAwake.session-detector", qos: .utility)
    private let remoteQueue = DispatchQueue(label: "com.stslex.CodexAwake.remote", qos: .utility)
    private let relativeDateFormatter = RelativeDateTimeFormatter()

    private var modeItems: [AwakeMode: NSMenuItem] = [:]
    private var activeSessionItems: [NSMenuItem] = []
    private var currentMode: AwakeMode = .activeSession
    private var remoteStatus = RemoteStatus.checking
    private var activeSessions: [CodexSession] = []
    private var recentSessions: [CodexSession] = []
    private var activeSessionCount = 0
    private var sessionsLoaded = false
    private var scanInProgress = false
    private var remoteWorkInProgress = false
    private var lastRemoteRefresh: Date?
    private var sessionTimer: Timer?
    private var remoteTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        relativeDateFormatter.unitsStyle = .abbreviated
        configureMenu()
        loadMode()
        applyMode()
        scanForSessions()
        refreshRemoteAndSessions(force: true)

        let sessionTimer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanForSessions() }
        }
        RunLoop.main.add(sessionTimer, forMode: .common)
        self.sessionTimer = sessionTimer

        let remoteTimer = Timer(timeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRemoteAndSessions(force: true) }
        }
        RunLoop.main.add(remoteTimer, forMode: .common)
        self.remoteTimer = remoteTimer
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionTimer?.invalidate()
        remoteTimer?.invalidate()
        assertion.setHeld(false)
    }

    func menuWillOpen(_ menu: NSMenu) {
        scanForSessions()
        refreshRemoteAndSessions(force: false)
    }

    private func configureMenu() {
        menu.autoenablesItems = false
        menu.minimumWidth = 340
        menu.delegate = self

        menu.addItem(sectionHeader("REMOTE CONTROL"))
        configureStatusItem(remoteStatusItem)
        menu.addItem(remoteStatusItem)

        remoteStartItem.target = self
        remoteStartItem.action = #selector(startRemoteControl)
        remoteStartItem.image = menuSymbol("antenna.radiowaves.left.and.right")
        menu.addItem(remoteStartItem)

        menu.addItem(.separator())
        menu.addItem(sectionHeader("ACTIVE SESSIONS"))
        for _ in 0..<maximumVisibleSessions {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = 1
            item.image = menuSymbol("terminal")
            activeSessionItems.append(item)
            menu.addItem(item)
        }

        recentSessionsItem.isEnabled = true
        recentSessionsItem.image = menuSymbol("clock.arrow.circlepath")
        recentSessionsItem.submenu = recentSessionsMenu
        menu.addItem(recentSessionsItem)

        menu.addItem(.separator())
        menu.addItem(sectionHeader("AWAKE"))
        configureStatusItem(awakeStatusItem)
        menu.addItem(awakeStatusItem)

        for mode in AwakeMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.tag
            item.isEnabled = true
            menu.addItem(item)
            modeItems[mode] = item
        }

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        refreshItem.isEnabled = true
        refreshItem.image = menuSymbol("arrow.clockwise")
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit Codex Awake", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        statusItem.menu = menu
        updatePresentation()
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        return item
    }

    private func configureStatusItem(_ item: NSMenuItem) {
        item.isEnabled = false
        item.indentationLevel = 1
    }

    private func menuSymbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func loadMode() {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: Self.defaultsKey),
           let mode = AwakeMode(rawValue: stored) {
            currentMode = mode
        } else {
            currentMode = .activeSession
            defaults.set(currentMode.rawValue, forKey: Self.defaultsKey)
        }
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let selectedMode = AwakeMode(tag: sender.tag) else { return }
        currentMode = selectedMode
        UserDefaults.standard.set(selectedMode.rawValue, forKey: Self.defaultsKey)
        applyMode()
        scanForSessions()
    }

    @objc private func startRemoteControl() {
        guard !remoteWorkInProgress else { return }
        remoteStatus = RemoteStatus(
            state: .connecting,
            serverName: remoteStatus.serverName,
            environmentID: remoteStatus.environmentID,
            detail: "Connecting…",
            configuredEnabled: true
        )
        updatePresentation()
        refreshRemoteAndSessions(force: true)
    }

    @objc private func refreshNow() {
        scanForSessions()
        refreshRemoteAndSessions(force: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func scanForSessions() {
        guard !scanInProgress else { return }
        scanInProgress = true

        detectorQueue.async { [weak self] in
            let count = CodexSessionDetector.activeSessionCount()
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanInProgress = false
                self.activeSessionCount = count
                self.applyMode()
            }
        }
    }

    private func refreshRemoteAndSessions(force: Bool) {
        if !force,
           let lastRemoteRefresh,
           Date().timeIntervalSince(lastRemoteRefresh) < 5.0 {
            return
        }
        guard !remoteWorkInProgress else { return }
        remoteWorkInProgress = true
        updatePresentation()

        remoteQueue.async { [weak self] in
            let status = CodexRemoteBridge.ensureRemoteStarted()
            let activeSessions = CodexRemoteBridge.activeSessions(limit: maximumVisibleSessions)
            let activeIDs = Set(activeSessions.map(\.id))
            let recentSessions = CodexRemoteBridge
                .recentSessions(limit: maximumVisibleSessions + activeIDs.count)
                .filter { !activeIDs.contains($0.id) }
                .prefix(maximumVisibleSessions)
            DispatchQueue.main.async {
                guard let self else { return }
                self.remoteWorkInProgress = false
                self.remoteStatus = status
                self.activeSessions = activeSessions
                self.recentSessions = Array(recentSessions)
                self.sessionsLoaded = true
                self.lastRemoteRefresh = Date()
                self.updatePresentation()
            }
        }
    }

    private func applyMode() {
        let shouldHoldAssertion: Bool
        switch currentMode {
        case .on:
            shouldHoldAssertion = true
        case .off:
            shouldHoldAssertion = false
        case .activeSession:
            shouldHoldAssertion = activeSessionCount > 0
        }

        assertion.setHeld(shouldHoldAssertion)
        updatePresentation()
    }

    private func updatePresentation() {
        updateRemotePresentation()
        updateSessionPresentation()
        updateAwakePresentation()

        guard let button = statusItem.button else { return }
        button.image = StatusIconFactory.make(
            assertionActive: assertion.isHeld,
            remoteConnected: remoteStatus.state == .connected
        )
        let remoteLabel = remoteStatus.state == .connected ? "Remote connected" : "Remote \(remoteStatus.state.rawValue)"
        button.toolTip = "Codex Awake — \(remoteLabel) · Awake \(currentMode.title.lowercased())"
        button.contentTintColor = nil
    }

    private func updateRemotePresentation() {
        let title: String
        let symbolName: String
        switch remoteStatus.state {
        case .checking:
            title = remoteStatus.detail ?? "Checking connection…"
            symbolName = "arrow.triangle.2.circlepath"
        case .disabled:
            title = "Off"
            symbolName = "power.circle"
        case .connecting:
            title = remoteStatus.detail ?? "Connecting…"
            symbolName = "arrow.triangle.2.circlepath"
        case .connected:
            title = remoteStatus.serverName.map { "Connected · \($0)" } ?? "Connected"
            symbolName = "checkmark.circle.fill"
        case .errored:
            title = remoteStatus.detail.map { "Error · \($0)" } ?? "Connection error"
            symbolName = "exclamationmark.triangle.fill"
        case .unavailable:
            title = remoteStatus.detail.map { "Unavailable · \($0)" } ?? "Unavailable"
            symbolName = "questionmark.circle"
        }
        remoteStatusItem.title = title
        remoteStatusItem.image = menuSymbol(symbolName)
        remoteStatusItem.toolTip = remoteStatus.environmentID

        remoteStartItem.title = remoteStatus.state == .connected ? "Reconnect Remote Control" : "Start / Reconnect Remote Control"
        remoteStartItem.isEnabled = !remoteWorkInProgress
    }

    private func updateSessionPresentation() {
        if !sessionsLoaded {
            activeSessionItems[0].title = "Loading sessions…"
            activeSessionItems[0].toolTip = nil
            activeSessionItems[0].isHidden = false
            for item in activeSessionItems.dropFirst() { item.isHidden = true }
            updateRecentSessionsMenu()
            return
        }

        if activeSessions.isEmpty {
            activeSessionItems[0].title = "No active sessions"
            activeSessionItems[0].toolTip = nil
            activeSessionItems[0].isHidden = false
            for item in activeSessionItems.dropFirst() { item.isHidden = true }
            updateRecentSessionsMenu()
            return
        }

        for (index, item) in activeSessionItems.enumerated() {
            guard index < activeSessions.count else {
                item.isHidden = true
                continue
            }

            configureSessionItem(item, session: activeSessions[index])
            item.isHidden = false
        }
        updateRecentSessionsMenu()
    }

    private func updateRecentSessionsMenu() {
        recentSessionsMenu.removeAllItems()
        if !sessionsLoaded {
            let item = NSMenuItem(title: "Loading sessions…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            recentSessionsMenu.addItem(item)
            return
        }
        if recentSessions.isEmpty {
            let item = NSMenuItem(title: "No recent CLI sessions", action: nil, keyEquivalent: "")
            item.isEnabled = false
            recentSessionsMenu.addItem(item)
            return
        }

        for session in recentSessions {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.image = menuSymbol("clock")
            configureSessionItem(item, session: session)
            recentSessionsMenu.addItem(item)
        }
    }

    private func configureSessionItem(_ item: NSMenuItem, session: CodexSession) {
        let projectName = URL(fileURLWithPath: session.cwd).lastPathComponent
        item.title = "\(compact(session.displayName, maximumLength: 46)) · \(projectName)"
        let date = Date(timeIntervalSince1970: TimeInterval(session.recencyAt))
        let relativeDate = relativeDateFormatter.localizedString(for: date, relativeTo: Date())
        item.toolTip = "\(session.displayName)\n\(session.cwd)\nUpdated \(relativeDate)\n\(session.id)"
    }

    private func updateAwakePresentation() {
        for (mode, item) in modeItems {
            item.state = mode == currentMode ? .on : .off
        }

        if let error = assertion.lastError {
            awakeStatusItem.title = "Error · \(error)"
            awakeStatusItem.image = menuSymbol("exclamationmark.triangle.fill")
        } else {
            let assertionState = assertion.isHeld ? "On" : "Off"
            let sessionWord = activeSessionCount == 1 ? "session" : "sessions"
            awakeStatusItem.title = "\(assertionState) · \(activeSessionCount) active CLI \(sessionWord)"
            awakeStatusItem.image = menuSymbol(assertion.isHeld ? "bolt.circle.fill" : "moon.circle")
        }
    }

    private func compact(_ value: String, maximumLength: Int) -> String {
        guard value.count > maximumLength else { return value }
        return String(value.prefix(maximumLength - 1)) + "…"
    }
}

private func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(value),
          let text = String(data: data, encoding: .utf8) else {
        fputs("Could not encode result.\n", stderr)
        exit(EXIT_FAILURE)
    }
    print(text)
}

let arguments = CommandLine.arguments
if arguments.contains("--detect-sessions") {
    print(CodexSessionDetector.activeSessionCount())
    exit(EXIT_SUCCESS)
}
if arguments.contains("--remote-status") {
    let status = CodexRemoteBridge.ensureRemoteStarted()
    printJSON(status)
    exit(status.state == .connected ? EXIT_SUCCESS : EXIT_FAILURE)
}
if arguments.contains("--list-sessions") {
    printJSON(CodexRemoteBridge.recentSessions())
    exit(EXIT_SUCCESS)
}
if arguments.contains("--list-active-sessions") {
    printJSON(CodexRemoteBridge.activeSessions())
    exit(EXIT_SUCCESS)
}
if arguments.contains("--remote-start") {
    let status = CodexRemoteBridge.ensureRemoteStarted()
    printJSON(status)
    exit(status.state == .connected ? EXIT_SUCCESS : EXIT_FAILURE)
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let appDelegate = AppDelegate()
    application.delegate = appDelegate
    application.run()
}
