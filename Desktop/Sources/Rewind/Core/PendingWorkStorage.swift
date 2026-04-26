import Foundation
import GRDB

// MARK: - Errors

enum PendingWorkStorageError: LocalizedError {
    case databaseNotInitialized
    case payloadTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .databaseNotInitialized:
            return "PendingWorkStorage: database is not initialized"
        case .payloadTooLarge(let size):
            return "PendingWorkStorage: payload \(size) bytes exceeds 64 KB cap"
        }
    }
}

// MARK: - Mutation delegate (frozen interface I3)

/// Observes mutations to the `pending_work` table so listeners (e.g.
/// `BatteryAwareScheduler`) can push fresh depth snapshots to the Rust
/// daemon without polling.
///
/// Frozen contract:
/// - Single method, no payload — listener calls `storage.depthSummary()` itself.
/// - Fired AFTER each mutator's transaction commits, on the storage actor's
///   own serial executor (no thread-hop).
/// - NOT fired from read-only methods (`depthSummary`, `pendingCount`,
///   `healthCounts`).
protocol PendingWorkStorageDelegate: AnyObject {
    func pendingWorkStorageDidMutate(_ storage: PendingWorkStorage)
}

// MARK: - Depth summary

struct PendingWorkDepth {
    var queued:  [String: Int] = [:]
    var claimed: [String: Int] = [:]
    var failed:  [String: Int] = [:]
    var dead:    [String: Int] = [:]
    var oldestQueuedAt: Date?
}

// MARK: - PendingWorkStorage

