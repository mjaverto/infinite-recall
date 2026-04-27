import Foundation
import GRDB

/// Per-session transcribe enqueue + launch backfill.
///
/// Mirrors the dedup/payload contract of `ConversationSummaryBackfillService`:
///   workType  : `PendingWork.Kind.transcribe.rawValue`
///   payload   : `{"session_id": <Int64>}`
///   dedupKey  : `transcribe:<sessionId>`
///
/// The other transcribe producer in the codebase (`TranscriptionService`'s
/// deferred-window path) emits a window-shaped payload with `started_at`/
/// `ended_at`. The shared `.transcribe` handler in `PowerWorkBridge`
/// dispatches on payload shape, so both producers coexist on one workType
/// without forking the queue.
actor ConversationTranscribeBackfillService {
    static let shared = ConversationTranscribeBackfillService()

    private static let workType: String = PendingWork.Kind.transcribe.rawValue
    private static let dedupPrefix: String = "transcribe:"

    private init() {}

    struct PendingPayload: Codable {
        let session_id: Int64
    }

    static func dedupKey(for sessionId: Int64) -> String {
        return "\(Self.dedupPrefix)\(sessionId)"
    }

    /// Durably enqueue a single session for `.transcribe` work. Idempotent —
    /// repeat calls collapse via the dedup key.
    ///
    /// Bails when the session already has at least one non-empty segment:
    /// `transcription_segments` has no uniqueness constraint, so re-running
    /// the per-chunk Whisper pass on a happy-path session would double the
    /// segment rows. The handler enforces the same invariant defense-in-depth.
    func enqueueTranscribeIfNeeded(sessionId: Int64, reason: String) async {
        do {
            if try await sessionHasSegments(sessionId: sessionId) {
                log("ConversationTranscribeBackfillService: session \(sessionId) already has segments, skipping enqueue (\(reason))")
                return
            }
        } catch {
            logError("ConversationTranscribeBackfillService: segment-count check failed for session \(sessionId) (\(reason))", error: error)
            return
        }

        let payload: Data
        do {
            payload = try JSONEncoder().encode(PendingPayload(session_id: sessionId))
        } catch {
            logError("ConversationTranscribeBackfillService: failed to encode payload for session \(sessionId)", error: error)
            return
        }

        do {
            _ = try await PendingWorkStorage.shared.enqueue(
                workType: Self.workType,
                payload: payload,
                dedupKey: Self.dedupKey(for: sessionId)
            )
            log("ConversationTranscribeBackfillService: enqueued transcribe for session \(sessionId) (\(reason))")
        } catch {
            logError("ConversationTranscribeBackfillService: enqueue failed for session \(sessionId) (\(reason))", error: error)
        }
    }

    /// Walks finished, non-deleted, non-empty-audio sessions that have no
    /// transcript segments and no active `.transcribe` row keyed to the
    /// session, then enqueues each. Idempotent — re-running is a no-op once
    /// the queue has caught up.
    func enqueueHistoricalTranscribesIfNeeded(reason: String) async {
        do {
            let sessionIds = try await fetchEligibleSessionIds()
            guard !sessionIds.isEmpty else {
                log("ConversationTranscribeBackfillService: no historical transcribes needed (\(reason))")
                return
            }
            log("ConversationTranscribeBackfillService: enqueuing \(sessionIds.count) historical transcribe job(s) (\(reason))")
            for id in sessionIds {
                await enqueueTranscribeIfNeeded(sessionId: id, reason: "historical:\(reason)")
            }
        } catch {
            logError("ConversationTranscribeBackfillService: enqueueHistoricalTranscribesIfNeeded failed (\(reason))", error: error)
        }
    }

    private func sessionHasSegments(sessionId: Int64) async throws -> Bool {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw TranscriptionStorageError.databaseNotInitialized
        }
        let count = try await dbQueue.read { db -> Int in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM transcription_segments
                     WHERE sessionId = ?
                       AND text IS NOT NULL
                       AND TRIM(text) <> ''
                    """,
                arguments: [sessionId]
            ) ?? 0
        }
        return count > 0
    }

    private func fetchEligibleSessionIds() async throws -> [Int64] {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw TranscriptionStorageError.databaseNotInitialized
        }

        // Excludes active rows (queued/claimed) AND `done` rows for this
        // dedup key so a successful drain that wrote zero segments doesn't
        // re-qualify on every launch. `failed` rows are intentionally
        // INCLUDED so launch backfill retries permanently-failed sessions.
        let sql = """
            SELECT s.id FROM transcription_sessions AS s
             WHERE s.finishedAt IS NOT NULL
               AND s.deleted = 0
               AND NOT EXISTS (
                   SELECT 1 FROM transcription_segments seg
                    WHERE seg.sessionId = s.id
                      AND seg.text IS NOT NULL
                      AND TRIM(seg.text) <> ''
               )
               AND EXISTS (
                   SELECT 1 FROM audio_chunks ac
                    WHERE ac.transcriptionSessionId = s.id
                      AND LENGTH(ac.pcm) > 0
               )
               AND NOT EXISTS (
                   SELECT 1 FROM pending_work pw
                    WHERE pw.workType = 'transcribe'
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
