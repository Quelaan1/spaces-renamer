import AppKit
import SwiftUI

/// Shows a brief, glass-styled HUD centered on each display whose Space just changed — each display
/// showing its own current Space's name. Driven by `activeSpaceDidChangeNotification`; gated on the
/// user setting. Pure app UI, independent of the injected plugin.
@MainActor
final class SpaceHUDController {
  private let store: SpacesStore
  private let settings: AppSettings
  private var observer: (any NSObjectProtocol)?
  /// One reusable panel per screen, keyed by the screen's display id.
  private var panels: [CGDirectDisplayID: SpaceHUDPanel] = [:]
  /// Each monitor's current Space uuid as of the last change, so only displays that changed show the HUD.
  private var lastSpaces: [String: String]

  init(store: SpacesStore, settings: AppSettings) {
    self.store = store
    self.settings = settings
    lastSpaces = Self.currentSpaces(store.monitors)
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.spaceChanged() }
    }
  }

  private func spaceChanged() {
    let labels = store.currentDisplayLabels()
    let previous = lastSpaces
    lastSpaces = Self.currentSpaces(store.monitors)
    guard settings.showSpaceChangeHUD else { return }
    for (screen, monitor, label) in labels where previous[monitor.id] != monitor.currentSpaceUUID {
      guard let id = screen.displayID else { continue }
      let panel = panels[id] ?? SpaceHUDPanel()
      panels[id] = panel
      panel.show(label, on: screen)
    }
  }

  private static func currentSpaces(_ monitors: [Monitor]) -> [String: String] {
    Dictionary(monitors.map { ($0.id, $0.currentSpaceUUID) }, uniquingKeysWith: { first, _ in first })
  }
}

/// A borderless, click-through floating panel that fades a `SpaceHUDView` in and back out.
@MainActor
private final class SpaceHUDPanel {
  private let panel: NSPanel
  private let hosting: NSHostingView<SpaceHUDView>
  private var dismiss: DispatchWorkItem?

  init() {
    hosting = NSHostingView(rootView: SpaceHUDView(label: ""))
    panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .statusBar
    panel.ignoresMouseEvents = true
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    panel.contentView = hosting
    panel.alphaValue = 0
  }

  func show(_ label: String, on screen: NSScreen) {
    hosting.rootView = SpaceHUDView(label: label)
    let size = hosting.fittingSize
    let origin = CGPoint(
      x: screen.frame.midX - size.width / 2,
      y: screen.frame.midY - size.height / 2)
    panel.setFrame(CGRect(origin: origin, size: size), display: true)
    panel.orderFrontRegardless()

    NSAnimationContext.runAnimationGroup { context in
      context.duration = panel.alphaValue == 0 ? 0.16 : 0
      panel.animator().alphaValue = 1
    }

    dismiss?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
    dismiss = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
  }

  private func fadeOut() {
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.35
      panel.animator().alphaValue = 0
    }, completionHandler: { [weak panel] in
      MainActor.assumeIsolated { panel?.orderOut(nil) }
    })
  }
}

/// The glass card itself: the Space name on macOS's Liquid Glass material.
private struct SpaceHUDView: View {
  let label: String

  var body: some View {
    Text(label)
      .font(.system(size: 26, weight: .semibold, design: .rounded))
      .foregroundStyle(.primary)
      .lineLimit(1)
      .padding(.horizontal, 30)
      .padding(.vertical, 20)
      .glassEffect(.regular, in: .rect(cornerRadius: 26))
      .padding(24)
      .fixedSize()
  }
}
