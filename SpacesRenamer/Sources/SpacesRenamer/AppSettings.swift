import Foundation
import Observation

/// User-facing on/off switches for the ambient display features, persisted in `UserDefaults`.
@MainActor
@Observable
final class AppSettings {
  private enum Key {
    static let menuBarName = "ShowSpaceNameInMenuBar"
    static let spaceChangeHUD = "ShowSpaceChangeHUD"
  }

  /// Show the current Space's name to the left of the menu-bar icon.
  var showSpaceNameInMenuBar: Bool {
    didSet { UserDefaults.standard.set(showSpaceNameInMenuBar, forKey: Key.menuBarName) }
  }

  /// Flash a glass HUD, centered on every display, when the Space changes.
  var showSpaceChangeHUD: Bool {
    didSet { UserDefaults.standard.set(showSpaceChangeHUD, forKey: Key.spaceChangeHUD) }
  }

  init() {
    let defaults = UserDefaults.standard
    // Both features default on; assignments in init do not fire didSet, so nothing is written back.
    showSpaceNameInMenuBar = defaults.object(forKey: Key.menuBarName) as? Bool ?? true
    showSpaceChangeHUD = defaults.object(forKey: Key.spaceChangeHUD) as? Bool ?? true
  }
}
