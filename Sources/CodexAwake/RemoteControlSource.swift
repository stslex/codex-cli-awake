import Foundation

enum RemoteControlSource: String, CaseIterable {
    case terminalCLI = "terminal-cli"
    case codexDesktop = "codex-desktop"

    var title: String {
        switch self {
        case .terminalCLI:
            return "Terminal CLI"
        case .codexDesktop:
            return "Codex Desktop"
        }
    }

    var selectionTag: Int {
        switch self {
        case .terminalCLI:
            return 0
        case .codexDesktop:
            return 1
        }
    }

    init?(selectionTag: Int) {
        switch selectionTag {
        case 0:
            self = .terminalCLI
        case 1:
            self = .codexDesktop
        default:
            return nil
        }
    }
}

final class RemoteControlSourceStore {
    static let defaultsKey = "remoteControlSource"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    var source: RemoteControlSource {
        guard let stored = defaults.string(forKey: key),
              let source = RemoteControlSource(rawValue: stored) else {
            defaults.set(RemoteControlSource.terminalCLI.rawValue, forKey: key)
            return .terminalCLI
        }
        return source
    }

    func set(_ source: RemoteControlSource) {
        defaults.set(source.rawValue, forKey: key)
    }
}

enum RemoteControlSourceResolver {
    static func status(
        for source: RemoteControlSource,
        terminalStatus: () -> RemoteStatus = CodexRemoteBridge.ensureRemoteStarted,
        desktopIsRunning: () -> Bool = CodexRemoteBridge.codexDesktopIsRunning
    ) -> RemoteStatus {
        switch source {
        case .terminalCLI:
            return terminalStatus()
        case .codexDesktop:
            return CodexRemoteBridge.desktopManagedStatus(
                isDesktopRunning: desktopIsRunning()
            )
        }
    }
}
