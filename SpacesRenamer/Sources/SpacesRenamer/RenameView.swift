import AppKit
import SwiftUI

struct RenameView: View {
  private static let cellSpacing: CGFloat = 8
  private static let maxVisibleCells = 6

  let store: SpacesStore

  /// Edits in progress for every live Space, keyed by uuid; seeded from the preference domain each time the popover opens.
  @ViewState private var drafts: [String: String] = [:]
  @FocusState private var focusedSpaceID: Int?
  @Environment(\.dismiss) private var dismiss
  @ViewState private var launchAtLogin = LoginItem.isEnabled
  @ViewState private var loginStatus = LoginItem.statusDescription

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(store.monitors.enumerated()), id: \.element.id) { offset, monitor in
        if store.monitors.count > 1 {
          Text("Monitor \(offset + 1)")
            .font(.headline)
        }
        monitorRow(monitor)
      }

      Divider()

      HStack(spacing: 12) {
        Toggle("Launch at login", isOn: $launchAtLogin)
          .toggleStyle(.checkbox)
          .onChange(of: launchAtLogin) { _, enabled in
            guard enabled != LoginItem.isEnabled else { return }
            try? LoginItem.setEnabled(enabled)
            refreshLoginItem()
          }
        Text(loginStatus)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Quit") { NSApp.terminate(nil) }
        Button("Update Names", action: save)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding()
    .onAppear(perform: popoverOpened)
    .onExitCommand { dismiss() }
  }

  private func monitorRow(_ monitor: Monitor) -> some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        HStack(spacing: Self.cellSpacing) {
          ForEach(Array(monitor.spaces.enumerated()), id: \.element.id) { offset, space in
            SpaceCell(
              index: offset + 1,
              space: space,
              isCurrent: space.uuid == monitor.currentSpaceUUID,
              name: draft(for: space.uuid),
              focus: $focusedSpaceID,
              onSubmit: save
            )
          }
        }
        .padding(2)
      }
      .frame(width: rowWidth)
      .onChange(of: focusedSpaceID, initial: true) { _, id in
        if let id, monitor.spaces.contains(where: { $0.id == id }) {
          proxy.scrollTo(id)
        }
      }
    }
  }

  /// Wide enough for the largest monitor, capped so long rows scroll; a partial cell hints at overflow.
  private var rowWidth: CGFloat {
    let most = store.monitors.map(\.spaces.count).max() ?? 1
    let visible = CGFloat(min(most, Self.maxVisibleCells))
    let overflow: CGFloat = most > Self.maxVisibleCells ? SpaceCell.width / 2 : 0
    return visible * SpaceCell.width + (visible - 1) * Self.cellSpacing + overflow + 4
  }

  private func draft(for uuid: String) -> Binding<String> {
    Binding(
      get: { drafts[uuid] ?? "" },
      set: { drafts[uuid] = $0 }
    )
  }

  private func popoverOpened() {
    store.refresh()
    drafts = store.names
    for space in store.monitors.flatMap(\.spaces) where drafts[space.uuid] == nil {
      drafts[space.uuid] = ""
    }
    refreshLoginItem()
    // The window is not key yet when onAppear fires; defer so the field can accept focus.
    let target = store.focusedSpace?.id
    DispatchQueue.main.async { focusedSpaceID = target }
  }

  private func refreshLoginItem() {
    launchAtLogin = LoginItem.isEnabled
    loginStatus = LoginItem.statusDescription
  }

  private func save() {
    store.save(drafts)
    dismiss()
  }
}
