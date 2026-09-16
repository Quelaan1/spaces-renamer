import AppKit
import Observation

/// A one-tap fix offered next to a failing check.
enum RemedyAction: Equatable {
  /// Copy a Terminal command to the clipboard (used where macOS forbids automating the step).
  case copyCommand(String)
  /// Add `-arm64e_preview_abi` to boot-args (admin prompt), then offer to restart.
  case enableARM64e

  var buttonTitle: String {
    switch self {
    case .copyCommand: "Copy command"
    case .enableARM64e: "Enable & restart…"
    }
  }
}

struct DiagnosticCheck: Identifiable {
  enum Status {
    case pass, fail, unknown
  }

  let title: String
  var status: Status = .unknown
  var finding: String = "Not checked yet"
  /// Shown only for failures.
  var remedy: String?
  /// Optional one-tap fix shown only for failures.
  var action: RemedyAction?

  var id: String { title }
}

/// The four environment checks the Spaces-bar plugin depends on. Checks run off the main thread.
@MainActor
@Observable
final class DiagnosticsModel {
  nonisolated static let activationRemedy = "Turn on an injector in the Activation section below, then re-run checks."

  private(set) var checks: [DiagnosticCheck] = [
    DiagnosticCheck(title: "System Integrity Protection"),
    DiagnosticCheck(title: "Boot arguments"),
    DiagnosticCheck(title: "Plugin version"),
    DiagnosticCheck(title: "Plugin active in host"),
  ]
  private(set) var isRunning = false

  func run() {
    guard !isRunning else { return }
    isRunning = true
    Task.detached(priority: .userInitiated) {
      let results = Self.runAll()
      await MainActor.run {
        self.checks = results
        self.isRunning = false
      }
    }
  }

  /// Feedback for the most recent remedy button (a copy confirmation or an error).
  var actionNote: String?

  func perform(_ action: RemedyAction) {
    actionNote = nil
    switch action {
    case .copyCommand(let command):
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(command, forType: .string)
      actionNote = "Copied “\(command)” to the clipboard."
    case .enableARM64e:
      enableARM64e()
    }
  }

  private func enableARM64e() {
    Task {
      do {
        try await Task.detached(priority: .userInitiated) { try Injector.enableARM64e() }.value
        run()
        offerRestart()
      } catch InjectorError.cancelled {
      } catch {
        actionNote = error.localizedDescription
      }
    }
  }

  private func offerRestart() {
    let alert = NSAlert()
    alert.messageText = "Restart to apply the arm64e ABI?"
    alert.informativeText = "boot-args now includes -arm64e_preview_abi; it takes effect after a restart."
    alert.addButton(withTitle: "Restart Now")
    alert.addButton(withTitle: "Later")
    if alert.runModal() == .alertFirstButtonReturn {
      Injector.restartMac()
    }
  }

  nonisolated private static func runAll() -> [DiagnosticCheck] {
    let marker = PluginMarker.current()
    return [sip(), bootArgs(), pluginVersion(marker), pluginActive(marker)]
  }

  // MARK: - Checks

  nonisolated private static func sip() -> DiagnosticCheck {
    var check = DiagnosticCheck(title: "System Integrity Protection")
    guard let output = run("/usr/bin/csrutil", ["status"]) else {
      check.finding = "Could not run csrutil"
      return check
    }
    let line = output.split(separator: "\n").first.map(String.init) ?? output
    if output.localizedCaseInsensitiveContains("disabled") {
      check.status = .pass
      check.finding = line
    } else {
      check.status = .fail
      check.finding = line
      check.remedy = "macOS can only disable SIP from Recovery: reboot holding the power button, open Terminal, run `csrutil disable`, reboot. Copy the command below."
      check.action = .copyCommand("csrutil disable")
    }
    return check
  }

  nonisolated private static func bootArgs() -> DiagnosticCheck {
    var check = DiagnosticCheck(title: "Boot arguments")
    let output = run("/usr/sbin/nvram", ["boot-args"]) ?? ""
    let value = output.split(separator: "\t", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    if output.contains("-arm64e_preview_abi") {
      check.status = .pass
      check.finding = "boot-args = \(value)"
    } else {
      check.status = .fail
      check.finding = value.isEmpty || output.contains("Error") ? "boot-args not set" : "boot-args = \(value)"
      check.remedy = "Adds `-arm64e_preview_abi` to boot-args (keeping any existing flags) and takes effect after a restart."
      check.action = .enableARM64e
    }
    return check
  }

  nonisolated private static func pluginVersion(_ marker: PluginMarker?) -> DiagnosticCheck {
    var check = DiagnosticCheck(title: "Plugin version")
    guard let marker else {
      check.status = .fail
      check.finding = "not loaded"
      check.remedy = activationRemedy
      return check
    }
    check.status = .pass
    check.finding = "Version \(marker.version), build \(marker.build)"
    return check
  }

  nonisolated private static func pluginActive(_ marker: PluginMarker?) -> DiagnosticCheck {
    var check = DiagnosticCheck(title: "Plugin active in host")
    guard let marker else {
      check.status = .fail
      check.finding = "not loaded"
      check.remedy = activationRemedy
      return check
    }
    if marker.isLive {
      check.status = .pass
      check.finding = "active in \(marker.hostName) (pid \(marker.hostPID), \(marker.hostBundleID))"
    } else {
      check.status = .fail
      check.finding = "stale: loaded into \(marker.hostName) pid \(marker.hostPID) (\(marker.hostBundleID)), which is no longer running"
      check.remedy = activationRemedy
    }
    return check
  }

  // MARK: - Helpers

  /// Combined stdout+stderr of a finished process, or nil if it could not be launched.
  nonisolated private static func run(_ executable: String, _ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
    } catch {
      return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }
}

/// Status entry the plugin writes to its host's own preference domain under `SpacesRenamerPlugin`:
/// `com.apple.WindowManager` on macOS 27+, `com.apple.dock` on macOS 26.
struct PluginMarker {
  static let key = "SpacesRenamerPlugin"
  static let hostDomains = ["com.apple.WindowManager", "com.apple.dock"]

  let version: String
  let build: String
  let hostPID: Int
  let hostBundleID: String
  let loadedAt: Date
  /// `hostPID` is the pid of the running app with `hostBundleID`.
  let isLive: Bool

  var hostName: String {
    let last = hostBundleID.split(separator: ".").last.map(String.init) ?? hostBundleID
    return last.prefix(1).uppercased() + last.dropFirst()
  }

  /// The live entry across both host domains, else the most recently loaded (stale) one, else nil.
  static func current() -> PluginMarker? {
    let markers = hostDomains.compactMap { domain in
      UserDefaults(suiteName: domain)?.dictionary(forKey: key).flatMap(PluginMarker.init(raw:))
    }
    return markers.first(where: \.isLive) ?? markers.max { $0.loadedAt < $1.loadedAt }
  }

  private init?(raw: [String: Any]) {
    guard let hostPID = raw["HostPID"] as? Int, let hostBundleID = raw["HostBundleID"] as? String else { return nil }
    self.hostPID = hostPID
    self.hostBundleID = hostBundleID
    self.version = raw["Version"] as? String ?? "unknown"
    self.build = raw["Build"] as? String ?? "unknown"
    self.loadedAt = raw["LoadedAt"] as? Date ?? .distantPast
    self.isLive = NSRunningApplication.runningApplications(withBundleIdentifier: hostBundleID)
      .contains { Int($0.processIdentifier) == hostPID }
  }
}
