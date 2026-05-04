import Foundation
import GRDB

/// Owns durable enqueue, per-session summarize entry point, ambient audio
/// handling, and status normalization for conversation summaries.
///
/// These fields were originally filled by the cloud-backed Omi extraction
/// pipeline which is not present in the local-first fork.  Historical sessions
/// recorded before the local extraction pipeline was wired therefore have null
/// title/overview and appear as "Untitled Conversation" in the list.
///
/// **Wave-1 contract surface (see contracts/IRSummaryContracts.swift):**
/// - `enqueueSummary(sessionId:reason:)` — durable enqueue via PendingWorkStorage,
///   dedup key `summarize:<id>`, payload `{"session_id": <id>}`.
/// - `enqueueHistoricalSummariesIfNeeded(reason:)` — walks finished sessions
///   missing a summary and enqueues each.
/// - `processSummary(sessionId:autonomous:)` — process exactly one session.
///   When `autonomous == true`, routes the LLM call through
///   `LocalLLMClient.chatAutonomous` (Agent B's deliverable) so Memory Saver
///   can still unload after a drain.
///
/// Idempotency guarantee: the UserDefaults flag
/// `conversationSummaryBackfillCompleted_v2` is set only after 3 consecutive
/// empty queries confirm there is nothing left to process.  Running this 100
/// times is safe. v2 intentionally re-runs on machines where an earlier broken
/// v1 attempt marked completion before local summaries were reliably generated.
///
/// Battery awareness: the legacy `runIfNeeded` loop only runs when
/// `BatteryAwareScheduler.shared.allowHeavyWork` is true.  In the new flow the
/// blocked-readiness path durably enqueues via `PendingWorkStorage` instead of
/// dropping the request on the floor; the scheduler's autonomous-AI drain
/// (Agent B) picks it up later.
actor ConversationSummaryBackfillService {
    static let shared = ConversationSummaryBackfillService()

    private static let userDefaultsKey = "conversationSummaryBackfillCompleted_v2"
    /// Nanoseconds to sleep between individual LLM calls (~1 s).
    private static let throttleNanoseconds: UInt64 = 1_000_000_000
    /// Minimum total transcript length (chars) to bother summarizing.
    /// Aliased to `ConversationTranscriptLoader.minTranscriptLength` so summary
    /// + extractActionItems share one source of truth.
    private static let minTranscriptLength = ConversationTranscriptLoader.minTranscriptLength
    /// Maximum transcript length (chars) sent to the LLM.
    /// Aliased to `ConversationTranscriptLoader.maxTranscriptLength`.
    private static let maxTranscriptLength = ConversationTranscriptLoader.maxTranscriptLength
    /// How many consecutive empty queries before we declare completion.
    private static let emptyBatchTerminationCount = 3

    /// Pending-work `workType` for summary jobs. Must match
    /// `PendingWork.Kind.summarize.rawValue` and is shared across agents.
    private static let workType: String = PendingWork.Kind.summarize.rawValue

    private init() {}

    // MARK: - Pending-work payload

    /// Wire format for `pending_work.payload` rows of kind `summarize`.
    /// Matches the contract in `IRSummaryContracts.swift`:
    ///     {"session_id": Int64}
    /// Dedup key: `summarize:<session_id>`.
    struct PendingPayload: Codable {
        let session_id: Int64
    }

    static func dedupKey(for sessionId: Int64) -> String {
        return "summarize:\(sessionId)"
    }

    // MARK: - Public API (Wave-1 contract surface)

    /// Durably enqueue a single session for `.summarize` work via
    /// `PendingWorkStorage`. Idempotent — repeat calls collapse via the
    /// dedup key `summarize:<sessionId>`. Posts
    /// `.conversationsListNeedsRefresh` so the UI can reflect the pending
    /// state immediately.
    func enqueueSummary(sessionId: Int64, reason: String) async {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(PendingPayload(session_id: sessionId))
        } catch {
            logError("ConversationSummaryBackfillService: failed to encode summary payload for session \(sessionId)", error: error)
            return
        }

        do {
            _ = try await PendingWorkStorage.shared.enqueue(
                workType: Self.workType,
                payload: payload,
                dedupKey: Self.dedupKey(for: sessionId)
            )
            log("ConversationSummaryBackfillService: enqueued summarize for session \(sessionId) (\(reason))")
        } catch {
            logError("ConversationSummaryBackfillService: enqueue failed for session \(sessionId) (\(reason))", error: error)
        }

        // Mark the historical backfill flag as needing another sweep so the
        // legacy runIfNeeded path won't short-circuit on the next launch.
        UserDefaults.standard.set(false, forKey: Self.userDefaultsKey)

        await notifyConversationListNeedsRefresh()
    }

    /// Walks finished sessions with transcripts but missing title/overview and
    /// enqueues each. Called from AppState launch hook by Agent B.
    func enqueueHistoricalSummariesIfNeeded(reason: String) async {
        do {
            let sessionIds = try await fetchEligibleSessionIds()
            guard !sessionIds.isEmpty else {
                log("ConversationSummaryBackfillService: no historical summaries needed (\(reason))")
                return
            }
            log("ConversationSummaryBackfillService: enqueuing \(sessionIds.count) historical summary job(s) (\(reason))")
            for id in sessionIds {
                await enqueueSummary(sessionId: id, reason: "historical:\(reason)")
            }
        } catch {
            logError("ConversationSummaryBackfillService: enqueueHistoricalSummariesIfNeeded failed (\(reason))", error: error)
        }
    }

    /// Process exactly one session's summary.
    ///
    /// - Parameter autonomous: when `true` the LLM call MUST route through
    ///   `LocalLLMClient.chatAutonomous` (Agent B's deliverable) so that
    ///   `IdleAIController.recordAICall` is NOT invoked and Memory Saver can
    ///   still unload after the drain.
    /// - Throws: on retryable failure so PendingWork retry/backoff handles it.
    func processSummary(sessionId: Int64, autonomous: Bool) async throws {
        guard let row = try await fetchSession(id: sessionId, onlyIfNeedsSummary: true) else {
            log("ConversationSummaryBackfillService: processSummary skipped for session \(sessionId) — already summarized or missing")
            return
        }

        let mode = autonomous ? "autonomous" : "live"
        let outcome = try await process(row: row, mode: mode, autonomous: autonomous)
        switch outcome {
        case .summarized, .placeholder, .discarded:
            // Done: ack happens at the caller (Agent B's drain loop) or the
            // immediate-path entry point.
            return
        case .deferred:
            // Surface as a retryable error so PendingWork backoff schedules
            // another attempt.
            throw SummaryProcessingError.deferred(sessionId: sessionId)
        }
    }

    enum SummaryProcessingError: LocalizedError {
        case deferred(sessionId: Int64)

        var errorDescription: String? {
            switch self {
            case .deferred(let id):
                return "Summary deferred for session \(id) (LLM unavailable or response unparsable)"
            }
        }
    }

    // MARK: - Legacy entry points (kept for AppState/OmiApp callers)

    /// Legacy historical-backfill entry point. Preserved for the existing
    /// `OmiApp.swift` launch hook (BOUNDARY for this task — Agent B owns it).
    /// In the new flow this just enqueues eligible sessions; the autonomous
    /// drain owned by Agent B does the actual work.
    func runIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: Self.userDefaultsKey) else {
            log("ConversationSummaryBackfillService: already complete (v2), skipping")
            return
        }

        // Always enqueue. The blocked-readiness path used to log-and-retry-on-launch;
        // we now durably enqueue so work survives until conditions are right.
        await enqueueHistoricalSummariesIfNeeded(reason: "runIfNeeded")

        // If we're currently safe to run heavy work, also drive an immediate
        // pass for snappy UX. If we're not, the items stay queued and Agent B's
        // autonomous-AI drain handles them.
        guard await MainActor.run(body: { BatteryAwareScheduler.shared.allowHeavyWork }) else {
            log("ConversationSummaryBackfillService: heavy work not allowed (battery/thermal); items queued for autonomous drain")
            return
        }

        log("ConversationSummaryBackfillService: starting historical conversation summary backfill")
        let startTime = Date()

        do {
            try await backfillLoop(startTime: startTime)
        } catch {
            logError("ConversationSummaryBackfillService: backfill loop failed, will retry next launch", error: error)
        }
    }

    /// Mark the historical backfill as incomplete. Used when launch recovery
    /// turns stale `recording` rows into finished conversations after a prior
    /// empty scan, or when live summarization defers work.
    func markBackfillNeeded(reason: String) {
        UserDefaults.standard.set(false, forKey: Self.userDefaultsKey)
        log("ConversationSummaryBackfillService: marked backfill needed (\(reason))")
    }

    /// One-time sweep: soft-discard pre-existing rows that are genuinely
    /// empty (no transcription segments) and were marked unavailable by the
    /// summary-state migration. Soft-discard via the rewritten
    /// `discardEmptySession`, so rows land in the recovery panel and stay
    /// recoverable.
    ///
    /// V2 supersedes V1, which keyed off `title = 'Short Recording'` — that
    /// title was a catch-all placeholder that ate sessions far longer than
    /// 2-second blips. V2 only sweeps rows with zero segments, so a session
    /// with real transcript content but an unfortunate title is left alone.
    /// We bump the flag so machines that completed V1 re-run with the
    /// safer V2 rules. Idempotent — safe to call on every launch.
    func backfillDiscardEmptyShortRecordingsOnce() async {
        let flagKey = "irEmptyShortRecordingBackfillCompletedV2"
        guard !UserDefaults.standard.bool(forKey: flagKey) else {
            return
        }

        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            log("ConversationSummaryBackfillService: discard-empty backfill skipped — database not initialized")
            return
        }

        // Daemon-health gate: only `.fileMissing` is genuinely transient
        // (daemon not yet started). On `.unreadable` / `.empty` the daemon is
        // broken in a way that won't self-heal across launches — looping
        // forever on it accomplishes nothing, and `segment_count = 0` is a
        // structural check that doesn't actually need daemon liveness to be
        // safe. Log loudly on those and proceed with the sweep.
        do {
            let syncRead: () throws -> String = LocalDaemonToken.read  // sync overload, not waitFor:
            _ = try syncRead()
        } catch LocalDaemonToken.TokenError.fileMissing {
            log("ConversationSummaryBackfillService: skipping discard sweep — daemon not yet started, will retry next cycle")
            return
        } catch {
            logError("ConversationSummaryBackfillService: daemon token unreadable/empty during discard sweep — proceeding without health gate", error: error)
            // fall through to the sweep
        }

        // Only rows that are genuinely empty (no segments) AND already marked
        // unavailable. Drops the V1 title='Short Recording' criterion — that
        // was over-aggressive — and replaces it with a hard structural check.
        let sql = """
            SELECT id FROM transcription_sessions
             WHERE deleted = 0
               AND discarded = 0
               AND summary_state = 'unavailable'
               AND NOT EXISTS (
                   SELECT 1 FROM transcription_segments seg
                    WHERE seg.sessionId = transcription_sessions.id
               )
            """

        let ids: [Int64]
        do {
            ids = try await dbQueue.read { db in
                try Int64.fetchAll(db, sql: sql)
            }
        } catch {
            logError("ConversationSummaryBackfillService: discard-empty backfill query failed", error: error)
            return
        }

        log("ConversationSummaryBackfillService: discard-empty backfill starting — \(ids.count) candidate row(s)")

        var failures = 0
        for id in ids {
            do {
                try await TranscriptionStorage.shared.discardEmptySession(id: id, reason: "backfill_short_recording")
            } catch {
                failures += 1
                logError("ConversationSummaryBackfillService: discard-empty backfill failed for session \(id)", error: error)
            }
        }

        if failures == 0 {
            UserDefaults.standard.set(true, forKey: flagKey)
            // V1 flag is obsolete after V2 sweep — clear it to avoid stale
            // keys accumulating across future Vn bumps.
            UserDefaults.standard.removeObject(forKey: "irEmptyShortRecordingBackfillCompletedV1")
            log("ConversationSummaryBackfillService: discard-empty backfill complete — processed \(ids.count) row(s)")
        } else {
            log("ConversationSummaryBackfillService: discard-empty backfill partial — \(ids.count - failures) ok, \(failures) failed; will retry next launch")
        }
    }

    /// Summarize one just-finished session immediately when conditions are
    /// safe; otherwise durably enqueue for the autonomous drain. Always
    /// enqueues a durable record first so nothing is lost.
    func summarizeSessionIfNeeded(_ sessionId: Int64, reason: String) async {
        // 1. Durable enqueue — survives crash/quit/blocked-readiness.
        await enqueueSummary(sessionId: sessionId, reason: "live:\(reason)")

        // 2. Try to run immediately when currently safe so the user sees the
        //    summary as soon as possible without waiting for an autonomous
        //    drain.
        guard await MainActor.run(body: { BatteryAwareScheduler.shared.allowHeavyWork }) else {
            log("ConversationSummaryBackfillService: live summary deferred for session \(sessionId) — heavy work not allowed; queued for autonomous drain (\(reason))")
            return
        }

        do {
            try await processSummary(sessionId: sessionId, autonomous: false)
        } catch SummaryProcessingError.deferred {
            log("ConversationSummaryBackfillService: live summary deferred for session \(sessionId); pending row remains queued")
        } catch {
            logError("ConversationSummaryBackfillService: live summary failed for session \(sessionId)", error: error)
        }
    }

    // MARK: - Private — backfill loop (legacy; still callable for in-process drain)

    private func backfillLoop(startTime: Date) async throws {
        var totalProcessed = 0
        var consecutiveEmpty = 0
        var hasDeferredOrPending = false

        while consecutiveEmpty < Self.emptyBatchTerminationCount {
            // Re-check power state between rows.
            guard await MainActor.run(body: { BatteryAwareScheduler.shared.allowHeavyWork }) else {
                log("ConversationSummaryBackfillService: pausing — power conditions changed after \(totalProcessed) rows; remaining items stay queued for autonomous drain")
                hasDeferredOrPending = true
                return
            }

            guard let row = try await fetchNextSession() else {
                consecutiveEmpty += 1
                log("ConversationSummaryBackfillService: empty query (\(consecutiveEmpty)/\(Self.emptyBatchTerminationCount))")
                continue
            }

            consecutiveEmpty = 0

            let outcome = try await process(row: row, mode: "backfill", autonomous: false)
            switch outcome {
            case .summarized:
                totalProcessed += 1
                // Throttle: give the LLM server a brief breather.
                try await Task.sleep(nanoseconds: Self.throttleNanoseconds)
            case .placeholder, .discarded:
                continue
            case .deferred:
                // Do not spin forever on the same row if the local LLM is
                // offline or returned unparsable JSON. Leave it eligible and
                // retry on the next safe window — pending-work row already
                // survives via enqueueSummary above.
                log("ConversationSummaryBackfillService: deferred after LLM/parse failure; will retry later")
                hasDeferredOrPending = true
                return
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        // Requirement 5: do not mark global backfill complete while pending
        // /deferred rows remain.
        if !hasDeferredOrPending {
            UserDefaults.standard.set(true, forKey: Self.userDefaultsKey)
            log(String(format: "ConversationSummaryBackfillService: complete — %d rows in %.1fs", totalProcessed, elapsed))
        } else {
            log(String(format: "ConversationSummaryBackfillService: partial pass — %d rows in %.1fs (pending/deferred remain)", totalProcessed, elapsed))
        }
    }

    private enum ProcessOutcome {
        case summarized
        case placeholder
        case discarded
        case deferred
    }

    private func process(row: PendingSession, mode: String, autonomous: Bool) async throws -> ProcessOutcome {
        let sessionId = row.id
        let transcript = row.transcript

        // Short transcript → soft-discard the empty session instead of
        // writing a "Short Recording" placeholder. Empty short recordings
        // are noise in the conversations list; surface them as discarded.
        //
        // BUT: PR #79 made transcribe an enqueued job, so summarize can fire
        // before any segments exist on a freshly-finished recording. Defer
        // when transcribe is still queued/claimed — otherwise we'd discard
        // every recording that takes longer to transcribe than to summarize.
        guard transcript.count >= Self.minTranscriptLength else {
            let isTerminal = try await TranscriptionStorage.shared.transcribeIsTerminal(sessionId: sessionId)
            guard isTerminal else {
                log("ConversationSummaryBackfillService: session \(sessionId) transcript empty but transcribe not terminal — deferring (\(mode))")
                return .deferred
            }
            log("ConversationSummaryBackfillService: session \(sessionId) transcript too short (\(transcript.count) chars), discarding empty session (\(mode))")
            try await TranscriptionStorage.shared.discardEmptySession(id: sessionId, reason: "short_transcript")
            await notifyConversationListNeedsRefresh()
            return .discarded
        }

        // Ambient/non-speech fallback: long enough to look real but mostly
        // bracketed/non-speech (music, noise). Don't throw — write a
        // structured placeholder instead so the row stops being re-queued.
        if Self.isMostlyNonSpeech(transcript) {
            log("ConversationSummaryBackfillService: session \(sessionId) detected as ambient/non-speech audio, writing Ambient Audio placeholder (\(mode))")
            try await writeAmbientAudioPlaceholder(sessionId: sessionId)
            await notifyConversationListNeedsRefresh()
            return .placeholder
        }

        log("ConversationSummaryBackfillService: summarizing session \(sessionId) (\(transcript.count) chars, \(mode))")

        guard let structured = await callLLM(transcript: transcript, sessionId: sessionId, autonomous: autonomous) else {
            log("ConversationSummaryBackfillService: session \(sessionId) summary deferred due to LLM/parse failure (\(mode))")
            return .deferred
        }

        try await writeBack(sessionId: sessionId, structured: structured)
        log("ConversationSummaryBackfillService: session \(sessionId) → \"\(structured.title)\" (\(mode))")
        await notifyConversationListNeedsRefresh()

        // Now that the session has a usable summary (i.e. transcript + LLM
        // both succeeded), enqueue the action-items extraction. Producing on
        // summary-success — not transcript-finish — avoids double-extracting
        // and racing transcript materialization.
        await ConversationActionItemsBackfillService.shared
            .enqueueActionItemsIfNeeded(sessionId: sessionId, reason: "post-summary:\(mode)")

        // Fire-and-forget: now that the conversation has its final title +
        // overview, hand it off to the local-integration outbox. This is the
        // unambiguous "conversation finished" moment in the local-first fork
        // (the legacy `memory_created` WebSocket handler is dead code). We
        // pass `String(sessionId)` because the API route
        // `GET /v1/conversations/{id}` parses the path as `i64` straight off
        // `transcription_sessions.id` — the sessionId IS the conversation id
        // in this fork; there is no separate column or resolver.
        Task.detached(priority: .utility) {
            await LocalIntegrationDispatcher.shared.enqueueDispatch(conversationId: String(sessionId))
        }

        return .summarized
    }

    private func notifyConversationListNeedsRefresh() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .conversationsListNeedsRefresh, object: nil)
        }
    }

    // MARK: - Ambient / non-speech detection

    /// Returns true when the transcript is dominated by bracketed non-speech
    /// markers like `[Music]`, `[Applause]`, `(noise)`, WhisperKit ambient
    /// tokens, etc. The summary path uses this to short-circuit into a
    /// structured "Ambient Audio" placeholder instead of paying for an LLM
    /// call (and instead of throwing).
    static func isMostlyNonSpeech(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Strip common bracketed non-speech markers and ambient tokens.
        // Patterns: [Music], (Applause), <Music>, [BLANK_AUDIO], etc.
        let bracketPattern = #"[\[\(\<][^\]\)\>]*[\]\)\>]"#
        let stripped = trimmed.replacingOccurrences(
            of: bracketPattern,
            with: "",
            options: .regularExpression
        )

        // Count remaining alphanumeric (speech) characters.
        let speechCharCount = stripped.unicodeScalars.reduce(0) { acc, s in
            (CharacterSet.letters.contains(s) || CharacterSet.decimalDigits.contains(s)) ? acc + 1 : acc
        }
        let totalCharCount = trimmed.unicodeScalars.reduce(0) { acc, s in
            (CharacterSet.letters.contains(s) || CharacterSet.decimalDigits.contains(s)) ? acc + 1 : acc
        }

        // If the original had alphanumerics but stripping brackets killed
        // most of them, the transcript was mostly bracketed non-speech.
        if totalCharCount == 0 { return true }
        let speechRatio = Double(speechCharCount) / Double(totalCharCount)
        return speechRatio < 0.2
    }

    // MARK: - Database helpers

    /// Holds one row from the "needs summary" query.
    private struct PendingSession {
        let id: Int64
        let transcript: String
    }

    /// Fetch IDs of finished, non-deleted sessions with at least one
    /// non-empty transcript segment AND missing title/overview. Used by
    /// `enqueueHistoricalSummariesIfNeeded`.
    private func fetchEligibleSessionIds() async throws -> [Int64] {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw TranscriptionStorageError.databaseNotInitialized
        }

        let sql = """
            SELECT s.id FROM transcription_sessions AS s
             WHERE s.finishedAt IS NOT NULL
               AND s.deleted = 0
               AND s.summary_state = 'pending'
               AND ((s.title IS NULL OR s.title = '')
                    OR (s.overview IS NULL OR s.overview = ''))
               AND EXISTS (
                   SELECT 1 FROM transcription_segments seg
                    WHERE seg.sessionId = s.id
                      AND seg.text IS NOT NULL
                      AND TRIM(seg.text) != ''
               )
             ORDER BY s.finishedAt DESC
            """

        return try await dbQueue.read { db in
            try Int64.fetchAll(db, sql: sql)
        }
    }

    /// Fetch the next finished session whose title+overview are both empty/null,
    /// along with its full transcript text.
    ///
    /// Returns nil when no rows match (signals progress toward completion).
    private func fetchNextSession() async throws -> PendingSession? {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw TranscriptionStorageError.databaseNotInitialized
        }

        // Step 1: find the most-recent finished session that still needs a summary.
        let sql = """
            SELECT id FROM transcription_sessions
             WHERE finishedAt IS NOT NULL
               AND summary_state = 'pending'
               AND ((title IS NULL OR title = '')
                    OR (overview IS NULL OR overview = ''))
             ORDER BY finishedAt DESC
             LIMIT 1
            """

        guard let sessionId: Int64 = try await dbQueue.read({ db in
            try Int64.fetchOne(db, sql: sql)
        }) else {
            return nil
        }

        return try await fetchSession(id: sessionId, onlyIfNeedsSummary: false)
    }

    private func fetchSession(id sessionId: Int64, onlyIfNeedsSummary: Bool) async throws -> PendingSession? {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw TranscriptionStorageError.databaseNotInitialized
        }

        if onlyIfNeedsSummary {
            // Filter must match `fetchEligibleSessionIds`'s OR-shape — otherwise
            // a session enqueued because (e.g.) only `overview` is empty gets
            // skipped here when it has a placeholder title, and the same row
            // bounces between enqueue and skip on every drain.
            let needsSummarySQL = """
                SELECT COUNT(*) FROM transcription_sessions
                 WHERE id = ?
                   AND finishedAt IS NOT NULL
                   AND summary_state = 'pending'
                   AND ((title IS NULL OR title = '')
                        OR (overview IS NULL OR overview = ''))
                """
            let needsSummary = try await dbQueue.read { db in
                try Int.fetchOne(db, sql: needsSummarySQL, arguments: [sessionId]) ?? 0
            }
            guard needsSummary > 0 else { return nil }
        }

        // Assemble transcript from segments, stripping WhisperKit tokens.
        // Single source of truth: `ConversationTranscriptLoader`.
        let transcript = try await ConversationTranscriptLoader
            .loadAssembled(sessionId: sessionId, dbQueue: dbQueue) ?? ""

        return PendingSession(id: sessionId, transcript: transcript)
    }

    /// Write the structured Ambient Audio placeholder defined in the contract:
    /// title=Ambient Audio, overview=…, emoji=🎧, category=other.
    private func writeAmbientAudioPlaceholder(sessionId: Int64) async throws {
        try await writePlaceholder(
            sessionId: sessionId,
            title: "Ambient Audio",
            overview: "This recording mostly contains ambient audio or non-speech sounds.",
            emoji: "🎧",
            category: "other"
        )
    }

    /// Write the "Summary Unavailable" structured placeholder for sessions
    /// whose `.summarize` pending-work row exhausted its retry budget. Wired
    /// up by `PowerWorkBridge`'s dead-letter callback. Distinct from the
    /// ambient/short-recording placeholders because this represents a
    /// real failure (LLM persistently unreachable or response unparsable),
    /// not a property of the audio itself.
    func writeUnavailablePlaceholder(sessionId: Int64) async throws {
        try await writePlaceholder(
            sessionId: sessionId,
            title: "Summary Unavailable",
            overview: "We couldn't generate a summary for this recording.",
            emoji: "⚠️",
            category: "other"
        )
    }

    private func writePlaceholder(
        sessionId: Int64,
        title: String,
        overview: String,
        emoji: String,
        category: String
    ) async throws {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw TranscriptionStorageError.databaseNotInitialized
        }
        let sql = """
            UPDATE transcription_sessions
               SET title = ?,
                   overview = ?,
                   emoji = ?,
                   category = ?,
                   summary_state = 'unavailable',
                   updatedAt = ?
             WHERE id = ?
            """
        try await dbQueue.write { db in
            try db.execute(
                sql: sql,
                arguments: [title, overview, emoji, category, Date(), sessionId]
            )
        }
    }

    /// Mark a session unsummarizable without overwriting its title/overview.
    /// Used when the dead-letter path or skip path needs to break the
    /// re-enqueue loop without touching the visible structured fields.
    func writeUnsummarizableState(sessionId: Int64, reason: String) async throws {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw TranscriptionStorageError.databaseNotInitialized
        }
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE transcription_sessions
                       SET summary_state = 'unavailable',
                           updatedAt = ?
                     WHERE id = ?
                    """,
                arguments: [Date(), sessionId]
            )
        }
        log("ConversationSummaryBackfillService: marked session \(sessionId) summary_state=unavailable (\(reason))")
    }

    /// Write the LLM-generated structured fields back to the session row.
    private func writeBack(sessionId: Int64, structured: SummaryResult) async throws {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw TranscriptionStorageError.databaseNotInitialized
        }
        let sql = """
            UPDATE transcription_sessions
               SET title = ?,
                   overview = ?,
                   emoji = ?,
                   category = ?,
                   summary_state = 'done',
                   updatedAt = ?
             WHERE id = ?
            """
        try await dbQueue.write { db in
            try db.execute(
                sql: sql,
                arguments: [
                    structured.title,
                    structured.overview,
                    structured.emoji,
                    structured.category,
                    Date(),
                    sessionId
                ]
            )
        }
    }

    // MARK: - LLM call

    private struct SummaryResult {
        let title: String
        let overview: String
        let emoji: String
        let category: String
    }

    /// Codable mirror for decoding the LLM's JSON response.
    private struct LLMSummaryResponse: Decodable {
        let title: String
        let overview: String
        let emoji: String
        let category: String
    }

    private func callLLM(transcript: String, sessionId: Int64, autonomous: Bool) async -> SummaryResult? {
        let truncated = transcript.count > Self.maxTranscriptLength
            ? String(transcript.prefix(Self.maxTranscriptLength)) + "..."
            : transcript

        let systemPrompt = """
            You are a conversation summarizer. Output ONLY a single valid JSON object — \
            no code fences, no prose, no commentary.

            Required fields:
            - "title": string, max 60 characters, a concise title for the conversation
            - "overview": string, 1–2 sentences summarizing what was discussed
            - "emoji": string, one single emoji that best represents the conversation topic
            - "category": string, exactly one of: meeting, conversation, note, call, planning, other
            """

        let userPrompt = "Transcript:\n\n\(truncated)"
        let label = "ConversationSummaryBackfill[\(sessionId)\(autonomous ? ":autonomous" : "")]"

        let raw: String?
        if autonomous {
            raw = await Self.generateJSONAutonomous(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                label: label
            )
        } else {
            raw = await LLMBridge.generateJSON(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                label: label
            )
        }

        guard let raw else { return nil }

        guard let data = raw.data(using: .utf8) else {
            log("ConversationSummaryBackfillService: session \(sessionId) — response not UTF-8")
            return nil
        }

        do {
            let decoded = try JSONDecoder().decode(LLMSummaryResponse.self, from: data)
            // Sanitise: trim and enforce title length.
            let title = String(decoded.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
            let overview = decoded.overview.trimmingCharacters(in: .whitespacesAndNewlines)
            let emoji = decoded.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
            let validCategories: Set<String> = ["meeting", "conversation", "note", "call", "planning", "other"]
            let category = validCategories.contains(decoded.category) ? decoded.category : "other"

            guard !title.isEmpty else {
                log("ConversationSummaryBackfillService: session \(sessionId) — decoded title is empty, skipping")
                return nil
            }

            return SummaryResult(title: title, overview: overview, emoji: emoji, category: category)
        } catch {
            // Use logError so this surfaces in error telemetry — JSON parse
            // failure is a real bug class (model regressed prompt format,
            // truncated response, etc.) not a routine transient. Include the
            // first 500 chars of the raw response (truncated, never the
            // transcript) so we can diagnose without leaking conversation
            // content. PR #30 review.
            let snippet = String(raw.prefix(500))
            logError(
                "ConversationSummaryBackfillService: session \(sessionId) — JSON parse failed; raw response (first 500): \(snippet)",
                error: error
            )
            return nil
        }
    }

    /// Autonomous-mode JSON generation. Routes through
    /// `LocalLLMClient.shared.chatAutonomous` which mirrors `chat(...)` but
    /// does NOT call `IdleAIController.recordAICall`, so Memory Saver can
    /// still unload the model after an autonomous drain.
    ///
    /// Augments the system prompt with a JSON-only instruction (mirroring
    /// `LLMBridge.generateJSON`) and strips ```json fences from the response
    /// best-effort. Returns nil on any error — matches `LLMBridge.generate`
    /// failure semantics so call-sites can stay graceful.
    private static func generateJSONAutonomous(
        systemPrompt: String,
        userPrompt: String,
        label: String
    ) async -> String? {
        let augmentedSystem = systemPrompt + "\n\nRespond ONLY with a single valid JSON object that conforms to the schema described in the user prompt. Do not include code fences, prose, or commentary."
        let messages: [LLM.ChatMessage] = [
            .init(role: .system, content: augmentedSystem),
            .init(role: .user, content: userPrompt),
        ]

        do {
            let stream = try await LocalLLMClient.shared.chatAutonomous(
                messages: messages,
                stream: false
            )
            var fullText = ""
            for try await chunk in stream {
                fullText += chunk.delta
            }
            return LLMBridge.stripJSONWrapper(fullText)
        } catch {
            log("[\(label)] autonomous LLM call failed: \(error.localizedDescription)")
            return nil
        }
    }
}
