import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` (macOS 13+) for the "launch at login"
/// preference. The OS registration is the source of truth for the menu checkmark;
/// `apply(_:)` reconciles it to the persisted `ClawdiSettings.launchAtLogin` value.
enum LaunchAtLogin {
    /// True when the app is currently registered and enabled to launch at login.
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Make the OS login-item registration match `enabled`. Returns `false` when the
    /// ServiceManagement call fails — e.g. a quarantined/translocated launch where the
    /// bundle has no stable on-disk location to register.
    @discardableResult
    static func apply(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled {
                guard service.status != .enabled else { return true }
                try service.register()
            } else {
                guard service.status == .enabled else { return true }
                try service.unregister()
            }
            return true
        } catch {
            return false
        }
    }
}
