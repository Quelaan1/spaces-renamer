import AppKit
import SwiftUI
import notify

/// One clickable name in a display's strip.
struct StripItem: Identifiable, Hashable {
  /// `ManagedSpaceID` of the desktop.
  let id: Int
  let name: String
  let isCurrent: Bool
}

extension SpacesStore {
  /// The named desktops of one display, in order. Unnamed desktops are left out.
  func stripItems(for monitor: Monitor) -> [StripItem] {
    monitor.spaces.compactMap { space in
      guard !space.isFullscreenApp, let name = names[space.uuid], !name.isEmpty else { return nil }
      return StripItem(id: space.id, name: name, isCurrent: space.uuid == monitor.currentSpaceUUID)
    }
  }
}

/// Width of a strip, so the panel is sized to exactly its display's names.
@MainActor
enum MenuBarStrip {
  static let font = NSFont.menuBarFont(ofSize: 0)
  static let itemPadding: CGFloat = 6
  static let itemSpacing: CGFloat = 2

  static func width(of items: [StripItem]) -> CGFloat {
    guard !items.isEmpty else { return 0 }
    let text = items.reduce(CGFloat(0)) { total, item in
      total + ceil((item.name as NSString).size(withAttributes: [.font: font]).width) + 2 * itemPadding
    }
    return text + CGFloat(items.count - 1) * itemSpacing
  }
}

/// Draws each display's own named desktops centred in that display's menu bar, one borderless panel
/// per display, each sized to its own names. A status item cannot do this: macOS mirrors every item
/// onto every menu bar at one shared width, so a display with fewer names would show a gap.
@MainActor
final class MenuBarStripController {
  private let store: SpacesStore
  private let settings: AppSettings
  private var panels: [CGDirectDisplayID: StripPanel] = [:]
  private var observer: (any NSObjectProtocol)?
  private var appearanceObserver: NSKeyValueObservation?
  private var renderScheduled = false

  init(store: SpacesStore, settings: AppSettings) {
    self.store = store
    self.settings = settings
    // Displays added, removed or rearranged; the menu bar shown or hidden.
    observer = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.scheduleRender() }
    }
    track()
  }

  /// Renders now and again whenever the names, the layout or the setting change.
  private func track() {
    withObservationTracking {
      render()
    } onChange: { [weak self] in
      Task { @MainActor in self?.track() }
    }
  }

  /// Screen notifications can arrive during AppKit's layout pass, where resizing a hosting view
  /// aborts the app; redraw on the next main-loop turn instead, once per burst.
  private func scheduleRender() {
    guard !renderScheduled else { return }
    renderScheduled = true
    DispatchQueue.main.async { [weak self] in
      self?.renderScheduled = false
      self?.render()
    }
  }

  private func render() {
    let appearance = menuBarAppearance()
    var shown = Set<CGDirectDisplayID>()
    for screen in NSScreen.screens where settings.showSpaceNameInMenuBar {
      guard let id = screen.displayID, let monitor = store.monitor(for: screen) else { continue }
      // A full-screen app hides the menu bar, and the strip would otherwise stay over the app (#22).
      if monitor.spaces.first(where: { $0.uuid == monitor.currentSpaceUUID })?.isFullscreenApp == true { continue }
      let items = store.stripItems(for: monitor)
      guard !items.isEmpty, let stripFrame = Self.stripFrame(on: screen, width: MenuBarStrip.width(of: items)) else { continue }
      shown.insert(id)
      let panel = panels[id] ?? StripPanel()
      panels[id] = panel
      panel.show(items: items, frame: stripFrame, appearance: appearance)
    }
    for (id, panel) in panels where !shown.contains(id) {
      panel.hide()
    }
  }

  /// The appearance the menu bar is drawn in. On macOS 26/27 it follows the wallpaper, not the system
  /// theme, so a light-mode Mac can have a dark menu bar. The strip borrows it from the app's own
  /// status-item window and redraws when it changes (#25). Nil until that window exists.
  // ponytail: one status-item window stands for every display; displays whose wallpapers give their
  // menu bars different colours would need a per-display source.
  private func menuBarAppearance() -> NSAppearance? {
    let window = NSApp?.windows.first { String(describing: type(of: $0)) == "NSStatusBarWindow" && $0.frame.width > 0 }
    guard let window else {
      // Neither NSApp nor the status item exists yet while the app is starting; look again shortly.
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.scheduleRender() }
      return nil
    }
    if appearanceObserver == nil {
      appearanceObserver = window.observe(\.effectiveAppearance) { [weak self] _, _ in
        Task { @MainActor in self?.scheduleRender() }
      }
    }
    return window.effectiveAppearance
  }

  /// The strip's frame, centred in the display's menu bar: to the right of the camera housing on a
  /// display with a notch. Nil while the display shows no menu bar (auto-hidden).
  private static func stripFrame(on screen: NSScreen, width: CGFloat) -> CGRect? {
    let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
    guard menuBarHeight > 0 else { return nil }
    var area = CGRect(x: screen.frame.minX, y: screen.frame.maxY - menuBarHeight, width: screen.frame.width, height: menuBarHeight)
    // ponytail: the notch areas are taken as relative to the display's own origin; unverified on a Mac
    // with a notch. If the strip lands in the wrong place there, drop the origin offset.
    if let right = screen.auxiliaryTopRightArea, right.width > 0 {
      area.origin.x = screen.frame.minX + right.minX
      area.size.width = right.width
    }
    return CGRect(x: floor(area.midX - width / 2), y: area.minY, width: ceil(width), height: area.height)
  }
}

