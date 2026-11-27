import Foundation
import ServiceManagement

// "Launch at login" for the menu-bar agent, implemented with `SMAppService`
// (ServiceManagement, macOS 13+). Compatibility mode only works while DoctKey is
// running, so starting it at login is what makes the feature usable day to day.
//
// The preference is not duplicated in our config file: `SMAppService.mainApp`
// is the single source of truth (the user can also revoke it in System Settings →
// General → Login Items, which must be reflected in the UI).

/// Normalised view of `SMAppService.mainApp.status`, independent from the
/// platform type so the UI text can be unit-tested headlessly.
enum LaunchAtLoginState: Equatable {
    /// Registered and allowed to launch at login.
    case enabled
    /// Not registered (the user never enabled it, or removed it).
    case disabled
    /// Registered, but the user must approve it in System Settings → Login Items.
    case requiresApproval
    /// The service could not be found for this bundle (typically: the app is
    /// running from a throw-away location such as the repo `build/` directory).
    case notFound
    /// Any other failure, with a human-readable reason.
    case unavailable(String)

    /// Whether the switch should look "on" (registered, possibly pending consent).
    var isRegistered: Bool {
        switch self {
        case .enabled, .requiresApproval: return true
        case .disabled, .notFound, .unavailable: return false
        }
    }
}

/// Vietnamese display strings for the launch-at-login row.
enum LaunchAtLoginText {
    static let enabled = "Đã bật — DoctKey sẽ tự khởi động cùng macOS."
    static let disabled = "Chưa bật — DoctKey không tự khởi động cùng macOS."
    static let requiresApproval = "Đã đăng ký nhưng cần bạn cho phép trong System Settings → General → Login Items."
    static let notFound = "Không tìm thấy ứng dụng trong Login Items — hãy dùng bản DoctKey đã cài vào hệ thống."
    static let repositoryBuildHint = "Bạn đang chạy bản build trong thư mục repo. Nên cài DoctKey vào hệ thống để việc tự khởi động ổn định."

    static func displayText(for state: LaunchAtLoginState) -> String {
        switch state {
        case .enabled: return enabled
        case .disabled: return disabled
        case .requiresApproval: return requiresApproval
        case .notFound: return notFound
        case .unavailable(let reason):
            return "Không đọc được trạng thái khởi động cùng macOS: \(reason)"
        }
    }

    static func tone(for state: LaunchAtLoginState) -> StatusTone {
        switch state {
        case .enabled: return .success
        case .requiresApproval: return .warning
        case .disabled: return .neutral
        case .notFound: return .warning
        case .unavailable: return .danger
        }
    }
}

/// Thin wrapper around `SMAppService.mainApp`. Every failure is reported as a
/// Vietnamese string: the callers show it and the app never crashes on a denied
/// or unsupported login item.
enum LaunchAtLogin {
    static func currentState() -> LaunchAtLoginState {
        switch SMAppService.mainApp.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered:
            return .disabled
        case .notFound:
            return .notFound
        @unknown default:
            return .unavailable("trạng thái không xác định")
        }
    }

    /// Registers/unregisters the app as a login item. Returns nil on success or a
    /// Vietnamese error message (also logged) on failure.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            NSLog("DoctKey: launch-at-login %@ failed: %@",
                  enabled ? "register" : "unregister",
                  String(describing: error))
            return error.localizedDescription
        }
    }
}
