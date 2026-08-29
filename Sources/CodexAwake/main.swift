import AppKit
import Foundation
import IOKit.pwr_mgt

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
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let defaultsKey = "awakeMode"

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "Checking Codex sessions…", action: nil, keyEquivalent: "")
    private let assertion = SleepAssertion()
    private let detectorQueue = DispatchQueue(label: "com.stslex.CodexAwake.session-detector", qos: .utility)

    private var modeItems: [AwakeMode: NSMenuItem] = [:]
    private var currentMode: AwakeMode = .activeSession
    private var activeSessionCount = 0
    private var scanInProgress = false
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        loadMode()
        applyMode()
        scanForSessions()

        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.scanForSessions()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        assertion.setHeld(false)
    }

    private func configureMenu() {
        menu.autoenablesItems = false
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        for mode in AwakeMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.tag
            item.isEnabled = true
            menu.addItem(item)
            modeItems[mode] = item
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Codex Awake", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        statusItem.menu = menu
        updatePresentation()
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
        for (mode, item) in modeItems {
            item.state = mode == currentMode ? .on : .off
        }

        if let error = assertion.lastError {
            statusMenuItem.title = "Error: \(error)"
        } else {
            let assertionState = assertion.isHeld ? "on" : "off"
            let sessionWord = activeSessionCount == 1 ? "session" : "sessions"
            statusMenuItem.title = "Assertion: \(assertionState) · \(activeSessionCount) Codex \(sessionWord)"
        }

        guard let button = statusItem.button else { return }
        let symbolName = assertion.isHeld ? "cup.and.saucer.fill" : "cup.and.saucer"
        let whitePalette = NSImage.SymbolConfiguration(paletteColors: [.white])
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Codex Awake"
        )?.withSymbolConfiguration(whitePalette)
        image?.isTemplate = false
        button.image = image
        button.toolTip = "Codex Awake — \(currentMode.title)"
        button.contentTintColor = nil
    }
}

if CommandLine.arguments.contains("--detect-sessions") {
    print(CodexSessionDetector.activeSessionCount())
    exit(EXIT_SUCCESS)
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let appDelegate = AppDelegate()
    application.delegate = appDelegate
    application.run()
}
