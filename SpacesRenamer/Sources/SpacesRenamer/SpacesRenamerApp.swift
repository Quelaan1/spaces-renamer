import AppKit
import SwiftUI

/// The macOS 27 SDK declares `State` both as a property wrapper and as a macro; the macro's plugin
/// (SwiftUIMacros) only ships with Xcode, so `@State` fails under the Command Line Tools. This alias
/// resolves to the property wrapper only.
typealias ViewState = SwiftUICore.State

@main
struct SpacesRenamerApp: App {
  @ViewState private var store = SpacesStore()

  init() {
    LoginItem.registerOnFirstLaunch()
  }

  var body: some Scene {
    MenuBarExtra {
      RenameView(store: store)
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
