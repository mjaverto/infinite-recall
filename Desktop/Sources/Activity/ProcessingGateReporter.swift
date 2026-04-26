// Activity Tab — Issue #32.
//
// Swift-side observer of the OS signals that decide whether deferred work
// (transcribe / OCR / summarize / extract) should drain. Computes a
// `GateState` every ~3s and POSTs it to the Rust daemon's
// `_internal/gate-state` loopback when (and only when) the value changes.
//
// Why Swift owns this and not Rust:
//   - `IdleAIController.systemIdleSeconds()` already wraps
//     `CGEventSource.secondsSinceLastEvent` for the AI-unload watchdog.
//   - `BatteryAwareScheduler` already subscribes to `.screenDidLock` /
//     `.screenDidUnlock`, `PowerStateMonitor`, and `.thermalState`.
//   - Re-implementing those in Rust would require IOKit / AppKit FFI for
//     no benefit — the Rust daemon is process-local and the bridge is a
//     127.0.0.1 POST.
//
// Priority order (highest first): locked > thermal > on-battery >
// device-active > allowed. The first matching condition wins.

import Foundation

/// Pure-function inputs to the gate-state decision. Extracted from
/// `BatteryAwareScheduler` / `IdleAIController` / `ProcessInfo` so the
/// computation is unit-testable without bringing up the whole stack.
public struct ProcessingGateInputs: Equatable {
  /// `true` when the screen is locked (NSDistributedNotification
  /// `.screenDidLock` since last `.screenDidUnlock`).
  public var isScreenLocked: Bool
  /// Wall-time since the user crossed the lock boundary. `nil` when not
  /// locked.
  public var lockedSince: Date?

  /// `true` when running on battery.
  public var onBattery: Bool
  /// `true` when low-power-mode is engaged.
  public var isLowPowerMode: Bool
  /// Wall-time the device transitioned into the current power state. Used
  /// as `since` for an `OnBattery` blocked state.
  public var batterySince: Date?

  public var thermalState: ProcessInfo.ThermalState
  /// Wall-time the device entered the current thermal state.
  public var thermalSince: Date?

  /// Seconds the user has been input-idle (CGEvent).
  public var systemIdleSeconds: TimeInterval
  /// Wall-time the user last became active (i.e. `now - systemIdleSeconds`).
  public var activeSince: Date

  /// Idle threshold (seconds) the gate must cross before flipping to
  /// `Allowed`. Matches the existing Memory Saver setting so we don't
  /// introduce a third user-visible knob.
  public var idleThresholdSeconds: TimeInterval

  /// Number of items currently waiting in the deferred queue. The
  /// `OnBattery` block reason is only meaningful when there's something
  /// to do — if the queue is empty, we report `Allowed` even on battery
  /// so the UI doesn't show a misleading "waiting for AC power" banner.
  public var pendingWorkCount: Int

  public init(
    isScreenLocked: Bool,
    lockedSince: Date?,
    onBattery: Bool,
    isLowPowerMode: Bool,
    batterySince: Date?,
    thermalState: ProcessInfo.ThermalState,
    thermalSince: Date?,
    systemIdleSeconds: TimeInterval,
    activeSince: Date,
    idleThresholdSeconds: TimeInterval,
    pendingWorkCount: Int
  ) {
    self.isScreenLocked = isScreenLocked
    self.lockedSince = lockedSince
    self.onBattery = onBattery
    self.isLowPowerMode = isLowPowerMode
    self.batterySince = batterySince
    self.thermalState = thermalState
    self.thermalSince = thermalSince
    self.systemIdleSeconds = systemIdleSeconds
    self.activeSince = activeSince
    self.idleThresholdSeconds = idleThresholdSeconds
    self.pendingWorkCount = pendingWorkCount
  }
}

