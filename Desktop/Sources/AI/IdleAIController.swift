// Infinite Recall fork: idle-unload for both local AI sidecars and the
// on-device pyannote diarizer.
//
// IdleAIController watches both system input idle (via Quartz CGEventSource)
// and time-since-last-AI-call. When both exceed `idleTimeoutMinutes` AND the
// user has the feature enabled, both the text LLM (mlx-lm.server) and the
// vision LLM (mlx-vlm.server) are asked to stop. Servers are auto-restarted
// on the next user-initiated AI call (chat / complete / describe) via
// `recordAICall()`, which is invoked by `LocalLLMClient` and `VisionLLMClient`
// callers before each HTTP issue.
//
// The mlx-lm.server holds ~7-9 GB resident; mlx-vlm.server holds ~6-8 GB.
// The pyannote CoreML diarizer holds ~80-120 MB.
// On a 36 GB machine reclaiming all of them when the user steps away is worth
// the cold-start cost the user has explicitly accepted.
//
// INVARIANT: `VisionLLMClient.isReachable()` must NEVER call `recordAICall()`.
// It is used as the polling probe inside `VLMLifecycleManager.ensureServerRunning()`
// and would pin the VLM server alive indefinitely if instrumented. Same lesson
// as Sprint BB for the text tier (`LocalLLMClient.isReachable()`).
//
// INVARIANT: No polling probe (e.g. reachability checks) should ever call
// `recordAICall()`. Doing so pins the respective server alive indefinitely,
// defeating idle eviction.

import AppKit
import Combine
import CoreGraphics
import Foundation
import SwiftUI

@MainActor
final class IdleAIController: ObservableObject {

  // MARK: - Singleton

  static let shared = IdleAIController()

  // MARK: - User-configurable state (persisted via @AppStorage in Settings)

  /// Memory Saver toggle. When false, idle-unload is fully disabled so
  /// Autonomous Work Mode can keep local AI available while the Mac is idle.
  @AppStorage("idle_ai_enabled") var isEnabled: Bool = false

  /// Minutes of combined system-idle + AI-idle before the server is stopped.
  /// Allowed values in the picker: 5, 10, 15, 30, 60.
  @AppStorage("idle_ai_timeout_minutes") var idleTimeoutMinutes: Int = 10

  // MARK: - Published runtime state

  /// Wall-clock of the last user input (mouse/keyboard). Refreshed on every tick.
  @Published private(set) var lastUserActivity: Date = Date()

  /// Wall-clock of the last user-initiated AI call (chat / complete).
  @Published private(set) var lastAICall: Date = Date()

  /// True iff we (this controller) stopped the text LLM server because of idle.
  /// Used to decide whether to auto-start it on the next AI call, and to
  /// drive the Settings UI status line.
  @Published private(set) var serverStoppedByIdle: Bool = false

  /// True iff we (this controller) stopped the vision LLM server because of idle.
  /// Mirrors `serverStoppedByIdle` for the VLM tier.
  @Published private(set) var vlmStoppedByIdle: Bool = false

  /// True iff we unloaded the pyannote diarizer because of idle (no audio for
  /// 60 s). PyannoteLifecycleManager.loadIfNeeded() reloads on next appendAudio.
  @Published private(set) var pyannoteUnloadedByIdle: Bool = false

  /// Briefly true while we're issuing a restart/stop, for UI status.
  @Published private(set) var isTransitioning: Bool = false

  // MARK: - Internals

  private var tickTask: Task<Void, Never>?

  /// Re-entrancy guard: prevents `ensureServerRunning()` from being called
  /// recursively if a restart-flow itself somehow re-enters `recordAICall()`.
  private var ensuringServer: Bool = false

  /// Tick interval for the idle-check loop. 30s — fine resolution for a
  /// timeout measured in minutes.
  private let tickIntervalSeconds: UInt64 = 30

