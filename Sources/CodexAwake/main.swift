import AppKit
import Foundation
import IOKit.pwr_mgt

private let maximumVisibleSessions = 6
private let maximumVisibleUsageLimits = 4
private let screenshotPreviewUsageDetails = CommandLine.arguments.contains("--screenshot-preview-usage")
private let screenshotPreviewSessionActions = CommandLine.arguments.contains("--screenshot-preview-session")
private let screenshotPreviewEnabled = CommandLine.arguments.contains("--screenshot-preview")
    || screenshotPreviewUsageDetails
    || screenshotPreviewSessionActions
    || screenshotPreviewUsageDetails
    || screenshotPreviewSessionActions

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

private enum AppUpdateState {
    case idle
    case checking
    case noPublishedRelease
    case upToDate(latestVersion: AppVersion)
    case available(AppUpdateRelease)
    case installing(AppUpdateRelease)
    case failed(String)
}

private enum CodexUsageState {
    case loading
    case loaded(CodexUsageSnapshot)
    case failed(String)
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
        CodexProcessInspector.liveProcesses()
            .filter { $0.pid != ProcessInfo.processInfo.processIdentifier }
            .count
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let defaultsKey = "awakeMode"

    private let statusItem = NSStatusBar.system.statusItem(withLength: 22)
    private let menu = NSMenu()
    private var usageStatusItems: [NSMenuItem] = []
    private let remoteSourceItem = NSMenuItem(title: "Source", action: nil, keyEquivalent: "")
    private let remoteSourceMenu = NSMenu(title: "Remote Source")
    private let remoteStatusItem = NSMenuItem(title: "Checking connection…", action: nil, keyEquivalent: "")
    private let remoteStartItem = NSMenuItem(title: "Start / Reconnect Remote Control", action: nil, keyEquivalent: "")
    private let recentSessionsItem = NSMenuItem(title: "Recent Sessions", action: nil, keyEquivalent: "")
    private let recentSessionsMenu = NSMenu(title: "Recent Sessions")
    private let awakeStatusItem = NSMenuItem(title: "Checking Codex sessions…", action: nil, keyEquivalent: "")
    private let rejoinTerminalItem = NSMenuItem(title: "Rejoin Terminal", action: nil, keyEquivalent: "")
    private let rejoinTerminalMenu = NSMenu(title: "Rejoin Terminal")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
    private let updateStatusItem = NSMenuItem(title: "Version", action: nil, keyEquivalent: "")
    private let updateActionItem = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
    private let assertion = SleepAssertion()
    private let detectorQueue = DispatchQueue(label: "com.stslex.CodexAwake.session-detector", qos: .utility)
    private let remoteQueue = DispatchQueue(label: "com.stslex.CodexAwake.remote", qos: .utility)
    private let usageQueue = DispatchQueue(label: "com.stslex.CodexAwake.usage", qos: .utility)
    private let updateQueue = DispatchQueue(label: "com.stslex.CodexAwake.updater", qos: .utility)
    private let relativeDateFormatter = RelativeDateTimeFormatter()
    private let remoteSourceStore = RemoteControlSourceStore()
    private let profileStore = SessionProfileStore()
    private let rejoinTerminalStore = RejoinTerminalStore()
    private let loginItemManager = LoginItemManager()
    private let updateClient = AppUpdateClient()

    private var modeItems: [AwakeMode: NSMenuItem] = [:]
    private var remoteSourceItems: [RemoteControlSource: NSMenuItem] = [:]
    private var rejoinTerminalItems: [TerminalProgram: NSMenuItem] = [:]
    private var activeSessionItems: [NSMenuItem] = []
    private var currentMode: AwakeMode = .activeSession
    private var remoteSource: RemoteControlSource = .terminalCLI
    private var usageState = CodexUsageState.loading
    private var remoteStatus = RemoteStatus.checking
    private var loginItemStatus = LoginItemStatus(state: .notRegistered, desired: true, detail: nil)
    private var updateState = AppUpdateState.idle
    private var activeSessions: [CodexSession] = []
    private var recentSessions: [CodexSession] = []
    private var activeSessionProcesses: [String: InteractiveCodexProcess] = [:]
    private var activeSessionCount = 0
    private var sessionsLoaded = false
    private var scanInProgress = false
    private var remoteWorkInProgress = false
    private var usageWorkInProgress = false
    private var lastRemoteRefresh: Date?
    private var lastUsageRefresh: Date?
    private var lastUpdateCheck: Date?
    private var sessionTimer: Timer?
    private var remoteTimer: Timer?
    private var usageTimer: Timer?
    private var screenshotBackdropWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = AppIconFactory.make(
            size: NSSize(width: 256, height: 256)
        )
        relativeDateFormatter.unitsStyle = .abbreviated
        remoteSource = screenshotPreviewEnabled ? .terminalCLI : remoteSourceStore.source
        configureMenu()

