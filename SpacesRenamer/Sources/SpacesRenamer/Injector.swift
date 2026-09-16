import AppKit
import Observation

/// The two ways to load `spaces-renamer.dylib` into the Spaces-bar host. Both are driven by the
/// embedded `injector.sh`; the difference is the loading mechanism and its cost.
enum InjectorBackend: String, CaseIterable, Identifiable {
  case dyld
  case mip

  var id: String { rawValue }

  var title: String {
    switch self {
    case .dyld: "DYLD_INSERT_LIBRARIES"
    case .mip: "MIP"
    }
  }

  /// One-line honest summary shown next to the picker.
  var summary: String {
    switch self {
    case .dyld:
      "No root. A per-user LaunchAgent sets the variable and restarts the host at login. The library is loaded into every app you launch, where it does nothing."
    case .mip:
      "Needs a working MIP install and an admin password. Targets only the host and survives reboot with no login agent."
    }
  }
}

/// Parsed output of `injector.sh status`.
struct InjectorState {
  enum Active: String {
    case none, dyld, mip
  }

  var host = "WindowManager"
  var dyldAgent = false
  var dyldEnv = false
  var dyldOn = false
  var mipInstalled = false
  var mipBundleOn = false
  var active: Active = .none

  init() {}

  init(statusOutput: String) {
    for line in statusOutput.split(separator: "\n") {
      let parts = line.split(separator: "=", maxSplits: 1)
      guard parts.count == 2 else { continue }
      let value = String(parts[1])
      switch parts[0] {
      case "host": host = value
      case "dyld_agent": dyldAgent = value == "present"
      case "dyld_env": dyldEnv = value == "set"
      case "dyld": dyldOn = value == "on"
      case "mip_installed": mipInstalled = value == "yes"
      case "mip_bundle": mipBundleOn = value == "on"
      case "active": active = Active(rawValue: value) ?? .none
      default: break
      }
    }
  }
}

enum InjectorError: LocalizedError {
  case notEmbedded
  case cancelled
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .notEmbedded:
      "This build has no embedded injector. Rebuild the app with `make` (it embeds the plugin, the mechanism script and the MIP bundle)."
    case .cancelled:
      "Authorization was cancelled."
    case .failed(let message):
      message.isEmpty ? "The injector command failed." : message
    }
  }
}

/// The app's front-end to `scripts/injector.sh`, embedded in the app bundle. DYLD activation is
/// unprivileged; MIP activation copies a bundle into a system directory and asks for an admin
/// password through `osascript`.
enum Injector {
  static var scriptURL: URL? {
    Bundle.main.url(forResource: "injector", withExtension: "sh")
  }

  static var dylibURL: URL? {
    Bundle.main.builtInPlugInsURL?.appendingPathComponent("spaces-renamer.dylib")
  }

  static var mipBundleURL: URL? {
    Bundle.main.url(forResource: "SpacesRenamer.mip", withExtension: "bundle")
  }

  /// True when the pieces DYLD activation needs are present in this build.
  static var isEmbedded: Bool {
    guard let script = scriptURL, let dylib = dylibURL else { return false }
    return FileManager.default.fileExists(atPath: script.path)
      && FileManager.default.fileExists(atPath: dylib.path)
  }

  static func status() -> InjectorState {
    guard scriptURL != nil, let output = try? sh(["status"]) else {
      var state = InjectorState()
      state.host = defaultHost
      return state
    }
    return InjectorState(statusOutput: output)
  }

  static func activate(_ backend: InjectorBackend) throws {
    switch backend {
    case .dyld:
      guard let dylib = dylibURL, FileManager.default.fileExists(atPath: dylib.path) else {
        throw InjectorError.notEmbedded
      }
      try sh(["dyld", "on", dylib.path])
    case .mip:
      guard let script = scriptURL, let bundle = mipBundleURL else { throw InjectorError.notEmbedded }
      try admin("/bin/sh \(shellQuote(script.path)) mip on \(shellQuote(bundle.path))")
    }
  }

  static func deactivate(_ backend: InjectorBackend) throws {
    switch backend {
    case .dyld:
      try sh(["dyld", "off"])
    case .mip:
      guard let script = scriptURL else { throw InjectorError.notEmbedded }
      try admin("/bin/sh \(shellQuote(script.path)) mip off")
    }
  }

  /// Adds `-arm64e_preview_abi` to boot-args via an admin prompt (root writes NVRAM).
  static func enableARM64e() throws {
    guard let script = scriptURL else { throw InjectorError.notEmbedded }
    try admin("/bin/sh \(shellQuote(script.path)) arm64e on")
  }

  /// User-space restart through System Events, so no extra privilege is needed.
  static func restartMac() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", "tell application \"System Events\" to restart"]
    try? process.run()
  }

  // MARK: - Running the script

  /// Runs the embedded script unprivileged, returning combined stdout+stderr.
  @discardableResult
  private static func sh(_ arguments: [String]) throws -> String {
    guard let script = scriptURL else { throw InjectorError.notEmbedded }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [script.path] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
    } catch {
      throw InjectorError.failed(error.localizedDescription)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else { throw InjectorError.failed(output) }
    return output
  }

  /// Runs a shell command as root via an `osascript` admin prompt.
  private static func admin(_ command: String) throws {
    let escaped = command
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", appleScript]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
    } catch {
      throw InjectorError.failed(error.localizedDescription)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
      // osascript reports a user-cancelled authorization dialog as error -128.
      if output.contains("-128") { throw InjectorError.cancelled }
      throw InjectorError.failed(output)
    }
  }

  private static func shellQuote(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private static var defaultHost: String {
    ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? "WindowManager" : "Dock"
  }
}

/// Drives the Activation section of the Diagnostics pane: current injector state plus activate and
/// deactivate actions. Blocking script work runs off the main actor.
@MainActor
@Observable
final class ActivationModel {
  private(set) var state = InjectorState()
  /// True once the first status read has completed, so the UI can distinguish "not active" from
  /// "not read yet" and avoid flashing a prompt at an already-active user.
  private(set) var hasLoaded = false
  private(set) var isBusy = false
  var backend: InjectorBackend = .dyld
  var errorMessage: String?

  var isEmbedded: Bool { Injector.isEmbedded }

  func refresh() {
    Task { await reload() }
  }

  func activate() {
    perform { try Injector.activate($0) }
  }

  func deactivate() {
    perform { try Injector.deactivate($0) }
  }

  private func perform(_ work: @escaping @Sendable (InjectorBackend) throws -> Void) {
    guard !isBusy else { return }
    isBusy = true
    errorMessage = nil
    let backend = backend
    Task {
      do {
        try await Task.detached(priority: .userInitiated) { try work(backend) }.value
      } catch let error as InjectorError {
        if case .cancelled = error {} else { errorMessage = error.localizedDescription }
      } catch {
        errorMessage = error.localizedDescription
      }
      await reload()
      isBusy = false
    }
  }

  private func reload() async {
    state = await Task.detached(priority: .userInitiated) { Injector.status() }.value
    hasLoaded = true
  }
}
