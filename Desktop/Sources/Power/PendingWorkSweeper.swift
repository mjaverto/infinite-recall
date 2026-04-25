import Foundation
import GRDB

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
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            return (0, 0, 0)
        }
        let now = Date()

        do {
            return try await dbQueue.write { db -> (Int, Int, Int) in
                // 1. Reclaim expired leases.
                let reclaimed = try db.execute(sql: """
                    UPDATE pending_work
                    SET status = CASE
                            WHEN attempts + 1 >= maxAttempts THEN 'dead'
                            ELSE 'queued'
                        END,
                        attempts      = attempts + 1,
                        lastError     = COALESCE(lastError || ' ', '') || '[lease expired]',
                        claimedAt     = NULL,
                        claimedBy     = NULL,
                        leaseExpiresAt = NULL,
                        scheduledFor  = datetime(?, '+30 seconds'),
                        updatedAt     = ?
                    WHERE status = 'claimed'
                      AND leaseExpiresAt < ?
                """, arguments: [now, now, now])
                let recoveredCount = db.changesCount

                // 2. GC done rows > 24 h old.
                try db.execute(sql: """
                    DELETE FROM pending_work
                    WHERE status = 'done'
                      AND updatedAt < datetime(?, '-1 day')
                """, arguments: [now])
                let doneGCCount = db.changesCount

                // 3. GC dead rows > 30 days old.
                try db.execute(sql: """
                    DELETE FROM pending_work
                    WHERE status = 'dead'
                      AND updatedAt < datetime(?, '-30 days')
                """, arguments: [now])
                let deadGCCount = db.changesCount

                if recoveredCount > 0 || doneGCCount > 0 || deadGCCount > 0 {
                    log("PendingWorkSweeper: recovered=\(recoveredCount) doneGC=\(doneGCCount) deadGC=\(deadGCCount)")
                }

                return (recoveredCount, doneGCCount, deadGCCount)
            }
        } catch {
            logError("PendingWorkSweeper: sweep failed", error: error)
            return (0, 0, 0)
        }
    }
}
