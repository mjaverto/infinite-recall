import Foundation
import GRDB

/// One-shot backfill that walks every existing local memory and enqueues an
/// `.extractKG` work item for it via `PendingWorkStorage`. The actual
/// extraction is performed lazily by the scheduler's `.extractKG` handler;
/// this service only seeds the queue.
///
/// Idempotency is gated by the `migration_status` row keyed
/// `kg_backfill_v1`. Repeat calls after success are no-ops.
///
/// Pattern mirrors `ConversationSummaryBackfillService` (PendingWorkStorage
/// enqueue + dedup key) rather than the inline-loop approach of
/// `EmbeddingBackfillService`.
actor KGBackfillService {
    static let shared = KGBackfillService()

    /// migration_status row key for this backfill.
    static let migrationKey = "kg_backfill_v1"

    /// Pending-work `workType` string. Must match
    /// `PendingWork.Kind.extractKG.rawValue` and is shared with the handler
    /// in `PowerWorkBridge`.
    private static let workType: String = PendingWork.Kind.extractKG.rawValue

    /// JSON wire format for `.extractKG` payload rows.
    /// Matches the contract used by `PowerWorkBridge.handleExtractKG`.
    private struct PendingPayload: Codable {
        let memory_id: Int64
    }

    /// Dedup key — colon-style, matches `summarize:<id>`.
    static func dedupKey(forMemoryId memoryId: Int64) -> String {
        return "extractKG:\(memoryId)"
    }

    private init() {}

    // MARK: - Public API

    /// One-time historical backfill. Idempotent — second call no-ops.
    /// Called from `AppDelegate` (or whichever boot site invokes
    /// `PowerWorkBridge.shared.start()`) after the scheduler is up.
    func runIfNeeded() async {
        do {
            if try await isComplete() {
                log("KGBackfillService: already complete (\(Self.migrationKey)), skipping")
                return
            }
        } catch {
            logError("KGBackfillService: failed to check migration_status; will attempt anyway", error: error)
        }

        do {
            try await markStarted()
        } catch {
            logError("KGBackfillService: failed to record migration start row", error: error)
        }

        let memoryIds: [Int64]
        do {
            memoryIds = try await fetchEligibleMemoryIds()
        } catch {
            logError("KGBackfillService: failed to fetch eligible memories; will retry next launch", error: error)
            return
        }

        guard !memoryIds.isEmpty else {
            log("KGBackfillService: no memories to backfill — marking complete")
            try? await markComplete()
            return
        }

        log("KGBackfillService: enqueueing \(memoryIds.count) memory(ies) for KG extraction")
        var enqueued = 0
        for id in memoryIds {
            do {
                let payload = try JSONEncoder().encode(PendingPayload(memory_id: id))
                _ = try await PendingWorkStorage.shared.enqueue(
                    workType: Self.workType,
                    payload: payload,
                    dedupKey: Self.dedupKey(forMemoryId: id)
                )
                enqueued += 1
            } catch {
                logError("KGBackfillService: enqueue failed for memory \(id)", error: error)
            }
        }

        log("KGBackfillService: enqueued \(enqueued)/\(memoryIds.count) extractKG jobs")

        // Mark complete: the migration is "all eligible memories enqueued".
        // Per-row retry / dead-letter is owned by PendingWorkStorage; this
        // service shouldn't loop on outcomes.
        try? await markComplete()
    }

    /// Durable enqueue for a single memory id. Used by the live insert path
    /// in the proactive assistants and the server-sync path. Idempotent via
    /// the dedup key.
    func enqueueExtractKG(memoryId: Int64, reason: String) async {
        // Skip the onboarding sentinel — it represents a bulk write, not a
        // single memory, and shouldn't generate a per-memory work item.
        guard memoryId != ONBOARDING_SENTINEL else { return }
        do {
            let payload = try JSONEncoder().encode(PendingPayload(memory_id: memoryId))
            _ = try await PendingWorkStorage.shared.enqueue(
                workType: Self.workType,
                payload: payload,
                dedupKey: Self.dedupKey(forMemoryId: memoryId)
            )
            log("KGBackfillService: enqueued extractKG for memory \(memoryId) (\(reason))")
        } catch {
            logError("KGBackfillService: enqueue failed for memory \(memoryId) (\(reason))", error: error)
        }
    }

    // MARK: - migration_status helpers

    private func isComplete() async throws -> Bool {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return false }
        return try await dbQueue.read { db in
            let completed = try Int.fetchOne(
                db,
                sql: "SELECT completed FROM migration_status WHERE name = ?",
                arguments: [Self.migrationKey]
            ) ?? 0
            return completed == 1
        }
    }

    private func markStarted() async throws {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return }
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO migration_status (name, completed, startedAt)
                VALUES (?, 0, datetime('now'))
            """, arguments: [Self.migrationKey])
        }
    }

    private func markComplete() async throws {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return }
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO migration_status (name, completed, startedAt, completedAt)
                VALUES (?, 1,
                    COALESCE((SELECT startedAt FROM migration_status WHERE name = ?), datetime('now')),
                    datetime('now'))
            """, arguments: [Self.migrationKey, Self.migrationKey])
        }
    }

    // MARK: - DB walks

    /// Memories eligible for KG backfill: not deleted, no extraction status
    /// yet (NULL), and id > 0 (excludes the onboarding sentinel).
    private func fetchEligibleMemoryIds() async throws -> [Int64] {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return [] }
        return try await dbQueue.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT id FROM memories
                    WHERE deleted = 0
                      AND kg_extraction_status IS NULL
                      AND id > 0
                    ORDER BY createdAt DESC
                """
            )
        }
    }
}
