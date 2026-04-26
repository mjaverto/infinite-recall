// Infinite Recall fork: in-app installer for the local MLX server and Rust
// API daemon. Replaces the prior UX where Settings → "Install local model"
// shelled out to Terminal.app.
//
// Lifecycle:
//   1. SettingsPage triggers `LocalAIInstaller.shared.startMLXInstall()`.
//   2. We extract `setup-mlx-server.sh` (and its plist) from `BundledScripts`
//      to `~/Library/Application Support/InfiniteRecall/scripts/` with mode
//      0755.
//   3. We spawn `bash <scriptPath>` via `Process` with
//      `INFINITE_RECALL_AUTO_CONFIRM=1` set so the script never prompts.
//   4. stdout + stderr are piped through a single `Pipe` whose
//      `readabilityHandler` parses lines:
//        - `PROGRESS:STEP=...`           → updates `currentStep`
//        - `PROGRESS:DOWNLOAD_PCT=N`     → updates `modelDownloadProgress`
//        - `PROGRESS:DOWNLOAD_BYTES=N`   → updates `modelDownloadedBytes`
//        - any other line                → appended to `logLines`
//   5. On exit:
//        - status 0 → `currentStep = .done`, refresh MLXLifecycleManager
//        - non-zero / cancelled → `currentStep = .failed` + `error`
//
// All `@Published` mutations are funnelled to MainActor.

import Foundation
import SwiftUI

@MainActor
final class LocalAIInstaller: ObservableObject {

  // MARK: - Singleton

  static let shared = LocalAIInstaller()

  // MARK: - Step model

  enum Step: String, CaseIterable, Identifiable {
    case checkingPrereqs = "Checking prerequisites"
    case installingUV = "Installing uv"
    case installingMLX = "Installing mlx-lm"
    case downloadingModel = "Downloading model"
    case installingLaunchAgent = "Registering background service"
    case startingService = "Starting AI server"
    case done = "Ready"
    case failed = "Failed"

    var id: String { rawValue }

    /// Steps shown in the UI list, in order. `.done` and `.failed` are
    /// terminal states, not list rows.
    static var displayed: [Step] {
      [
        .checkingPrereqs,
        .installingUV,
        .installingMLX,
        .downloadingModel,
        .installingLaunchAgent,
        .startingService,
      ]
    }

    /// Maps the raw `STEP=` token from the script to a Step case.
    static func fromScriptToken(_ token: String) -> Step? {
      switch token {
      case "checking_prereqs": return .checkingPrereqs
      case "installing_uv": return .installingUV
      case "installing_mlx": return .installingMLX
      case "downloading_model": return .downloadingModel
      case "installing_launchd": return .installingLaunchAgent
      case "starting_service": return .startingService
      case "done": return .done
      default: return nil
      }
    }
  }

  // MARK: - Published state

  @Published var currentStep: Step = .checkingPrereqs
  @Published var completedSteps: Set<Step> = []
  /// Tail of recent log lines (max ~200), in order.
  @Published var logLines: [String] = []
  @Published var modelDownloadProgress: Double? = nil
  @Published var modelDownloadedBytes: Int64? = nil
  /// Estimated total download size in bytes, sourced from the catalog entry
  /// being installed. Set at install start; defaults to 0 until then.
  @Published var modelTotalBytes: Int64 = 0
  @Published var isRunning: Bool = false
  @Published var error: String? = nil
  /// Set when the user clicks Cancel so terminal-state UI can distinguish a
  /// deliberate cancel (non-zero exit from SIGTERM) from a real crash.
  @Published private(set) var wasCancelled: Bool = false

  // MARK: - Internal

  private var process: Process?
  private var stdoutPipe: Pipe?
  private var stderrPipe: Pipe?
  /// Carries-over partial line buffer when reads split mid-line.
  private var lineBuffer: String = ""
  private static let maxLogLines = 200

  private init() {}

  // MARK: - Public API

  func startMLXInstall() async {
    await start(
      extractor: { try BundledScripts.extractMLXScripts() },
      kind: .mlx,
      modelId: nil)
  }

  /// Variant that installs a specific catalog model (rather than the default
  /// hardcoded in the shell script). The script honors the
  /// `INFINITE_RECALL_MLX_MODEL` env var both for the cache-presence check
  /// and the embedded Python download, and writes the launchd plist with
  /// the matching `--model` argument.
  func startMLXInstall(modelId: String) async {
    await start(
      extractor: { try BundledScripts.extractMLXScripts() },
      kind: .mlx,
      modelId: modelId)
  }

