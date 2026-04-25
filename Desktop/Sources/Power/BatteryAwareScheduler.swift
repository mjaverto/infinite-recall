import Foundation
import SwiftUI
#if canImport(Combine)
import Combine
#endif

/// A unit of deferred heavy work — Whisper inference, Vision OCR, local
/// LLM extraction, summarisation, etc. The scheduler holds these in memory
/// (v1) and lets consumers drain them when the machine is on AC.
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

  public init(
    id: UUID = UUID(),
    kind: Kind,
    payload: Data,
    queuedAt: Date = Date()
  ) {
    self.id = id
    self.kind = kind
    self.payload = payload
    self.queuedAt = queuedAt
  }
}

/// Tells callers when the machine has the headroom to do heavy ML work, and
/// holds a small in-memory queue of work that's been deferred.
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
@MainActor
public final class BatteryAwareScheduler: ObservableObject {
  public static let shared = BatteryAwareScheduler()

  /// Closure that consumers register to actually do the work for a given
  /// `PendingWork.Kind`. Returning normally means "done, remove from queue".
  /// Throwing leaves the item in place for retry on the next drain.
  public typealias Handler = @Sendable (PendingWork) async throws -> Void

  // MARK: - Published surface

  @Published public private(set) var source: PowerSource = .ac
  @Published public private(set) var isLowPowerMode: Bool = false
  @Published public private(set) var thermalState: ProcessInfo.ThermalState = .nominal
  @Published public private(set) var pendingWorkCount: Int = 0
  @Published public private(set) var isDraining: Bool = false

  /// Power-user override. When `true`, `allowHeavyWork` is forced true
  /// regardless of battery / low-power-mode / thermal signals.
  @AppStorage("battery_override_allowHeavyWork")
  public var userOverride: Bool = false

  /// Single source of truth for "may I run a Whisper pass right now?".
  public var allowHeavyWork: Bool {
    if userOverride { return true }
    if source != .ac { return false }
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

  // MARK: - Internal queue

  private var queue: [PendingWork] = []
  private var handlers: [PendingWork.Kind: Handler] = [:]
  private var monitorTask: Task<Void, Never>?
  private var lastAllow: Bool = true

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
    let initial = monitor.currentSnapshot()
    self.source = initial.source
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
  }

  /// Stop watching for transitions. Mainly for tests.
  public func stop() {
    monitorTask?.cancel()
    monitorTask = nil
  }

  // MARK: - Handler registration

  /// Register the closure that actually executes work for a given kind.
  /// Replaces any previously-registered handler for the same kind.
  public func registerHandler(for kind: PendingWork.Kind, _ handler: @escaping Handler) {
    handlers[kind] = handler
  }

  // MARK: - Queue API

  /// Enqueue a unit of deferred work. If the machine currently has
  /// headroom we kick off `drain()` immediately.
  public func enqueue(_ work: PendingWork) {
    queue.append(work)
    pendingWorkCount = queue.count
    if allowHeavyWork && !isDraining {
      Task { @MainActor in
        await self.drain()
      }
    }
  }

  /// Drain the queue, calling registered handlers in FIFO order. Stops
  /// early if `allowHeavyWork` flips back to false partway through.
  /// In-flight handler calls are NOT cancelled — they run to completion.
  public func drain() async {
    guard !isDraining else { return }
    isDraining = true
    defer { isDraining = false }

    while allowHeavyWork, let work = queue.first {
      guard let handler = handlers[work.kind] else {
        // No registered consumer for this kind yet; leave it in the queue
        // so when the consumer registers later it can be picked up.
        // But to avoid an infinite loop, break out now.
        break
      }
      do {
        try await handler(work)
        // Handler succeeded — drop from queue. Use ID match in case the
        // queue mutated during the await (e.g. another enqueue).
        if let idx = queue.firstIndex(where: { $0.id == work.id }) {
          queue.remove(at: idx)
        }
        pendingWorkCount = queue.count
      } catch {
        // Handler threw — leave the item in place and stop draining for
        // now. The next state transition or explicit drain() can retry.
        break
      }
    }
  }

  // MARK: - Internal

  /// Called whenever any input signal updates. If `allowHeavyWork` just
  /// flipped false → true, kick off a drain. true → false is handled
  /// implicitly by `drain()` re-checking at the top of every loop pass.
  private func handlePossibleTransition() {
    let now = allowHeavyWork
    let was = lastAllow
    lastAllow = now
    if !was && now && !queue.isEmpty {
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
  #endif
}
