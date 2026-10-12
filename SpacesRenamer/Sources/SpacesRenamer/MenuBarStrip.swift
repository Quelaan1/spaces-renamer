import AppKit
import CGSPrivate
import notify

/// One clickable name in a display's tray.
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

  /// The name of the display's current desktop, if it has one; nil when the current desktop is
  /// unnamed. The trigger shows this so the menu bar always carries just one name, never a row that
  /// can overflow into the menu-bar extras (#33).
  func currentName(for monitor: Monitor) -> String? {
    guard let name = names[monitor.currentSpaceUUID], !name.isEmpty else { return nil }
    return name
  }
}

/// Measurements for the trigger (in the menu bar) and the drop-down tray beneath it.
@MainActor
enum MenuBarStrip {
  static let triggerFont = NSFont.menuBarFont(ofSize: 0)
  static let rowFont = NSFont.systemFont(ofSize: 13)

  static let triggerPadH: CGFloat = 8
  static let nameChevronGap: CGFloat = 5
  static let chevronWidth: CGFloat = 8

  static let rowHeight: CGFloat = 28
  static let rowPadH: CGFloat = 12
  static let trayPadV: CGFloat = 6
  static let trayCorner: CGFloat = 10
  static let minTrayWidth: CGFloat = 180
  static let maxTrayWidth: CGFloat = 360

  static func textWidth(_ s: String, _ font: NSFont) -> CGFloat {
    ceil((s as NSString).size(withAttributes: [.font: font]).width)
  }

  /// The trigger is the current name (when there is one) plus a disclosure chevron.
  static func triggerWidth(name: String?) -> CGFloat {
    let namePart = (name?.isEmpty == false) ? textWidth(name!, triggerFont) + nameChevronGap : 0
    return 2 * triggerPadH + namePart + chevronWidth
  }

  static func trayWidth(items: [StripItem]) -> CGFloat {
    let widest = items.reduce(CGFloat(0)) { max($0, textWidth($1.name, rowFont)) }
    return min(maxTrayWidth, max(minTrayWidth, widest + 2 * rowPadH))
  }

  static func trayHeight(items: [StripItem]) -> CGFloat {
    CGFloat(items.count) * rowHeight + 2 * trayPadV
  }

  /// Middle-ellipsis a row name to fit the tray's text width.
  static func truncate(_ s: String, toWidth maxWidth: CGFloat) -> String {
    if textWidth(s, rowFont) <= maxWidth { return s }
    let chars = Array(s)
    var lo = 1
    var hi = chars.count
    var best = "…"
    while lo <= hi {
      let keep = (lo + hi) / 2
      let head = keep - keep / 2
      let tail = keep / 2
      let cand = String(chars.prefix(head)) + "…" + String(chars.suffix(tail))
      if textWidth(cand, rowFont) <= maxWidth {
        best = cand
        lo = keep + 1
      } else {
        hi = keep - 1
      }
    }
    return best
  }
}

/// Draws each display's current desktop name as one trigger in that display's menu bar; hovering (or
/// clicking) the trigger drops a vertical tray of that display's named desktops, each a click away.
/// A single name never overflows into the menu-bar extras the way a horizontal row of every name did
/// (#33), and a tray grows downward, so it holds any number of desktops. One borderless panel per
/// display: a status item cannot do this, as macOS mirrors every item onto every menu bar at one
/// shared width.
@MainActor
final class MenuBarStripController {
  private let store: SpacesStore
  private let settings: AppSettings
  private var strips: [CGDirectDisplayID: DisplayStrip] = [:]
  private var observers: [any NSObjectProtocol] = []
  private var appearanceObserver: NSKeyValueObservation?
  private var renderScheduled = false
  /// Set when the triggers may no longer be on every Space; the next render replaces them (#27).
  private var stripsStale = false

