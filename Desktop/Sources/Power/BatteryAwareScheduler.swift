import Foundation
import SwiftUI
#if canImport(Combine)
import Combine
#endif

/// A unit of deferred heavy work — Whisper inference, Vision OCR, local
/// LLM extraction, summarisation, etc. The scheduler persists these in
/// `pending_work` (SQLite-backed via `PendingWorkStorage`) so they survive
/// app crash / quit / forced reboot.
///
/// `payload` is intentionally opaque `Data`. Each consumer (transcription
/// service, OCR pipeline, assistants) decides its own envelope so the
/// scheduler doesn't need to know about audio buffers, CGImages, or
/// transcript IDs.
public struct PendingWork: Identifiable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case transcribe
    case ocr
    case extractMemory
    case extractActionItems
    case summarize
  }

  public let id: UUID
  public let kind: Kind
  public let payload: Data
  public let queuedAt: Date
  /// Row ID in `pending_work` table. Nil for legacy in-memory items (tests only).
  public let storageId: Int64?

  public init(
    id: UUID = UUID(),
    kind: Kind,
    payload: Data,
    queuedAt: Date = Date(),
    storageId: Int64? = nil
  ) {
    self.id = id
    self.kind = kind
    self.payload = payload
    self.queuedAt = queuedAt
    self.storageId = storageId
  }
}

/// Tells callers when the machine has the headroom to do heavy ML work, and
/// drains a persistent SQLite-backed queue of deferred work.
///
/// **Decision logic** (see `allowHeavyWork`):
/// 1. If the user has flipped the override toggle, always allow. (Power
///    users should be able to override "wait for AC" on a long flight.)
/// 2. Otherwise: AC power AND not in low-power mode AND thermal state is
///    below `.serious`.
///
/// **Drain semantics**: when `allowHeavyWork` flips false → true, the
/// scheduler automatically calls `drain()`. When it flips true → false, we
/// stop accepting new drains but in-flight handlers run to natural
/// completion — interrupting an in-progress Whisper pass would just waste
/// the work we already did.
///
/// **Queue persistence**: `enqueue(_:)` is now `async` and stores items in
/// `pending_work` (GRDB). Items survive crash/quit/reboot. The `drain()` loop
/// calls `PendingWorkStorage.shared.claimNext()` for atomic lease acquisition,
/// then `ack()` or `fail()` based on handler result.
@MainActor
public final class BatteryAwareScheduler: ObservableObject {
  public static let shared = BatteryAwareScheduler()

  /// Closure that consumers register to actually do the work for a given
  /// `PendingWork.Kind`. Returning normally means "done, remove from queue".
  /// Throwing leaves the item in place for retry on the next drain.
  public typealias Handler = @Sendable (PendingWork) async throws -> Void

  // MARK: - Debounce configuration

  /// How long (in seconds) a new power-source state must be stable before
  /// `allowHeavyWork` is updated and a drain is triggered.
  ///
  /// Both directions are debounced:
  /// - Battery → AC: drain fires 30 s AFTER the cable is plugged in.
  /// - AC → battery: heavy work continues for 30 s after unplug, then ceases.
  ///
  /// INVARIANT: this debounces the *transition decision*, not the underlying
  /// power state read. `IOPSCopyPowerSourcesInfo` (via `PowerStateMonitor`) still
  /// reflects current truth at all times — only the SCHEDULER's `allowHeavyWork`
  /// commitment lags behind by up to `acTransitionDebounceSeconds`.
  public static let acTransitionDebounceSeconds: Double = 30.0

  // MARK: - Published surface

  @Published public private(set) var source: PowerSource = .ac
  @Published public private(set) var isLowPowerMode: Bool = false
  @Published public private(set) var thermalState: ProcessInfo.ThermalState = .nominal
  @Published public private(set) var pendingWorkCount: Int = 0
  @Published public private(set) var isDraining: Bool = false

