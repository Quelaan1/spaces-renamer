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
      if activation.hasLoaded && activation.state.active == .none {
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
        RenameView(store: store)
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
