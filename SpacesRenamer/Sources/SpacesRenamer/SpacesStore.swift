import AppKit
import CGSPrivate
import Observation

struct Space: Identifiable, Hashable {
  /// `ManagedSpaceID`; stable while the Space exists, unlike `uuid` which is empty for the primary desktop.
  let id: Int
  let uuid: String
  let isFullscreenApp: Bool

  init?(raw: [String: Any]) {
    guard let id = raw["ManagedSpaceID"] as? Int, let uuid = raw["uuid"] as? String else { return nil }
    self.id = id
    self.uuid = uuid
    self.isFullscreenApp = raw["type"] as? Int == 4
  }
}

struct Monitor: Identifiable {
  /// `Display Identifier`: a display UUID, or `Main`.
  let id: String
  let spaces: [Space]
  let currentSpaceUUID: String

  /// Monitors without a `Spaces` array (disconnected displays with a `Collapsed Space`) are skipped.
  init?(raw: [String: Any]) {
    guard let id = raw["Display Identifier"] as? String,
          let spaces = raw["Spaces"] as? [[String: Any]] else { return nil }
    self.id = id
    self.spaces = spaces.compactMap(Space.init(raw:))
    self.currentSpaceUUID = (raw["Current Space"] as? [String: Any])?["uuid"] as? String ?? ""
  }
}

extension Monitor {
  /// The display label of this monitor's current Space: the custom name if set, else "Desktop N"
  /// counting only real desktops. Empty when the current Space is a full-screen app (no title here).
  func currentSpaceLabel(names: [String: String]) -> String {
    guard let current = spaces.first(where: { $0.uuid == currentSpaceUUID }) else { return "" }
    if let name = names[current.uuid], !name.isEmpty { return name }
    if current.isFullscreenApp { return "" }
    var number = 0
    for space in spaces where !space.isFullscreenApp {
      number += 1
      if space.uuid == current.uuid { return "Desktop \(number)" }
    }
    return "Desktop"
  }
}

/// Live Spaces layout plus the custom names, kept in sync with the `com.apple.dock` preference keys the plugin reads.
@MainActor
@Observable
final class SpacesStore {
  private(set) var monitors: [Monitor] = []
  /// Custom names by Space uuid, as last read from the preference domain. Empty string means no custom name.
  private(set) var names: [String: String] = [:]

  private let connection = _CGSDefaultConnection()
  private let dock = UserDefaults(suiteName: Paths.dockDomain)!
  private var fileMonitor: DispatchSourceFileSystemObject?
  private var observers: [any NSObjectProtocol] = []