  /// True when the macOS screen is locked. Updated by direct subscription to
  /// `.screenDidLock` / `.screenDidUnlock` (posted by AppState lifecycle observers).
  /// We subscribe directly here rather than depending on AppState observer order —
  /// the scheduler must be able to evaluate `allowAutonomousAIWork` at any time.
  @Published public private(set) var isScreenLocked: Bool = false

  /// Power-user override. When `true`, `allowHeavyWork` is forced true
  /// regardless of battery / low-power-mode / thermal signals.
  @AppStorage("battery_override_allowHeavyWork")
  public var userOverride: Bool = false

  /// Single source of truth for "may I run a Whisper pass right now?".
  /// This reflects the *committed* power state — it lags real hardware by
  /// up to `acTransitionDebounceSeconds` on any transition after launch.
  public var allowHeavyWork: Bool {
    if userOverride { return true }
    if committedSource != .ac { return false }
    if isLowPowerMode { return false }
    if thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { return false }
    return true
  }

  /// Stricter readiness gate for autonomous AI work (e.g. `.summarize`).
  ///
  /// Requires `allowHeavyWork` PLUS one of:
  ///   - the screen is locked, OR
  ///   - the user has been input-idle for at least
  ///     `IdleAIController.shared.idleTimeoutMinutes * 60` seconds.
  ///
  /// Lock-or-idle ensures autonomous LLM drain never interrupts an active
  /// user. Idle threshold reuses the existing Memory Saver setting — no new
  /// user-facing knob is introduced.
  ///
  /// Used ONLY for `.summarize` (and future autonomous-LLM kinds). Existing
  /// kinds (`.transcribe`, `.ocr`, …) keep using `allowHeavyWork`, so their
  /// behavior is unchanged.
  public var allowAutonomousAIWork: Bool {
    guard allowHeavyWork else { return false }
    if isScreenLocked { return true }
    let threshold = TimeInterval(IdleAIController.shared.idleTimeoutMinutes * 60)
    return IdleAIController.shared.systemIdleSeconds() >= threshold
  }

