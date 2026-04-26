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

  // === activity:G ===
  /// Currently-running work item per kind, surfaced for the Activity UI.
  /// Mirrors what we report to the Rust daemon via
  /// `APIClient.shared.reportInFlight(...)` so SwiftUI views can bind to
  /// instant local state without waiting on the snapshot poller.
  /// Cleared (entry removed) when the handler returns or throws.
  @Published public private(set) var inFlight: [PendingWork.Kind: InFlight] = [:]
  // === /activity:G ===

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
  private var lastAllow: Bool = true

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
  }

  /// Stop watching for transitions. Mainly for tests.
  public func stop() {
    monitorTask?.cancel()
    monitorTask = nil
    countPollerTask?.cancel()
    countPollerTask = nil
    pendingTransitionTask?.cancel()
    pendingTransitionTask = nil
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
    while allowHeavyWork {
      guard let work = try? await PendingWorkStorage.shared.claimNext(claimedBy: tag) else {
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

      // === activity:G ===
      // 1. user-pause check (additive to idle/battery/thermal gating already
      //    enforced above via `allowHeavyWork` in the `while` condition).
      //    If the user has paused this kind from the Activity tab, stop
      //    draining. We've already claimed this row; per the existing
      //    "no handler for X, leaving claimed" pattern just above, we leave
      //    it claimed and break — the sweeper reclaims after lease expiry,
      //    and the next drain past the pause window will pick it up.
      //
      //    The check is intentionally ADDITIVE to the device-idle / battery /
      //    thermal gates — it does NOT replace them.
      let isUserPaused = await MainActor.run {
        CapturePauseGate.shared.isPaused(target: "kind", id: work.kind.rawValue)
      }
      if isUserPaused {
        log("BatteryAwareScheduler: user-paused \(work.kind.rawValue), leaving claimed")
        break
      }

      // 2. wrap handler with in-flight reporting so the Activity tab can show
      //    the running task in real time. Local @Published mirror is updated
      //    synchronously on @MainActor; the daemon report fires-and-forgets.
      let inflightLabel = WorkLabels.humanLabel(work)
      let inflightEntry = InFlight(label: inflightLabel, startedAt: Date())
      self.inFlight[work.kind] = inflightEntry
      Task {
        try? await APIClient.shared.reportInFlight(
          kind: work.kind.rawValue,
          inFlight: inflightEntry
        )
      }
      // === /activity:G ===

      do {
        try await handler(work)
        try? await PendingWorkStorage.shared.ack(storageId: storageId)
        // === activity:G ===
        self.inFlight[work.kind] = nil
        Task {
          try? await APIClient.shared.reportInFlight(
            kind: work.kind.rawValue,
            inFlight: nil
          )
        }
        // === /activity:G ===
      } catch {
        try? await PendingWorkStorage.shared.fail(storageId: storageId, error: error)
        // === activity:G ===
        self.inFlight[work.kind] = nil
        Task {
          try? await APIClient.shared.reportInFlight(
            kind: work.kind.rawValue,
            inFlight: nil
          )
        }
        // === /activity:G ===
        // Stop draining; next state transition or explicit drain() can retry.
        break
      }
    }
  }

  // === activity:G ===
  // Phase-0 placeholder so this file compiles before Stream F lands the real
  // `APIClient.reportInFlight(kind:inFlight:)`. When Stream F's PR adds the
  // real method on `APIClient`, this entire bracketed extension MUST be
  // deleted — having both will be a duplicate-symbol compile error.
  // === /activity:G ===

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
  #endif
}