  init(store: SpacesStore, settings: AppSettings) {
    self.store = store
    self.settings = settings
    // Displays added, removed or rearranged; the menu bar shown or hidden; the Mac woken. Sleep and
    // wake re-enumerate external displays, and the window server then leaves an existing panel on
    // one Space only although its collection behaviour still says every Space (#27).
    let rebuild: @Sendable (Notification) -> Void = { [weak self] _ in
      MainActor.assumeIsolated {
        self?.stripsStale = true
        self?.scheduleRender()
      }
    }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main,
        using: rebuild))
    observers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: rebuild))
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

  /// Screen notifications can arrive during AppKit's layout pass; redraw on the next main-loop turn
  /// instead, once per burst.
  private func scheduleRender() {
    guard !renderScheduled else { return }
    renderScheduled = true
    DispatchQueue.main.async { [weak self] in
      self?.renderScheduled = false
      self?.render()
    }
  }

  private func render() {
    if stripsStale {
      // A new panel joins every Space; re-fronting an old one does not. Also drops the strips of
      // display IDs that no longer exist.
      stripsStale = false
      strips.values.forEach { $0.hide() }
      strips.removeAll()
    }
    let appearance = menuBarAppearance()
    var shown = Set<CGDirectDisplayID>()
    for screen in NSScreen.screens where settings.showSpaceNameInMenuBar {
      guard let id = screen.displayID, let monitor = store.monitor(for: screen) else { continue }
      // A full-screen app hides the menu bar, and the trigger would otherwise stay over the app (#22).
      let current = monitor.spaces.first { $0.uuid == monitor.currentSpaceUUID }
      if current?.isFullscreenApp == true { continue }
      let items = store.stripItems(for: monitor)
      guard !items.isEmpty else { continue }
      let name = store.currentName(for: monitor)
      guard let frames = Self.frames(on: screen, name: name, items: items) else { continue }
      shown.insert(id)
      // Leaving a full-screen app leaves the panel on the desktop the display returns to and on no
      // other, with no wake or display change to rebuild on. A trigger that is not on the Space its
      // display shows is replaced, whatever the cause; a new one joins every Space (#31).
      if let current, let old = strips[id], !old.isOn(space: current.id) {
        old.hide()
        strips[id] = nil
      }
      let strip = strips[id] ?? DisplayStrip()
      strips[id] = strip
      strip.update(
        name: name, items: items, triggerFrame: frames.trigger, trayFrame: frames.tray,
        appearance: appearance)
    }
    for (id, strip) in strips where !shown.contains(id) {
      strip.hide()
    }
  }

  /// The appearance the menu bar is drawn in. On macOS 26/27 it follows the wallpaper, not the system
  /// theme, so a light-mode Mac can have a dark menu bar. The trigger borrows it from the app's own
  /// status-item window and redraws when it changes (#25). Nil until that window exists.
  // ponytail: one status-item window stands for every display; displays whose wallpapers give their
  // menu bars different colours would need a per-display source.
  private func menuBarAppearance() -> NSAppearance? {
    let window = NSApp?.windows.first {
      String(describing: type(of: $0)) == "NSStatusBarWindow" && $0.frame.width > 0
    }
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

  /// The trigger's frame in the menu bar and the tray's frame beneath it. The trigger sits just right
  /// of the camera housing on a notched display, or centred on a display without one — never out in
  /// the menu-bar extras on the right. The tray hangs from the menu bar under the trigger, clamped to
  /// stay on the display. Nil while the display shows no menu bar (auto-hidden).
  private static func frames(on screen: NSScreen, name: String?, items: [StripItem]) -> (
    trigger: CGRect, tray: CGRect
  )? {
    let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
    guard menuBarHeight > 0 else { return nil }
    let top = screen.frame.maxY - menuBarHeight
    let triggerW = MenuBarStrip.triggerWidth(name: name)
    let triggerX: CGFloat
    // ponytail: the notch area is taken relative to the display's own origin; if the trigger lands in
    // the wrong place on a notched Mac, drop the `screen.frame.minX +` offset.
    if let right = screen.auxiliaryTopRightArea, right.width > 0 {
      triggerX = screen.frame.minX + right.minX + 6
    } else {
      triggerX = screen.frame.midX - triggerW / 2
    }
    let trigger = CGRect(x: floor(triggerX), y: top, width: ceil(triggerW), height: menuBarHeight)

    let trayW = MenuBarStrip.trayWidth(items: items)
    let trayH = MenuBarStrip.trayHeight(items: items)
    let trayX = min(
      max(trigger.midX - trayW / 2, screen.frame.minX + 6), screen.frame.maxX - trayW - 6)
    let tray = CGRect(x: floor(trayX), y: top - trayH, width: ceil(trayW), height: ceil(trayH))
    return (trigger, tray)
  }
}

