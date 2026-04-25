// Infinite Recall fork: local LLM via mlx-lm.server. No cloud calls.
//
// MLXLifecycleManager — observes whether the local mlx-lm.server is alive,
// whether the launchd plist is installed, and whether the default model is
// downloaded. Exposes published state for UI plus a `start()` / `installAgent()`
// command surface. Does NOT itself spawn the server in-process — we lean on
// launchd so the server outlives the desktop app.

import Foundation
import SwiftUI

@MainActor
final class MLXLifecycleManager: ObservableObject {

  // MARK: - Singleton

  static let shared = MLXLifecycleManager()

  // MARK: - Configuration

  /// Reverse-DNS label of the launchd agent. Must match the plist `Label` key.
  static let launchdLabel = "com.infiniterecall.mlx"

  /// Default model id. Mirrors the `--model` flag in the plist template and the
  /// default in `LocalLLMClient`.
  static let defaultModelID = "mlx-community/Qwen2.5-32B-Instruct-4bit"

  /// Path to the launchd plist once installed.
  static var installedPlistURL: URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home
      .appendingPathComponent("Library/LaunchAgents/\(launchdLabel).plist")
  }

  /// Path to the on-disk huggingface snapshot for the default model.
  /// Matches the canonical layout used by `huggingface_hub.snapshot_download`.
  static var defaultModelCacheURL: URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let slug = defaultModelID.replacingOccurrences(of: "/", with: "--")
    return home
      .appendingPathComponent(".cache/huggingface/hub/models--\(slug)")
  }

  // MARK: - Published state

  /// True if the local server responds to `/v1/models`.
  @Published private(set) var serverRunning: Bool = false

  /// True if the launchd plist exists at `~/Library/LaunchAgents/com.infiniterecall.mlx.plist`.
  @Published private(set) var agentInstalled: Bool = false

  /// True if the model snapshot directory exists locally.
  @Published private(set) var modelPresent: Bool = false

  /// Optional progress for an in-flight model download. Currently unused —
  /// download is delegated to the setup script. Reserved for future in-app downloads.
  @Published private(set) var modelDownloadProgress: Double? = nil

  /// Last poll error, if any (for surfacing in UI).
  @Published private(set) var lastError: String? = nil

  /// True after the first `refresh()` or `refreshSync()` completes. Lets UI
  /// suppress "AI not set up" banners during the brief startup window before
  /// we have any real signal.
  @Published private(set) var hasRefreshedAtLeastOnce: Bool = false

  // MARK: - Polling

  private var pollTask: Task<Void, Never>?

  private init() {
    refreshSync()
  }

  /// Synchronously refresh on-disk facts (plist + model dir). Reachability is async.
  func refreshSync() {
    let fm = FileManager.default
    self.agentInstalled = fm.fileExists(atPath: Self.installedPlistURL.path)
    self.modelPresent = fm.fileExists(atPath: Self.defaultModelCacheURL.path)
    self.hasRefreshedAtLeastOnce = true
  }

  /// Async refresh including a reachability ping.
  func refresh() async {
    refreshSync()
    let reachable = await LocalLLMClient.shared.isReachable()
    self.serverRunning = reachable
    self.hasRefreshedAtLeastOnce = true
  }

  /// Start a background poller that refreshes state every `interval` seconds.
  /// Idempotent — calling twice replaces the previous task.
  func startPolling(interval: TimeInterval = 5) {
    pollTask?.cancel()
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refresh()
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
      }
    }
  }

  func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
  }

  // MARK: - launchctl commands

  /// Ask launchd to start the agent. Caller should `refresh()` afterwards.
  /// No-op (returns false) if the agent isn't installed yet.
  @discardableResult
  func startServer() async -> Bool {
    guard agentInstalled else {
      lastError = "launchd agent not installed — run scripts/setup-mlx-server.sh"
      return false
    }
    let result = Self.runShell(
      "/bin/launchctl", arguments: ["start", Self.launchdLabel])
    if let err = result.stderr, !err.isEmpty {
      lastError = err
    }
    return result.exitCode == 0
  }

  /// Ask launchd to stop the agent.
  @discardableResult
  func stopServer() async -> Bool {
    guard agentInstalled else { return false }
    let result = Self.runShell(
      "/bin/launchctl", arguments: ["stop", Self.launchdLabel])
    if let err = result.stderr, !err.isEmpty {
      lastError = err
    }
    return result.exitCode == 0
  }

  /// Loads the installed plist into launchd. (Setup script normally does this.)
  @discardableResult
  func loadAgent() async -> Bool {
    guard agentInstalled else { return false }
    let result = Self.runShell(
      "/bin/launchctl",
      arguments: ["load", Self.installedPlistURL.path])
    if let err = result.stderr, !err.isEmpty {
      lastError = err
    }
    return result.exitCode == 0
  }

  // MARK: - Process helper

  private struct ShellResult {
    let exitCode: Int32
    let stdout: String?
    let stderr: String?
  }

  private static func runShell(_ launchPath: String, arguments: [String]) -> ShellResult {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: launchPath)
    task.arguments = arguments

    let outPipe = Pipe()
    let errPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = errPipe

    do {
      try task.run()
    } catch {
      return ShellResult(
        exitCode: -1,
        stdout: nil,
        stderr: "Failed to launch \(launchPath): \(error.localizedDescription)")
    }

    task.waitUntilExit()

    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    return ShellResult(
      exitCode: task.terminationStatus,
      stdout: String(data: outData, encoding: .utf8),
      stderr: String(data: errData, encoding: .utf8))
  }
}
