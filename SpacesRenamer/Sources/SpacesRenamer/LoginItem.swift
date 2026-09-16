import ServiceManagement

/// "Launch at login" backed by `SMAppService.mainApp`.
enum LoginItem {
  private static let registeredOnceKey = "LoginItemRegisteredOnce"

  static var status: SMAppService.Status { SMAppService.mainApp.status }

  static var isEnabled: Bool { status == .enabled }

  /// The previous app added itself to the login items on first launch; keep that behaviour once.
  static func registerOnFirstLaunch() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: registeredOnceKey) else { return }
    defaults.set(true, forKey: registeredOnceKey)
    try? SMAppService.mainApp.register()
  }

  static func setEnabled(_ enabled: Bool) throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }

  static var statusDescription: String {
    switch status {
    case .enabled: "Enabled"
    case .notRegistered: "Not registered"
    case .requiresApproval: "Requires approval in System Settings"
    case .notFound: "Not found"
    @unknown default: "Unknown"
    }
  }
}