/// One display's always-visible trigger plus its on-demand tray, and the hover handoff between them.
@MainActor
private final class DisplayStrip {
  private let triggerPanel: NSPanel
  private let trayPanel: NSPanel
  private let triggerView = TriggerView()
  private let trayView = TrayView()
  private var trayFrame: CGRect = .zero
  private var hoveringTrigger = false
  private var hoveringTray = false
  private var hideWork: DispatchWorkItem?

  init() {
    triggerPanel = Self.makePanel(rounded: false)
    trayPanel = Self.makePanel(rounded: true)
    triggerPanel.contentView = triggerView

    // The tray is a native menu-style vibrant card with the list drawn on top.
    let effect = NSVisualEffectView()
    effect.material = .menu
    effect.blendingMode = .behindWindow
    effect.state = .active
    effect.wantsLayer = true
    effect.layer?.cornerRadius = MenuBarStrip.trayCorner
    effect.layer?.masksToBounds = true
    trayView.autoresizingMask = [.width, .height]
    effect.addSubview(trayView)
    trayPanel.contentView = effect

    triggerView.onEnter = { [weak self] in
      self?.hoveringTrigger = true
      self?.showTray()
    }
    triggerView.onExit = { [weak self] in
      self?.hoveringTrigger = false
      self?.scheduleHide()
    }
    triggerView.onClick = { [weak self] in self?.toggleTray() }
    trayView.onEnter = { [weak self] in
      self?.hoveringTray = true
      self?.cancelHide()
    }
    trayView.onExit = { [weak self] in
      self?.hoveringTray = false
      self?.scheduleHide()
    }
    trayView.onSelect = { [weak self] item in
      DesktopSwitcher.switchTo(space: item.id)
      self?.hideTray()
    }
  }

  private static func makePanel(rounded: Bool) -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = rounded
    // Explicitly false: a clear window otherwise lets clicks fall through to what is beneath.
    panel.ignoresMouseEvents = false
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    // No .fullScreenAuxiliary. On macOS 27 that alone does not keep the panel off full-screen
    // Spaces, so render() hides it there itself (#22).
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    return panel
  }

  func update(
    name: String?, items: [StripItem], triggerFrame: CGRect, trayFrame: CGRect,
    appearance: NSAppearance?
  ) {
    // The trigger's text colour follows the menu bar, not the app's light/dark setting (#25).
    triggerPanel.appearance = appearance
    triggerView.name = name
    triggerPanel.setFrame(triggerFrame, display: true)
    triggerPanel.orderFrontRegardless()

    trayView.items = items
    trayView.textWidth = trayFrame.width - 2 * MenuBarStrip.rowPadH
    self.trayFrame = trayFrame
    if trayPanel.isVisible {
      trayPanel.setFrame(trayFrame, display: true)
      trayView.needsDisplay = true
    }
  }

  private func showTray() {
    cancelHide()
    triggerView.trayOpen = true
    trayPanel.setFrame(trayFrame, display: true)
    trayView.needsDisplay = true
    trayPanel.orderFrontRegardless()
  }

  private func hideTray() {
    cancelHide()
    triggerView.trayOpen = false
    trayPanel.orderOut(nil)
  }

  private func toggleTray() {
    if trayPanel.isVisible { hideTray() } else { showTray() }
  }

  private func cancelHide() {
    hideWork?.cancel()
    hideWork = nil
  }

  /// Leaving the trigger for the tray, or back, crosses a one-pixel seam; a short grace period keeps
  /// the tray up across it and closes it only once the pointer has truly left both.
  private func scheduleHide() {
    cancelHide()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.hoveringTrigger, !self.hoveringTray else { return }
      self.hideTray()
    }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
  }

  /// Whether the window server has the trigger on the given Space (`ManagedSpaceID`). AppKit cannot
  /// say: it still believes the panel is on every Space. True when the window server gives no answer.
  func isOn(space id: Int) -> Bool {
    let spaces =
      CGSCopySpacesForWindows(CGSMainConnectionID(), 7, [triggerPanel.windowNumber] as CFArray)
      as? [Int] ?? []
    return spaces.isEmpty || spaces.contains(id)
  }

  func hide() {
    cancelHide()
    triggerPanel.orderOut(nil)
    trayPanel.orderOut(nil)
  }
}

