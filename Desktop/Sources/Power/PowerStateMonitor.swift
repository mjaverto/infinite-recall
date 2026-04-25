import Foundation
import IOKit
import IOKit.ps
#if canImport(Combine)
import Combine
#endif

/// Where the machine is currently drawing power from.
///
/// Treats UPS-on-AC as `.ac` because IOKit reports it as `kIOPMACPowerKey`
/// while the wall power is up; once the UPS switches to its own battery,
/// IOKit flips to `kIOPMBatteryPowerKey` and we'll follow.
public enum PowerSource: String, Codable, Equatable, Sendable {
  case ac
  case battery
}

/// Observes macOS power state and exposes it as `@Published` properties for
/// SwiftUI / Combine consumers, and as a one-shot async stream for callers
/// that just want change events.
///
/// Internally this owns a dedicated thread running a CFRunLoop so that the
/// IOKit power-source notification callback has somewhere to land. The
/// callback NEVER blocks — it just hops back to `DispatchQueue.main` to
/// publish the change.
@MainActor
public final class PowerStateMonitor: ObservableObject {
  public static let shared = PowerStateMonitor()

  @Published public private(set) var source: PowerSource = .ac
  @Published public private(set) var isLowPowerMode: Bool = false
  @Published public private(set) var thermalState: ProcessInfo.ThermalState = .nominal

  /// Async stream of `PowerState` snapshots, fired on every observed change
  /// (source / low-power-mode / thermal). Consumers that only care about the
  /// boolean "is heavy work allowed" should derive from this.
  public struct Snapshot: Sendable, Equatable {
    public let source: PowerSource
    public let isLowPowerMode: Bool
    public let thermalState: ProcessInfo.ThermalState
  }

  // MARK: - Lifecycle

  private var started: Bool = false
  private var runLoopThread: Thread?
  private var notificationRunLoopSource: CFRunLoopSource?
  // Keep a strong reference to the dedicated run loop so we can stop it on deinit.
  // Stored as `Unmanaged` because CFRunLoop is not Sendable.
  private var runLoop: CFRunLoop?

  // The set of AsyncStream continuations subscribed to snapshots.
  private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

  private init() {}

  /// Begin observing power state. Idempotent.
  public func start() {
    guard !started else { return }
    started = true

    // 1) Synchronously query current state — IOKit's notification source
    //    does NOT fire on registration, so without this we'd be stuck at
    //    the default `.ac` until the user actually unplugs.
    refreshFromIOKit()

    // 2) NSProcessInfo signals — these DO emit on first observation if you
    //    read the property, so we read once and subscribe.
    isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    thermalState = ProcessInfo.processInfo.thermalState

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(lowPowerModeDidChange),
      name: .NSProcessInfoPowerStateDidChange,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(thermalStateDidChange),
      name: ProcessInfo.thermalStateDidChangeNotification,
      object: nil
    )

    // 3) Spawn dedicated thread that owns a CFRunLoop and registers the
    //    IOKit power-source notification source.
    let thread = Thread { [weak self] in
      guard let self else { return }
      Thread.current.name = "PowerStateMonitor.RunLoop"
      let rl = CFRunLoopGetCurrent()
      Task { @MainActor in
        self.runLoop = rl
      }

      // Build the CFRunLoopSource. The callback receives a raw pointer to
      // `self` — we use Unmanaged so we can cross the C boundary safely.
      let context = Unmanaged.passUnretained(self).toOpaque()
      let cb: IOPowerSourceCallbackType = { rawSelf in
        guard let rawSelf else { return }
        let monitor = Unmanaged<PowerStateMonitor>.fromOpaque(rawSelf)
          .takeUnretainedValue()
        // Hop to main; refreshFromIOKit() is @MainActor.
        DispatchQueue.main.async {
          monitor.refreshFromIOKit()
        }
      }
      guard
        let source = IOPSNotificationCreateRunLoopSource(cb, context)?.takeRetainedValue()
      else {
        return
      }
      Task { @MainActor in
        self.notificationRunLoopSource = source
      }
      CFRunLoopAddSource(rl, source, .defaultMode)
      CFRunLoopRun()
    }
    thread.qualityOfService = .utility
    thread.start()
    runLoopThread = thread
  }

  deinit {
    if let rl = runLoop {
      CFRunLoopStop(rl)
    }
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Snapshots

  /// Subscribe to snapshots as an `AsyncStream`. The first element is the
  /// current state at the time of subscription.
  public func snapshots() -> AsyncStream<Snapshot> {
    AsyncStream { continuation in
      let id = UUID()
      self.continuations[id] = continuation
      // Yield current state immediately.
      continuation.yield(self.currentSnapshot())
      continuation.onTermination = { @Sendable _ in
        Task { @MainActor [weak self] in
          self?.continuations.removeValue(forKey: id)
        }
      }
    }
  }

  public func currentSnapshot() -> Snapshot {
    Snapshot(source: source, isLowPowerMode: isLowPowerMode, thermalState: thermalState)
  }

  // MARK: - Internal

  /// Read the current power source from IOKit and publish if it changed.
  /// Must be called on the main actor (it mutates `@Published` state).
  fileprivate func refreshFromIOKit() {
    let new = Self.queryCurrentSource()
    if new != source {
      source = new
      broadcastSnapshot()
    }
  }

  @objc private func lowPowerModeDidChange() {
    let new = ProcessInfo.processInfo.isLowPowerModeEnabled
    Task { @MainActor in
      if self.isLowPowerMode != new {
        self.isLowPowerMode = new
        self.broadcastSnapshot()
      }
    }
  }

  @objc private func thermalStateDidChange() {
    let new = ProcessInfo.processInfo.thermalState
    Task { @MainActor in
      if self.thermalState != new {
        self.thermalState = new
        self.broadcastSnapshot()
      }
    }
  }

  private func broadcastSnapshot() {
    let snap = currentSnapshot()
    for cont in continuations.values {
      cont.yield(snap)
    }
  }

  /// One-shot synchronous query of `IOPSCopyPowerSourcesInfo` +
  /// `IOPSGetProvidingPowerSourceType`. UPS-on-AC reports as AC; that's
  /// the desired behaviour.
  static func queryCurrentSource() -> PowerSource {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
      return .ac  // Conservative default: assume plugged in.
    }
    guard let providing = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String?
    else {
      return .ac
    }
    if providing == kIOPMBatteryPowerKey as String {
      return .battery
    }
    // kIOPMACPowerKey, kIOPMUPSPowerKey, or anything unknown → treat as AC.
    return .ac
  }
}