/// Pure decision: turn `ProcessingGateInputs` into a `GateState`.
///
/// `now` is injected so tests can pin time without touching `Date()`.
///
/// Priority (highest first):
///   1. Locked            → `Blocked(.locked,        WaitCondition.unlock)`
///   2. Thermal serious+  → `Blocked(.thermal,       .thermalCooldown)`
///   3. On battery        → `Blocked(.onBattery,     .acPower)`
///      (only when there's queued work — empty queue + battery = Allowed)
///   4. Idle < threshold  → `Blocked(.deviceActive,  .idleFor(remaining))`
///   5. Else              → `Allowed(since: idleEnteredAt)`
///
/// MUST mirror `BatteryAwareScheduler.allowHeavyWork` exactly — any
/// condition that prevents the scheduler from draining must produce a
/// `Blocked` state here, otherwise the snapshot will lie about
/// `Allowed` while the scheduler quietly refuses to drain. The scheduler
/// blocks on ANY of: source != .ac, isLowPowerMode, thermal >= .serious
/// (modulo userOverride which is intentionally not mirrored — the
/// override is a per-user policy choice, not a hardware fact, so the
/// gate stays honest about the underlying signal).
public func computeGateState(_ inputs: ProcessingGateInputs, now: Date = Date()) -> GateState {
  // 1. Lock wins over everything — even thermal cooldown, since the user
  //    is gone and we should resume the moment they unlock regardless of
  //    what else changed in the interim.
  if inputs.isScreenLocked {
    return .blocked(
      reason: .locked,
      since: inputs.lockedSince ?? now,
      waitingFor: .unlock
    )
  }

  // 2. Thermal pressure. `serious` and `critical` block; `nominal` and
  //    `fair` are fine.
  if inputs.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
    return .blocked(
      reason: .thermal,
      since: inputs.thermalSince ?? now,
      waitingFor: .thermalCooldown
    )
  }

  // 3. Power. `BatteryAwareScheduler.allowHeavyWork` returns false the
  //    moment the source is not AC — LPM is a separate AND-clause but
  //    on-battery alone is already enough to block draining. So the gate
  //    must report `Blocked(.onBattery)` whenever the laptop is on
  //    battery with queued work, regardless of LPM. Otherwise the
  //    snapshot would lie: `Allowed` while the scheduler refuses to drain.
  //    Empty queue = nothing to defer, so report Allowed (no banner spam
  //    when there's nothing waiting).
  if inputs.onBattery && inputs.pendingWorkCount > 0 {
    return .blocked(
      reason: .onBattery,
      since: inputs.batterySince ?? now,
      waitingFor: .acPower
    )
  }

  // 4. Device-active. Below the threshold, we hold off so we don't spin
  //    up Whisper / OCR / LLM while the user is typing. Remaining time is
  //    clamped to ≥ 1s so the UI never shows "waiting for 0 min of idle".
  let idleThreshold = inputs.idleThresholdSeconds
  if inputs.systemIdleSeconds < idleThreshold {
    let remaining = max(1.0, idleThreshold - inputs.systemIdleSeconds)
    return .blocked(
      reason: .deviceActive,
      since: inputs.activeSince,
      waitingFor: .idleFor(seconds: UInt64(remaining.rounded(.up)))
    )
  }

  // 5. Allowed. `since` is the moment the user crossed the idle threshold,
  //    not "now" — that gives the UI a stable timestamp ("idle for 4 min")
  //    instead of one that resets every poll.
  let idleEnteredAt = now.addingTimeInterval(-(inputs.systemIdleSeconds - idleThreshold))
  return .allowed(since: idleEnteredAt)
}

/// Polls OS signals from `BatteryAwareScheduler` + `IdleAIController` and
/// reports the resulting `GateState` to the Rust daemon over the
/// `_internal/gate-state` loopback whenever it changes.
///
/// Sequencing:
///   1. `start()` is called from `OmiApp` after `BatteryAwareScheduler`
///      starts.
///   2. We POST the initial state immediately (so the Rust gate's
///      `Blocked(.initializing)` startup window closes within ~1 RTT).
///   3. We re-evaluate every `pollIntervalSeconds` (default 3s) and POST
///      only when the computed state structurally differs from
///      `lastPostedState`.
///   4. `stop()` cancels the polling task.
@MainActor
public final class ProcessingGateReporter {
  public static let shared = ProcessingGateReporter()

  /// Default poll cadence. 3s is a good balance between "snappy enough
  /// for the user to see the banner update" and "not hammering CGEvent /
  /// the Rust daemon for no reason".
  public static let defaultPollIntervalSeconds: TimeInterval = 3.0

