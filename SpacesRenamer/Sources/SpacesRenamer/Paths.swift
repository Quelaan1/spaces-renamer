import Foundation

/// File locations shared with the Dock plugin. The plugin hardcodes the lowercase
/// container spelling; the filesystem is case-insensitive so both resolve to one directory.
enum Paths {
  static let bundleIdentifier = "com.alexbeals.SpacesRenamer"

  private static let library = FileManager.default
    .homeDirectoryForCurrentUser
    .appending(path: "Library", directoryHint: .isDirectory)

  static let container = library
    .appending(path: "Containers/\(bundleIdentifier)", directoryHint: .isDirectory)

  /// `{ "spaces_renaming": { <space uuid>: <name> } }`, written by the app, read by the plugin.
  static let names = container.appending(path: "com.alexbeals.spacesrenamer.plist")

  /// `{ "Monitors": <CGSCopyManagedDisplaySpaces output> }`, written by the app, read by the plugin.
  static let currentSpaces = container.appending(path: "com.alexbeals.spacesrenamer.currentspaces.plist")

  /// Status marker written by the plugin when it loads into Dock.
  static let pluginMarker = container.appending(path: "com.alexbeals.spacesrenamer.plugin.plist")

  /// System Spaces database; rewritten by Dock whenever Spaces are added or removed.
  static let systemSpaces = library.appending(path: "Preferences/com.apple.spaces.plist")
}