        if screenshotPreviewEnabled {
            configureScreenshotPreview()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openScreenshotPreviewMenu()
            }
            return
        }

        loadMode()
        loginItemStatus = loginItemManager.reconcile()
        applyMode()
        scanForSessions()
        refreshUsage(force: true)
        refreshRemoteAndSessions(force: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.checkForUpdatesIfNeeded()
        }

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

        let usageTimer = Timer(timeInterval: 300.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshUsage(force: true) }
        }
        RunLoop.main.add(usageTimer, forMode: .common)
        self.usageTimer = usageTimer
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionTimer?.invalidate()
        remoteTimer?.invalidate()
        usageTimer?.invalidate()
        assertion.setHeld(false)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if screenshotPreviewEnabled {
            updatePresentation()
            applyScreenshotPreviewVisibility()
            return
        }

        loginItemStatus = loginItemManager.status()
        scanForSessions()
        refreshUsage(force: false)
        refreshRemoteAndSessions(force: false)
        checkForUpdatesIfNeeded()
        updatePresentation()
    }

    private func configureMenu() {
        menu.autoenablesItems = false
        menu.minimumWidth = 340
        menu.delegate = self

        menu.addItem(sectionHeader("USAGE"))
        for _ in 0..<maximumVisibleUsageLimits {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            configureStatusItem(item)
            item.isHidden = true
            usageStatusItems.append(item)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(sectionHeader("REMOTE CONTROL"))

        remoteSourceItem.image = menuSymbol("point.3.connected.trianglepath.dotted")
        remoteSourceItem.isEnabled = true
        remoteSourceItem.submenu = remoteSourceMenu
        for source in RemoteControlSource.allCases {
            let item = NSMenuItem(
                title: source.title,
                action: #selector(selectRemoteControlSource(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = source.selectionTag
            item.isEnabled = true
            remoteSourceMenu.addItem(item)
            remoteSourceItems[source] = item
        }
        menu.addItem(remoteSourceItem)

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
        menu.addItem(sectionHeader("APP"))

        rejoinTerminalItem.image = menuSymbol("terminal")
        rejoinTerminalItem.isEnabled = true
        rejoinTerminalItem.submenu = rejoinTerminalMenu
        for terminal in TerminalProgram.selectablePrograms {
            let item = NSMenuItem(
                title: terminal.displayName,
                action: #selector(selectRejoinTerminal(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = terminal.selectionTag
            item.isEnabled = true
            rejoinTerminalMenu.addItem(item)
            rejoinTerminalItems[terminal] = item
        }
        menu.addItem(rejoinTerminalItem)

        launchAtLoginItem.target = self
        launchAtLoginItem.action = #selector(toggleLaunchAtLogin)
        launchAtLoginItem.isEnabled = true
        menu.addItem(launchAtLoginItem)

        configureStatusItem(updateStatusItem)
        menu.addItem(updateStatusItem)

        updateActionItem.target = self
        updateActionItem.action = #selector(performUpdateAction)
        updateActionItem.isEnabled = true
        menu.addItem(updateActionItem)

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

    private func configureScreenshotPreview() {
        if let screen = NSScreen.main {
            let backdropSize = NSSize(width: 1_100, height: 680)
            let backdropFrame = NSRect(
                x: screen.frame.maxX - backdropSize.width,
                y: screen.frame.maxY - backdropSize.height,
                width: backdropSize.width,
                height: backdropSize.height
            )
            let backdrop = NSWindow(
                contentRect: backdropFrame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            backdrop.backgroundColor = .windowBackgroundColor
            backdrop.isOpaque = true
            backdrop.hasShadow = false
            backdrop.ignoresMouseEvents = true
            backdrop.collectionBehavior = [.canJoinAllSpaces, .stationary]
            backdrop.orderFrontRegardless()
            screenshotBackdropWindow = backdrop
        }

        usageState = .loaded(
            CodexUsageSnapshot(
                limits: [
                    CodexUsageLimit(
                        limitID: "codex",
                        limitName: nil,
                        primary: CodexUsageWindow(
                            usedPercent: 22,
                            windowDurationMins: 10_080,
                            resetsAt: 1_788_424_200
                        ),
                        secondary: nil,
                        credits: CodexUsageCredits(hasCredits: false, unlimited: false, balance: "0"),
                        planType: "pro",
                        rateLimitReachedType: nil
                    ),
                    CodexUsageLimit(
                        limitID: "codex_bengalfox",
                        limitName: "GPT-5.3-Codex-Spark",
                        primary: CodexUsageWindow(
                            usedPercent: 8,
                            windowDurationMins: 300,
                            resetsAt: 1_788_089_400
                        ),
                        secondary: CodexUsageWindow(
                            usedPercent: 36,
                            windowDurationMins: 10_080,
                            resetsAt: 1_788_251_400
                        ),
                        credits: nil,
                        planType: "pro",
                        rateLimitReachedType: nil
                    )
                ],
                availableResetCredits: 1
            )
        )
        remoteStatus = RemoteStatus(
            state: .connected,
            serverName: "MacBook",
            environmentID: "preview",
            detail: nil,
            configuredEnabled: true
        )
        let now = Int64(Date().timeIntervalSince1970)
        activeSessions = [
            CodexSession(
                id: "preview-auth",
                displayName: "Improve authentication flow",
                cwd: "/Users/codex/Projects/sample-app",
                recencyAt: now
            ),
            CodexSession(
                id: "preview-release",
                displayName: "Document the release process",
                cwd: "/Users/codex/Projects/codex-cli-awake",
                recencyAt: now - 180
            ),
            CodexSession(
                id: "preview-tests",
                displayName: "Add regression coverage for session loading",
                cwd: "/Users/codex/Projects/desktop-tools",
                recencyAt: now - 360
            )
        ]
        activeSessionProcesses = Dictionary(
            uniqueKeysWithValues: activeSessions.enumerated().map { index, session in
                (
                    session.id,
                    InteractiveCodexProcess(
                        pid: 10_000 + index,
                        tty: "ttys00\(index)",
                        command: "codex",
                        workingDirectory: session.cwd,
                        sessionID: session.id,
                        profile: .defaultProfile
                    )
                )
            }
        )
        recentSessions = [
            CodexSession(
                id: "preview-readme",
                displayName: "Refresh README screenshots",
                cwd: "/Users/codex/Projects/codex-cli-awake",
                recencyAt: now - 3_600
            )
        ]
        activeSessionCount = 3
        sessionsLoaded = true
        loginItemStatus = LoginItemStatus(state: .enabled, desired: true, detail: nil)
        currentMode = .activeSession
        assertion.setHeld(true)
        updatePresentation()
        applyScreenshotPreviewVisibility()
    }

    private func applyScreenshotPreviewVisibility() {
        if screenshotPreviewUsageDetails {
            let visibleUsageItems = usageStatusItems.filter { !$0.isHidden }
            menu.items.forEach { $0.isHidden = true }
            menu.items.first(where: { $0.title == "USAGE" })?.isHidden = false
            visibleUsageItems.forEach { $0.isHidden = false }
        }
        if screenshotPreviewSessionActions {
            let visibleSessionItems = activeSessionItems.filter { !$0.isHidden }
            menu.items.forEach { $0.isHidden = true }
            let spacer = menu.items[0]
            spacer.attributedTitle = NSAttributedString(string: " ")
            spacer.isHidden = false
            menu.items.first(where: { $0.title == "ACTIVE SESSIONS" })?.isHidden = false
            for item in visibleSessionItems {
                item.toolTip = nil
                item.isHidden = false
            }
            recentSessionsItem.isHidden = false
        }
    }

    private func openScreenshotPreviewMenu() {
        guard let button = statusItem.button else { return }

        let verticalOffset: CGFloat?
        if screenshotPreviewUsageDetails {
            verticalOffset = 36
        } else if screenshotPreviewSessionActions {
            verticalOffset = 70
        } else {
            verticalOffset = nil
        }

        if let verticalOffset,
           let window = button.window,
           let screen = window.screen ?? NSScreen.main {
            let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
            let point = CGPoint(
                x: buttonRect.minX + 170,
                y: screen.frame.maxY - buttonRect.minY + verticalOffset
            )
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.6) {
                CGWarpMouseCursorPosition(point)
                CGEvent(
                    mouseEventSource: nil,
                    mouseType: .mouseMoved,
                    mouseCursorPosition: point,
                    mouseButton: .left
                )?.post(tap: .cghidEventTap)
            }
        }

        button.performClick(nil)
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

    @objc private func selectRejoinTerminal(_ sender: NSMenuItem) {
        guard let terminal = TerminalProgram(selectionTag: sender.tag) else { return }
        rejoinTerminalStore.set(terminal)
        updatePresentation()
    }

    @objc private func selectRemoteControlSource(_ sender: NSMenuItem) {
        guard !remoteWorkInProgress,
              let selectedSource = RemoteControlSource(selectionTag: sender.tag),
              selectedSource != remoteSource else {
            return
        }

        switch selectedSource {
        case .terminalCLI:
            switchRemoteControlToTerminal()
        case .codexDesktop:
            switchRemoteControlToDesktop()
        }
    }

    @objc private func startRemoteControl() {
        guard !remoteWorkInProgress else { return }
        guard remoteSource == .terminalCLI else {
            showCodexDesktopRemoteInstructions()
            return
        }
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

    private func switchRemoteControlToTerminal() {
        let alert = appAlert(style: .warning)
        alert.messageText = "Switch Remote Control to Terminal CLI?"
        alert.informativeText = "First turn off Allow connections in Codex Desktop under Settings > Connections > Control this Mac. Codex Awake will then start and maintain the Terminal CLI host."
        alert.addButton(withTitle: "Switch to Terminal CLI")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        remoteSource = .terminalCLI
        remoteSourceStore.set(remoteSource)
        remoteStatus = RemoteStatus(
            state: .connecting,
            serverName: nil,
            environmentID: nil,
            detail: "Connecting Terminal CLI…",
            configuredEnabled: true
        )
        updatePresentation()
        refreshRemoteAndSessions(force: true)
    }

    private func switchRemoteControlToDesktop() {
        guard codexDesktopApplicationURL() != nil else {
            showError("Codex Desktop could not be found. Install the latest Codex Desktop app before releasing the Terminal CLI Remote host.")
            return
        }

        let alert = appAlert(style: .warning)
        alert.messageText = "Switch Remote Control to Codex Desktop?"
        alert.informativeText = "Codex Awake must stop the Terminal CLI Remote host before Codex Desktop can claim it. This can disconnect TUI clients attached through the shared CLI daemon."
        alert.addButton(withTitle: "Stop CLI and Switch")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        remoteSource = .codexDesktop
        remoteSourceStore.set(remoteSource)
        remoteWorkInProgress = true
        remoteStatus = RemoteStatus(
            state: .connecting,
            serverName: nil,
            environmentID: nil,
            detail: "Stopping Terminal CLI host…",
            configuredEnabled: true
        )
        updatePresentation()

        remoteQueue.async { [weak self] in
            let error = CodexRemoteBridge.stopTerminalRemoteControl()
            let status = CodexRemoteBridge.desktopManagedStatus(
                isDesktopRunning: CodexRemoteBridge.codexDesktopIsRunning()
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.remoteWorkInProgress = false
                if let error {
                    self.remoteSource = .terminalCLI
                    self.remoteSourceStore.set(.terminalCLI)
                    self.remoteStatus = RemoteStatus(
                        state: .errored,
                        serverName: nil,
                        environmentID: nil,
                        detail: error,
                        configuredEnabled: true
                    )
                    self.updatePresentation()
                    self.showError("Could not stop the Terminal CLI Remote host:\n\(error)")
                    return
                }

                self.remoteStatus = status
                self.lastRemoteRefresh = Date()
                self.updatePresentation()
                self.showCodexDesktopRemoteInstructions()
            }
        }
    }

    private func showCodexDesktopRemoteInstructions() {
        let alert = appAlert()
        alert.messageText = "Finish in Codex Desktop"
        alert.informativeText = "Open Settings > Connections > Control this Mac and turn on Allow connections. If it is already on, turn it off and on again so Codex Desktop claims the released Remote host."
        alert.addButton(withTitle: "Open Codex")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        openCodexDesktop()
    }

    private func openCodexDesktop() {
        let workspace = NSWorkspace.shared
        guard let appURL = codexDesktopApplicationURL(),
              workspace.open(appURL) else {
            showError("Codex Desktop could not be opened. Open it manually, then configure Remote Control under Settings > Connections.")
            return
        }
    }

    private func codexDesktopApplicationURL() -> URL? {
        let workspace = NSWorkspace.shared
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let fallbackCandidates = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            URL(fileURLWithPath: "/Applications/Codex.app"),
            home.appendingPathComponent("Applications/ChatGPT.app"),
            home.appendingPathComponent("Applications/Codex.app")
        ]
        return workspace.urlForApplication(withBundleIdentifier: "com.openai.codex")
            ?? fallbackCandidates.first(where: { fileManager.fileExists(atPath: $0.path) })
    }

    @objc private func refreshNow() {
        loginItemStatus = loginItemManager.status()
        scanForSessions()
        refreshUsage(force: true)
        refreshRemoteAndSessions(force: true)
        updatePresentation()
    }

    @objc private func toggleLaunchAtLogin() {
        let presentation = LoginItemMenuPresentation.make(status: loginItemStatus)
        switch presentation.action {
        case .register:
            loginItemStatus = loginItemManager.register()
        case .unregister:
            loginItemStatus = loginItemManager.unregister()
        case .openSettings:
            LoginItemManager.openSystemSettings()
            return
        }

        updatePresentation()
        if let detail = loginItemStatus.detail,
           loginItemStatus.state != .requiresApproval {
            showError("Launch at Login could not be updated:\n\(detail)")
        }
    }

    @objc private func performUpdateAction() {
        switch updateState {
        case let .available(release):
            offerToInstall(release)
        case .checking, .installing:
            return
        case .idle, .noPublishedRelease, .upToDate, .failed:
            checkForUpdates(userInitiated: true)
        }
    }

    @objc private func openSessionInChatGPT(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? CodexSession,
              let url = URL(string: "codex://threads/\(session.id)") else {
            showError("The ChatGPT thread link could not be created.")
            return
        }
        if !NSWorkspace.shared.open(url) {
            showError("ChatGPT could not open this session.")
        }
    }

    @objc private func focusSessionInTerminal(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? CodexSession else { return }
        guard let process = activeSessionProcesses[session.id] else {
            showError("The active Codex process could not be matched to this session. Refresh the menu and try again.")
            return
        }

        detectorQueue.async { [weak self] in
            let result = TerminalSessionFocuser.focus(
                process: process,
                sessionID: session.id,
                sessionName: session.displayName
            )
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .focused:
                    break
                case .surfaceUnavailable:
                    self.offerToRejoinSession(session)
                case let .failed(message):
                    self.showError(message)
                }
            }
        }
    }

    @objc private func resumeSession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? CodexSession else { return }
        launchSession(session, action: .resume)
    }

    @objc private func rejoinSession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? CodexSession else { return }
        launchSession(session, action: .rejoin)
    }

    @objc private func forkSession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? CodexSession else { return }
        launchSession(session, action: .fork)
    }

    @objc private func revealWorkingDirectory(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? CodexSession else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: session.cwd, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            showError("The working directory no longer exists:\n\(session.cwd)")
            return
        }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
    }

    @objc private func copySessionValue(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    @objc private func chooseSessionProfile(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? CodexSession else { return }
        _ = promptForProfile(
            session: session,
            current: profileStore.profile(for: session.id),
            confirmationTitle: "Save"
        )
        updatePresentation()
    }

    @objc private func archiveSession(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? CodexSession else { return }

        let alert = appAlert(style: .warning)
        alert.messageText = "Archive this Codex session?"
        alert.informativeText = "“\(session.displayName)” will be removed from Recent Sessions. You can unarchive it later with Codex CLI."
        alert.addButton(withTitle: "Archive")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        remoteQueue.async { [weak self] in
            let error = CodexRemoteBridge.archiveSession(id: session.id)
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.showError(error)
                } else {
                    self.refreshRemoteAndSessions(force: true)
                }
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func offerToRejoinSession(_ session: CodexSession) {
        let terminal = rejoinTerminalStore.program
        let alert = appAlert()
        alert.messageText = "Original terminal is no longer available"
        alert.informativeText = "“\(session.displayName)” is still running, but its original terminal surface no longer exists. Rejoin the same Codex session in \(terminal.displayName)? The existing Codex process will not be stopped."
        alert.addButton(withTitle: "Rejoin in \(terminal.displayName)")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        launchSession(session, action: .rejoin)
    }

    private func launchSession(_ session: CodexSession, action: SessionTerminalAction) {
        let profile: SessionProfile
        if let storedProfile = profileStore.profile(for: session.id) {
            profile = storedProfile
        } else {
            guard let selectedProfile = promptForProfile(
                session: session,
                current: nil,
                confirmationTitle: action.confirmationTitle
            ) else {
                return
            }
            profile = selectedProfile
        }

        guard let executable = CodexRemoteBridge.codexExecutableURL else {
            showError("Codex CLI was not found.")
            return
        }
        let arguments = CodexSessionCommand.arguments(
            action: action,
            sessionID: session.id,
            profile: profile
        )
        let script = CodexSessionCommand.terminalScript(
            executablePath: executable.path,
            arguments: arguments,
            workingDirectory: session.cwd
        )
        let terminal = action.launchTerminal(rejoinTerminal: rejoinTerminalStore.program)

        detectorQueue.async { [weak self] in
            let result = TerminalLauncher.launch(script: script, terminal: terminal)
            DispatchQueue.main.async {
                guard let self else { return }
                if result.terminationStatus != 0 {
                    self.showError(result.combinedOutput.isEmpty ? "Terminal could not launch Codex." : result.combinedOutput)
                }
            }
        }
    }

    @discardableResult
    private func promptForProfile(
        session: CodexSession,
        current: SessionProfile?,
        confirmationTitle: String
    ) -> SessionProfile? {
        let choices = CodexRemoteBridge.availableProfiles().map(SessionProfile.named) + [.defaultProfile]
        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 28), pullsDown: false)
        popUp.addItems(withTitles: choices.map(\.displayName))
        if let current, let index = choices.firstIndex(of: current) {
            popUp.selectItem(at: index)
        }

        let alert = appAlert()
        alert.messageText = current == nil ? "Choose this session's Codex profile" : "Session profile"
        alert.informativeText = "Codex does not store the --profile name in thread metadata. Choose the profile originally used by “\(session.displayName)”. Codex Awake will remember it for Resume and Fork."
        alert.accessoryView = popUp
        alert.addButton(withTitle: confirmationTitle)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              choices.indices.contains(popUp.indexOfSelectedItem) else {
            return nil
        }

        let selected = choices[popUp.indexOfSelectedItem]
        profileStore.set(selected, for: session.id)
        return selected
    }

    private func showError(_ message: String) {
        let alert = appAlert(style: .warning)
        alert.messageText = "Codex Awake"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func checkForUpdatesIfNeeded() {
        guard let lastUpdateCheck else {
            checkForUpdates(userInitiated: false)
            return
        }
        if Date().timeIntervalSince(lastUpdateCheck) >= 6 * 60 * 60 {
            checkForUpdates(userInitiated: false)
        }
    }

    private func checkForUpdates(userInitiated: Bool) {
        switch updateState {
        case .checking, .installing:
            return
        case .idle, .noPublishedRelease, .upToDate, .available, .failed:
            break
        }

        let currentVersion = appVersion
        let updateClient = updateClient
        let currentBundleURL = Bundle.main.bundleURL
        updateState = .checking
        updatePresentation()

        updateQueue.async { [weak self] in
            guard let self else { return }
            do {
                let availability = try updateClient.check(
                    currentVersion: currentVersion,
                    allowSameVersionUpgrade: updateClient.requiresSignedReleaseMigration(
                        at: currentBundleURL
                    )
                )
                DispatchQueue.main.async {
                    self.lastUpdateCheck = Date()
                    switch availability {
                    case .noPublishedRelease:
                        self.updateState = .noPublishedRelease
                        if userInitiated {
                            self.showUpdateInformation(
                                title: "No Published Updates",
                                detail: "No signed Codex Awake release has been published yet."
                            )
                        }
                    case let .upToDate(latestVersion):
                        self.updateState = .upToDate(latestVersion: latestVersion)
                        if userInitiated {
                            self.showUpdateInformation(
                                title: "Codex Awake Is Up to Date",
                                detail: "Version \(currentVersion) is the newest published release."
                            )
                        }
                    case let .available(release):
                        self.updateState = .available(release)
                        if userInitiated {
                            self.offerToInstall(release)
                        }
                    }
                    self.updatePresentation()
                }
            } catch {
                DispatchQueue.main.async {
                    self.lastUpdateCheck = Date()
                    self.updateState = .failed(error.localizedDescription)
                    self.updatePresentation()
                    if userInitiated {
                        self.showError("Update check failed:\n\(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func offerToInstall(_ release: AppUpdateRelease) {
        let alert = appAlert()
        let replacesSourceBuild = release.version.description == appVersion
        alert.messageText = replacesSourceBuild
            ? "Install the signed Codex Awake \(release.version) release?"
            : "Install Codex Awake \(release.version)?"
        var detail = replacesSourceBuild
            ? "This source-built copy will be replaced by the Developer ID-signed and notarized release of the same version. The release will be downloaded from GitHub, verified, installed, and then Codex Awake will relaunch. Active Codex CLI sessions and the selected Remote Control owner will not be stopped."
            : "The notarized update will be downloaded from GitHub, verified, installed, and then Codex Awake will relaunch. Active Codex CLI sessions and the selected Remote Control owner will not be stopped."
        if let notes = release.releaseNotes,
           !notes.isEmpty {
            detail += "\n\n" + compact(notes, maximumLength: 900)
        }
        alert.informativeText = detail
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "View Release")
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            install(release)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(release.releasePageURL)
        default:
            break
        }
    }

    private func install(_ release: AppUpdateRelease) {
        let targetBundleURL = Bundle.main.bundleURL
        let updateClient = updateClient
        let processID = ProcessInfo.processInfo.processIdentifier
        updateState = .installing(release)
        updatePresentation()

        updateQueue.async { [weak self] in
            guard let self else { return }
            do {
                let prepared = try updateClient.prepare(
                    release: release,
                    replacing: targetBundleURL
                )
                try updateClient.launchInstaller(
                    for: prepared,
                    waitingFor: processID
                )
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self.updateState = .failed(error.localizedDescription)
                    self.updatePresentation()
                    self.showError("Update installation failed:\n\(error.localizedDescription)")
                }
            }
        }
    }

    private func showUpdateInformation(title: String, detail: String) {
        let alert = appAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
        let source = remoteSource

        remoteQueue.async { [weak self] in
            let status = RemoteControlSourceResolver.status(for: source)
            let loadedSessions = CodexRemoteBridge.loadedSessions(limit: 20)
            let liveProcesses = CodexProcessInspector.liveProcesses(includeWorkingDirectories: true)
            let resolvedProcesses = CodexProcessInspector.resolvedSessionProcesses(
                sessions: loadedSessions,
                processes: liveProcesses
            )
            let activeSessions = Array(
                loadedSessions
                    .filter { resolvedProcesses[$0.id] != nil }
                    .prefix(maximumVisibleSessions)
            )
            let activeIDs = Set(activeSessions.map(\.id))
            let activeSessionProcesses = resolvedProcesses.filter { activeIDs.contains($0.key) }
            let discoveredProfiles = activeSessionProcesses.mapValues(\.profile)
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
                self.activeSessionProcesses = activeSessionProcesses
                for (sessionID, profile) in discoveredProfiles {
                    self.profileStore.set(profile, for: sessionID)
                }
                self.sessionsLoaded = true
                self.lastRemoteRefresh = Date()
                self.updatePresentation()
            }
        }
    }

    private func refreshUsage(force: Bool) {
        if !force,
           let lastUsageRefresh,
           Date().timeIntervalSince(lastUsageRefresh) < 60.0 {
            return
        }
        guard !usageWorkInProgress else { return }
        usageWorkInProgress = true
        updatePresentation()

        usageQueue.async { [weak self] in
            let newState: CodexUsageState
            do {
                newState = .loaded(try CodexUsageBridge.fetch())
            } catch {
                newState = .failed(error.localizedDescription)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.usageWorkInProgress = false
                self.usageState = newState
                self.lastUsageRefresh = Date()
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
        updateUsagePresentation()
        updateRemotePresentation()
        updateSessionPresentation()
        updateAwakePresentation()
        updateRejoinTerminalPresentation()
        updateLoginItemPresentation()
        updateUpdatePresentation()

        guard let button = statusItem.button else { return }
        button.image = StatusIconFactory.make(
            assertionActive: assertion.isHeld,
            remoteConnected: remoteStatus.state == .connected
        )
        let remoteLabel = remoteStatus.state == .managed
            ? "Remote managed by Codex Desktop"
            : (remoteStatus.state == .connected ? "Remote connected" : "Remote \(remoteStatus.state.rawValue)")
        button.toolTip = "Codex Awake — \(remoteLabel) · Awake \(currentMode.title.lowercased())"
        button.contentTintColor = nil
    }

    private func updateUsagePresentation() {
        guard let firstItem = usageStatusItems.first else { return }

        switch usageState {
        case .loading:
            firstItem.title = "Loading usage…"
            firstItem.image = menuSymbol("arrow.triangle.2.circlepath")
            firstItem.toolTip = nil
            firstItem.submenu = nil
            firstItem.isEnabled = false
            firstItem.isHidden = false
            for item in usageStatusItems.dropFirst() { item.isHidden = true }

        case let .failed(detail):
            firstItem.title = "Usage unavailable"
            firstItem.image = menuSymbol("exclamationmark.triangle.fill")
            firstItem.toolTip = detail
            firstItem.submenu = nil
            firstItem.isEnabled = false
            firstItem.isHidden = false
            for item in usageStatusItems.dropFirst() { item.isHidden = true }

        case let .loaded(snapshot):
            let presentations = CodexUsageMenuPresentation.make(snapshot: snapshot)
            guard !presentations.isEmpty else {
                firstItem.title = "No usage data"
                firstItem.image = menuSymbol("questionmark.circle")
                firstItem.toolTip = "Codex returned no rate-limit windows."
                firstItem.submenu = nil
                firstItem.isEnabled = false
                firstItem.isHidden = false
                for item in usageStatusItems.dropFirst() { item.isHidden = true }
                return
            }

            for (index, item) in usageStatusItems.enumerated() {
                guard index < presentations.count else {
                    item.submenu = nil
                    item.toolTip = nil
                    item.isEnabled = false
                    item.isHidden = true
                    continue
                }
                let presentation = presentations[index]
                item.title = presentation.title
                item.image = menuSymbol(presentation.symbolName)
                item.toolTip = nil
                item.submenu = usageDetailsMenu(for: presentation)
                item.isEnabled = true
                item.isHidden = false
            }
        }
    }

    private func usageDetailsMenu(for presentation: CodexUsageMenuItemPresentation) -> NSMenu {
        let detailsMenu = NSMenu(title: presentation.title)
        detailsMenu.autoenablesItems = false
        for detail in presentation.details {
            let item = NSMenuItem(title: detail.title, action: nil, keyEquivalent: "")
            item.image = menuSymbol(detail.symbolName)
            item.isEnabled = false
            detailsMenu.addItem(item)
        }
        return detailsMenu
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
        case .managed:
            title = remoteStatus.detail ?? "Managed by Codex Desktop"
            symbolName = "macwindow"
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

        remoteSourceItem.title = "Source · \(remoteSource.title)"
        remoteSourceItem.image = menuSymbol(
            remoteSource == .terminalCLI ? "terminal" : "macwindow"
        )
        remoteSourceItem.isEnabled = !remoteWorkInProgress
        for (source, item) in remoteSourceItems {
            item.state = source == remoteSource ? .on : .off
            item.isEnabled = !remoteWorkInProgress
        }

        if remoteSource == .codexDesktop {
            remoteStartItem.title = "Open Codex Remote Settings…"
            remoteStartItem.image = menuSymbol("macwindow")
        } else {
            remoteStartItem.title = remoteStatus.state == .connected
                ? "Reconnect Remote Control"
                : "Start / Reconnect Remote Control"
            remoteStartItem.image = menuSymbol("antenna.radiowaves.left.and.right")
        }
        remoteStartItem.isEnabled = !remoteWorkInProgress
    }

    private func updateSessionPresentation() {
        if !sessionsLoaded {
            activeSessionItems[0].title = "Loading sessions…"
            activeSessionItems[0].toolTip = nil
            activeSessionItems[0].submenu = nil
            activeSessionItems[0].isEnabled = false
            activeSessionItems[0].isHidden = false
            for item in activeSessionItems.dropFirst() { item.isHidden = true }
            updateRecentSessionsMenu()
            return
        }

        if activeSessions.isEmpty {
            activeSessionItems[0].title = "No active sessions"
            activeSessionItems[0].toolTip = nil
            activeSessionItems[0].submenu = nil
            activeSessionItems[0].isEnabled = false
            activeSessionItems[0].isHidden = false
            for item in activeSessionItems.dropFirst() { item.isHidden = true }
            updateRecentSessionsMenu()
            return
        }

        for (index, item) in activeSessionItems.enumerated() {
            guard index < activeSessions.count else {
                item.submenu = nil
                item.isEnabled = false
                item.isHidden = true
                continue
            }

            configureSessionItem(item, session: activeSessions[index], isActive: true)
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
            item.isEnabled = true
            item.image = menuSymbol("clock")
            configureSessionItem(item, session: session, isActive: false)
            recentSessionsMenu.addItem(item)
        }
    }

    private func configureSessionItem(_ item: NSMenuItem, session: CodexSession, isActive: Bool) {
        item.title = CodexSessionMenuPresentation.title(for: session)
        let date = Date(timeIntervalSince1970: TimeInterval(session.recencyAt))
        let relativeDate = relativeDateFormatter.localizedString(for: date, relativeTo: Date())
        let profile = profileStore.profile(for: session.id)?.displayName ?? "Unknown profile"
        item.toolTip = "\(session.displayName)\n\(session.cwd)\nProfile: \(profile)\nUpdated \(relativeDate)\n\(session.id)"
        item.isEnabled = true
        item.submenu = sessionActionsMenu(for: session, isActive: isActive)
    }

    private func sessionActionsMenu(for session: CodexSession, isActive: Bool) -> NSMenu {
        let actions = NSMenu(title: session.displayName)
        actions.autoenablesItems = false

        if isActive, activeSessionProcesses[session.id] != nil {
            actions.addItem(sessionActionItem(
                title: "Focus in Terminal",
                symbol: "scope",
                action: #selector(focusSessionInTerminal(_:)),
                session: session
            ))
        } else if isActive {
            actions.addItem(sessionActionItem(
                title: "Rejoin in \(rejoinTerminalStore.program.displayName)",
                symbol: "play.fill",
                action: #selector(rejoinSession(_:)),
                session: session
            ))
        }

        actions.addItem(sessionActionItem(
            title: "Open in ChatGPT",
            symbol: "bubble.left.and.bubble.right",
            action: #selector(openSessionInChatGPT(_:)),
            session: session
        ))

        if !isActive {
            actions.addItem(sessionActionItem(
                title: "Resume in Terminal",
                symbol: "play.fill",
                action: #selector(resumeSession(_:)),
                session: session
            ))
        }

        actions.addItem(sessionActionItem(
            title: "Fork in New Terminal",
            symbol: "arrow.triangle.branch",
            action: #selector(forkSession(_:)),
            session: session
        ))
        actions.addItem(sessionActionItem(
            title: "Reveal Working Directory",
            symbol: "folder",
            action: #selector(revealWorkingDirectory(_:)),
            session: session
        ))

        let copyItem = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
        copyItem.isEnabled = true
        copyItem.image = menuSymbol("doc.on.doc")
        copyItem.submenu = copyMenu(for: session)
        actions.addItem(copyItem)
        actions.addItem(.separator())

        let profileTitle: String
        if let profile = profileStore.profile(for: session.id) {
            profileTitle = "Profile: \(profile.displayName)…"
        } else {
            profileTitle = "Set Session Profile…"
        }
        actions.addItem(sessionActionItem(
            title: profileTitle,
            symbol: "person.crop.circle.badge.checkmark",
            action: #selector(chooseSessionProfile(_:)),
            session: session
        ))

        if !isActive {
            actions.addItem(.separator())
            actions.addItem(sessionActionItem(
                title: "Archive Session…",
                symbol: "archivebox",
                action: #selector(archiveSession(_:)),
                session: session
            ))
        }
        return actions
    }

    private func sessionActionItem(
        title: String,
        symbol: String,
        action: Selector,
        session: CodexSession
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = session
        item.image = menuSymbol(symbol)
        item.isEnabled = true
        return item
    }

    private func copyMenu(for session: CodexSession) -> NSMenu {
        let menu = NSMenu(title: "Copy")
        menu.autoenablesItems = false
        let values = [
            ("Name", session.displayName),
            ("Session ID", session.id),
            ("Working Directory", session.cwd),
            ("ChatGPT Link", "codex://threads/\(session.id)")
        ]
        for (title, value) in values {
            let item = NSMenuItem(title: title, action: #selector(copySessionValue(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.isEnabled = true
            menu.addItem(item)
        }
        return menu
    }

    private func updateAwakePresentation() {
        for (mode, item) in modeItems {
            item.state = mode == currentMode ? .on : .off
        }

        if let error = assertion.lastError {
            awakeStatusItem.title = "Error · \(error)"
            awakeStatusItem.image = menuSymbol("exclamationmark.triangle.fill")
        } else {
            let assertionState = assertion.isHeld ? "Preventing sleep" : "Sleep allowed"
            let cliWord = activeSessionCount == 1 ? "CLI" : "CLIs"
            awakeStatusItem.title = "\(assertionState) · \(activeSessionCount) interactive \(cliWord)"
            awakeStatusItem.image = menuSymbol(assertion.isHeld ? "bolt.circle.fill" : "moon.circle")
        }
    }

    private func updateLoginItemPresentation() {
        let presentation = LoginItemMenuPresentation.make(status: loginItemStatus)
        launchAtLoginItem.title = presentation.title
        launchAtLoginItem.image = presentation.isChecked ? nil : menuSymbol(presentation.symbolName)
        launchAtLoginItem.state = presentation.isChecked ? .on : .off
        launchAtLoginItem.toolTip = loginItemStatus.detail
    }

    private func updateRejoinTerminalPresentation() {
        let selectedTerminal = rejoinTerminalStore.program
        rejoinTerminalItem.title = "Rejoin Terminal · \(selectedTerminal.displayName)"
        rejoinTerminalItem.toolTip = "New Rejoin clients open in \(selectedTerminal.displayName)."
        for (terminal, item) in rejoinTerminalItems {
            item.state = terminal == selectedTerminal ? .on : .off
        }
    }

    private func updateUpdatePresentation() {
        let version = appVersion
        updateStatusItem.image = menuSymbol("shippingbox")
        updateStatusItem.toolTip = nil

        switch updateState {
        case .idle:
            updateStatusItem.title = "Version \(version)"
            updateActionItem.title = "Check for Updates…"
            updateActionItem.image = menuSymbol("arrow.triangle.2.circlepath")
            updateActionItem.isEnabled = true
        case .checking:
            updateStatusItem.title = "Version \(version) · Checking…"
            updateActionItem.title = "Checking for Updates…"
            updateActionItem.image = menuSymbol("arrow.triangle.2.circlepath")
            updateActionItem.isEnabled = false
        case .noPublishedRelease:
            updateStatusItem.title = "Version \(version) · No published release"
            updateActionItem.title = "Check for Updates…"
            updateActionItem.image = menuSymbol("arrow.triangle.2.circlepath")
            updateActionItem.isEnabled = true
        case .upToDate:
            updateStatusItem.title = "Version \(version) · Up to date"
            updateActionItem.title = "Check for Updates…"
            updateActionItem.image = menuSymbol("checkmark.circle")
            updateActionItem.isEnabled = true
        case let .available(release):
            if release.version.description == version {
                updateStatusItem.title = "Version \(version) · Signed release available"
                updateActionItem.title = "Install Signed Release \(release.version)…"
            } else {
                updateStatusItem.title = "Version \(version) · \(release.version) available"
                updateActionItem.title = "Install Update \(release.version)…"
            }
            updateStatusItem.image = menuSymbol("arrow.down.circle.fill")
            updateActionItem.image = menuSymbol("square.and.arrow.down")
            updateActionItem.isEnabled = true
        case let .installing(release):
            updateStatusItem.title = "Version \(version) · Installing \(release.version)…"
            updateStatusItem.image = menuSymbol("arrow.down.circle.fill")
            updateActionItem.title = "Installing Update…"
            updateActionItem.image = menuSymbol("hourglass")
            updateActionItem.isEnabled = false
        case let .failed(detail):
            updateStatusItem.title = "Version \(version) · Update failed"
            updateStatusItem.image = menuSymbol("exclamationmark.triangle.fill")
            updateStatusItem.toolTip = detail
            updateActionItem.title = "Check for Updates…"
            updateActionItem.image = menuSymbol("arrow.triangle.2.circlepath")
            updateActionItem.isEnabled = true
        }
    }

    private var appVersion: String {
        AppUpdateClient.currentVersion()
    }

    private func appAlert(style: NSAlert.Style = .informational) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.icon = NSApp.applicationIconImage ?? AppIconFactory.make(
            size: NSSize(width: 128, height: 128)
        )
        return alert
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
if arguments.contains("--apply-update") {
    guard let updateRequest = AppUpdateApplyRequest(arguments: arguments) else {
        fputs("Invalid update helper arguments.\n", stderr)
        exit(EXIT_FAILURE)
    }
    exit(AppUpdateHelper.apply(updateRequest))
}
if arguments.contains("--detect-sessions") {
    print(CodexSessionDetector.activeSessionCount())
    exit(EXIT_SUCCESS)
}
if arguments.contains("--update-archive-name") {
    guard let version = AppVersion(AppUpdateClient.currentVersion()) else {
        fputs("Invalid application version.\n", stderr)
        exit(EXIT_FAILURE)
    }
    print(AppUpdateClient.archiveName(version: version))
    exit(EXIT_SUCCESS)
}
if let renderIconIndex = arguments.firstIndex(of: "--render-app-icon"),
   arguments.indices.contains(renderIconIndex + 1) {
    let destination = URL(fileURLWithPath: arguments[renderIconIndex + 1])
    do {
        try AppIconFactory.writePNG(to: destination, pixelSize: 1_024)
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Could not render application icon: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}
if let renderStatusIconIndex = arguments.firstIndex(of: "--render-status-icon"),
   arguments.indices.contains(renderStatusIconIndex + 1) {
    let destination = URL(fileURLWithPath: arguments[renderStatusIconIndex + 1])
    do {
        try StatusIconFactory.writePreviewPNG(
            to: destination,
            assertionActive: true,
            remoteConnected: true
        )
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Could not render status icon: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}
if arguments.contains("--check-for-updates") {
    let currentVersion = AppUpdateClient.currentVersion()
    do {
        let client = AppUpdateClient()
        let availability = try client.check(
            currentVersion: currentVersion,
            allowSameVersionUpgrade: client.requiresSignedReleaseMigration(
                at: Bundle.main.bundleURL
            )
        )
        printJSON(
            AppUpdateCommandStatus.make(
                currentVersion: currentVersion,
                availability: availability
            )
        )
        exit(EXIT_SUCCESS)
    } catch {
        printJSON(AppUpdateCommandStatus.failure(currentVersion: currentVersion, error: error))
        exit(EXIT_FAILURE)
    }
}
if arguments.contains("--usage") {
    do {
        printJSON(try CodexUsageBridge.fetch())
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Could not read Codex usage: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
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
if arguments.contains("--login-item-status") {
    let status = LoginItemManager().status()
    printJSON(status)
    exit(LoginItemCommandExitCode.registration(status))
}
if arguments.contains("--register-login-item") {
    let status = LoginItemManager().register()
    printJSON(status)
    exit(LoginItemCommandExitCode.registration(status))
}
if arguments.contains("--reconcile-login-item") {
    let status = LoginItemManager().reconcile()
    printJSON(status)
    exit(LoginItemCommandExitCode.reconciliation(status))
}
if arguments.contains("--unregister-login-item") {
    let status = LoginItemManager().unregister()
    printJSON(status)
    exit(LoginItemCommandExitCode.unregistration(status))
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let appDelegate = AppDelegate()
    application.delegate = appDelegate
    application.run()
}