  /// Human-readable summary for the menu-bar badge.
  public var statusText: String {
    if pendingWorkCount == 0 {
      return "Up to date"
    }
    let qualifier: String
    if userOverride {
      qualifier = "override"
    } else if source == .battery {
      qualifier = "battery"
    } else if isLowPowerMode {
      qualifier = "low-power"
    } else if thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
      qualifier = "thermal throttling"
    } else {
      qualifier = "draining"
    }
    let noun = pendingWorkCount == 1 ? "item" : "items"
    return "\(pendingWorkCount) \(noun) waiting (\(qualifier))"
  }

  // MARK: - Internal state

  private var handlers: [PendingWork.Kind: Handler] = [:]
  private var monitorTask: Task<Void, Never>?
  private var countPollerTask: Task<Void, Never>?
  private var readinessTickTask: Task<Void, Never>?
  private var screenLockObserver: NSObjectProtocol?
  private var screenUnlockObserver: NSObjectProtocol?
  private var lastAllow: Bool = true
  private var lastAutonomousAllow: Bool = false

  /// The power source that `allowHeavyWork` is evaluated against.
  /// Updated only after a debounce window elapses — not on every raw signal.
  private var committedSource: PowerSource = .ac

  /// Pending task that, after the debounce window, commits a new power source
  /// and optionally fires `drain()`. Cancelled whenever another transition
  /// arrives before the window closes.
  private var pendingTransitionTask: Task<Void, Never>?

  /// Worker tag embedded in `claimedBy` column so sweeper can identify orphans.
  private var workerTag: String { "PowerWorkBridge#\(ProcessInfo.processInfo.processIdentifier)" }

  private init() {}

  /// Wire up to the shared `PowerStateMonitor` and start watching for
  /// transitions. Idempotent.
  public func start() {
    start(monitor: .shared)
  }

  /// Test-friendly entry point that lets you inject a specific monitor.
  public func start(monitor: PowerStateMonitor) {
    guard monitorTask == nil else { return }
    monitor.start()

    // Seed from current state so we don't briefly think we're on battery.
    // No debounce on launch — commit the initial state immediately.
    let initial = monitor.currentSnapshot()
    self.source = initial.source
    self.committedSource = initial.source
    self.isLowPowerMode = initial.isLowPowerMode
    self.thermalState = initial.thermalState
    self.lastAllow = self.allowHeavyWork

    monitorTask = Task { @MainActor [weak self] in
      for await snap in monitor.snapshots() {
        guard let self else { return }
        self.source = snap.source
        self.isLowPowerMode = snap.isLowPowerMode
        self.thermalState = snap.thermalState
        self.handlePossibleTransition()
      }
    }

    // 5-second count poller (design doc §7 open question: poll not ValueObservation)
    countPollerTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let count = await PendingWorkStorage.shared.pendingCount()
        self.pendingWorkCount = count
        try? await Task.sleep(nanoseconds: 5_000_000_000)
      }
    }

    // Lock-state observers. Subscribe directly to AppState's notifications so
    // we don't depend on AppState observer order. `isScreenLocked` is part of
    // `allowAutonomousAIWork`, so a flip in either direction must re-evaluate
    // readiness immediately and (if it just became true) kick off a drain.
    if screenLockObserver == nil {
      screenLockObserver = NotificationCenter.default.addObserver(
        forName: .screenDidLock,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.isScreenLocked = true
          self?.reevaluateAutonomousReadiness()
        }
      }
    }
    if screenUnlockObserver == nil {
      screenUnlockObserver = NotificationCenter.default.addObserver(
        forName: .screenDidUnlock,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.isScreenLocked = false
          self?.reevaluateAutonomousReadiness()
        }
      }
    }

    // 60s periodic readiness tick. `systemIdleSeconds()` changes silently — no
    // notification fires when the user crosses the idle threshold — so we
    // poll. AC / low-power / thermal still drive their own immediate paths
    // via the snapshot loop above.
    readinessTickTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        guard let self else { return }
        self.reevaluateAutonomousReadiness()
      }
    }

    // Seed lastAutonomousAllow from current state so the first tick doesn't
    // mistake "still false" for "just transitioned to false".
    self.lastAutonomousAllow = self.allowAutonomousAIWork
  }

  /// Stop watching for transitions. Mainly for tests.
  public func stop() {
    monitorTask?.cancel()
    monitorTask = nil
    countPollerTask?.cancel()
    countPollerTask = nil
    readinessTickTask?.cancel()
    readinessTickTask = nil
    pendingTransitionTask?.cancel()
    pendingTransitionTask = nil

    if let obs = screenLockObserver {
      NotificationCenter.default.removeObserver(obs)
      screenLockObserver = nil
    }
    if let obs = screenUnlockObserver {
      NotificationCenter.default.removeObserver(obs)
      screenUnlockObserver = nil
    }
  }

  // MARK: - Handler registration

  /// Register the closure that actually executes work for a given kind.
  /// Replaces any previously-registered handler for the same kind.
  public func registerHandler(for kind: PendingWork.Kind, _ handler: @escaping Handler) {
    handlers[kind] = handler
  }

  // MARK: - Queue API

  /// Enqueue a unit of deferred work. Stores it persistently in `pending_work`.
  /// If the machine currently has headroom we kick off `drain()` immediately.
  ///
  /// - Parameters:
  ///   - work: The work item to enqueue.
  ///   - dedupKey: Optional natural key; duplicate active rows are silently ignored.
  public func enqueue(_ work: PendingWork, dedupKey: String? = nil) async {
    do {
      try await PendingWorkStorage.shared.enqueue(
        workType: work.kind.rawValue,
        payload: work.payload,
        dedupKey: dedupKey
      )
      // Refresh count immediately rather than waiting for the 5s poller.
      let count = await PendingWorkStorage.shared.pendingCount()
      pendingWorkCount = count
    } catch {
      logError("BatteryAwareScheduler: enqueue failed", error: error)
    }

    if allowHeavyWork && !isDraining {
      Task { @MainActor in
        await self.drain()
      }
    }
  }

  /// Drain the queue by claiming and executing items one at a time.
  ///
  /// Stops when:
  /// - `claimNext()` returns nil (queue empty or all future-scheduled), or
  /// - `allowHeavyWork` flips false.
  ///
  /// On handler success → `ack()`. On handler throw → `fail()` (backoff + retry).
  /// In-flight handlers are NOT cancelled on `allowHeavyWork` flip — they run
  /// to completion.
  public func drain() async {
    guard !isDraining else { return }
    isDraining = true
    defer {
      isDraining = false
      Task { @MainActor [weak self] in
        let count = await PendingWorkStorage.shared.pendingCount()
        self?.pendingWorkCount = count
      }
    }

    let tag = workerTag
    var drainedAnyAutonomous = false
    while allowHeavyWork {
      guard let work = try? await PendingWorkStorage.shared.claimNext(claimedBy: tag) else {
        break
      }
      // Per-kind readiness gate: `.summarize` (and future autonomous-LLM
      // kinds) require the stricter `allowAutonomousAIWork`. Other kinds
      // (`.transcribe`, `.ocr`, …) keep the existing `allowHeavyWork` gate
      // so their behavior is unchanged.
      //
      // If we just claimed a `.summarize` row but autonomous readiness is
      // false, RELEASE the claim back to `queued` without counting an attempt
      // or triggering exponential backoff. Readiness loss is not a handler
      // failure, so it must not burn one of the row's `maxAttempts` budget —
      // otherwise a few transient lock/unlock cycles could dead-letter a row
      // that never had a real chance to run. `fail()` is reserved for actual
      // handler failures.
      if Self.requiresAutonomousReadiness(work.kind), !allowAutonomousAIWork {
        if let storageId = work.storageId {
          try? await PendingWorkStorage.shared.releaseClaim(storageId: storageId)
        }
        break
      }
      guard let handler = handlers[work.kind] else {
        // No registered consumer for this kind yet — leave it claimed; sweeper
        // will reclaim after lease expiry. Break to avoid tight loop.
        log("BatteryAwareScheduler: no handler for \(work.kind.rawValue), leaving claimed")
        break
      }
      guard let storageId = work.storageId else {
        log("BatteryAwareScheduler: claimed item missing storageId, skipping")
        continue
      }

      do {
        try await handler(work)
        try? await PendingWorkStorage.shared.ack(storageId: storageId)
        if Self.requiresAutonomousReadiness(work.kind) {
          drainedAnyAutonomous = true
        }
      } catch {
        try? await PendingWorkStorage.shared.fail(storageId: storageId, error: error)
        // Stop draining; next state transition or explicit drain() can retry.
        break
      }
    }

    // Memory Saver: after each batch drain, if we touched any autonomous-LLM
    // work AND the .summarize queue is now empty AND the user is idle/locked
    // with Memory Saver enabled, give IdleAIController a chance to unload the
    // local LLM. `chatAutonomous` deliberately does NOT bump
    // `IdleAIController.lastAICall`, so this release path is the only thing
    // that prevents autonomous drains from pinning the model in memory.
    if drainedAnyAutonomous {
      let depth = try? await PendingWorkStorage.shared.depthSummary()
      let key = PendingWork.Kind.summarize.rawValue
      let summarizeRemaining = (depth?.queued[key] ?? 0) + (depth?.failed[key] ?? 0)
      if summarizeRemaining == 0 {
        await IdleAIController.shared.releaseAfterAutonomousWorkIfAppropriate()
      }
    }
  }

  /// Returns true for kinds gated by `allowAutonomousAIWork`.
  /// Currently: `.summarize`. Future autonomous-LLM kinds should be added here.
  fileprivate static func requiresAutonomousReadiness(_ kind: PendingWork.Kind) -> Bool {
    switch kind {
    case .summarize:
      return true
    case .transcribe, .ocr, .extractMemory, .extractActionItems:
      return false
    }
  }

  // MARK: - Internal

  /// Called whenever any input signal updates. Debounces power-source
  /// transitions by `acTransitionDebounceSeconds` before committing a new
  /// `allowHeavyWork` value and (if the new value is true) triggering drain.
  ///
  /// Non-source signals (low-power mode, thermal state) update raw published
  /// properties immediately but still flow through the same debounce window
  /// because `allowHeavyWork` is evaluated against `committedSource`.
  ///
  /// If the source is unchanged since the last committed state, any pending
  /// debounce task is cancelled and the transition is a no-op.
  private func handlePossibleTransition() {
    let pendingSource = self.source  // raw value from latest snapshot

    if pendingSource == committedSource {
      // Source flipped back to what we already committed — cancel any pending
      // transition and stay on the committed state without delay.
      pendingTransitionTask?.cancel()
      pendingTransitionTask = nil

      // Still re-evaluate non-source signals (thermal / low-power).
      let now = allowHeavyWork
      let was = lastAllow
      lastAllow = now
      if !was && now {
        Task { @MainActor in
          await self.drain()
        }
      }
      // Autonomous readiness depends on heavy + lock/idle; re-evaluate too so
      // a thermal / low-power flip can also unblock or block summarize work.
      reevaluateAutonomousReadiness()
      return
    }

    // New source differs from committed source — start (or restart) the
    // debounce window. Cancel whatever was pending.
    pendingTransitionTask?.cancel()

    let debounce = Self.acTransitionDebounceSeconds
    pendingTransitionTask = Task { @MainActor [weak self] in
      // Wait for the debounce window.
      try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))

      // If we were cancelled during the sleep, do nothing.
      guard !Task.isCancelled, let self else { return }

      // Commit the new source.
      self.committedSource = pendingSource
      self.pendingTransitionTask = nil

      let now = self.allowHeavyWork
      let was = self.lastAllow
      self.lastAllow = now
      if !was && now {
        await self.drain()
      } else {
        // allowHeavyWork may have flipped false — update lastAllow so the
        // next real transition is detected correctly.
        self.lastAllow = now
      }
      self.reevaluateAutonomousReadiness()
    }
  }

  /// Reads the latest `allowAutonomousAIWork` value and, if it just flipped
  /// false → true, kicks off `drain()` so any waiting `.summarize` rows pick
  /// up immediately rather than waiting for the next 60s tick or AC flip.
  ///
  /// Idempotent and cheap — safe to call from any signal source (AC change,
  /// thermal, lock state, periodic tick).
  fileprivate func reevaluateAutonomousReadiness() {
    let now = allowAutonomousAIWork
    let was = lastAutonomousAllow
    lastAutonomousAllow = now
    if !was && now && !isDraining {
      Task { @MainActor in
        await self.drain()
      }
    }
  }

  // MARK: - Test hooks

  #if DEBUG
  /// For tests: inject a synthetic snapshot so we can exercise transitions
  /// without actually unplugging the laptop.
  public func _testInject(
    source: PowerSource? = nil,
    isLowPowerMode: Bool? = nil,
    thermalState: ProcessInfo.ThermalState? = nil
  ) {
    if let source { self.source = source }
    if let isLowPowerMode { self.isLowPowerMode = isLowPowerMode }
    if let thermalState { self.thermalState = thermalState }
    handlePossibleTransition()
  }

  /// For tests: bypass the debounce window and commit a power source
  /// immediately so unit tests don't wait 30s.
  public func _testCommitSource(_ source: PowerSource) {
    pendingTransitionTask?.cancel()
    pendingTransitionTask = nil
    self.source = source
    self.committedSource = source
    self.lastAllow = self.allowHeavyWork
    self.lastAutonomousAllow = self.allowAutonomousAIWork
  }

  /// For tests: drive lock state directly without raising real distributed
  /// notifications. Mirrors what the production `.screenDidLock`/`Unlock`
  /// observer would do.
  public func _testSetScreenLocked(_ locked: Bool) {
    self.isScreenLocked = locked
    self.reevaluateAutonomousReadiness()
  }
  #endif
}
