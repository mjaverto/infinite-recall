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
  ///
  /// Switched from Qwen2.5-32B-Instruct-4bit (~18 GB disk, ~20 GB RAM) to the
  /// 7B variant (~4.3 GB disk, ~7-9 GB RAM) for new installs. Existing users
  /// who already pulled the 32B snapshot keep working — the launchd plist they
  /// have on disk still points at the 32B path; only fresh `setup-mlx-server.sh`
  /// runs default to the new model. Same Qwen2.5 family / chat template, so the
  /// prompt formats in the rest of the app are unchanged.
  static let defaultModelID = "mlx-community/Qwen2.5-7B-Instruct-4bit"

  /// Path to the launchd plist once installed.
  static var installedPlistURL: URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home
      .appendingPathComponent("Library/LaunchAgents/\(launchdLabel).plist")
  }

  /// Path to the on-disk huggingface snapshot for the default model.
  /// Matches the canonical layout used by `huggingface_hub.snapshot_download`.
  static var defaultModelCacheURL: URL {
    modelCacheURL(for: defaultModelID)
  }

  /// Hugging Face cache path for an arbitrary model id (the standard
  /// `~/.cache/huggingface/hub/models--<owner>--<repo>` layout).
  static func modelCacheURL(for modelId: String) -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let slug = modelId.replacingOccurrences(of: "/", with: "--")
    return home
      .appendingPathComponent(".cache/huggingface/hub/models--\(slug)")
  }

  /// `@AppStorage("activeLocalModelID")` key. Defined here so all readers
  /// agree on the spelling — the SwiftUI `@AppStorage` wrapper in views
  /// uses the literal directly.
  static let activeModelDefaultsKey = "activeLocalModelID"

  /// The id the user has selected, falling back to `defaultModelID`. Reads
  /// straight from `UserDefaults` so non-view code (e.g. the installer) can
  /// pick it up without owning a SwiftUI binding.
  static var activeModelID: String {
    UserDefaults.standard.string(forKey: activeModelDefaultsKey) ?? defaultModelID
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

  // MARK: - Per-model install state

  /// True if the Hugging Face cache for `modelId` exists locally. We check
  /// for the directory's existence — same shallow check `modelPresent` uses
  /// for the default model. Doesn't validate that the snapshot is complete
  /// or unbroken; HF's `snapshot_download` does that lazily on launch.
  func isModelInstalled(modelId: String) -> Bool {
    FileManager.default.fileExists(
      atPath: Self.modelCacheURL(for: modelId).path)
  }

  // MARK: - Plist regeneration for active model

  /// Rewrites the launchd plist at `installedPlistURL` so its `--model`
  /// argument matches `Self.activeModelID`. Mirrors what
  /// `scripts/setup-mlx-server.sh` does on first install — substituting
  /// `__USER_HOME__`, `__UV_BIN__`, `__MODEL__`, `__HOST__`, `__PORT__` —
  /// but driven entirely from Swift so we don't have to re-run the shell
  /// installer just to switch models.
  ///
  /// Caller is responsible for `launchctl unload` + `launchctl load` (and
  /// for stopping the server first if it's running).
  ///
  /// Returns `true` on success. On failure sets `lastError` and returns
  /// `false`. No-op (returns false) if the agent isn't installed yet.
  @discardableResult
  func regeneratePlistForActiveModel() -> Bool {
    guard agentInstalled else {
      lastError = "launchd agent not installed — install the local model first."
      return false
    }

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    guard let uvBin = Self.locateUVBinary() else {
      lastError =
        "Could not find `uv` on PATH. Re-run the local model installer."
      return false
    }

    let model = Self.activeModelID
    let host = "127.0.0.1"
    let port = "8080"

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

  /// Probe likely locations for `uv`. Mirrors the order
  /// `scripts/setup-mlx-server.sh` uses (`command -v uv`, then the homebrew
  /// + ~/.local/bin fallbacks via PATH manipulation). We don't shell out
  /// here because Swift can stat the candidates directly.
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

    // Last-ditch: ask the shell. This runs `which`, not `uv`, so it's safe.
    let result = runShell("/usr/bin/which", arguments: ["uv"])
    if result.exitCode == 0,
       let out = result.stdout?.trimmingCharacters(in: .whitespacesAndNewlines),
       !out.isEmpty
    {
      return out
    }
    return nil
  }

  /// Inline copy of `scripts/com.infiniterecall.mlx.plist`. Kept in-source
  /// so we can rewrite the plist without depending on the bundled-script
  /// extraction having run. Must stay byte-identical to the template stored
  /// in `BundledScripts.mlxLaunchdPlist` (sync contract — see that file).
  private static let plistTemplate: String = ##"""
<?xml version="1.0" encoding="UTF-8"?>
<!--
  Infinite Recall — launchd agent template for mlx-lm.server.
  Placeholders are replaced by scripts/setup-mlx-server.sh:
    __USER_HOME__  -> $HOME
    __UV_BIN__     -> absolute path to `uv`
    __MODEL__      -> Hugging Face model id
    __HOST__       -> bind host (default 127.0.0.1)
    __PORT__       -> bind port (default 8080)
-->
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.infiniterecall.mlx</string>

  <key>ProgramArguments</key>
  <array>
    <string>__UV_BIN__</string>
    <string>tool</string>
    <string>run</string>
    <string>--from</string>
    <string>mlx-lm</string>
    <string>mlx_lm.server</string>
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
  <string>__USER_HOME__/Library/Logs/InfiniteRecall/mlx.out.log</string>

  <key>StandardErrorPath</key>
  <string>__USER_HOME__/Library/Logs/InfiniteRecall/mlx.err.log</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>__USER_HOME__/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
</dict>
</plist>
"""##

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
