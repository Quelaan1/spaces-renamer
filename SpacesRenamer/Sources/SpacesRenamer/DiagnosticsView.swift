import SwiftUI

struct DiagnosticsView: View {
  let model: DiagnosticsModel
  let activation: ActivationModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(model.checks) { check in
        HStack(alignment: .top, spacing: 8) {
          Self.icon(for: check.status)
            .font(.title3)
            .frame(width: 20)
          VStack(alignment: .leading, spacing: 2) {
            Text(check.title)
              .font(.headline)
            Text(check.finding)
              .textSelection(.enabled)
            if let remedy = check.remedy {
              Text(remedy)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            if let action = check.action, check.status == .fail {
              Button(action.buttonTitle) { model.perform(action) }
                .controlSize(.small)
                .padding(.top, 2)
            }
          }
        }
      }

      if let note = model.actionNote {
        Text(note)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }

      Divider()

      ActivationSection(model: activation)

      Divider()

      HStack(spacing: 8) {
        Button("Re-run checks", action: model.run)
          .disabled(model.isRunning)
        if model.isRunning {
          ProgressView()
            .controlSize(.small)
        }
        Spacer()
        Button("Quit") { NSApp.terminate(nil) }
      }
    }
    .frame(minWidth: 480, alignment: .leading)
    .onAppear {
      model.run()
      activation.refresh()
    }
    .onChange(of: activation.isBusy) { _, busy in
      if !busy { model.run() }
    }
  }

  private static func icon(for status: DiagnosticCheck.Status) -> some View {
    switch status {
    case .pass:
      Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
    case .fail:
      Image(systemName: "xmark.circle.fill").foregroundStyle(Color.red)
    case .unknown:
      Image(systemName: "questionmark.circle").foregroundStyle(Color.secondary)
    }
  }
}

/// The plugin-activation controls: pick an injector, then turn it on or off. Reflects the live
/// state read from `injector.sh status`.
private struct ActivationSection: View {
  let model: ActivationModel

  private var state: InjectorState { model.state }

  private var activeText: String {
    if state.active == .none {
      return model.pluginIsLive
        ? "The plugin is loaded in \(state.host) — renaming is active. No injector managed by this app is set up."
        : "No injector is active — the Spaces bar shows the default names."
    }
    switch state.active {
    case .dyld: return "Active via DYLD_INSERT_LIBRARIES in \(state.host)."
    case .mip: return "Active via MIP in \(state.host)."
    case .none: return ""
    }
  }

  /// Whether the chosen backend can be turned on right now.
  private var canActivate: Bool {
    guard !model.isBusy else { return false }
    switch model.backend {
    case .dyld: return model.isEmbedded
    case .mip: return state.mipInstalled
    }
  }

  /// Whether the chosen backend is currently on and can be turned off.
  private var canDeactivate: Bool {
    guard !model.isBusy else { return false }
    switch model.backend {
    case .dyld: return state.dyldOn
    case .mip: return state.mipBundleOn
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Activation")
        .font(.headline)
      Text(activeText)
        .font(.callout)
        .foregroundStyle(.secondary)

      Picker("Injector", selection: Binding(get: { model.backend }, set: { model.backend = $0 })) {
        ForEach(InjectorBackend.allCases) { backend in
          Text(backend.title).tag(backend)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .disabled(model.isBusy)

      Text(model.backend.summary)
        .font(.footnote)
        .foregroundStyle(.secondary)

      if model.backend == .mip, !state.mipInstalled {
        Text("MIP is not installed. Install github.com/LIJI32/MIP first (see the README), then reopen this app.")
          .font(.footnote)
          .foregroundStyle(Color.orange)
      }
      if model.backend == .dyld, !model.isEmbedded {
        Text("This build has no embedded injector. Rebuild the app with `make`.")
          .font(.footnote)
          .foregroundStyle(Color.orange)
      }

      HStack(spacing: 8) {
        Button("Activate", action: model.activate)
          .disabled(!canActivate)
        Button("Deactivate", action: model.deactivate)
          .disabled(!canDeactivate)
        if model.isBusy {
          ProgressView().controlSize(.small)
        }
      }

      if let error = model.errorMessage {
        Text(error)
          .font(.footnote)
          .foregroundStyle(Color.red)
          .textSelection(.enabled)
      }
    }
  }
}
