import SwiftUI

struct SpaceCell: View {
  static let width: CGFloat = 120

  let index: Int
  let space: Space
  let isCurrent: Bool
  @Binding var name: String
  let focus: FocusState<Int?>.Binding
  let onSubmit: () -> Void

  var body: some View {
    VStack(spacing: 6) {
      HStack(spacing: 4) {
        Text("\(index)")
          .font(.headline)
          .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        if space.isFullscreenApp {
          Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help("Full-screen app")
        }
      }
      TextField("Desktop \(index)", text: $name)
        .textFieldStyle(.roundedBorder)
        .focused(focus, equals: space.id)
        .onSubmit(onSubmit)
    }
    .padding(8)
    .frame(width: Self.width)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(isCurrent ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isCurrent ? 2 : 1)
    )
    .id(space.id)
  }
}
