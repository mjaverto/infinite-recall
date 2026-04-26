import Foundation

/// Periodic background maintenance task for the `pending_work` table.
///
/// Runs every 60 seconds and performs three operations:
///
/// 1. **Lease expiry recovery** — any row with `status = 'claimed'` and
///    `leaseExpiresAt < now` is treated as orphaned (app crash, process kill,
///    system sleep edge case). It is reset to `queued` (or `dead` if
///    `attempts + 1 >= maxAttempts`). Each lease expiry consumes one attempt,
///    so a poison payload that crashes the app every time can only trigger
///    `maxAttempts` retries before being dead-lettered.
///
/// 2. **Done-row GC** — rows with `status = 'done'` older than 24 hours are
///    hard-deleted. They were kept briefly for postmortem visibility.
///
/// 3. **Dead-row GC** — rows with `status = 'dead'` older than 30 days are
///    hard-deleted. The 30-day window is long enough for a developer to inspect
///    them via `sqlite3` CLI.
///
/// All three SQL operations live inside `PendingWorkStorage.runMaintenanceSweep`
/// so they go through the actor's mutation delegate — keeps the Activity panel
/// in sync without polling.
///
/// Lifecycle: started from `PowerWorkBridge.start()` after
/// `BatteryAwareScheduler.shared.start()`.
final class PendingWorkSweeper {
    static let shared = PendingWorkSweeper()
    private var task: Task<Void, Never>?
    private init() {}

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                // Initial delay so we don't sweep on every cold start before
                // the database is fully open.
                try? await Task.sleep(nanoseconds: 60_000_000_000)   // 60 s
                guard !Task.isCancelled else { return }
                await self?.sweep()
            }
        }
        log("PendingWorkSweeper: started")
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    // MARK: - Sweep

    @discardableResult
    func sweep() async -> (recovered: Int, doneGC: Int, deadGC: Int) {
        do {
            let result = try await PendingWorkStorage.shared.runMaintenanceSweep()
            if result.recovered > 0 || result.doneGC > 0 || result.deadGC > 0 {
                log("PendingWorkSweeper: recovered=\(result.recovered) doneGC=\(result.doneGC) deadGC=\(result.deadGC)")
            }
            return result
        } catch {
            logError("PendingWorkSweeper: sweep failed", error: error)
            return (0, 0, 0)
        }
    }
}
