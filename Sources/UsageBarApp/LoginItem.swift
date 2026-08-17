import AppKit
import ServiceManagement

/// "Start at login", backed by `SMAppService` — launchd is the store, we keep
/// no copy. The same switch exists in System Settings › General › Login Items,
/// so a mirror in UserDefaults would be wrong the moment the user flips it
/// there. Every read asks launchd.
enum LoginItem {
    /// launchd registers a bundle, not a process. `swift run` produces a bare
    /// binary with nothing to register, so the checkbox stays off and disabled
    /// instead of throwing at the user.
    static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The user said no in System Settings. Registering again changes nothing —
    /// only they can undo it, and only there.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