  func startAPIInstall() async {
    await start(
      extractor: { try BundledScripts.extractAPIScripts() },
      kind: .api,
      modelId: nil)
  }

  /// Vision-tier (mlx-vlm) installer. Same flow as the MLX path but extracts
  /// the VLM scripts and reports state into `VLMLifecycleManager` instead of
  /// the text-tier lifecycle. Pass an explicit `modelId` to override the
  /// shell script's hardcoded default; nil means "use the script default".
  func startVLMInstall(modelId: String? = nil) async {
    await start(
      extractor: { try BundledScripts.extractVLMScripts() },
      kind: .vlm,
      modelId: modelId)
  }

  /// Clear a terminal `.failed` state so inline UI (e.g. `LocalAIInstallStrip`)
  /// can be dismissed by the user without retrying. Safe to call from the
  /// main actor; no-op while an install is still in flight.
  @MainActor
  func dismissResult() {
    guard !isRunning else { return }
    // Clear only the tier whose terminal state is being dismissed — the other
    // tier's pending id may still be meaningful (e.g. a recent successful
    // install that the user hasn't acknowledged yet).
    switch pendingKind {
    case .mlx: pendingMLXModelId = nil
    case .vlm: pendingVLMModelId = nil
    case .api: break
    }
    resetState()
    modelTotalBytes = 0
  }

