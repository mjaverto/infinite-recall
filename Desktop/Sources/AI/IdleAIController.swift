// Infinite Recall fork: idle-unload for the local mlx-lm.server.
//
// IdleAIController watches both system input idle (via Quartz CGEventSource)
// and time-since-last-AI-call. When both exceed `idleTimeoutMinutes` AND the
// user has the feature enabled, the local LLM server is asked to stop. The
// server is auto-restarted on the next user-initiated AI call (chat / complete)
// via `recordAICall()`, which is invoked by `LocalLLMClient` before each HTTP
// issue.
//
// The mlx-lm.server holds ~20 GB resident; on a 36 GB machine that's worth
// reclaiming when the user steps away. Cold-start cost is ~30s, which the user
// has explicitly accepted.

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

  /// Master toggle. When false, idle-unload is fully disabled.
  @AppStorage("idle_ai_enabled") var isEnabled: Bool = true

  /// Minutes of combined system-idle + AI-idle before the server is stopped.
  /// Allowed values in the picker: 5, 10, 15, 30, 60.
  @AppStorage("idle_ai_timeout_minutes") var idleTimeoutMinutes: Int = 10

  // MARK: - Published runtime state

  /// Wall-clock of the last user input (mouse/keyboard). Refreshed on every tick.
  @Published private(set) var lastUserActivity: Date = Date()

  /// Wall-clock of the last user-initiated AI call (chat / complete).
  @Published private(set) var lastAICall: Date = Date()

  /// True iff we (this controller) stopped the server because of idle.
  /// Used to decide whether to auto-start it on the next AI call, and to
  /// drive the Settings UI status line.
  @Published private(set) var serverStoppedByIdle: Bool = false

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

    let serverRunning = MLXLifecycleManager.shared.serverRunning
    guard serverRunning else { return }

    if sysIdle >= threshold && aiIdle >= threshold {
      log(
        "IdleAIController: idle thresholds met (sys=\(Int(sysIdle))s, ai=\(Int(aiIdle))s, threshold=\(Int(threshold))s) — stopping local LLM server"
      )
      isTransitioning = true
      let ok = await MLXLifecycleManager.shared.stopServer()
      // Force a refresh so `serverRunning` flips to false promptly for UI.
      await MLXLifecycleManager.shared.refresh()
      isTransitioning = false
      if ok {
        serverStoppedByIdle = true
        log("IdleAIController: local LLM server stopped (idle).")
      } else {
        log("IdleAIController: stopServer() returned false — leaving state alone.")
      }
    }
  }

  // MARK: - Public hooks

  /// Called by `LocalLLMClient` at the start of every public method that
  /// issues an HTTP call. Bumps `lastAICall` and, if we previously stopped
  /// the server due to idle, awaits a restart before returning so the caller
  /// can issue the HTTP request against a live server.
  ///
  /// Re-entrancy: the polling inside `ensureServerRunning()` calls
  /// `LocalLLMClient.isReachable()` directly, which is intentionally NOT
  /// instrumented to call back into `recordAICall()` — otherwise we'd loop.
  func recordAICall() async {
    lastAICall = Date()
    if serverStoppedByIdle && !ensuringServer {
      await ensureServerRunning()
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

  /// Human-readable status line for the Settings → AI / Models → Power Saving card.
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