  /// Max wall-clock to wait for `serverRunning == true` after issuing a start.
  /// User accepted ~30s cold-start; cap at 60s to avoid hanging the UI.
  private let restartPollTimeoutSeconds: TimeInterval = 60
  private let restartPollIntervalSeconds: UInt64 = 1

  private init() {}

  // MARK: - Lifecycle

  /// Start the periodic idle-check loop. Idempotent.
  func start() {
    tickTask?.cancel()
    tickTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.tick()
        try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
      }
    }
    log("IdleAIController: started (enabled=\(isEnabled), timeout=\(idleTimeoutMinutes)m)")
  }

  /// Cancel the tick loop. Safe to call multiple times.
  func stop() {
    tickTask?.cancel()
    tickTask = nil
    log("IdleAIController: stopped")
  }

  // MARK: - System idle (CGEventSource)

  /// Seconds since the last user input event observed by Quartz across the
  /// combined session (covers keyboard, mouse, trackpad, scroll). Returns 0
  /// if the API call fails for any reason — fail-safe so we don't unload
  /// during weird Quartz hiccups.
  ///
  /// API: `CGEventSource.secondsSinceLastEventType(_:eventType:)` is the
  /// Swift-flavored binding for `CGEventSourceSecondsSinceLastEventType`.
  /// `.combinedSessionState` includes events from all session sources;
  /// `.any` matches all event kinds (the `kCGAnyInputEventType` value).
  func systemIdleSeconds() -> TimeInterval {
    let raw = CGEventSource.secondsSinceLastEventType(
      .combinedSessionState,
      eventType: CGEventType(rawValue: ~0) ?? .null  // kCGAnyInputEventType == ~0
    )
    return raw.isFinite && raw >= 0 ? raw : 0
  }

  // MARK: - Tick

  private func tick() async {
    guard isEnabled else { return }

    let sysIdle = systemIdleSeconds()
    let aiIdle = Date().timeIntervalSince(lastAICall)
    let threshold = TimeInterval(idleTimeoutMinutes * 60)

    // Refresh published activity timestamp from the system idle reading.
    lastUserActivity = Date().addingTimeInterval(-sysIdle)

    guard sysIdle >= threshold && aiIdle >= threshold else { return }

    // ── Text tier ────────────────────────────────────────────────────────────
    if MLXLifecycleManager.shared.serverRunning {
      log(
        "IdleAIController: idle thresholds met (sys=\(Int(sysIdle))s, ai=\(Int(aiIdle))s, threshold=\(Int(threshold))s) — stopping local LLM server"
      )
      isTransitioning = true
      let ok = await MLXLifecycleManager.shared.stopServer()
      await MLXLifecycleManager.shared.refresh()
      isTransitioning = false
      if ok {
        serverStoppedByIdle = true
        log("IdleAIController: local LLM server stopped (idle).")
      } else {
        log("IdleAIController: stopServer() (text) returned false — leaving state alone.")
      }
    }

    // ── Vision tier ──────────────────────────────────────────────────────────
    if VLMLifecycleManager.shared.serverRunning {
      log(
        "IdleAIController: idle thresholds met — stopping vision LLM server"
      )
      isTransitioning = true
      let okVLM = await VLMLifecycleManager.shared.stopServer()
      await VLMLifecycleManager.shared.refresh()
      isTransitioning = false
      if okVLM {
        vlmStoppedByIdle = true
        log("IdleAIController: vision LLM server stopped (idle).")
      } else {
        log("IdleAIController: stopServer() (vision) returned false — leaving state alone.")
      }
    }

    // ── Pyannote diarizer tier ────────────────────────────────────────────────
    // Trigger: 60 s no audio (system idle threshold covers this). Unload the
    // CoreML models (~80-120 MB) so memory is reclaimed while idle. The next
    // SpeakerDiarizationService.start() call will trigger a reload via
    // PyannoteLifecycleManager.loadIfNeeded().
    if #available(macOS 13, *) {
      if PyannoteLifecycleManager.shared.speakerKit != nil {
        log("IdleAIController: idle thresholds met — unloading pyannote diarizer")
        await PyannoteLifecycleManager.shared.unload()
        pyannoteUnloadedByIdle = true
        log("IdleAIController: pyannote diarizer unloaded (idle).")
      }
    }
  }

  // MARK: - Public hooks

  /// Called by `LocalLLMClient` (and VisionLLMClient callers) at the start of
  /// every public method that issues an HTTP call. Bumps `lastAICall` and, if
  /// we previously stopped either server due to idle, awaits a restart before
  /// returning so the caller can issue the HTTP request against a live server.
  ///
  /// Re-entrancy: the polling inside `ensureServerRunning()` calls
  /// `LocalLLMClient.isReachable()` directly, which is intentionally NOT
  /// instrumented to call back into `recordAICall()` — otherwise we'd loop.
  ///
  /// INVARIANT: `VisionLLMClient.isReachable()` must NEVER be wired to call
  /// `recordAICall()`. It is the polling probe inside
  /// `VLMLifecycleManager.ensureServerRunning()` and calling back here would
  /// pin the vision server alive indefinitely, defeating idle eviction.
  func recordAICall() async {
    lastAICall = Date()
    if serverStoppedByIdle && !ensuringServer {
      await ensureServerRunning()
    }
    // Mirror for the vision tier — restart if we were the ones who stopped it.
    if vlmStoppedByIdle {
      await VLMLifecycleManager.shared.ensureServerRunning()
      vlmStoppedByIdle = false
    }
  }

  /// If the server isn't running and we previously stopped it due to idle,
  /// ask launchd to start it and poll until reachable (or timeout). Logs
  /// progress so the user can see it in `omi-dev.log` and in the AI / Models
  /// settings card status line.
  func ensureServerRunning() async {
    guard !ensuringServer else { return }
    ensuringServer = true
    defer { ensuringServer = false }

    // Refresh first — maybe something else (the user, launchd KeepAlive)
    // already brought it back.
    await MLXLifecycleManager.shared.refresh()
    if MLXLifecycleManager.shared.serverRunning {
      serverStoppedByIdle = false
      return
    }

    guard serverStoppedByIdle else { return }

    log("IdleAIController: AI call after idle-unload — restarting local LLM server")
    isTransitioning = true
    defer { isTransitioning = false }

    let started = await MLXLifecycleManager.shared.startServer()
    if !started {
      log("IdleAIController: startServer() returned false — server may not be installed")
      return
    }

    // Poll for readiness. Cold start of mlx-lm.server is typically 15–30s on
    // M3 Max for the 4-bit Qwen 32B; budget 60s.
    let deadline = Date().addingTimeInterval(restartPollTimeoutSeconds)
    var attempts = 0
    while Date() < deadline {
      attempts += 1
      // Use the actor-level isReachable directly so we don't recurse.
      let reachable = await LocalLLMClient.shared.isReachable()
      if reachable {
        await MLXLifecycleManager.shared.refresh()
        serverStoppedByIdle = false
        log("IdleAIController: local LLM server is back up after \(attempts) probe(s).")
        return
      }
      try? await Task.sleep(nanoseconds: restartPollIntervalSeconds * 1_000_000_000)
    }

    log(
      "IdleAIController: server did not become reachable within \(Int(restartPollTimeoutSeconds))s — proceeding; the upcoming HTTP call will surface the error."
    )
  }

  // MARK: - UI helpers

  /// Human-readable status line for the Settings → AI / Models → Autonomous Work Mode card.
  var statusText: String {
    if isTransitioning {
      return serverStoppedByIdle ? "Restarting…" : "Stopping…"
    }
    if serverStoppedByIdle {
      let mins = Int(Date().timeIntervalSince(lastUserActivity) / 60)
      return "Stopped due to idle (\(mins)m). Will restart on next AI request."
    }
    if MLXLifecycleManager.shared.serverRunning {
      return "Running."
    }
    return "Stopped."
  }
}