  /// Terminate the running install. Sends SIGTERM, then SIGKILL after 2s if
  /// the process is still alive.
  func cancel() {
    guard let p = process, p.isRunning else { return }
    Task { @MainActor in self.wasCancelled = true }
    p.terminate()
    let proc = p
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
      if proc.isRunning {
        // SIGKILL via interrupt isn't quite right; use kill(2).
        kill(proc.processIdentifier, SIGKILL)
      }
    }
  }

  // MARK: - Implementation

  /// Which sidecar a given install run targets. Published via `pendingKind`
  /// so inline UI (e.g. `LocalAIInstallStrip`) can scope itself to the right
  /// settings card without inspecting model-id state.
  enum Kind { case mlx, api, vlm }

  /// Catalog model id to install when `kind == .mlx`. nil means "use the
  /// shell script's hardcoded default" (preserves the original single-model
  /// install path). Published so UI (e.g. `LocalAIInstallSheet`) can render
  /// the actual id being installed instead of falling back to the catalog
  /// recommendation when the install was kicked off without an explicit id.
  @Published private(set) var pendingMLXModelId: String? = nil

  /// Catalog model id to install when `kind == .vlm`. Mirrors `pendingMLXModelId`
  /// but for the vision tier. nil means use the VLM script's default.
  @Published private(set) var pendingVLMModelId: String? = nil

  /// Tracks which kind we're currently running so refresh + env-setup can branch
  /// without inspecting the extractor closure. Published so per-tier UI strips
  /// only render for the install they're scoped to.
  @Published private(set) var pendingKind: Kind = .mlx

  private func start(
    extractor: () throws -> URL,
    kind: Kind,
    modelId: String?
  ) async {
    guard !isRunning else { return }
    resetState()
    isRunning = true
    pendingKind = kind
    pendingMLXModelId = (kind == .mlx) ? modelId : nil
    pendingVLMModelId = (kind == .vlm) ? modelId : nil

    // Seed modelTotalBytes from the catalog so the progress label never shows
    // a stale hardcoded number. For custom (user-supplied) HF ids the catalog
    // returns nil — leave modelTotalBytes at 0 so the UI runs an indeterminate
    // progress bar rather than a misleading total. For the default install
    // (no modelId), fall back to the catalog's recommended entry.
    switch kind {
    case .mlx:
      if let id = modelId {
        if let entry = LocalModelCatalog.option(forId: id) {
          modelTotalBytes = Int64(entry.approxDiskGB * 1_000_000_000)
        } else {
          // Custom id — unknown size; leave indeterminate.
          modelTotalBytes = 0
        }
      } else {
        modelTotalBytes = Int64(LocalModelCatalog.recommended.approxDiskGB * 1_000_000_000)
      }
    case .vlm:
      if let id = modelId {
        if let entry = VisionModelCatalog.option(forId: id) {
          modelTotalBytes = Int64(entry.approxDiskGB * 1_000_000_000)
        } else {
          // Custom id — unknown size; leave indeterminate.
          modelTotalBytes = 0
        }
      } else {
        modelTotalBytes = Int64(VisionModelCatalog.recommended.approxDiskGB * 1_000_000_000)
      }
    case .api:
      modelTotalBytes = 0
    }

    let scriptURL: URL
    do {
      scriptURL = try extractor()
    } catch {
      self.error = "Failed to extract installer script: \(error.localizedDescription)"
      self.currentStep = .failed
      self.isRunning = false
      return
    }

    // Pre-skip steps that are already done so the UI reflects reality. For
    // a per-model install we look at THAT model's cache, not the default.
    if kind == .mlx {
      let lifecycle = MLXLifecycleManager.shared
      let modelInstalled: Bool = {
        if let id = modelId {
          return lifecycle.isModelInstalled(modelId: id)
        }
        return lifecycle.modelPresent
      }()
      if modelInstalled {
        completedSteps.insert(.downloadingModel)
      }
      if lifecycle.agentInstalled {
        completedSteps.insert(.installingLaunchAgent)
      }
    } else if kind == .vlm {
      let lifecycle = VLMLifecycleManager.shared
      let modelInstalled: Bool = {
        if let id = modelId {
          return lifecycle.isModelInstalled(modelId: id)
        }
        return lifecycle.modelPresent
      }()
      if modelInstalled {
        completedSteps.insert(.downloadingModel)
      }
      if lifecycle.agentInstalled {
        completedSteps.insert(.installingLaunchAgent)
      }
    }

    await runProcess(scriptURL: scriptURL, kind: kind)
  }

  private func resetState() {
    currentStep = .checkingPrereqs
    completedSteps = []
    logLines = []
    modelDownloadProgress = nil
    modelDownloadedBytes = nil
    error = nil
    lineBuffer = ""
    wasCancelled = false
  }

  private func runProcess(scriptURL: URL, kind: Kind) async {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [scriptURL.path]

    var env = ProcessInfo.processInfo.environment
    env["INFINITE_RECALL_AUTO_CONFIRM"] = "1"
    // Ensure /opt/homebrew/bin and ~/.local/bin (uv) are on PATH for spawned bash.
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let extraPath = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin"
    env["PATH"] = (env["PATH"].map { "\(extraPath):\($0)" }) ?? extraPath
    // If the caller picked a non-default catalog model, hand it to the
    // script via env. The script honors INFINITE_RECALL_MLX_MODEL for both
    // the cache-presence check and the Python snapshot_download call, and
    // bakes the value into the launchd plist's `--model` argument.
    if let modelId = pendingMLXModelId, kind == .mlx {
      env["INFINITE_RECALL_MLX_MODEL"] = modelId
    }
    // Vision-tier override. The VLM shell script reads
    // INFINITE_RECALL_VLM_MODEL for both the cache-presence check and the
    // Python snapshot_download call, and bakes the value into the launchd
    // plist's `--model` argument.
    if let modelId = pendingVLMModelId, kind == .vlm {
      env["INFINITE_RECALL_VLM_MODEL"] = modelId
    }
    p.environment = env

    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe

    self.process = p
    self.stdoutPipe = outPipe
    self.stderrPipe = errPipe

    // Stream both stdout and stderr through the same parser. We dispatch back
    // onto the main actor for every chunk because @Published mutations require
    // it.
    let onChunk: @Sendable (FileHandle) -> Void = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
      Task { @MainActor [weak self] in
        self?.ingest(chunk: text)
      }
    }
    outPipe.fileHandleForReading.readabilityHandler = onChunk
    errPipe.fileHandleForReading.readabilityHandler = onChunk

    do {
      try p.run()
    } catch {
      self.error = "Failed to launch installer: \(error.localizedDescription)"
      self.currentStep = .failed
      self.isRunning = false
      cleanupPipes()
      return
    }

    // Wait for completion off the main actor so we don't block the UI.
    let exitCode: Int32 = await withCheckedContinuation { cont in
      DispatchQueue.global().async {
        p.waitUntilExit()
        cont.resume(returning: p.terminationStatus)
      }
    }

    // Final flush — drain any straggler bytes.
    if let remaining = try? outPipe.fileHandleForReading.readToEnd(),
       let text = String(data: remaining, encoding: .utf8), !text.isEmpty {
      ingest(chunk: text)
    }
    if let remaining = try? errPipe.fileHandleForReading.readToEnd(),
       let text = String(data: remaining, encoding: .utf8), !text.isEmpty {
      ingest(chunk: text)
    }

    cleanupPipes()
    self.process = nil

    if exitCode == 0 {
      // Mark every displayed step complete (the script may have skipped some
      // because they were already done, but as far as the user is concerned
      // we're finished).
      for step in Step.displayed {
        completedSteps.insert(step)
      }
      currentStep = .done
      // Refresh lifecycle so the AI/Models panel flips to green without a
      // manual reload.
      lifecycleRefresh()
    } else {
      currentStep = .failed
      if error == nil || error?.isEmpty == true {
        let tail = logLines.suffix(5).joined(separator: "\n")
        error =
          "Installer exited with status \(exitCode).\(tail.isEmpty ? "" : "\n" + tail)"
      }
    }
    isRunning = false
  }

  private func cleanupPipes() {
    stdoutPipe?.fileHandleForReading.readabilityHandler = nil
    stderrPipe?.fileHandleForReading.readabilityHandler = nil
    stdoutPipe = nil
    stderrPipe = nil
  }

  private func lifecycleRefresh() {
    switch pendingKind {
    case .vlm:
      Task { await VLMLifecycleManager.shared.refresh() }
      VLMLifecycleManager.shared.refreshSync()
    case .mlx, .api:
      Task { await MLXLifecycleManager.shared.refresh() }
      MLXLifecycleManager.shared.refreshSync()
    }
  }

  // MARK: - Stream parsing

  private func ingest(chunk: String) {
    lineBuffer.append(chunk)
    while let nlIndex = lineBuffer.firstIndex(of: "\n") {
      let line = String(lineBuffer[..<nlIndex])
      lineBuffer.removeSubrange(...nlIndex)
      handleLine(line)
    }
  }

  private func handleLine(_ raw: String) {
    let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !line.isEmpty else { return }

    if let payload = line.range(of: "PROGRESS:")?.upperBound, line.hasPrefix("PROGRESS:") {
      parseProgress(String(line[payload...]))
      // Don't surface PROGRESS lines in the log — they're noise for humans.
      return
    }

    appendLog(line)
  }

  private func parseProgress(_ payload: String) {
    // Payload examples:
    //   "STEP=installing_uv"
    //   "DOWNLOAD_PCT=42"
    //   "DOWNLOAD_BYTES=1234567"
    let parts = payload.split(separator: "=", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return }
    let key = parts[0]
    let value = parts[1]

    switch key {
    case "STEP":
      if let step = Step.fromScriptToken(value) {
        // Mark all steps before this one complete.
        if step == .done {
          for s in Step.displayed { completedSteps.insert(s) }
          // currentStep set to .done at process-exit, not here, so we keep the
          // last in-progress row visible if the script over-emits.
        } else {
          // Mark prior displayed steps complete.
          if let idx = Step.displayed.firstIndex(of: step) {
            for s in Step.displayed.prefix(idx) {
              completedSteps.insert(s)
            }
          }
          currentStep = step
        }
      }

    case "DOWNLOAD_PCT":
      if let n = Double(value) {
        modelDownloadProgress = max(0, min(1, n / 100.0))
      }

    case "DOWNLOAD_BYTES":
      if let n = Int64(value) {
        modelDownloadedBytes = n
      }

    case "DOWNLOAD_FAIL":
      // Embedded Python in the install scripts emits this sentinel when
      // huggingface_hub.snapshot_download raises (bad id, gated repo, HTTP
      // error, etc.). Capture the reason verbatim, mark the install failed,
      // and let the process-exit branch surface our error rather than the
      // generic "exited with status N" fallback.
      let reason = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if !reason.isEmpty {
        error = "Download failed: \(reason)"
      } else {
        error = "Download failed."
      }
      currentStep = .failed

    default:
      break
    }
  }

  private func appendLog(_ line: String) {
    logLines.append(line)
    if logLines.count > Self.maxLogLines {
      logLines.removeFirst(logLines.count - Self.maxLogLines)
    }
  }

  // MARK: - Helpers exposed for the UI

  /// Format a byte count for display (e.g. "12.3 GB").
  static func formattedBytes(_ bytes: Int64?) -> String {
    guard let bytes = bytes else { return "—" }
    let fmt = ByteCountFormatter()
    fmt.countStyle = .binary
    fmt.allowedUnits = [.useGB, .useMB]
    return fmt.string(fromByteCount: bytes)
  }
}
