import AppKit
import Observation

struct DiagnosticCheck: Identifiable {
  enum Status {
    case pass, fail, unknown
  }

  let title: String
  var status: Status = .unknown
  var finding: String = "Not checked yet"
  /// Shown only for failures.
  var remedy: String?

  var id: String { title }
}

/// The four environment checks the Spaces-bar plugin depends on. Checks run off the main thread.
@MainActor
@Observable
final class DiagnosticsModel {
  nonisolated static let activationTODO = "TODO: plugin activation steps (tracked separately in issue #2)"

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

  nonisolated private static func runAll() -> [DiagnosticCheck] {
    let marker = NSDictionary(contentsOf: Paths.pluginMarker)
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
      check.remedy = "Reboot into Recovery (hold the power button), open Terminal, run `csrutil disable`, then reboot."
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
      check.remedy = "Run `sudo nvram boot-args=-arm64e_preview_abi` in Terminal and reboot."
    }
    return check
  }

  nonisolated private static func pluginVersion(_ marker: NSDictionary?) -> DiagnosticCheck {
    var check = DiagnosticCheck(title: "Plugin version")
    guard let marker else {
      check.status = .fail
      check.finding = "not loaded"
      check.remedy = activationTODO
      return check
    }
    let version = marker["Version"] as? String ?? "unknown"
    let build = marker["Build"] as? String ?? "unknown"
    check.status = .pass
    check.finding = "Version \(version), build \(build)"
    return check
  }

  /// The marker names the host the plugin loaded into: `com.apple.dock` on macOS 26,
  /// `com.apple.WindowManager` on macOS 27+ (which draws the Spaces bar there).
  nonisolated private static func pluginActive(_ marker: NSDictionary?) -> DiagnosticCheck {
    var check = DiagnosticCheck(title: "Plugin active in host")
    guard let marker, let markerPID = marker["HostPID"] as? Int, let bundleID = marker["HostBundleID"] as? String else {
      check.status = .fail
      check.finding = "not loaded"
      check.remedy = activationTODO
      return check
    }
    let lastComponent = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    let hostName = lastComponent.prefix(1).uppercased() + lastComponent.dropFirst()
    guard let hostPID = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier else {
      check.finding = "\(hostName) (\(bundleID)) is not running"
      return check
    }
    if Int(hostPID) == markerPID {
      check.status = .pass
      check.finding = "active in \(hostName) (pid \(hostPID), \(bundleID))"
    } else {
      check.status = .fail
      check.finding = "loaded into \(hostName) pid \(markerPID), but the current \(hostName) pid is \(hostPID) (\(bundleID))"
      check.remedy = activationTODO
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
