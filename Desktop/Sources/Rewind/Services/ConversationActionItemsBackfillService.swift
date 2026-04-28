import Foundation
import GRDB

/// Per-session action-item extraction enqueue + launch backfill.
///
/// Mirrors the dedup/payload contract of the other backfill services:
///   workType  : `PendingWork.Kind.extractActionItems.rawValue`
///   payload   : `{"session_id": <Int64>}`
///   dedupKey  : `extractActionItems:<sessionId>`
///
/// Producer-side guard: bail when `transcription_sessions.action_items_extracted_at`
/// is already non-null. Nullable column so a user "clear + re-extract" workflow
/// can re-qualify a session by nulling it out.
actor ConversationActionItemsBackfillService {
    static let shared = ConversationActionItemsBackfillService()

    private static let workType: String = PendingWork.Kind.extractActionItems.rawValue
    private static let dedupPrefix: String = "extractActionItems:"

    private init() {}

    struct PendingPayload: Codable {
        let session_id: Int64
    }

    static func dedupKey(for sessionId: Int64) -> String {
        return "\(Self.dedupPrefix)\(sessionId)"
    }

    /// Durably enqueue a single session for `.extractActionItems` work.
    /// Idempotent — repeat calls collapse via the dedup key. Bails when the
    /// session already has a non-null `action_items_extracted_at`.
    func enqueueActionItemsIfNeeded(sessionId: Int64, reason: String) async {
        do {
            if try await sessionAlreadyExtracted(sessionId: sessionId) {
                log("ConversationActionItemsBackfillService: session \(sessionId) already extracted, skipping enqueue (\(reason))")
                return
            }
        } catch {
            logError("ConversationActionItemsBackfillService: extracted-check failed for session \(sessionId) (\(reason))", error: error)
            return
        }

        let payload: Data
        do {
            payload = try JSONEncoder().encode(PendingPayload(session_id: sessionId))
        } catch {
            logError("ConversationActionItemsBackfillService: failed to encode payload for session \(sessionId)", error: error)
            return
        }

        do {
            _ = try await PendingWorkStorage.shared.enqueue(
                workType: Self.workType,
                payload: payload,
                dedupKey: Self.dedupKey(for: sessionId)
            )
            log("ConversationActionItemsBackfillService: enqueued extractActionItems for session \(sessionId) (\(reason))")
        } catch {
            logError("ConversationActionItemsBackfillService: enqueue failed for session \(sessionId) (\(reason))", error: error)
        }
    }

    /// Walks finished, non-deleted sessions that have transcript segments and
    /// no `action_items_extracted_at` yet, and enqueues each. Idempotent —
    /// re-running is a no-op once the queue has caught up.
    func enqueueHistoricalActionItemsIfNeeded(reason: String) async {
        do {
            let sessionIds = try await fetchEligibleSessionIds()
            guard !sessionIds.isEmpty else {
                log("ConversationActionItemsBackfillService: no historical extractions needed (\(reason))")
                return
            }
            log("ConversationActionItemsBackfillService: enqueuing \(sessionIds.count) historical extractActionItems job(s) (\(reason))")
            for id in sessionIds {
                await enqueueActionItemsIfNeeded(sessionId: id, reason: "historical:\(reason)")
            }
        } catch {
            logError("ConversationActionItemsBackfillService: enqueueHistoricalActionItemsIfNeeded failed (\(reason))", error: error)
        }
    }

    /// Mark a session's action_items_extracted_at = now. Called by the handler
    /// after a successful extraction (including the empty-result and
    /// short-transcript paths so the row doesn't re-qualify on next launch).
    func markSessionExtracted(sessionId: Int64) async throws {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw TranscriptionStorageError.databaseNotInitialized
        }
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE transcription_sessions
                       SET action_items_extracted_at = ?
                     WHERE id = ?
                    """,
                arguments: [Date(), sessionId]
            )
        }
    }

    private func sessionAlreadyExtracted(sessionId: Int64) async throws -> Bool {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw TranscriptionStorageError.databaseNotInitialized
        }
        return try await dbQueue.read { db -> Bool in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT action_items_extracted_at IS NOT NULL
                      FROM transcription_sessions
                     WHERE id = ?
                    """,
                arguments: [sessionId]
            ) ?? false
        }
    }

    private func fetchEligibleSessionIds() async throws -> [Int64] {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw TranscriptionStorageError.databaseNotInitialized
        }

        // Excludes active rows (queued/claimed) AND `done` rows for this dedup
        // key so a successful drain doesn't re-qualify on every launch.
        // `failed` rows are intentionally INCLUDED so launch backfill retries
        // permanently-failed sessions.
        let sql = """
            SELECT s.id FROM transcription_sessions AS s
             WHERE s.finishedAt IS NOT NULL
               AND s.deleted = 0
               AND s.action_items_extracted_at IS NULL
               AND EXISTS (
                   SELECT 1 FROM transcription_segments seg
                    WHERE seg.sessionId = s.id
                      AND seg.text IS NOT NULL
                      AND TRIM(seg.text) <> ''
               )
               AND NOT EXISTS (
                   SELECT 1 FROM pending_work pw
                    WHERE pw.workType = 'extractActionItems'
                      AND pw.status IN ('queued', 'claimed', 'done')
                      AND pw.dedupKey = '\(Self.dedupPrefix)' || s.id
               )
             ORDER BY s.finishedAt DESC
            """

        return try await dbQueue.read { db in
            try Int64.fetchAll(db, sql: sql)
        }
    }
}