  init() {
    migrateLegacyNames()
    refresh()

    let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
      Task { @MainActor in self?.refresh() }
    }
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil, using: refresh))
    observers.append(NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil, using: refresh))
    watchSystemSpacesFile()
  }

  /// Re-reads the layout, rewrites `SpacesRenamerMonitors` when it changed, and prunes names of vanished Spaces.
  func refresh() {
    let raw = readLayout()
    monitors = raw.compactMap(Monitor.init(raw:))
    writeMonitors(raw)
    names = readNames()
    pruneNames()
  }

  /// Persists every provided name (keyed by Space uuid) into `SpacesRenamerNames`.
  func save(_ newNames: [String: String]) {
    var merged = readNames()
    merged.merge(newNames) { _, new in new }
    writeNames(merged)
  }

  /// `ManagedSpaceID` of the Space shown on the main screen, per the window server.
  func mainScreenCurrentSpaceID() -> Int? {
    guard let screen = NSScreen.main,
          let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
          let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return nil }
    let id = CGSManagedDisplayGetCurrentSpace(CGSMainConnectionID(), CFUUIDCreateString(nil, uuid))
    return id == 0 ? nil : Int(id)
  }

  /// The Space that should receive focus when the popover opens: the main screen's current Space,
  /// falling back to the first monitor's `Current Space`.
  var focusedSpace: Space? {
    let all = monitors.flatMap(\.spaces)
    if let id = mainScreenCurrentSpaceID(), let space = all.first(where: { $0.id == id }) {
      return space
    }
    return monitors.lazy
      .compactMap { monitor in monitor.spaces.first { $0.uuid == monitor.currentSpaceUUID } }
      .first
  }

  // MARK: - Display labels (menu bar + HUD)

  /// The monitor driving a given screen, matched by display UUID (or the `Main` identifier).
  func monitor(for screen: NSScreen) -> Monitor? {
    if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
       let cfUUID = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue(),
       let uuid = CFUUIDCreateString(nil, cfUUID) as String?,
       let match = monitors.first(where: { $0.id == uuid }) {
      return match
    }
    if screen == NSScreen.main, let main = monitors.first(where: { $0.id == "Main" }) {
      return main
    }
    return monitors.count == 1 ? monitors.first : nil
  }

  /// The current Space's label on the main screen, for the menu-bar item.
  var menuBarLabel: String {
    if let screen = NSScreen.main, let monitor = monitor(for: screen) {
      return monitor.currentSpaceLabel(names: names)
    }
    return monitors.first?.currentSpaceLabel(names: names) ?? ""
  }

  /// The current Space label for every attached display, for the per-display HUD. Reads fresh so it
  /// is correct immediately after a Space change, regardless of observer ordering.
  func currentDisplayLabels() -> [(screen: NSScreen, label: String)] {
    refresh()
    return NSScreen.screens.compactMap { screen in
      guard let monitor = monitor(for: screen) else { return nil }
      let label = monitor.currentSpaceLabel(names: names)
      return label.isEmpty ? nil : (screen, label)
    }
  }

  // MARK: - Layout

  private func readLayout() -> [[String: Any]] {
    if let live = CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]], !live.isEmpty {
      return live
    }
    let plist = NSDictionary(contentsOf: Paths.systemSpaces)
    return plist?.value(forKeyPath: "SpacesDisplayConfiguration.Management Data.Monitors") as? [[String: Any]] ?? []
  }

  private func writeMonitors(_ raw: [[String: Any]]) {
    let previous = dock.array(forKey: Paths.monitorsKey)
    if previous == nil || !NSArray(array: raw).isEqual(previous) {
      dock.set(raw, forKey: Paths.monitorsKey)
    }
  }

  // MARK: - Names

  private func readNames() -> [String: String] {
    dock.dictionary(forKey: Paths.namesKey) as? [String: String] ?? [:]
  }

  private func writeNames(_ newNames: [String: String]) {
    dock.set(newNames, forKey: Paths.namesKey)
    names = newNames
  }

  private func pruneNames() {
    let live = Set(monitors.flatMap(\.spaces).map(\.uuid))
    guard !live.isEmpty else { return }
    let kept = names.filter { live.contains($0.key) }
    if kept.count != names.count {
      writeNames(kept)
    }
  }

  /// One-time copy of the pre-2.0 container plist into the preference domain; the old file is left in place.
  private func migrateLegacyNames() {
    guard dock.object(forKey: Paths.namesKey) == nil,
          let legacy = NSDictionary(contentsOf: Paths.legacyNames)?["spaces_renaming"] as? [String: String] else { return }
    writeNames(legacy)
  }

  // MARK: - File monitor

  /// Dock replaces com.apple.spaces.plist atomically, so a delete event means the Spaces changed.
  private func watchSystemSpacesFile() {
    let fd = open(Paths.systemSpaces.path, O_EVTONLY)
    guard fd >= 0 else {
      NSLog("SpacesRenamer: cannot watch \(Paths.systemSpaces.path)")
      return
    }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .delete, queue: .main)
    source.setEventHandler { [weak self] in
      source.cancel()
      MainActor.assumeIsolated {
        self?.refresh()
        self?.watchSystemSpacesFile()
      }
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    fileMonitor = source
  }
}
