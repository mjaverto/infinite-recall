// Infinite Recall fork: local VLM (vision-language model) sidecar via
// mlx-vlm.server. Mirrors MLXLifecycleManager but for the image-text-to-text
// tier on 127.0.0.1:8081.
//
// Two-tier architecture: text tier (mlx-lm.server, 8080) handles transcripts +
// extraction; vision tier (mlx-vlm.server, 8081) handles screenshot/frame
// analysis. Each owns its own launchd agent + Python toolchain.

import Foundation
import SwiftUI

@MainActor
final class VLMLifecycleManager: ObservableObject {

  // MARK: - Singleton

  static let shared = VLMLifecycleManager()

  // MARK: - Configuration

  /// Reverse-DNS label of the launchd agent. Must match the plist `Label` key.
  static let launchdLabel = "com.infiniterecall.vlm"

  /// Default vision model id. Verified on huggingface.co:
  ///   - mlx-community/Qwen3-VL-8B-Instruct-4bit
  ///   - pipeline_tag: image-text-to-text
  ///   - license: Apache 2.0
  ///   - converted via mlx-vlm 0.3.4
  ///   - ~5–6 GB on disk for 4-bit weights
  static let defaultModelID = "mlx-community/Qwen3-VL-8B-Instruct-4bit"

  /// Path to the launchd plist once installed.
  static var installedPlistURL: URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home
      .appendingPathComponent("Library/LaunchAgents/\(launchdLabel).plist")
  }

  /// Path to the on-disk huggingface snapshot for the default model.
  static var defaultModelCacheURL: URL {
    modelCacheURL(for: defaultModelID)
  }

  static func modelCacheURL(for modelId: String) -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let slug = modelId.replacingOccurrences(of: "/", with: "--")
    return home
      .appendingPathComponent(".cache/huggingface/hub/models--\(slug)")
  }

  /// `@AppStorage("activeVisionModelID")` key. Mirrors the text tier pattern.
  static let activeModelDefaultsKey = "activeVisionModelID"

  /// The vision model id the user has selected, falling back to the default.
  static var activeModelID: String {
    UserDefaults.standard.string(forKey: activeModelDefaultsKey) ?? defaultModelID
  }

  // MARK: - Published state

  @Published private(set) var serverRunning: Bool = false
  @Published private(set) var agentInstalled: Bool = false
  @Published private(set) var modelPresent: Bool = false
  @Published private(set) var modelDownloadProgress: Double? = nil
  @Published private(set) var lastError: String? = nil
  @Published private(set) var hasRefreshedAtLeastOnce: Bool = false

  // MARK: - Polling

  private var pollTask: Task<Void, Never>?

  private init() {
    refreshSync()
  }

  func refreshSync() {
    let fm = FileManager.default
    self.agentInstalled = fm.fileExists(atPath: Self.installedPlistURL.path)
    self.modelPresent = Self.installedCacheURL(for: Self.activeModelID) != nil
    self.hasRefreshedAtLeastOnce = true
  }

  func refresh() async {
    refreshSync()
    let reachable = await VisionLLMClient.shared.isReachable()
    self.serverRunning = reachable
    self.hasRefreshedAtLeastOnce = true
  }

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

  // MARK: - Per-model install state

  func isModelInstalled(modelId: String) -> Bool {
    Self.installedCacheURL(for: modelId) != nil
  }

  // MARK: - Disk-size + delete helpers
  //
  // Vision models follow the same on-disk layout as text models, so we share
  // `MLXLifecycleManager`'s implementation rather than duplicating the
  // FileManager.enumerator walk.

  /// Both possible on-disk locations for `modelId`. Mirrors the text tier so
  /// vision and text caches share a single defensive guard.
  static func candidateCacheURLs(for modelId: String) -> [URL] {
    MLXLifecycleManager.candidateCacheURLs(for: modelId)
  }

  static func installedCacheURL(for modelId: String) -> URL? {
    MLXLifecycleManager.installedCacheURL(for: modelId)
  }

  /// Total bytes consumed by a vision model's cache. Delegates to the shared
  /// helper; same canonical paths apply (HF puts every model under the same
  /// root regardless of pipeline).
  static func modelCacheSizeBytes(for modelId: String) -> Int64 {
    MLXLifecycleManager.modelCacheSizeBytes(for: modelId)
  }

  /// Recursively delete a vision model's cache. Returns false (no-op) if
  /// `modelId` is the currently active vision model — caller must switch
  /// models first. Delegates the actual removal + path guard to
  /// `MLXLifecycleManager.deleteModel(_:)` (HF cache layout is identical).
  @discardableResult
  static func deleteModel(_ modelId: String) -> Bool {
    // Defensive: never delete the model that is currently configured as active.
    guard modelId != activeModelID else { return false }
    return MLXLifecycleManager.deleteModel(modelId)
  }

  // MARK: - Plist regeneration for active model

  /// Rewrites the launchd plist at `installedPlistURL` so its `--model`
  /// argument matches `Self.activeModelID`. Mirrors
  /// `MLXLifecycleManager.regeneratePlistForActiveModel()` exactly, but
  /// substitutes the VLM label, port (8081), and mlx-vlm tool invocation.
  ///
  /// Caller is responsible for `launchctl unload` + `launchctl load` (and
  /// for stopping the server first if it's running).
  ///
  /// Returns `true` on success. On failure sets `lastError` and returns
  /// `false`. No-op (returns false) if the agent isn't installed yet.
  @discardableResult
  func regeneratePlistForActiveModel() -> Bool {
    guard agentInstalled else {
      lastError = "launchd agent not installed — install the vision model first."
      return false
    }

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    guard let uvBin = Self.locateUVBinary() else {
      lastError =
        "Could not find `uv` on PATH. Re-run the vision model installer."
      return false
    }

    let model = Self.activeModelID
    let host = "127.0.0.1"
    let port = "8081"

    let rendered = Self.plistTemplate
      .replacingOccurrences(of: "__USER_HOME__", with: home)
      .replacingOccurrences(of: "__UV_BIN__", with: uvBin)
      .replacingOccurrences(of: "__MODEL__", with: model)
      .replacingOccurrences(of: "__HOST__", with: host)
      .replacingOccurrences(of: "__PORT__", with: port)

    let dest = Self.installedPlistURL
    do {
      try rendered.data(using: .utf8)?
        .write(to: dest, options: .atomic)
    } catch {
      lastError = "Failed to write \(dest.path): \(error.localizedDescription)"
      return false
    }
    return true
  }

  /// Re-applies the plist (unload + load) so launchd picks up the rewritten
  /// `ProgramArguments`. Does NOT start the server — caller follows up with
  /// `startServer()` if desired.
  @discardableResult
  func reloadAgent() async -> Bool {
    guard agentInstalled else { return false }
    _ = Self.runShell(
      "/bin/launchctl",
      arguments: ["unload", Self.installedPlistURL.path])
    let load = Self.runShell(
      "/bin/launchctl",
      arguments: ["load", Self.installedPlistURL.path])
    if let err = load.stderr, !err.isEmpty {
      lastError = err
    }
    return load.exitCode == 0
  }

  /// Probe likely locations for `uv`. Mirrors `MLXLifecycleManager.locateUVBinary()`.
  private static func locateUVBinary() -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
      "\(home)/.local/bin/uv",
      "/opt/homebrew/bin/uv",
      "/usr/local/bin/uv",
      "/usr/bin/uv",
    ]
    let fm = FileManager.default
    for path in candidates where fm.isExecutableFile(atPath: path) {
      return path
    }

    // Last-ditch: ask the shell.
    let result = runShell("/usr/bin/which", arguments: ["uv"])
    if result.exitCode == 0,
       let out = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
       !out.isEmpty
    {
      return out
    }
    return nil
  }

  /// Inline copy of `scripts/com.infiniterecall.vlm.plist`. Must stay
  /// byte-identical to the template stored in `BundledScripts.vlmLaunchdPlist`
  /// (sync contract — see that file).
  private static let plistTemplate: String = ##"""
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Infinite Recall — launchd agent template for mlx-vlm.server (vision tier).
  Placeholders are replaced by scripts/setup-vlm-server.sh:
    __USER_HOME__  -> $HOME
    __UV_BIN__     -> absolute path to `uv`
    __MODEL__      -> Hugging Face model id
    __HOST__       -> bind host (default 127.0.0.1)
    __PORT__       -> bind port (default 8081)