  private var pollTask: Task<Void, Never>?
  private var lastPostedState: GateState?
  private let pollIntervalSeconds: TimeInterval

  /// Track when the user last became active so we can report a stable
  /// `since` for `Blocked(.deviceActive)` instead of one that drifts
  /// every poll. Reset whenever idle drops to ~0.
  private var activeSince: Date = Date()
  private var lastObservedIdleSeconds: TimeInterval = 0

  /// Wall-time the gate inputs last transitioned. Used as `since` for
  /// the Blocked variants whose causal trigger doesn't already have a
  /// timestamp on `BatteryAwareScheduler`.
  private var lockedSince: Date?
  private var batterySince: Date?
  private var thermalSince: Date?
  private var lastIsLocked: Bool = false
  private var lastOnBattery: Bool = false
  private var lastThermalRaw: Int = ProcessInfo.ThermalState.nominal.rawValue

  public init(pollIntervalSeconds: TimeInterval = defaultPollIntervalSeconds) {
    self.pollIntervalSeconds = pollIntervalSeconds
  }

  /// Idempotent — calling `start()` twice is a no-op.
  public func start() {
    guard pollTask == nil else { return }

    // Seed transition timestamps from current state so the first POST
    // doesn't lie about how long we've been in (e.g.) the locked state.
    let now = Date()
    let scheduler = BatteryAwareScheduler.shared
    self.lastIsLocked = scheduler.isScreenLocked
    self.lastOnBattery = scheduler.source == .battery
    self.lastThermalRaw = scheduler.thermalState.rawValue
    self.lockedSince = scheduler.isScreenLocked ? now : nil
    self.batterySince = self.lastOnBattery ? now : nil
    self.thermalSince = self.lastThermalRaw >= ProcessInfo.ThermalState.serious.rawValue ? now : nil
    self.activeSince = now

    pollTask = Task { @MainActor [weak self] in
      // First tick fires immediately so the Rust gate stops reporting
      // `Initializing` as soon as we have credentials + reachability.
      await self?.tick()
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64((self?.pollIntervalSeconds ?? 3.0) * 1_000_000_000))
        guard let self else { return }
        await self.tick()
      }
    }
  }

  public func stop() {
    pollTask?.cancel()
    pollTask = nil
    lastPostedState = nil
  }

  /// Test-friendly forced tick. Public so unit tests can drive the loop
  /// deterministically without sleeping. Production code does not need
  /// to call this.
  public func tickForTesting() async {
    await tick()
  }

  /// Internal tick: recompute → diff → POST.
  private func tick() async {
    let now = Date()
    let inputs = collectInputs(now: now)
    let newState = computeGateState(inputs, now: now)

    if let last = lastPostedState, statesAreEquivalent(last, newState) {
      return
    }

    do {
      try await APIClient.shared.reportGateState(newState)
      lastPostedState = newState
    } catch {
      // Surface to console; the next tick will retry. We deliberately do
      // not back off — the daemon is loopback, transient errors are
      // typically "daemon not yet up" or "token file not yet written",
      // both of which resolve on the next poll. Spamming a stack trace
      // every 3s during boot is fine and was previously the
      // ActivityMonitorService pattern.
      NSLog("[gate-reporter] failed to post gate state: \(error.localizedDescription)")

      // Daemon-restart heuristic: 401 (token rotated), connection refused,
      // or 5xx gateway-style errors all indicate the daemon may have just
      // restarted with a fresh `Blocked(.initializing)` initial state. Clear
      // the local de-dupe cache so the NEXT successful POST re-syncs the
      // daemon to current Swift-side truth — otherwise the daemon could
      // stay stuck on Initializing while Swift believes it already posted the
      // current state.
      if Self.isDaemonRestartIndicator(error) {
        lastPostedState = nil
      }
    }
  }

  /// True when the error looks like the Rust daemon just restarted (token
  /// rotated → 401, socket gone → connection refused, gateway-class 5xx).
  /// Used to invalidate the local `lastPostedState` cache so the next
  /// successful POST re-syncs the daemon.
  private static func isDaemonRestartIndicator(_ error: Error) -> Bool {
    if let api = error as? APIError {
      switch api {
      case .unauthorized:
        return true
      case .httpError(let code) where code == 502 || code == 503 || code == 504:
        return true
      default:
        break
      }
    }
    let nsErr = error as NSError
    if nsErr.domain == NSURLErrorDomain {
      switch nsErr.code {
      case NSURLErrorCannotConnectToHost,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorTimedOut:
        return true
      default:
        break
      }
    }
    return false
  }

  /// Pull the live signal values from `BatteryAwareScheduler` /
  /// `IdleAIController` / `ProcessInfo` and update transition
  /// timestamps. Updates `self.activeSince`, `self.lockedSince`,
  /// `self.batterySince`, `self.thermalSince` as side effects.
  private func collectInputs(now: Date) -> ProcessingGateInputs {
    let scheduler = BatteryAwareScheduler.shared
    let idleController = IdleAIController.shared

    // Lock transition.
    if scheduler.isScreenLocked != lastIsLocked {
      lockedSince = scheduler.isScreenLocked ? now : nil
      lastIsLocked = scheduler.isScreenLocked
    }

    // Battery transition.
    let onBattery = scheduler.source == .battery
    if onBattery != lastOnBattery {
      batterySince = onBattery ? now : nil
      lastOnBattery = onBattery
    }

    // Thermal transition.
    let thermalRaw = scheduler.thermalState.rawValue
    if thermalRaw != lastThermalRaw {
      thermalSince =
        (thermalRaw >= ProcessInfo.ThermalState.serious.rawValue) ? now : nil
      lastThermalRaw = thermalRaw
    }

    // Active-since: we update only on the falling edge (idle dropped back
    // toward 0). On the rising edge we keep the prior `activeSince` so the
    // UI shows a stable "active for X seconds".
    let idleSeconds = idleController.systemIdleSeconds()
    if idleSeconds < lastObservedIdleSeconds - 1.0 || idleSeconds < 1.0 {
      // User input arrived (or first tick): mark this as the new active
      // start. Subtract whatever idle time the OS still reports so the
      // timestamp is consistent with what the next tick will compute.
      activeSince = now.addingTimeInterval(-idleSeconds)
    }
    lastObservedIdleSeconds = idleSeconds

    let threshold = TimeInterval(idleController.idleTimeoutMinutes * 60)

    return ProcessingGateInputs(
      isScreenLocked: scheduler.isScreenLocked,
      lockedSince: lockedSince,
      onBattery: onBattery,
      isLowPowerMode: scheduler.isLowPowerMode,
      batterySince: batterySince,
      thermalState: scheduler.thermalState,
      thermalSince: thermalSince,
      systemIdleSeconds: idleSeconds,
      activeSince: activeSince,
      idleThresholdSeconds: threshold,
      pendingWorkCount: scheduler.pendingWorkCount
    )
  }

  /// Two `GateState`s are equivalent for de-dupe purposes when they
  /// describe the same situation, ignoring the millisecond drift of
  /// `since` between ticks. We treat `since` as "best effort" rather
  /// than exact — re-POSTing solely because `since` ticked forward by
  /// 3s would defeat the whole point of de-duping.
  private func statesAreEquivalent(_ a: GateState, _ b: GateState) -> Bool {
    switch (a, b) {
    case (.allowed, .allowed):
      return true
    case let (.blocked(rA, _, wA), .blocked(rB, _, wB)):
      // For `idleFor(seconds)` specifically we DO want a re-POST when the
      // remaining-idle counter changes, because the UI binds its "resumes
      // in 30s" copy directly to that number.
      if case .idleFor(let sA) = wA, case .idleFor(let sB) = wB, rA == rB {
        // Re-POST whenever the remaining seconds change by ≥ 1s. The
        // previous 5s tolerance combined with the 3s post cadence made
        // the UI countdown stutter (e.g. "90 → 90 → 84 → 84") because
        // every other tick fell under the threshold. 1s keeps the
        // counter monotonic from the user's perspective.
        return abs(Int64(sA) - Int64(sB)) < 1
      }
      return rA == rB && wA == wB
    default:
      return false
    }
  }
}
