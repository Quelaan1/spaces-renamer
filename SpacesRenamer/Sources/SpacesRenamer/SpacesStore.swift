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

/// Live Spaces layout plus the custom names, kept in sync with the two plists the Dock plugin reads.
@MainActor
@Observable
final class SpacesStore {
  private(set) var monitors: [Monitor] = []
  /// Custom names by Space uuid, as last read from disk. Empty string means no custom name.
  private(set) var names: [String: String] = [:]

  private let connection = _CGSDefaultConnection()
  private var fileMonitor: DispatchSourceFileSystemObject?
  private var observers: [any NSObjectProtocol] = []

  init() {
    try? FileManager.default.createDirectory(at: Paths.container, withIntermediateDirectories: true)
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

  /// Re-reads the layout, rewrites the currentspaces plist when it changed, and prunes names of vanished Spaces.
  func refresh() {
    let raw = readLayout()
    monitors = raw.compactMap(Monitor.init(raw:))
    writeCurrentSpaces(raw)
    names = Self.readNames()
    pruneNames()
  }

  /// Persists every provided name (keyed by Space uuid) into the names plist.
  func save(_ newNames: [String: String]) {
    let plist = NSMutableDictionary(contentsOf: Paths.names) ?? NSMutableDictionary()
    var merged = plist["spaces_renaming"] as? [String: String] ?? [:]
    merged.merge(newNames) { _, new in new }
    plist["spaces_renaming"] = merged
    plist.write(to: Paths.names, atomically: true)
    names = merged
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

  // MARK: - Layout

  private func readLayout() -> [[String: Any]] {
    if let live = CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]], !live.isEmpty {
      return live
    }
    let plist = NSDictionary(contentsOf: Paths.systemSpaces)
    return plist?.value(forKeyPath: "SpacesDisplayConfiguration.Management Data.Monitors") as? [[String: Any]] ?? []
  }

  private func writeCurrentSpaces(_ raw: [[String: Any]]) {
    let next = NSDictionary(dictionary: ["Monitors": raw])
    let previous = NSDictionary(contentsOf: Paths.currentSpaces)
    if previous == nil || !next.isEqual(previous) {
      next.write(to: Paths.currentSpaces, atomically: true)
    }
  }

  // MARK: - Names

  private static func readNames() -> [String: String] {
    NSDictionary(contentsOf: Paths.names)?["spaces_renaming"] as? [String: String] ?? [:]
  }

  private func pruneNames() {
    let live = Set(monitors.flatMap(\.spaces).map(\.uuid))
    guard !live.isEmpty else { return }
    let kept = names.filter { live.contains($0.key) }
    guard kept.count != names.count, let plist = NSMutableDictionary(contentsOf: Paths.names) else { return }
    plist["spaces_renaming"] = kept
    plist.write(to: Paths.names, atomically: true)
    names = kept
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
