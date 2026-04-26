import Foundation
import GRDB

// MARK: - Errors

/// Errors thrown by `LocalIntegrationOutboxStorage`.
enum LocalIntegrationOutboxStorageError: LocalizedError {
    case databaseNotInitialized

    var errorDescription: String? {
        switch self {
        case .databaseNotInitialized:
            return "LocalIntegrationOutboxStorage: database is not initialized"
        }
    }
}

// MARK: - Mutation delegate (frozen interface)

/// Observes enqueues to the `local_integration_outbox` table so the drain
/// service can react without polling.
///
/// Frozen contract:
/// - Single method, no payload — listener calls back into the storage actor
///   itself to fetch due rows.
/// - Fired AFTER `enqueue`'s transaction commits, on the storage actor's own
///   serial executor (no thread-hop).
/// - NOT fired from `markSuccess`, `markFailure`, `clearAll`, or
///   `deleteOrphans` — those represent drain-side bookkeeping, not new work.
protocol LocalIntegrationOutboxDelegate: AnyObject {
    func outboxDidEnqueue(_ storage: LocalIntegrationOutboxStorage)
}

// MARK: - Record

/// GRDB row record mirroring the `local_integration_outbox` table (see
/// `RewindDatabase.swift` migration `createLocalIntegrationOutbox`).
///
/// Note: `integrationId` is just a `String` — the FK is intentionally NOT
/// enforced at the DB level. The drainer treats orphans as soft-delete (skip
/// + remove via `deleteOrphans`) rather than failing the whole transaction.
struct LocalIntegrationOutboxRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?

    /// References `local_integrations.id` but NOT enforced at the DB level.
    var integrationId: String

    /// For traceability + manual debugging only — payload is already
    /// snapshotted in `payloadJson`.
    var memoryId: String

    /// Payload serialised once at enqueue time so later memory edits don't
    /// change what gets delivered.
    var payloadJson: String

    var attempts: Int

    /// Initially equals `enqueuedAt` so the first drain tick picks it up.
    var nextRetryAt: Date

    var lastError: String?

    var enqueuedAt: Date

    static let databaseTableName = "local_integration_outbox"

    init(
        id: Int64? = nil,
        integrationId: String,
        memoryId: String,
        payloadJson: String,
        attempts: Int = 0,
        nextRetryAt: Date = Date(),
        lastError: String? = nil,
        enqueuedAt: Date = Date()
    ) {
        self.id = id
        self.integrationId = integrationId
        self.memoryId = memoryId
        self.payloadJson = payloadJson
        self.attempts = attempts
        self.nextRetryAt = nextRetryAt
        self.lastError = lastError
        self.enqueuedAt = enqueuedAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - LocalIntegrationOutboxStorage

/// Actor-based persistent queue for local-integration deliveries.
///
/// Every dispatch (first attempt and retries) goes through this table so a
/// crash or a transient failure never loses a memory. Rows are deleted on
/// success and rescheduled with backoff on failure.
///
/// Single in-process consumer model: the drainer simply reads → tries →
/// updates. No claim/ack/lease semantics — that complexity is unnecessary
/// for a single drainer and would add failure modes (lease expiry, retry
/// release) we don't need.
///
/// Mirrors `PendingWorkStorage`'s actor-singleton shape, including the
/// post-commit mutation delegate (`LocalIntegrationOutboxDelegate`).
actor LocalIntegrationOutboxStorage {
    static let shared = LocalIntegrationOutboxStorage()

    private var _dbQueue: DatabasePool?

    /// Mutation observer. Weak so listeners don't extend storage's lifetime.
    weak var delegate: LocalIntegrationOutboxDelegate?

    private init() {}

    // MARK: - Delegate wiring

    /// Set or clear the enqueue delegate. Async because the actor owns the slot.
    func setDelegate(_ delegate: LocalIntegrationOutboxDelegate?) {
        self.delegate = delegate
    }

    /// Fire the post-commit notification. Called from `enqueue` AFTER
    /// `db.write { … }` returns, while still on the actor's serial executor.
    private func notifyDidEnqueue() {
        delegate?.outboxDidEnqueue(self)
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
            log("LocalIntegrationOutboxStorage: DB init failed: \(error.localizedDescription)")
            throw error
        }
        guard let q = await RewindDatabase.shared.getDatabaseQueue() else {
            throw LocalIntegrationOutboxStorageError.databaseNotInitialized
        }
        _dbQueue = q
        return q
    }

    // MARK: - Enqueue

    /// Insert one outbox row with `attempts = 0`, `nextRetryAt = at`,
    /// `enqueuedAt = at` so the first drain tick picks it up immediately.
    ///
    /// Fires `LocalIntegrationOutboxDelegate.outboxDidEnqueue` after the
    /// write commits.
    ///
    /// - Returns: the assigned row id.
    @discardableResult
    func enqueue(
        integrationId: String,
        memoryId: String,
        payloadJson: String,
        at: Date = Date()
    ) async throws -> Int64 {
        let db = try await ensureInitialized()

        let rowId: Int64 = try await db.write { database in
            var record = LocalIntegrationOutboxRecord(
                integrationId: integrationId,
                memoryId: memoryId,
                payloadJson: payloadJson,
                attempts: 0,
                nextRetryAt: at,
                lastError: nil,
                enqueuedAt: at
            )
            try record.insert(database)
            return record.id ?? -1
        }

        log("LocalIntegrationOutboxStorage: enqueued id=\(rowId) integration=\(integrationId) memory=\(memoryId)")
        notifyDidEnqueue()
        return rowId
    }

    // MARK: - Drain reads

    /// Fetch outbox rows whose `nextRetryAt` is at or before `now`, ordered
    /// ascending so the drainer processes the oldest-due first. Limit caps a
    /// single drain tick's batch size.
    func fetchDue(now: Date = Date(), limit: Int = 50) async throws -> [LocalIntegrationOutboxRecord] {
        let db = try await ensureInitialized()
        return try await db.read { database in
            try LocalIntegrationOutboxRecord
                .filter(Column("nextRetryAt") <= now)
                .order(Column("nextRetryAt").asc)
                .limit(limit)
                .fetchAll(database)
        }
    }

    // MARK: - Drain mutators

    /// Delivery succeeded — drop the row.
    func markSuccess(id: Int64) async throws {
        let db = try await ensureInitialized()
        try await db.write { database in
            try database.execute(
                sql: "DELETE FROM local_integration_outbox WHERE id = ?",
                arguments: [id]
            )
        }
        log("LocalIntegrationOutboxStorage: markSuccess id=\(id)")
    }

    /// Delivery failed — increment `attempts`, record `lastError`, and push
    /// `nextRetryAt` forward by the caller-supplied backoff.
    func markFailure(id: Int64, error: String, nextRetryAt: Date) async throws {
        let db = try await ensureInitialized()
        try await db.write { database in
            try database.execute(
                sql: """
                    UPDATE local_integration_outbox
                    SET attempts = attempts + 1,
                        lastError = ?,
                        nextRetryAt = ?
                    WHERE id = ?
                """,
                arguments: [error, nextRetryAt, id]
            )
        }
        log("LocalIntegrationOutboxStorage: markFailure id=\(id) nextRetryAt=\(nextRetryAt)")
    }

    // MARK: - Bookkeeping

    /// Pending row count for one integration. Used by the settings UI to show
    /// a backlog badge.
    func pendingCount(forIntegrationId integrationId: String) async throws -> Int {
        let db = try await ensureInitialized()
        return try await db.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM local_integration_outbox WHERE integrationId = ?",
                arguments: [integrationId]
            ) ?? 0
        }
    }

    /// User-initiated "Retry now": bump every row for this integration to
    /// be due immediately, including rows that were parked at +30 days by
    /// a permanent-failure outcome. Without this, the UI's "Retry now"
    /// button is a no-op for permanently-failed rows.
    @discardableResult
    func resetForRetry(forIntegrationId integrationId: String, at: Date = Date()) async throws -> Int {
        let db = try await ensureInitialized()
        return try await db.write { database in
            try database.execute(
                sql: """
                    UPDATE local_integration_outbox
                    SET nextRetryAt = ?
                    WHERE integrationId = ? AND nextRetryAt > ?
                """,
                arguments: [at, integrationId, at]
            )
            return database.changesCount
        }
    }

    /// Drop every outbox row for one integration. Called when the user
    /// disables or deletes an integration and wants to abandon its backlog.
    func clearAll(forIntegrationId integrationId: String) async throws {
        let db = try await ensureInitialized()
        try await db.write { database in
            try database.execute(
                sql: "DELETE FROM local_integration_outbox WHERE integrationId = ?",
                arguments: [integrationId]
            )
        }
        log("LocalIntegrationOutboxStorage: clearAll integration=\(integrationId)")
    }

    /// Drainer-side orphan sweep: delete any outbox rows whose `integrationId`
    /// is NOT in the supplied set of currently-valid ids. Returns the number
    /// of rows deleted so the drainer can log/metric the sweep.
    @discardableResult
    func deleteOrphans(validIntegrationIds: Set<String>) async throws -> Int {
        let db = try await ensureInitialized()
        return try await db.write { database in
            // Empty set → every row is an orphan; truncate the table.
            if validIntegrationIds.isEmpty {
                try database.execute(sql: "DELETE FROM local_integration_outbox")
                return database.changesCount
            }
            // Build a parameterised IN-list. Set sizes here are bounded by
            // the user's integration count (small) so a single statement is
            // fine.
            let placeholders = Array(repeating: "?", count: validIntegrationIds.count).joined(separator: ", ")
            let sql = "DELETE FROM local_integration_outbox WHERE integrationId NOT IN (\(placeholders))"
            let args = StatementArguments(Array(validIntegrationIds))
            try database.execute(sql: sql, arguments: args)
            return database.changesCount
        }
    }
}