/// The current desktop's name and a disclosure chevron, drawn in the menu bar. Hovering or clicking
/// it opens the tray; it takes the first click so a click lands without first activating the app.
private final class TriggerView: NSView {
  var name: String? { didSet { needsDisplay = true } }
  var trayOpen = false { didSet { needsDisplay = true } }
  private var hovering = false { didSet { needsDisplay = true } }
  var onEnter: (() -> Void)?
  var onExit: (() -> Void)?
  var onClick: (() -> Void)?

  override var isFlipped: Bool { false }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
  }

  override func mouseEntered(with event: NSEvent) {
    hovering = true
    onEnter?()
  }
  override func mouseExited(with event: NSEvent) {
    hovering = false
    onExit?()
  }
  override func mouseDown(with event: NSEvent) { onClick?() }

  override func draw(_ dirtyRect: NSRect) {
    if hovering || trayOpen {
      NSColor.labelColor.withAlphaComponent(0.15).setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 3), xRadius: 5, yRadius: 5).fill()
    }
    var x = MenuBarStrip.triggerPadH
    if let name, !name.isEmpty {
      let attrs: [NSAttributedString.Key: Any] = [
        .font: MenuBarStrip.triggerFont, .foregroundColor: NSColor.labelColor,
      ]
      let s = name as NSString
      let size = s.size(withAttributes: attrs)
      s.draw(at: NSPoint(x: x, y: bounds.midY - size.height / 2), withAttributes: attrs)
      x += size.width + MenuBarStrip.nameChevronGap
    }
    // Disclosure chevron: a downward V, centred vertically.
    let cw = MenuBarStrip.chevronWidth
    let ch: CGFloat = 4
    let cy = bounds.midY
    let path = NSBezierPath()
    path.move(to: NSPoint(x: x, y: cy + ch / 2))
    path.line(to: NSPoint(x: x + cw / 2, y: cy - ch / 2))
    path.line(to: NSPoint(x: x + cw, y: cy + ch / 2))
    path.lineWidth = 1.3
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    NSColor.labelColor.withAlphaComponent(0.75).setStroke()
    path.stroke()
  }
}

/// The drop-down list of a display's named desktops. The current one is marked; a click switches to
/// the clicked desktop. Takes the first click so no prior activation is needed.
private final class TrayView: NSView {
  var items: [StripItem] = [] { didSet { needsDisplay = true } }
  var textWidth: CGFloat = 0
  var onEnter: (() -> Void)?
  var onExit: (() -> Void)?
  var onSelect: ((StripItem) -> Void)?
  private var rowRects: [(CGRect, StripItem)] = []

  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
  }

  override func mouseEntered(with event: NSEvent) { onEnter?() }
  override func mouseExited(with event: NSEvent) { onExit?() }

  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    for (rect, item) in rowRects where rect.contains(p) {
      onSelect?(item)
      return
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    rowRects.removeAll()
    var y = MenuBarStrip.trayPadV
    for item in items {
      let row = CGRect(x: 4, y: y, width: bounds.width - 8, height: MenuBarStrip.rowHeight)
      if item.isCurrent {
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: row, xRadius: 6, yRadius: 6).fill()
      }
      let attrs: [NSAttributedString.Key: Any] = [
        .font: item.isCurrent
          ? NSFont.systemFont(ofSize: 13, weight: .semibold) : MenuBarStrip.rowFont,
        .foregroundColor: NSColor.labelColor,
      ]
      let name = MenuBarStrip.truncate(item.name, toWidth: textWidth)
      let s = name as NSString
      let size = s.size(withAttributes: attrs)
      s.draw(
        at: NSPoint(x: row.minX + (MenuBarStrip.rowPadH - 4), y: row.midY - size.height / 2),
        withAttributes: attrs)
      rowRects.append((row, item))
      y += MenuBarStrip.rowHeight
    }
  }
}

/// Asks the plugin to switch to a Space. macOS has no public API to change the Space, so the plugin
/// does it from inside the process that draws Mission Control: on macOS 27 with the window-server
/// calls WindowManager uses itself, on macOS 26 by pressing the "Switch to Desktop N" shortcut
/// inside the Dock. Nothing happens while the plugin is not active.
enum DesktopSwitcher {
  static func switchTo(space id: Int) {
    var token: Int32 = 0
    guard notify_register_check(Paths.switchSpaceNotification, &token) == NOTIFY_STATUS_OK else {
      return
    }
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
