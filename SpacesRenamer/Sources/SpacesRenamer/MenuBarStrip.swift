import AppKit
import SwiftUI
import notify

/// One clickable name in a display's strip.
struct StripItem: Identifiable, Hashable {
  /// `ManagedSpaceID` of the desktop.
  let id: Int
  let name: String
  /// The number in "Switch to Desktop N": desktops counted across all displays in layout order,
  /// full-screen app Spaces excluded.
  let number: Int
  let isCurrent: Bool
}

extension SpacesStore {
  /// The named desktops of one display, in order. Unnamed desktops are left out.
  func stripItems(for monitor: Monitor) -> [StripItem] {
    var number = 0
    var items: [StripItem] = []
    for candidate in monitors {
      for space in candidate.spaces where !space.isFullscreenApp {
        number += 1
        guard candidate.id == monitor.id, let name = names[space.uuid], !name.isEmpty else { continue }
        items.append(StripItem(id: space.id, name: name, number: number, isCurrent: space.uuid == candidate.currentSpaceUUID))
      }
    }
    return items
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
      panel.show(items: items, frame: stripFrame)
    }
    for (id, panel) in panels where !shown.contains(id) {
      panel.hide()
    }
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

  func show(items: [StripItem], frame: CGRect) {
    hosting.rootView = StripView(items: items) { item in
      DesktopSwitcher.switchTo(desktop: item.number)
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

/// Asks the plugin to switch desktops. macOS has no public API to change the Space, and an app
/// may not press keys without a permission prompt, so the plugin presses the "Switch to Desktop N"
/// shortcut from inside WindowManager, which macOS already allows to post key events. Nothing
/// happens while the plugin is not active.
enum DesktopSwitcher {
  static func switchTo(desktop number: Int) {
    var token: Int32 = 0
    guard notify_register_check(Paths.switchDesktopNotification, &token) == NOTIFY_STATUS_OK else { return }
    notify_set_state(token, UInt64(number))
    notify_post(Paths.switchDesktopNotification)
    notify_cancel(token)
  }
}

extension NSScreen {
  var displayID: CGDirectDisplayID? {
    deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
  }
}
