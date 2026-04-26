import Foundation
import GRDB

/// Actor-based storage manager for transcription sessions and segments
/// Provides crash-safe persistence for transcription data during recording
actor TranscriptionStorage {
    static let shared = TranscriptionStorage()

    private var _dbQueue: DatabasePool?
    private var isInitialized = false

    private init() {}

    /// Invalidate cached DB queue (called on user switch / sign-out)
    func invalidateCache() {
        _dbQueue = nil
        isInitialized = false
    }

    /// Ensure database is initialized before use
    private func ensureInitialized() async throws -> DatabasePool {
        if let db = _dbQueue {
            return db
        }

        // Initialize RewindDatabase which creates our tables via migrations
        do {
            try await RewindDatabase.shared.initialize()
        } catch {
            log("TranscriptionStorage: Database initialization failed: \(error.localizedDescription)")
            throw error
        }

        guard let db = await RewindDatabase.shared.getDatabaseQueue() else {
            throw TranscriptionStorageError.databaseNotInitialized
        }

        _dbQueue = db
        isInitialized = true
        return db
    }

    // MARK: - Session Lifecycle

    /// Start a new transcription session
    /// - Returns: The new session's ID
    @discardableResult
    func startSession(
        source: String,
        language: String = "en",
        timezone: String = "UTC",
        inputDeviceName: String? = nil
    ) async throws -> Int64 {
        let db = try await ensureInitialized()

        let session = TranscriptionSessionRecord(
            startedAt: Date(),
            source: source,
            language: language,
            timezone: timezone,
            inputDeviceName: inputDeviceName,
            status: .recording
        )

        let record = try await db.write { database in
            try session.inserted(database)
        }

        log("TranscriptionStorage: Started session \(record.id ?? -1) (source: \(source), device: \(inputDeviceName ?? "unknown"))")
        return record.id!
    }

    /// Mark session as finished (recording complete, ready for upload)
    func finishSession(id: Int64) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            guard var record = try TranscriptionSessionRecord.fetchOne(database, key: id) else {
                throw TranscriptionStorageError.sessionNotFound
            }

            let now = Date()
            record.finishedAt = now
            // Local-first fork: there is no remote upload/processing backend.
            // A finished recording is complete locally and ready for summary generation.
            record.status = .completed
            record.conversationStatus = .completed
            record.updatedAt = now
            try record.update(database)
        }

        log("TranscriptionStorage: Finished session \(id)")
    }

    /// Mark session as pending upload
    func markSessionPendingUpload(id: Int64) async throws {
        try await updateSessionStatus(id: id, status: .pendingUpload)
    }

    /// Mark session as currently uploading
    func markSessionUploading(id: Int64) async throws {
        try await updateSessionStatus(id: id, status: .uploading)
    }

    /// Mark session as completed (uploaded successfully)
    func markSessionCompleted(id: Int64, backendId: String) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            guard var record = try TranscriptionSessionRecord.fetchOne(database, key: id) else {
                throw TranscriptionStorageError.sessionNotFound
            }

            record.status = .completed
            record.conversationStatus = .completed
            record.backendId = backendId
            record.backendSynced = true
            record.updatedAt = Date()
            try record.update(database)
        }

        log("TranscriptionStorage: Completed session \(id) (backendId: \(backendId))")
    }

    /// Mark session as failed with error.
    /// No-op if the session is already completed (prevents race with concurrent completion).
    func markSessionFailed(id: Int64, error: String) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            guard var record = try TranscriptionSessionRecord.fetchOne(database, key: id) else {
                throw TranscriptionStorageError.sessionNotFound
            }

            // Don't regress a completed session back to failed
            guard record.status != .completed else {
                log("TranscriptionStorage: Skipping markSessionFailed for already-completed session \(id)")
                return
            }

            record.status = .failed
            record.lastError = error
            record.updatedAt = Date()
            try record.update(database)
        }

        log("TranscriptionStorage: Failed session \(id) (error: \(error))")
    }

    /// Increment retry count for a session.
    /// No-op if the session is already completed (prevents race with concurrent completion).
    func incrementRetryCount(id: Int64) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            guard var record = try TranscriptionSessionRecord.fetchOne(database, key: id) else {
                throw TranscriptionStorageError.sessionNotFound
            }

            // Don't modify a completed session
            guard record.status != .completed else {
                log("TranscriptionStorage: Skipping incrementRetryCount for already-completed session \(id)")
                return
            }

            record.retryCount += 1
            record.updatedAt = Date()
            try record.update(database)
        }

        log("TranscriptionStorage: Incremented retry count for session \(id)")
    }

    /// Delete a session and its segments
    func deleteSession(id: Int64) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            try database.execute(
                sql: "DELETE FROM transcription_sessions WHERE id = ?",
                arguments: [id]
            )
        }

        log("TranscriptionStorage: Deleted session \(id)")
    }

    /// Update session status helper
    private func updateSessionStatus(id: Int64, status: TranscriptionSessionStatus) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            guard var record = try TranscriptionSessionRecord.fetchOne(database, key: id) else {
                throw TranscriptionStorageError.sessionNotFound
            }

            record.status = status
            record.updatedAt = Date()
            try record.update(database)
        }

        log("TranscriptionStorage: Updated session \(id) status to \(status.rawValue)")
    }

    // MARK: - Conversation Field Updates (by backendId)

    /// Update starred status by backend conversation ID
    func updateStarredByBackendId(_ backendId: String, starred: Bool) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            try database.execute(
                sql: "UPDATE transcription_sessions SET starred = ?, updatedAt = ? WHERE backendId = ?",
                arguments: [starred, Date(), backendId]
            )
        }
    }

    /// Update title by backend conversation ID
    func updateTitleByBackendId(_ backendId: String, title: String) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            try database.execute(
                sql: "UPDATE transcription_sessions SET title = ?, updatedAt = ? WHERE backendId = ?",
                arguments: [title, Date(), backendId]
            )
        }
    }

    /// Soft-delete by backend conversation ID
    func deleteByBackendId(_ backendId: String) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            try database.execute(
                sql: "UPDATE transcription_sessions SET deleted = 1, updatedAt = ? WHERE backendId = ?",
                arguments: [Date(), backendId]
            )
        }
    }

    /// Update folder by backend conversation ID
    func updateFolderByBackendId(_ backendId: String, folderId: String?) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            try database.execute(
                sql: "UPDATE transcription_sessions SET folderId = ?, updatedAt = ? WHERE backendId = ?",
                arguments: [folderId, Date(), backendId]
            )
        }
    }

    // MARK: - Segment Operations

    /// Append a new segment to a session
    @discardableResult
    func appendSegment(
        sessionId: Int64,
        speaker: Int,
        text: String,
        startTime: Double,
        endTime: Double
    ) async throws -> Int64 {
        let db = try await ensureInitialized()

        // Get the next segment order
        let segmentOrder = try await db.read { database -> Int in
            try Int.fetchOne(
                database,
                sql: "SELECT COALESCE(MAX(segmentOrder), -1) + 1 FROM transcription_segments WHERE sessionId = ?",
                arguments: [sessionId]
            ) ?? 0
        }

        let segment = TranscriptionSegmentRecord(
            sessionId: sessionId,
            speaker: speaker,
            text: text,
            startTime: startTime,
            endTime: endTime,
            segmentOrder: segmentOrder
        )

        let record = try await db.write { database in
            try segment.inserted(database)
        }

        log("TranscriptionStorage: Appended segment \(record.id ?? -1) to session \(sessionId) (speaker: \(speaker), \(String(format: "%.1f", startTime))s-\(String(format: "%.1f", endTime))s)")
        return record.id!
    }

    /// Upsert a segment by backend segment ID — update if exists, insert if not.
    /// This handles the Python backend protocol where segments are sent with updates.
    @discardableResult
    func upsertSegment(
        sessionId: Int64,
        backendSegmentId: String?,
        speaker: Int,
        text: String,
        startTime: Double,
        endTime: Double,
        isUser: Bool = false,
        personId: String? = nil,
        speakerLabel: String? = nil,
        translationsJson: String? = nil
    ) async throws -> Int64 {
        let db = try await ensureInitialized()

        // If we have a backend segment ID, try to update existing
        if let segId = backendSegmentId {
            let updated = try await db.write { database -> Bool in
                try database.execute(
                    sql: """
                        UPDATE transcription_segments
                        SET text = ?, speaker = ?, startTime = ?, endTime = ?, isUser = ?, personId = ?,
                            speakerLabel = COALESCE(?, speakerLabel),
                            translationsJson = COALESCE(?, translationsJson)
                        WHERE sessionId = ? AND segmentId = ?
                        """,
                    arguments: [text, speaker, startTime, endTime, isUser, personId, speakerLabel, translationsJson, sessionId, segId]
                )
                return database.changesCount > 0
            }
            if updated {
                return 0  // Updated existing row
            }
        }

        // Insert new segment
        let segmentOrder = try await db.read { database -> Int in
            try Int.fetchOne(
                database,
                sql: "SELECT COALESCE(MAX(segmentOrder), -1) + 1 FROM transcription_segments WHERE sessionId = ?",
                arguments: [sessionId]
            ) ?? 0
        }

        let segment = TranscriptionSegmentRecord(
            sessionId: sessionId,
            speaker: speaker,
            text: text,
            startTime: startTime,
            endTime: endTime,
            segmentOrder: segmentOrder,
            segmentId: backendSegmentId,
            speakerLabel: speakerLabel,
            isUser: isUser,
            personId: personId,
            translationsJson: translationsJson
        )

        let record = try await db.write { database in
            try segment.inserted(database)
        }

        return record.id!
    }

    /// Update personId/isUser for segments by their backend segment IDs (UUIDs)
    func updateSegmentSpeakerAssignment(backendConversationId: String, segmentIds: [String], personId: String?, isUser: Bool) async throws {
        guard !segmentIds.isEmpty else { return }
        guard let session = try await getSessionByBackendId(backendConversationId) else { return }
        guard let sessionId = session.id else { return }
        let db = try await ensureInitialized()

        for segId in segmentIds {
            try await db.write { database in
                try database.execute(
                    sql: "UPDATE transcription_segments SET personId = ?, isUser = ? WHERE sessionId = ? AND segmentId = ?",
                    arguments: [personId, isUser, sessionId, segId]
                )
            }
        }
        log("TranscriptionStorage: Updated speaker assignment for \(segmentIds.count) segments in session \(sessionId)")
    }

    /// Delete segments by their backend segment IDs
    func deleteSegmentsByBackendIds(sessionId: Int64, segmentIds: [String]) async throws {
        guard !segmentIds.isEmpty else { return }
        let db = try await ensureInitialized()

        try await db.write { database in
            try TranscriptionSegmentRecord
                .filter(Column("sessionId") == sessionId)
                .filter(segmentIds.contains(Column("segmentId")))
                .deleteAll(database)
        }
        log("TranscriptionStorage: Deleted \(segmentIds.count) segments by backend IDs from session \(sessionId)")
    }

    /// Infinite Recall fork: resolve a backend conversation id to its local
    /// transcription_sessions.id. Used by the local-first People assignment
    /// path to backfill speaker_embeddings.
    func sessionIdForBackendId(_ backendId: String) async -> Int64? {
        do {
            let db = try await ensureInitialized()
            return try await db.read { database in
                try Int64.fetchOne(
                    database,
                    sql: "SELECT id FROM transcription_sessions WHERE backendId = ?",
                    arguments: [backendId]
                )
            }
        } catch {
            return nil
        }
    }

    /// Update speaker assignment metadata for existing segments in a synced conversation.
    /// Matches by backend segment IDs when available, then falls back to local segment order.
    func updateSpeakerAssignmentByBackendId(
        _ backendId: String,
        segmentIds: [String],
        fallbackSegmentOrders: [Int],
        isUser: Bool,
        personId: String?
    ) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            guard let sessionId = try Int64.fetchOne(
                database,
                sql: "SELECT id FROM transcription_sessions WHERE backendId = ?",
                arguments: [backendId]
            ) else {
                return
            }

            let encodedSegmentIds = String(
                decoding: try JSONEncoder().encode(segmentIds),
                as: UTF8.self
            )
            let encodedFallbackOrders = String(
                decoding: try JSONEncoder().encode(fallbackSegmentOrders),
                as: UTF8.self
            )

            if !segmentIds.isEmpty {
                try database.execute(
                    sql: """
                        UPDATE transcription_segments
                        SET isUser = ?, personId = ?
                        WHERE sessionId = ? AND segmentId IN (
                            SELECT value FROM json_each(?)
                        )
                        """,
                    arguments: [isUser, personId, sessionId, encodedSegmentIds]
                )
            }

            if !fallbackSegmentOrders.isEmpty {
                try database.execute(
                    sql: """
                        UPDATE transcription_segments
                        SET isUser = ?, personId = ?
                        WHERE sessionId = ? AND segmentOrder IN (
                            SELECT value FROM json_each(?)
                        )
                        """,
                    arguments: [isUser, personId, sessionId, encodedFallbackOrders]
                )
            }
        }
    }
    /// Get all segments for a session ordered by segmentOrder
    func getSegments(sessionId: Int64) async throws -> [TranscriptionSegmentRecord] {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try TranscriptionSegmentRecord
                .filter(Column("sessionId") == sessionId)
                .order(Column("segmentOrder").asc)
                .fetchAll(database)
        }
    }

    /// Get segment count for a session
    func getSegmentCount(sessionId: Int64) async throws -> Int {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM transcription_segments WHERE sessionId = ?",
                arguments: [sessionId]
            ) ?? 0
        }
    }

    /// Get audio_chunks count for a session.
    /// Note: audio_chunks uses `transcriptionSessionId` (not `sessionId`).
    func getAudioChunkCount(sessionId: Int64) async throws -> Int {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM audio_chunks WHERE transcriptionSessionId = ?",
                arguments: [sessionId]
            ) ?? 0
        }
    }

    /// Recover sessions left in `recording` after an app crash/quit. In the
    /// local-first fork there is no remote backend retry to reconcile these, so
    /// old recording rows with transcript/audio must be closed locally; otherwise
    /// they remain forever in-progress and never qualify for summary backfill.
    /// Returns the number of rows closed.
    @discardableResult
    func recoverStaleRecordingSessions(olderThan maxAge: TimeInterval = 120) async throws -> Int {
        let db = try await ensureInitialized()
        let cutoff = Date().addingTimeInterval(-maxAge)

        let rows = try await db.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT s.id,
                           s.startedAt,
                           COALESCE(MAX(seg.endTime), 1.0) AS maxEnd
                      FROM transcription_sessions s
                      LEFT JOIN transcription_segments seg ON seg.sessionId = s.id
                     WHERE s.status = 'recording'
                       AND s.finishedAt IS NULL
                       AND s.createdAt < ?
                       AND (
                            EXISTS (SELECT 1 FROM transcription_segments ts WHERE ts.sessionId = s.id)
                         OR EXISTS (SELECT 1 FROM audio_chunks ac WHERE ac.transcriptionSessionId = s.id)
                       )
                     GROUP BY s.id
                    """,
                arguments: [cutoff]
            )
        }

        var recovered = 0
        for row in rows {
            guard let id: Int64 = row["id"], let startedAt: Date = row["startedAt"] else { continue }
            let rawMaxEnd: Double = row["maxEnd"] ?? 1.0
            let maxEnd = max(rawMaxEnd, 1.0)
            let finishedAt = startedAt.addingTimeInterval(maxEnd)
            let changed = try await db.write { database -> Int in
                try database.execute(
                    sql: """
                        UPDATE transcription_sessions
                           SET finishedAt = ?,
                               status = 'completed',
                               conversationStatus = 'completed',
                               updatedAt = ?
                         WHERE id = ?
                           AND status = 'recording'
                           AND finishedAt IS NULL
                        """,
                    arguments: [finishedAt, Date(), id]
                )
                return database.changesCount
            }
            recovered += changed
        }

        if recovered > 0 {
            log("TranscriptionStorage: Recovered \(recovered) stale recording session(s)")
        }
        return recovered
    }

    /// Retrospectively delete sessions that produced no segments AND no
    /// audio_chunks — these are 0-second artifacts from sessions that were
    /// started but where no audio actually flowed (e.g. brief launches,
    /// permission-denied, mid-launch failures).
    ///
    /// Only purges sessions in `recording` or `pending_upload` status.
    /// Active recordings are protected by a 30s grace window — there's a
    /// race where capture has started but no segments have arrived yet.
    /// Returns the number of rows deleted.
    @discardableResult
    func purgeEmptySessions() async throws -> Int {
        let db = try await ensureInitialized()
        // 30-second grace window: don't kill sessions that just started.
        let cutoff = Date().addingTimeInterval(-30)

        return try await db.write { database -> Int in
            try database.execute(
                sql: """
                    DELETE FROM transcription_sessions
                    WHERE id NOT IN (
                        SELECT DISTINCT sessionId FROM transcription_segments
                        WHERE sessionId IS NOT NULL
                    )
                      AND id NOT IN (
                        SELECT DISTINCT transcriptionSessionId FROM audio_chunks
                        WHERE transcriptionSessionId IS NOT NULL
                      )
                      AND status IN ('recording', 'pending_upload')
                      AND NOT (status = 'recording' AND createdAt > ?)
                    """,
                arguments: [cutoff]
            )
            return database.changesCount
        }
    }

    /// Fetch the first segment's text per session in a single SQL pass.
    /// Used by the Conversations list to render a 1-2 line inline preview
    /// without paying for the full segment fetch on every row.
    /// Returns a map of sessionId -> trimmed text (WhisperKit special
    /// tokens like <|0.00|> stripped defensively).
    func getFirstSegmentTexts(sessionIds: [Int64]) async throws -> [Int64: String] {
        guard !sessionIds.isEmpty else { return [:] }
        let db = try await ensureInitialized()

        // Use a correlated subquery that picks the lowest segmentOrder per
        // session — this returns one row per session in a single pass.
        let placeholders = sessionIds.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            SELECT s.sessionId, s.text
              FROM transcription_segments s
              JOIN (
                  SELECT sessionId, MIN(segmentOrder) AS minOrder
                    FROM transcription_segments
                   WHERE sessionId IN (\(placeholders))
                   GROUP BY sessionId
              ) m
                ON m.sessionId = s.sessionId AND m.minOrder = s.segmentOrder
            """
        let args = StatementArguments(sessionIds)

        return try await db.read { database -> [Int64: String] in
            var out: [Int64: String] = [:]
            let rows = try Row.fetchAll(database, sql: sql, arguments: args)
            for row in rows {
                guard let sid: Int64 = row["sessionId"], let text: String = row["text"] else { continue }
                let stripped = text.replacingOccurrences(
                    of: #"<\|[^|>]+\|>"#,
                    with: "",
                    options: .regularExpression
                )
                let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    out[sid] = trimmed
                }
            }
            return out
        }
    }

    // MARK: - Queries

    /// Get a session by ID
    func getSession(id: Int64) async throws -> TranscriptionSessionRecord? {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try TranscriptionSessionRecord.fetchOne(database, key: id)
        }
    }

    /// Get the currently active recording session (if any)
    func getActiveSession() async throws -> TranscriptionSessionRecord? {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try TranscriptionSessionRecord
                .filter(Column("status") == TranscriptionSessionStatus.recording.rawValue)
                .order(Column("createdAt").desc)
                .fetchOne(database)
        }
    }

    /// Get sessions pending upload
    func getPendingUploadSessions() async throws -> [TranscriptionSessionRecord] {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try TranscriptionSessionRecord
                .filter(Column("status") == TranscriptionSessionStatus.pendingUpload.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll(database)
        }
    }

    /// Get failed sessions that can be retried
    func getFailedSessions(maxRetries: Int = 5) async throws -> [TranscriptionSessionRecord] {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try TranscriptionSessionRecord
                .filter(Column("status") == TranscriptionSessionStatus.failed.rawValue)
                .filter(Column("retryCount") < maxRetries)
                .order(Column("updatedAt").asc)
                .fetchAll(database)
        }
    }

    /// Get sessions that were left in "recording" status (crashed)
    func getCrashedSessions() async throws -> [TranscriptionSessionRecord] {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try TranscriptionSessionRecord
                .filter(Column("status") == TranscriptionSessionStatus.recording.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll(database)
        }
    }

    /// Get sessions stuck in 'uploading' status for longer than the given threshold (in seconds)
    /// These are sessions where the app quit/crashed during upload or markSessionCompleted failed silently
    func getStuckUploadingSessions(olderThan seconds: TimeInterval) async throws -> [TranscriptionSessionRecord] {
        let db = try await ensureInitialized()
        let cutoff = Date().addingTimeInterval(-seconds)

        return try await db.read { database in
            try TranscriptionSessionRecord
                .filter(Column("status") == TranscriptionSessionStatus.uploading.rawValue)
                .filter(Column("updatedAt") < cutoff)
                .order(Column("createdAt").asc)
                .fetchAll(database)
        }
    }

    /// Get a session with its segments
    func getSessionWithSegments(id: Int64) async throws -> TranscriptionSessionWithSegments? {
        let db = try await ensureInitialized()

        return try await db.read { database in
            guard let session = try TranscriptionSessionRecord.fetchOne(database, key: id) else {
                return nil
            }

            let segments = try TranscriptionSegmentRecord
                .filter(Column("sessionId") == id)
                .order(Column("segmentOrder").asc)
                .fetchAll(database)

            return TranscriptionSessionWithSegments(session: session, segments: segments)
        }
    }

    /// Get all sessions needing recovery (crashed, pending, or failed with retries left)
    func getSessionsNeedingRecovery() async throws -> [TranscriptionSessionRecord] {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try TranscriptionSessionRecord
                .filter(
                    Column("status") == TranscriptionSessionStatus.recording.rawValue ||
                    Column("status") == TranscriptionSessionStatus.pendingUpload.rawValue ||
                    (Column("status") == TranscriptionSessionStatus.failed.rawValue && Column("retryCount") < 5)
                )
                .order(Column("createdAt").asc)
                .fetchAll(database)
        }
    }

    /// Get storage statistics
    func getStats() async throws -> (totalSessions: Int, pendingCount: Int, failedCount: Int, completedCount: Int) {
        let db = try await ensureInitialized()

        return try await db.read { database in
            let total = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM transcription_sessions") ?? 0
            let pending = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM transcription_sessions WHERE status = ?",
                arguments: [TranscriptionSessionStatus.pendingUpload.rawValue]
            ) ?? 0
            let failed = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM transcription_sessions WHERE status = ?",
                arguments: [TranscriptionSessionStatus.failed.rawValue]
            ) ?? 0
            let completed = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM transcription_sessions WHERE status = ?",
                arguments: [TranscriptionSessionStatus.completed.rawValue]
            ) ?? 0

            return (total, pending, failed, completed)
        }
    }

    // MARK: - Backend Sync Operations

    /// Get a session by backend ID
    func getSessionByBackendId(_ backendId: String) async throws -> TranscriptionSessionRecord? {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try TranscriptionSessionRecord
                .filter(Column("backendId") == backendId)
                .fetchOne(database)
        }
    }

    /// Upsert a session from a ServerConversation (insert if not exists, update if exists)
    /// Returns the local session ID
    @discardableResult
    func upsertFromServerConversation(_ conversation: ServerConversation) async throws -> (sessionId: Int64, changed: Bool) {
        let db = try await ensureInitialized()

        return try await db.write { database -> (Int64, Bool) in
            // Check if session already exists by backendId
            if var existingSession = try TranscriptionSessionRecord
                .filter(Column("backendId") == conversation.id)
                .fetchOne(database) {
                // Skip if local record is newer than the conversation's latest timestamp.
                // This prevents sync from overwriting recent local mutations (star, delete, title edit, etc.)
                let serverTimestamp = conversation.finishedAt ?? conversation.startedAt ?? conversation.createdAt
                if existingSession.updatedAt >= serverTimestamp {
                    guard let sessionId = existingSession.id else {
                        throw TranscriptionStorageError.invalidState("Session ID is nil")
                    }
                    return (sessionId, false)
                }

                // Update existing session
                existingSession.updateFrom(conversation)
                try existingSession.update(database)
                guard let sessionId = existingSession.id else {
                    throw TranscriptionStorageError.invalidState("Session ID is nil after update")
                }
                log("TranscriptionStorage: Updated session \(sessionId) from backend \(conversation.id)")
                return (sessionId, true)
            } else {
                // Insert new session - use inserted() to get record with ID
                let newSession = TranscriptionSessionRecord.from(conversation)
                let insertedSession = try newSession.inserted(database)
                guard let sessionId = insertedSession.id else {
                    throw TranscriptionStorageError.invalidState("Session ID is nil after insert")
                }
                log("TranscriptionStorage: Inserted new session \(sessionId) from backend \(conversation.id)")
                return (sessionId, true)
            }
        }
    }

    /// Upsert segments from a ServerConversation
    /// Deletes existing segments and re-inserts from conversation.
    /// Skips when incoming segments are empty to avoid wiping locally-cached data
    /// (list endpoints often return conversations without transcript segments).
    func upsertSegmentsFromServerConversation(_ conversation: ServerConversation, sessionId: Int64) async throws {
        guard !conversation.transcriptSegments.isEmpty else { return }

        let db = try await ensureInitialized()

        try await db.write { database in
            // Delete existing segments for this session
            try database.execute(
                sql: "DELETE FROM transcription_segments WHERE sessionId = ?",
                arguments: [sessionId]
            )

            // Insert new segments
            for (index, segment) in conversation.transcriptSegments.enumerated() {
                let record = TranscriptionSegmentRecord.from(segment, sessionId: sessionId, segmentOrder: index)
                _ = try record.inserted(database)
            }

            log("TranscriptionStorage: Upserted \(conversation.transcriptSegments.count) segments for session \(sessionId)")
        }
    }

    /// Sync a full ServerConversation (session + segments) to local storage
    @discardableResult
    func syncServerConversation(_ conversation: ServerConversation) async throws -> Int64 {
        // First upsert the session
        let (sessionId, changed) = try await upsertFromServerConversation(conversation)

        // Only re-sync segments if the session was actually inserted or updated
        if changed {
            try await upsertSegmentsFromServerConversation(conversation, sessionId: sessionId)
        }

        return sessionId
    }

    /// Get all sessions synced from backend (for display in Conversations page)
    func getSyncedSessions(limit: Int = 100, offset: Int = 0) async throws -> [TranscriptionSessionRecord] {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try TranscriptionSessionRecord
                .filter(Column("backendSynced") == true)
                .filter(Column("deleted") == false)
                .filter(Column("discarded") == false)
                .order(Column("startedAt").desc)
                .limit(limit, offset: offset)
                .fetchAll(database)
        }
    }

    /// Update starred status for a session
    func updateStarred(id: Int64, starred: Bool) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            guard var record = try TranscriptionSessionRecord.fetchOne(database, key: id) else {
                throw TranscriptionStorageError.sessionNotFound
            }

            record.starred = starred
            record.updatedAt = Date()
            try record.update(database)
        }

        log("TranscriptionStorage: Updated starred=\(starred) for session \(id)")
    }

    /// Get starred sessions
    func getStarredSessions() async throws -> [TranscriptionSessionRecord] {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try TranscriptionSessionRecord
                .filter(Column("starred") == true)
                .filter(Column("deleted") == false)
                .order(Column("startedAt").desc)
                .fetchAll(database)
        }
    }

    /// Get conversations from local storage as ServerConversation objects
    /// Used for instant display before API fetch completes
    /// Note: Does NOT load segments for performance - segments are loaded on-demand for detail view
    func getLocalConversations(
        limit: Int = 50,
        offset: Int = 0,
        starredOnly: Bool = false,
        folderId: String? = nil
    ) async throws -> [ServerConversation] {
        let db = try await ensureInitialized()

        return try await db.read { database in
            // Infinite Recall fork: dropped `backendSynced == true` filter —
            // all sessions are local; there's no backend to sync against,
            // so the original filter wiped the entire conversation list.
            var query = TranscriptionSessionRecord
                .filter(Column("deleted") == false)
                .filter(Column("discarded") == false)

            if starredOnly {
                query = query.filter(Column("starred") == true)
            }

            if let folderId = folderId {
                query = query.filter(Column("folderId") == folderId)
            }

            let sessions = try query
                .order(Column("startedAt").desc)
                .limit(limit, offset: offset)
                .fetchAll(database)

            // Convert each session to ServerConversation WITHOUT loading segments
            // Segments are only needed for conversation detail view, not list view
            // This makes the query O(1) instead of O(N) for much faster loading
            return sessions.compactMap { session in
                session.toServerConversation(segments: [])
            }
        }
    }

    /// Get count of local conversations
    func getLocalConversationsCount(starredOnly: Bool = false) async throws -> Int {
        let db = try await ensureInitialized()

        return try await db.read { database in
            // Infinite Recall fork: dropped `backendSynced == true` filter —
            // all sessions are local; there's no backend to sync against,
            // so the original filter wiped the entire conversation list.
            var query = TranscriptionSessionRecord
                .filter(Column("deleted") == false)
                .filter(Column("discarded") == false)

            if starredOnly {
                query = query.filter(Column("starred") == true)
            }

            return try query.fetchCount(database)
        }
    }
}
