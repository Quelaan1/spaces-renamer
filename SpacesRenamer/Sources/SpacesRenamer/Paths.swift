import Foundation

/// Preference domains and files shared with the Spaces-bar plugin. WindowManager (the macOS 27 host) is
/// sandboxed away from `~/Library`, so the live data channel is the `com.apple.dock` preference domain.
enum Paths {
  static let bundleIdentifier = "com.alexbeals.SpacesRenamer"

  /// Domain the plugin can read from inside its host; the app writes names and monitors here.
  static let dockDomain = "com.apple.dock"
  static let namesKey = "SpacesRenamerNames"
  static let monitorsKey = "SpacesRenamerMonitors"

  private static let library = FileManager.default
    .homeDirectoryForCurrentUser
    .appending(path: "Library", directoryHint: .isDirectory)

  /// Names file written by versions before the preference-domain channel; migrated once, never deleted.
  static let legacyNames = library
    .appending(path: "Containers/\(bundleIdentifier)/com.alexbeals.spacesrenamer.plist")

  /// System Spaces database; rewritten by Dock whenever Spaces are added or removed.
  static let systemSpaces = library.appending(path: "Preferences/com.apple.spaces.plist")
}
