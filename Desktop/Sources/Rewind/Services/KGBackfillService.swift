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
            // Cluster D4: surface the read error loudly. We still proceed
            // (the dedup key + status filter limits blast radius — at worst
            // we re-enqueue rows that already have a live work item, which
            // PendingWorkStorage's UNIQUE dedup index will collapse to a
            // no-op), but a transient DB error must not hide.
            logError("KGBackfillService: WARNING — migration_status read failed; proceeding with backfill anyway. Per-row dedup will absorb duplicates.", error: error)
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
        var capDropped = 0
        var failed = 0
        for id in memoryIds {
            do {
                let payload = try JSONEncoder().encode(PendingPayload(memory_id: id))
                // `enqueue` returns nil for both dedup-hits and cap-drops.
                // We can't distinguish them from the return value alone
                // without breaking the API; instead infer cap-drop by
                // observing `recentDrops` deltas. Simpler: if the result is
                // nil AND no dedup row exists for this memory, count it as
                // cap-drop (this is the case the consensus review wants
                // counted as a failure). If we can't tell, we err on the
                // side of treating nil as success (dedup hit) so an
                // already-enqueued row doesn't re-trigger a re-run.
                let beforeDrops = await PendingWorkStorage.shared.recentDrops
                let rowId = try await PendingWorkStorage.shared.enqueue(
                    workType: Self.workType,
                    payload: payload,
                    dedupKey: Self.dedupKey(forMemoryId: id)
                )
                let afterDrops = await PendingWorkStorage.shared.recentDrops
                if rowId != nil {
                    enqueued += 1
                } else if afterDrops > beforeDrops {
                    // Cap-drop — log loudly so the operator sees it; D1
                    // partial-enqueue path will take over.
                    capDropped += 1
                    log("KGBackfillService: cap-drop for memory \(id) — queue at depth limit")
                } else {
                    // Dedup hit — already-active row exists for this memory.
                    // Treat as already enqueued for the completion check.
                    enqueued += 1
                }
            } catch {
                failed += 1
                logError("KGBackfillService: enqueue failed for memory \(id)", error: error)
            }
        }

        log("KGBackfillService: enqueued \(enqueued)/\(memoryIds.count) extractKG jobs (cap-dropped=\(capDropped), failed=\(failed))")

        // Cluster D1: only mark complete when every eligible row landed in
        // the queue. Otherwise the next launch will retry the misses.
        // Per-row retry / dead-letter is still owned by PendingWorkStorage;
        // this service only owns the all-enqueued invariant.
        if enqueued == memoryIds.count {
            try? await markComplete()
        } else {
            log("KGBackfillService: NOT marking complete — \(memoryIds.count - enqueued) row(s) failed to enqueue; will retry on next launch")
        }
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
