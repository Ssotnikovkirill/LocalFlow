import Foundation
import ServiceManagement

enum LaunchAtLoginState: Equatable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable

    var title: String {
        switch self {
        case .disabled:
            return "Автозапуск: выключен"
        case .enabled:
            return "Автозапуск: включён системой"
        case .requiresApproval:
            return "Автозапуск: требуется подтверждение в System Settings"
        case .unavailable:
            return "Автозапуск: служба недоступна"
        }
    }
}

@MainActor
final class LaunchAtLoginController {
    @discardableResult
    func apply(enabled: Bool) throws -> LaunchAtLoginState {
        let service = SMAppService.mainApp

        if enabled {
            switch service.status {
            case .enabled, .requiresApproval:
                break
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                try service.register()
            }
        } else {
            switch service.status {
            case .enabled, .requiresApproval:
                try service.unregister()
            case .notRegistered, .notFound:
                break
            @unknown default:
                break
            }
        }
        return state
    }

    var state: LaunchAtLoginState {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            return .disabled
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
