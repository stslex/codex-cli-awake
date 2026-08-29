import Foundation
import ServiceManagement

enum LoginItemState: String, Codable, Equatable {
    case notRegistered = "not-registered"
    case enabled
    case requiresApproval = "requires-approval"
    case notFound = "not-found"
    case unknown
}

struct LoginItemStatus: Codable, Equatable {
    let state: LoginItemState
    let desired: Bool
    let detail: String?
}

enum LoginItemMenuAction: Equatable {
    case register
    case unregister
    case openSettings
}

struct LoginItemMenuPresentation: Equatable {
    let title: String
    let symbolName: String
    let isChecked: Bool
    let action: LoginItemMenuAction

    static func make(status: LoginItemStatus) -> LoginItemMenuPresentation {
        switch status.state {
        case .enabled:
            return LoginItemMenuPresentation(
                title: "Launch at Login",
                symbolName: "checkmark.circle.fill",
                isChecked: true,
                action: .unregister
            )
        case .requiresApproval:
            return LoginItemMenuPresentation(
                title: "Launch at Login (Approval Required)…",
                symbolName: "exclamationmark.triangle.fill",
                isChecked: false,
                action: .openSettings
            )
        case .notRegistered, .notFound, .unknown:
            return LoginItemMenuPresentation(
                title: status.desired ? "Launch at Login (Unavailable)" : "Launch at Login",
                symbolName: status.desired ? "exclamationmark.circle" : "circle",
                isChecked: false,
                action: .register
            )
        }
    }
}

final class LoginItemManager {
    static let desiredDefaultsKey = "launchAtLoginDesired"

    private let service: SMAppService
    private let defaults: UserDefaults
    private(set) var lastError: String?

    init(
        service: SMAppService = .mainApp,
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.defaults = defaults
    }

    var isDesired: Bool {
        guard defaults.object(forKey: Self.desiredDefaultsKey) != nil else {
            return true
        }
        return defaults.bool(forKey: Self.desiredDefaultsKey)
    }

    func status() -> LoginItemStatus {
        snapshot(detail: lastError)
    }

    func reconcile() -> LoginItemStatus {
        if defaults.object(forKey: Self.desiredDefaultsKey) == nil {
            defaults.set(true, forKey: Self.desiredDefaultsKey)
        }
        guard isDesired else { return status() }

        switch mappedState {
        case .enabled, .requiresApproval:
            return status()
        case .notRegistered, .notFound, .unknown:
            return register()
        }
    }

    func register() -> LoginItemStatus {
        defaults.set(true, forKey: Self.desiredDefaultsKey)
        lastError = nil

        switch mappedState {
        case .enabled, .requiresApproval:
            return status()
        case .notRegistered, .notFound, .unknown:
            do {
                try service.register()
            } catch {
                lastError = error.localizedDescription
            }
            return status()
        }
    }

    func unregister() -> LoginItemStatus {
        defaults.set(false, forKey: Self.desiredDefaultsKey)
        lastError = nil

        switch mappedState {
        case .notRegistered, .notFound:
            return status()
        case .enabled, .requiresApproval, .unknown:
            do {
                try service.unregister()
            } catch {
                lastError = error.localizedDescription
            }
            return status()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private var mappedState: LoginItemState {
        switch service.status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .unknown
        }
    }

    private func snapshot(detail: String?) -> LoginItemStatus {
        let state = mappedState
        let stateDetail: String?
        if let detail {
            stateDetail = detail
        } else if state == .requiresApproval {
            stateDetail = "Allow Codex Awake in System Settings > General > Login Items."
        } else if state == .notFound {
            stateDetail = "macOS could not find the registered application bundle."
        } else {
            stateDetail = nil
        }
        return LoginItemStatus(state: state, desired: isDesired, detail: stateDetail)
    }
}

enum LoginItemCommandExitCode {
    static func registration(_ status: LoginItemStatus) -> Int32 {
        switch status.state {
        case .enabled:
            return EXIT_SUCCESS
        case .requiresApproval:
            return 2
        case .notRegistered, .notFound, .unknown:
            return EXIT_FAILURE
        }
    }

    static func reconciliation(_ status: LoginItemStatus) -> Int32 {
        if !status.desired && (status.state == .notRegistered || status.state == .notFound) {
            return EXIT_SUCCESS
        }
        return registration(status)
    }

    static func unregistration(_ status: LoginItemStatus) -> Int32 {
        switch status.state {
        case .notRegistered, .notFound:
            return EXIT_SUCCESS
        case .requiresApproval:
            return 2
        case .enabled, .unknown:
            return EXIT_FAILURE
        }
    }
}
