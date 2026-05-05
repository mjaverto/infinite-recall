import Foundation

/// Narrow seam for the consumer of escalation banners. `ActivityMonitorService`
/// is the production conformer; tests inject a stub so they don't have to
/// touch the `@MainActor` singleton (which transitively hangs on macOS-15
/// GitHub runners — see `InternalPostFailureTrackerTests` setUp comment).
@MainActor
protocol InternalPostFailureReporter: AnyObject {
    var lastError: String? { get }
    func clearLastError()
    func reportInternalPostFailure(category: String, consecutive: Int)
}

/// Tracks consecutive failures of `_internal/*` POSTs (inflight, gate-state)
/// so the user gets a banner when internal reporting is silently broken.
/// Each category has its own counter; hitting `escalationThreshold`
/// consecutive failures fires once into the attached
/// `InternalPostFailureReporter` (`ActivityMonitorService` in production).
/// A subsequent success resets the counter and re-arms escalation.
///
/// Issue #137: the `queueDepth` category was pruned. Activity snapshots are
/// now DB-authoritative (`snapshotWithAuthoritativeQueueDepth` reads
/// `pending_work` directly), so the legacy Swift→Rust queue-depth POST has
/// no producer and the legacy Rust `_internal/queue-depth` route was
/// removed alongside it.
@MainActor
final class InternalPostFailureTracker {
    static let shared = InternalPostFailureTracker()

    let escalationThreshold: Int

    /// Default initializer used by `shared`. Tests can construct local
    /// instances by passing a custom `escalationThreshold` (or the default)
    /// to avoid singleton bleed.
    init(escalationThreshold: Int = 3) {
        self.escalationThreshold = escalationThreshold
    }

    enum Category: String, CaseIterable {
        case inflight
        case gateState = "gate-state"
    }

    private weak var monitor: InternalPostFailureReporter?
    private var counts: [Category: Int] = [:]
    private var escalated: Set<Category> = []

    func attach(_ monitor: InternalPostFailureReporter) {
        self.monitor = monitor
    }

    func reportFailure(_ category: Category, error: Error? = nil) {
        if let error, Self.isDaemonRestartIndicator(error) {
            // Benign daemon-restart signal (token rotated, socket gone, 5xx
            // gateway-class) — neither failure nor success. Don't bump the
            // counter; the next real call will get an honest verdict.
            return
        }
        let next = (counts[category] ?? 0) + 1
        counts[category] = next
        if next >= escalationThreshold && !escalated.contains(category) {
            escalated.insert(category)
            guard let monitor else {
                // Production safety: escalation crossed but nobody is
                // listening. Log loudly so the "attach was forgotten"
                // failure mode is visible in /private/tmp/omi-dev.log
                // instead of being silently swallowed.
                NSLog(
                    "[internal-post-failure] escalation for category=\(category.rawValue) count=\(next) but monitor is nil — attach was not called"
                )
                return
            }
            monitor.reportInternalPostFailure(
                category: category.rawValue,
                consecutive: next
            )
        }
    }

    func reportSuccess(_ category: Category) {
        counts[category] = 0
        escalated.remove(category)
    }

    func failureCount(_ category: Category) -> Int {
        counts[category] ?? 0
    }

    /// True when `error` looks like the Rust daemon just restarted (token
    /// rotated → 401, socket gone → connection refused, gateway-class 5xx,
    /// timeout). Delegates to `DaemonErrorClassifier` so this tracker,
    /// `ProcessingGateReporter`, and `ActivityMonitorService` cannot drift.
    private static func isDaemonRestartIndicator(_ error: Error) -> Bool {
        DaemonErrorClassifier.isTransient(error)
    }
}