/// Actor-based CRUD layer for the `pending_work` table.
///
/// Design constraints (from design doc §3.5):
/// - Single consumer process (the Swift app). One drain at a time is enforced
///   by `BatteryAwareScheduler.isDraining`.
/// - Atomic claim via UPDATE … WHERE id = (SELECT … LIMIT 1) … RETURNING inside
///   one `dbQueue.write` — correct even for future multi-worker use.
/// - `RETURNING` requires SQLite 3.35+; macOS 14 ships 3.43+.
///
/// NOTE: This is the persistent deferred-work queue. It is completely unrelated
/// to per-assistant `clearPendingWork()` methods (`FocusAssistant`,
/// `MemoryAssistant`, `AssistantCoordinator`) — those clear transient in-flight
/// ML tasks under memory pressure and live entirely in memory.
actor PendingWorkStorage {
    static let shared = PendingWorkStorage()

    private var _dbQueue: DatabasePool?

    // Per-kind depth caps (drop-newest when exceeded).
    private let depthCaps: [String: Int] = [
        PendingWork.Kind.transcribe.rawValue:         5_000,
        PendingWork.Kind.ocr.rawValue:               50_000,
    ]
    private let defaultDepthCap = 10_000
    private let maxPayloadBytes = 64 * 1024   // 64 KB

    // In-memory drop counter exposed via depthSummary (last-hour precision not required).
    private(set) var recentDrops: Int = 0

    // Mutation observer (interface I3). Weak so listeners don't extend storage's lifetime.
    weak var delegate: PendingWorkStorageDelegate?

    private init() {}

    // MARK: - Delegate wiring

    /// Set or clear the mutation delegate. Async because the actor owns the slot.
    func setDelegate(_ delegate: PendingWorkStorageDelegate?) {
        self.delegate = delegate
    }

    /// Fire the post-commit notification. Called from every mutator AFTER
    /// `db.write { … }` returns, while still on the actor's serial executor.
    private func notifyDidMutate() {
        delegate?.pendingWorkStorageDidMutate(self)
    }

    // MARK: - Cache management

    func invalidateCache() {
        _dbQueue = nil
    }

    private func ensureInitialized() async throws -> DatabasePool {
        if let q = _dbQueue { return q }
        do {
            try await RewindDatabase.shared.initialize()
        } catch {
            log("PendingWorkStorage: DB init failed: \(error.localizedDescription)")
            throw error
        }
        guard let q = await RewindDatabase.shared.getDatabaseQueue() else {
            throw PendingWorkStorageError.databaseNotInitialized
        }
        _dbQueue = q
        return q
    }

    // MARK: - Enqueue

    /// Insert a new work item, returning the assigned row id.
    ///
    /// - Returns: row id, or nil if the item was a no-op dedup or cap-drop.
    @discardableResult
    func enqueue(
        workType: String,
        payload: Data,
        dedupKey: String? = nil,
        scheduledFor: Date = Date()
    ) async throws -> Int64? {

        // Payload size cap (§5.6)
        guard payload.count <= maxPayloadBytes else {
            log("PendingWorkStorage: payload \(payload.count)B exceeds 64 KB cap for \(workType), dropping")
            throw PendingWorkStorageError.payloadTooLarge(payload.count)
        }

        let db = try await ensureInitialized()

        // Result: (rowId, wasCapped)
        let (rowId, wasCapped) = try await db.write { database -> (Int64?, Bool) in

            // Depth cap check (§5.2): count active rows for this kind.
            let cap = self.depthCaps[workType] ?? self.defaultDepthCap
            let currentDepth = try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM pending_work
                WHERE workType = ? AND status IN ('queued', 'claimed', 'failed')
            """, arguments: [workType]) ?? 0

            if currentDepth >= cap {
                log("PendingWorkStorage: \(workType) queue at cap (\(currentDepth)), dropping new item")
                return (nil, true)
            }

            let now = Date()
            var record = PendingWorkRecord(
                workType: workType,
                payload: payload,
                status: PendingWorkStatus.queued.rawValue,
                scheduledFor: scheduledFor,
                dedupKey: dedupKey,
                createdAt: now,
                updatedAt: now
            )

            do {
                try record.insert(database)
                log("PendingWorkStorage: enqueued \(workType) id=\(record.id ?? -1) dedup=\(dedupKey ?? "nil")")
                return (record.id, false)
            } catch let dbError as DatabaseError
                where dbError.resultCode == .SQLITE_CONSTRAINT {
                // Dedup index fired — already active in queue, no-op.
                log("PendingWorkStorage: dedup hit for \(workType) key=\(dedupKey ?? "?"), skipping")
                return (nil, false)
            }
        }

        // Update drop counter on actor-isolated side (after write closure returns).
        if wasCapped { recentDrops += 1 }
        notifyDidMutate()
        return rowId
    }

    // MARK: - Claim (atomic)

    /// Atomically claim the next claimable item.
    ///
    /// Uses a single write transaction with UPDATE…WHERE id=(SELECT…LIMIT 1)…RETURNING
    /// so the claim is serialised through SQLite's single writer.
    ///
    /// - Returns: The claimed `PendingWork` value, or nil when the queue is
    ///   empty / all rows are future-scheduled.
    func claimNext(claimedBy: String) async throws -> PendingWork? {
        let db = try await ensureInitialized()
        let now = Date()

        let result: PendingWork? = try await db.write { database -> PendingWork? in
            let rows = try Row.fetchAll(database, sql: """
                UPDATE pending_work
                SET status = 'claimed',
                    claimedAt = ?,
                    claimedBy = ?,
                    leaseExpiresAt = datetime(?, '+10 minutes'),
                    updatedAt = ?
                WHERE id = (
                    SELECT id FROM pending_work
                    WHERE status IN ('queued', 'failed')
                      AND scheduledFor <= ?
                    ORDER BY scheduledFor ASC, id ASC
                    LIMIT 1
                )
                RETURNING id, workType, payload, attempts, maxAttempts, createdAt
            """, arguments: [now, claimedBy, now, now, now])

            guard let row = rows.first else { return nil }
            let rowId: Int64 = row["id"] ?? 0
            let workType: String = row["workType"] ?? ""
            let payload: Data = row["payload"] ?? Data()
            let createdAt: Date = row["createdAt"] ?? Date()

            guard let kind = PendingWork.Kind(rawValue: workType) else {
                log("PendingWorkStorage: unknown workType '\(workType)' in claimed row \(rowId), skipping")
                return nil
            }

            log("PendingWorkStorage: claimed \(workType) id=\(rowId)")
            return PendingWork(
                kind: kind,
                payload: payload,
                queuedAt: createdAt,
                storageId: rowId
            )
        }
        notifyDidMutate()
        return result
    }

    // MARK: - Ack

    /// Mark a successfully completed item as done.
    func ack(storageId: Int64) async throws {
        let db = try await ensureInitialized()
        try await db.write { database in
            try database.execute(sql: """
                UPDATE pending_work
                SET status = 'done', updatedAt = ?
                WHERE id = ?
            """, arguments: [Date(), storageId])
        }
        log("PendingWorkStorage: ack id=\(storageId)")
        notifyDidMutate()
    }

    // MARK: - Release claim (readiness loss)

    /// Release a previously-claimed item back to `queued` WITHOUT counting an
    /// attempt and WITHOUT bumping the exponential backoff. Used when readiness
    /// (e.g. autonomous-AI gate) is lost AFTER claiming a row but BEFORE the
    /// handler ran — semantically the item never failed, so it shouldn't burn
    /// an attempt or be subject to per-failure backoff.
    ///
    /// Reschedules `scheduledFor` 30 s in the future so we don't immediately
    /// re-claim it on the very next loop tick.
    public func releaseClaim(storageId: Int64) async throws {
        let db = try await ensureInitialized()
        let now = Date()
        let later = now.addingTimeInterval(30)
        try await db.write { database in
            try database.execute(sql: """
                UPDATE pending_work
                SET status        = 'queued',
                    claimedAt     = NULL,
                    claimedBy     = NULL,
                    leaseExpiresAt = NULL,
                    scheduledFor  = ?,
                    updatedAt     = ?
                WHERE id = ? AND status = 'claimed'
            """, arguments: [later, now, storageId])
        }
        log("PendingWorkStorage: released claim id=\(storageId) (no attempt counted)")
        notifyDidMutate()
    }

    // MARK: - Dead-letter callback

    /// Optional callback invoked from `fail()` when an item transitions to
    /// `dead`. Wired up by `PowerWorkBridge.start()` to write a "Summary
    /// Unavailable" placeholder for `.summarize` work whose attempts are
    /// exhausted, so the UI doesn't render an indefinitely-pending row.
    ///
    /// Sendable so it can be invoked across actor boundaries from inside the
    /// `fail()` hot path.
    public var deadLetterCallback: (@Sendable (_ workType: String, _ payload: Data) async -> Void)?

    public func setDeadLetterCallback(_ cb: (@Sendable (_ workType: String, _ payload: Data) async -> Void)?) {
        self.deadLetterCallback = cb
    }

    // MARK: - Fail

    /// Record a handler failure. Transitions to `failed` (with backoff) or `dead`
    /// when `maxAttempts` is exhausted.
    func fail(storageId: Int64, error: Error) async throws {
        let db = try await ensureInitialized()
        let errorMsg = String(error.localizedDescription.prefix(2048))
        let now = Date()

        // Fetch current attempts + maxAttempts + workType + payload so we can
        // notify the dead-letter callback if this transition lands in `dead`.
        let (attempts, maxAttempts, workType, payload): (Int, Int, String, Data) = try await db.read { database in
            guard let row = try Row.fetchOne(database, sql: """
                SELECT attempts, maxAttempts, workType, payload FROM pending_work WHERE id = ?
            """, arguments: [storageId]) else {
                return (0, 8, "", Data())
            }
            return (
                row["attempts"] ?? 0,
                row["maxAttempts"] ?? 8,
                row["workType"] ?? "",
                row["payload"] ?? Data()
            )
        }

        let newAttempts = attempts + 1
        let newStatus = newAttempts >= maxAttempts
            ? PendingWorkStatus.dead.rawValue
            : PendingWorkStatus.failed.rawValue

        // Exponential backoff with ±20% jitter, base 30s, cap 1h.
        let backoffSeconds: Double = {
            if newAttempts >= maxAttempts { return 0 }   // dead — don't schedule
            let base: Double = 30
            let cap: Double  = 3600
            let exp = base * pow(2.0, Double(attempts))
            let capped = min(exp, cap)
            let jitter = capped * Double.random(in: -0.2...0.2)
            return capped + jitter
        }()

        let scheduledFor = newAttempts >= maxAttempts
            ? now
            : now.addingTimeInterval(backoffSeconds)

        try await db.write { database in
            try database.execute(sql: """
                UPDATE pending_work
                SET status        = ?,
                    attempts      = ?,
                    lastError     = ?,
                    claimedAt     = NULL,
                    claimedBy     = NULL,
                    leaseExpiresAt = NULL,
                    scheduledFor  = ?,
                    updatedAt     = ?
                WHERE id = ?
            """, arguments: [newStatus, newAttempts, errorMsg, scheduledFor, now, storageId])
        }

        // Fire delegate exactly once per fail() call, regardless of whether
        // this transition lands in `failed` or `dead`.
        notifyDidMutate()

        if newStatus == PendingWorkStatus.dead.rawValue {
            log("PendingWorkStorage: dead-lettered id=\(storageId) after \(newAttempts) attempts")
            // Fire the dead-letter callback after the SQL transition completes.
            // PowerWorkBridge wires this up to write a "Summary Unavailable"
            // placeholder for .summarize work and post a list-refresh notification.
            if let cb = self.deadLetterCallback, !workType.isEmpty {
                await cb(workType, payload)
            }
        } else {
            log("PendingWorkStorage: fail id=\(storageId) attempt \(newAttempts)/\(maxAttempts), retry in \(Int(backoffSeconds))s")
        }
    }

    // MARK: - Depth summary

    func depthSummary() async throws -> PendingWorkDepth {
        let db = try await ensureInitialized()
        return try await db.read { database in
            var summary = PendingWorkDepth()

            let rows = try Row.fetchAll(database, sql: """
                SELECT status, workType, COUNT(*) AS cnt
                FROM pending_work
                GROUP BY status, workType
            """)
            for row in rows {
                let status: String  = row["status"]  ?? ""
                let type: String    = row["workType"] ?? ""
                let count: Int      = row["cnt"]      ?? 0
                switch status {
                case "queued":  summary.queued[type]  = (summary.queued[type]  ?? 0) + count
                case "claimed": summary.claimed[type] = (summary.claimed[type] ?? 0) + count
                case "failed":  summary.failed[type]  = (summary.failed[type]  ?? 0) + count
                case "dead":    summary.dead[type]    = (summary.dead[type]    ?? 0) + count
                default: break
                }
            }

            if let row = try Row.fetchOne(database, sql: """
                SELECT MIN(scheduledFor) AS oldest FROM pending_work
                WHERE status = 'queued'
            """) {
                summary.oldestQueuedAt = row["oldest"]
            }
            return summary
        }
    }

    // MARK: - Count for published badge

    /// Fast count of actionable rows (queued + failed). Used by the 5s poll timer.
    func pendingCount() async -> Int {
        guard let db = try? await ensureInitialized() else { return 0 }
        return (try? await db.read { database in
            try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM pending_work
                WHERE status IN ('queued', 'failed')
            """) ?? 0
        }) ?? 0
    }

    // MARK: - Health query (used by Rust health endpoint via SQLite read-only)

    /// Returns (queued, claimed, failed, dead, oldestQueuedSeconds).
    /// Called by the Rust `/v1/health` handler over a separate read-only pool.
    func healthCounts() async throws -> (queued: Int, claimed: Int, failed: Int, dead: Int, oldestQueuedSeconds: Double?) {
        let db = try await ensureInitialized()
        return try await db.read { database in
            let rows = try Row.fetchAll(database, sql: """
                SELECT status, COUNT(*) AS cnt FROM pending_work GROUP BY status
            """)
            var q = 0, c = 0, f = 0, d = 0
            for row in rows {
                let s: String = row["status"] ?? ""
                let n: Int    = row["cnt"]    ?? 0
                switch s {
                case "queued":  q = n
                case "claimed": c = n
                case "failed":  f = n
                case "dead":    d = n
                default: break
                }
            }
            var oldest: Double? = nil
            if let row = try Row.fetchOne(database, sql: """
                SELECT MIN(scheduledFor) AS ts FROM pending_work WHERE status = 'queued'
            """), let ts: Date = row["ts"] {
                oldest = -ts.timeIntervalSinceNow
            }
            return (q, c, f, d, oldest)
        }
    }
}
