import AppKit
import SwiftUI

/// The macOS 27 SDK declares `State` both as a property wrapper and as a macro; the macro's plugin
/// (SwiftUIMacros) only ships with Xcode, so `@State` fails under the Command Line Tools. This alias
/// resolves to the property wrapper only.
typealias ViewState = SwiftUICore.State

@main
struct SpacesRenamerApp: App {
  @ViewState private var store = SpacesStore()
  @ViewState private var diagnostics = DiagnosticsModel()
  @ViewState private var activation = ActivationModel()

  init() {
    LoginItem.registerOnFirstLaunch()
  }

  var body: some Scene {
    MenuBarExtra {
      PopoverContent(store: store, diagnostics: diagnostics, activation: activation)
    } label: {
      Image(nsImage: Self.statusIcon)
    }
    .menuBarExtraStyle(.window)
  }

  private static let statusIcon: NSImage = {
    let image = NSImage(named: "StatusBarIcon") ?? NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "Spaces")!
    image.isTemplate = true
    return image
  }()
}

/// Switches the popover between the rename grid and the diagnostics pane; Escape closes either.
private struct PopoverContent: View {
  enum Pane: Hashable {
    case spaces, diagnostics
  }

  let store: SpacesStore
  let diagnostics: DiagnosticsModel
  let activation: ActivationModel

  @ViewState private var pane = Pane.spaces
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker("Pane", selection: $pane) {
        Text("Spaces").tag(Pane.spaces)
        Text("Diagnostics").tag(Pane.diagnostics)
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      switch pane {
      case .spaces:
        RenameView(store: store)
      case .diagnostics:
        DiagnosticsView(model: diagnostics, activation: activation)
      }
    }
    .padding()
    .onExitCommand { dismiss() }
  }
}