/// A borderless, non-activating panel over the middle of one display's menu bar.
@MainActor
private final class StripPanel {
  private let panel: NSPanel
  private let hosting: StripHostingView

  init() {
    hosting = StripHostingView(rootView: StripView(items: [], onSelect: { _ in }))
    panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    // Explicitly false: a clear window otherwise lets clicks fall through to the menu bar beneath.
    panel.ignoresMouseEvents = false
    // Above the menu bar it is drawn over.
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    // No .fullScreenAuxiliary. On macOS 27 that alone does not keep the strip off full-screen
    // Spaces, so render() hides it there itself (#22).
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    panel.contentView = hosting
  }

  func show(items: [StripItem], frame: CGRect, appearance: NSAppearance?) {
    // The text colour comes from this, not from the app's light/dark setting (#25).
    panel.appearance = appearance
    hosting.rootView = StripView(items: items) { item in
      DesktopSwitcher.switchTo(space: item.id)
    }
    panel.setFrame(frame, display: true)
    panel.orderFrontRegardless()
  }

  func hide() {
    panel.orderOut(nil)
  }
}

/// Takes the first click, so a name switches desktops without first activating the app.
private final class StripHostingView: NSHostingView<StripView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct StripView: View {
  let items: [StripItem]
  let onSelect: (StripItem) -> Void

  var body: some View {
    HStack(spacing: MenuBarStrip.itemSpacing) {
      ForEach(items) { item in
        Text(item.name)
          .font(Font(MenuBarStrip.font))
          .lineLimit(1)
          .fixedSize()
          .padding(.horizontal, MenuBarStrip.itemPadding)
          .padding(.vertical, 2)
          .background(RoundedRectangle(cornerRadius: 5).fill(item.isCurrent ? Color.primary.opacity(0.18) : .clear))
          .contentShape(Rectangle())
          .onTapGesture { onSelect(item) }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Asks the plugin to switch to a Space. macOS has no public API to change the Space, so the plugin
/// does it from inside the process that draws Mission Control: on macOS 27 with the window-server
/// calls WindowManager uses itself, on macOS 26 by pressing the "Switch to Desktop N" shortcut
/// inside the Dock. Nothing happens while the plugin is not active.
enum DesktopSwitcher {
  static func switchTo(space id: Int) {
    var token: Int32 = 0
    guard notify_register_check(Paths.switchSpaceNotification, &token) == NOTIFY_STATUS_OK else { return }
    notify_set_state(token, UInt64(id))
    notify_post(Paths.switchSpaceNotification)
    notify_cancel(token)
  }
}

extension NSScreen {
  var displayID: CGDirectDisplayID? {
    deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
  }
}