-->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.infiniterecall.vlm</string>

  <key>ProgramArguments</key>
  <array>
    <string>__UV_BIN__</string>
    <string>tool</string>
    <string>run</string>
    <string>--from</string>
    <string>mlx-vlm</string>
    <string>mlx_vlm.server</string>
    <string>--model</string>
    <string>__MODEL__</string>
    <string>--host</string>
    <string>__HOST__</string>
    <string>--port</string>
    <string>__PORT__</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <true/>

  <key>ProcessType</key>
  <string>Interactive</string>

  <key>StandardOutPath</key>
  <string>__USER_HOME__/Library/Logs/InfiniteRecall/vlm.out.log</string>

  <key>StandardErrorPath</key>
  <string>__USER_HOME__/Library/Logs/InfiniteRecall/vlm.err.log</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>__USER_HOME__/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
"""##

  // MARK: - launchctl commands

  @discardableResult
  func startServer() async -> Bool {
    guard agentInstalled else {
      lastError = "launchd agent not installed — run scripts/setup-vlm-server.sh"
      return false
    }
    let result = Self.runShell(
      "/bin/launchctl", arguments: ["start", Self.launchdLabel])
    if let err = result.stderr, !err.isEmpty {
      lastError = err
    }
    return result.exitCode == 0
  }

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

  // MARK: - Re-entrant-safe ensure-running

  /// Re-entrancy guard: prevents recursive deadlock when the restart polling
  /// loop calls `VisionLLMClient.isReachable()`, which must NOT call back into
  /// `recordAICall()` (same invariant as Sprint BB for the text tier).
  private var ensuringServer: Bool = false

  /// If the VLM server isn't running and `serverStoppedByIdle` is true, ask
  /// launchd to start it and poll until reachable (or timeout). Mirrors
  /// `IdleAIController.ensureServerRunning()` for the text tier.
  ///
  /// INVARIANT: `VisionLLMClient.isReachable()` must NEVER call back into this
  /// path (directly or transitively). It is a bare HTTP probe used only as the
  /// polling mechanism here and in `refresh()`. Violating this invariant would
  /// pin the VLM server alive indefinitely, defeating idle eviction.
  func ensureServerRunning() async {
    guard !ensuringServer else { return }
    ensuringServer = true
    defer { ensuringServer = false }

    await refresh()
    if serverRunning { return }
    guard agentInstalled else { return }

    log("VLMLifecycleManager: restarting vision LLM server after idle-unload")
    _ = await startServer()

    let deadline = Date().addingTimeInterval(60)
    while Date() < deadline {
      let reachable = await VisionLLMClient.shared.isReachable()
      if reachable {
        await refresh()
        log("VLMLifecycleManager: vision LLM server is back up.")
        return
      }
      try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    log("VLMLifecycleManager: vision LLM server did not come up within 60s.")
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
