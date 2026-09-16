import AppKit
import SwiftUI

/// The macOS 27 SDK declares `State` both as a property wrapper and as a macro; the macro's plugin
/// (SwiftUIMacros) only ships with Xcode, so `@State` fails under the Command Line Tools. This alias
/// resolves to the property wrapper only.
typealias ViewState = SwiftUICore.State

@main
struct SpacesRenamerApp: App {
  @ViewState private var store: SpacesStore
  @ViewState private var settings: AppSettings
  @ViewState private var diagnostics = DiagnosticsModel()
  @ViewState private var activation = ActivationModel()
  private let hud: SpaceHUDController

  init() {
    LoginItem.registerOnFirstLaunch()
    let store = SpacesStore()
    let settings = AppSettings()
    _store = ViewState(initialValue: store)
    _settings = ViewState(initialValue: settings)
    hud = SpaceHUDController(store: store, settings: settings)
  }

  var body: some Scene {
    MenuBarExtra {
      PopoverContent(store: store, diagnostics: diagnostics, activation: activation, settings: settings)
    } label: {
      MenuBarLabel(store: store, settings: settings)
    }
    .menuBarExtraStyle(.window)
  }

  static let statusIcon: NSImage = {
    let image = NSImage(named: "StatusBarIcon") ?? NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Spaces")!
    image.isTemplate = true
    return image
  }()

  /// The menu-bar content as one template image — the name drawn to the left of the icon. A
  /// MenuBarExtra always renders a separate label image on the leading edge, so the only way to put
  /// the name *before* the icon is to bake both into a single image.
  static func menuBarImage(name: String) -> NSImage {
    let iconLength: CGFloat = 16
    let icon = statusIcon
    guard !name.isEmpty else {
      let image = NSImage(size: NSSize(width: iconLength, height: iconLength))
      image.lockFocus()
      icon.draw(in: NSRect(x: 0, y: 0, width: iconLength, height: iconLength))
      image.unlockFocus()
      image.isTemplate = true
      return image
    }
    let font = NSFont.menuBarFont(ofSize: 0)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    let text = name as NSString
    let textSize = text.size(withAttributes: attributes)
    let gap: CGFloat = 5
    let height = ceil(max(textSize.height, iconLength))
    let width = ceil(textSize.width + gap + iconLength)
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    text.draw(at: NSPoint(x: 0, y: (height - textSize.height) / 2), withAttributes: attributes)
    icon.draw(in: NSRect(x: textSize.width + gap, y: (height - iconLength) / 2, width: iconLength, height: iconLength))
    image.unlockFocus()
    image.isTemplate = true
    return image
  }
}

/// The menu-bar item: the current Space's name (optional) to the left of the icon, live-updating as
/// the Space changes.
private struct MenuBarLabel: View {
  let store: SpacesStore
  let settings: AppSettings

  var body: some View {
    Image(nsImage: SpacesRenamerApp.menuBarImage(
      name: settings.showSpaceNameInMenuBar ? store.menuBarLabel : ""))
  }
}

/// Switches the popover between the rename grid and the diagnostics pane; Escape closes either.
private struct PopoverContent: View {
  enum Pane: Hashable {
    case spaces, diagnostics
  }

  let store: SpacesStore
  let diagnostics: DiagnosticsModel
  let activation: ActivationModel
  let settings: AppSettings

  @ViewState private var pane = Pane.spaces
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if activation.hasLoaded && !activation.isActive {
        ActivationPrompt(activation: activation) { pane = .diagnostics }
      }

      Picker("Pane", selection: $pane) {
        Text("Spaces").tag(Pane.spaces)
        Text("Diagnostics").tag(Pane.diagnostics)
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      switch pane {
      case .spaces:
        RenameView(store: store, settings: settings)
      case .diagnostics:
        DiagnosticsView(model: diagnostics, activation: activation)
      }
    }
    .padding()
    .onExitCommand { dismiss() }
    .onAppear { activation.refresh() }
  }
}

/// First-run nudge shown above the panes whenever no injector is active, so the very first thing a
/// new user sees is a one-click way to turn renaming on — not an empty grid with no hint.
private struct ActivationPrompt: View {
  let activation: ActivationModel
  let showDetails: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "wand.and.stars")
        .font(.title3)
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 4) {
        Text("Renaming isn't active yet")
          .font(.headline)
        Text("Load the plugin so your names show in Mission Control.")
          .font(.callout)
          .foregroundStyle(.secondary)
        HStack(spacing: 8) {
          Button("Activate", action: activation.activate)
            .buttonStyle(.borderedProminent)
            .disabled(activation.isBusy || !activation.isEmbedded)
          Button("Details", action: showDetails)
          if activation.isBusy {
            ProgressView().controlSize(.small)
          }
        }
        if let error = activation.errorMessage {
          Text(error)
            .font(.footnote)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
  }
}
