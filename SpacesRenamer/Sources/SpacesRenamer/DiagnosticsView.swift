import SwiftUI

struct DiagnosticsView: View {
  let model: DiagnosticsModel

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
          }
        }
      }

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
    .onAppear(perform: model.run)
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
