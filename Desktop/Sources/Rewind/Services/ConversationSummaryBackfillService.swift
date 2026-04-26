import Foundation
import GRDB

/// One-time backfill actor that generates structured summaries (title, overview,
/// emoji, category) for finished conversations whose structured fields are empty.
///
/// These fields were originally filled by the cloud-backed Omi extraction
/// pipeline which is not present in the local-first fork.  Historical sessions
/// recorded before the local extraction pipeline was wired therefore have null
/// title/overview and appear as "Untitled Conversation" in the list.
///
/// Idempotency guarantee: the UserDefaults flag
/// `conversationSummaryBackfillCompleted_v2` is set only after 3 consecutive
/// empty queries confirm there is nothing left to process.  Running this 100
/// times is safe. v2 intentionally re-runs on machines where an earlier broken
/// v1 attempt marked completion before local summaries were reliably generated.
///
/// Battery awareness: the loop only runs when
/// `BatteryAwareScheduler.shared.allowHeavyWork` is true.  If the machine is
/// on battery / low-power at launch the service logs a skip and exits; the flag
/// is intentionally NOT set so the next launch retries.
actor ConversationSummaryBackfillService {
    static let shared = ConversationSummaryBackfillService()

    private static let userDefaultsKey = "conversationSummaryBackfillCompleted_v2"
    /// Nanoseconds to sleep between individual LLM calls (~1 s).
    private static let throttleNanoseconds: UInt64 = 1_000_000_000
    /// Minimum total transcript length (chars) to bother summarizing.
    private static let minTranscriptLength = 30
    /// Maximum transcript length (chars) sent to the LLM.
    private static let maxTranscriptLength = 6000
    /// How many consecutive empty queries before we declare completion.
    private static let emptyBatchTerminationCount = 3

    private init() {}

    // MARK: - Public API

    /// Entry point.  Call once after capture services are initialized.
    /// Returns immediately if the backfill has already completed or if the
    /// machine lacks headroom to run heavy work.
    func runIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: Self.userDefaultsKey) else {
            log("ConversationSummaryBackfillService: already complete (v2), skipping")
            return
        }

        guard await MainActor.run(body: { BatteryAwareScheduler.shared.allowHeavyWork }) else {
            log("ConversationSummaryBackfillService: heavy work not allowed (battery/thermal), will retry next launch")
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

    /// Summarize one just-finished session immediately instead of waiting for
    /// the historical backfill lifecycle. Safe to call repeatedly: rows that
    /// already have a title or overview are ignored.
    func summarizeSessionIfNeeded(_ sessionId: Int64, reason: String) async {
        guard await MainActor.run(body: { BatteryAwareScheduler.shared.allowHeavyWork }) else {
            markBackfillNeeded(reason: "live summary deferred for session \(sessionId): heavy work not allowed")
            log("ConversationSummaryBackfillService: live summary deferred for session \(sessionId) — heavy work not allowed (\(reason))")
            return
        }

        do {
            guard let row = try await fetchSession(id: sessionId, onlyIfNeedsSummary: true) else {
                log("ConversationSummaryBackfillService: live summary skipped for session \(sessionId) — already summarized or missing (\(reason))")
                return
            }
            let outcome = try await process(row: row, mode: "live \(reason)")
            if case .deferred = outcome {
                markBackfillNeeded(reason: "live summary deferred for session \(sessionId)")
            }
        } catch {
            markBackfillNeeded(reason: "live summary error for session \(sessionId)")
            logError("ConversationSummaryBackfillService: live summary failed for session \(sessionId)", error: error)
        }
    }

    // MARK: - Private

    private func backfillLoop(startTime: Date) async throws {
        var totalProcessed = 0
        var consecutiveEmpty = 0

        while consecutiveEmpty < Self.emptyBatchTerminationCount {
            // Re-check power state between rows.
            guard await MainActor.run(body: { BatteryAwareScheduler.shared.allowHeavyWork }) else {
                log("ConversationSummaryBackfillService: pausing — power conditions changed after \(totalProcessed) rows, will retry next launch")
                return
            }

            guard let row = try await fetchNextSession() else {
                consecutiveEmpty += 1
                log("ConversationSummaryBackfillService: empty query (\(consecutiveEmpty)/\(Self.emptyBatchTerminationCount))")
                continue
            }

            consecutiveEmpty = 0

            let outcome = try await process(row: row, mode: "backfill")
            switch outcome {
            case .summarized:
                totalProcessed += 1
                // Throttle: give the LLM server a brief breather.
                try await Task.sleep(nanoseconds: Self.throttleNanoseconds)
            case .placeholder:
                continue
            case .deferred:
                // Do not spin forever on the same row if the local LLM is
                // offline or returned unparsable JSON. Leave it eligible and
                // retry on the next launch/manual trigger.
                log("ConversationSummaryBackfillService: deferred after LLM/parse failure; will retry later")
                return
            }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        UserDefaults.standard.set(true, forKey: Self.userDefaultsKey)
        log(String(format: "ConversationSummaryBackfillService: complete — %d rows in %.1fs", totalProcessed, elapsed))
    }

    private enum ProcessOutcome {
        case summarized
        case placeholder
        case deferred
    }

    private func process(row: PendingSession, mode: String) async throws -> ProcessOutcome {
        let sessionId = row.id
        let transcript = row.transcript

        guard transcript.count >= Self.minTranscriptLength else {
            log("ConversationSummaryBackfillService: session \(sessionId) transcript too short (\(transcript.count) chars), writing placeholder (\(mode))")
            // Write a sentinel so it won't be re-selected on the next run.
            try await writeBackPlaceholder(sessionId: sessionId)
            await notifyConversationListNeedsRefresh()
            return .placeholder
        }

        log("ConversationSummaryBackfillService: summarizing session \(sessionId) (\(transcript.count) chars, \(mode))")

        guard let structured = await callLLM(transcript: transcript, sessionId: sessionId) else {
            log("ConversationSummaryBackfillService: session \(sessionId) summary deferred due to LLM/parse failure (\(mode))")
            return .deferred
        }

        try await writeBack(sessionId: sessionId, structured: structured)
        log("ConversationSummaryBackfillService: session \(sessionId) → \"\(structured.title)\" (\(mode))")
        await notifyConversationListNeedsRefresh()
        return .summarized
    }

    private func notifyConversationListNeedsRefresh() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .conversationsListNeedsRefresh, object: nil)
        }
    }

    // MARK: - Database helpers

    /// Holds one row from the "needs summary" query.
    private struct PendingSession {
        let id: Int64
        let transcript: String
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
               AND (title IS NULL OR title = '')
               AND (overview IS NULL OR overview = '')
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
            let needsSummarySQL = """
                SELECT COUNT(*) FROM transcription_sessions
                 WHERE id = ?
                   AND finishedAt IS NOT NULL
                   AND (title IS NULL OR title = '')
                   AND (overview IS NULL OR overview = '')
                """
            let needsSummary = try await dbQueue.read { db in
                try Int.fetchOne(db, sql: needsSummarySQL, arguments: [sessionId]) ?? 0
            }
            guard needsSummary > 0 else { return nil }
        }

        // Assemble transcript from segments, stripping WhisperKit tokens.
        let segmentSQL = """
            SELECT text FROM transcription_segments
             WHERE sessionId = ?
             ORDER BY segmentOrder ASC
            """
        let rawTexts: [String] = try await dbQueue.read { db in
            try String.fetchAll(db, sql: segmentSQL, arguments: [sessionId])
        }

        let transcript = rawTexts
            .map { $0.replacingOccurrences(of: #"<\|[^|>]+\|>"#, with: "", options: .regularExpression)
                      .trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return PendingSession(id: sessionId, transcript: transcript)
    }

    /// Write a non-empty sentinel back for a session whose transcript is too
    /// short to summarize, so it won't be re-queried.
    private func writeBackPlaceholder(sessionId: Int64) async throws {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw TranscriptionStorageError.databaseNotInitialized
        }
        let sql = """
            UPDATE transcription_sessions
               SET title = ?,
                   overview = ?,
                   emoji = ?,
                   category = ?,
                   updatedAt = ?
             WHERE id = ?
            """
        try await dbQueue.write { db in
            try db.execute(
                sql: sql,
                arguments: ["Short Recording", "", "🎙", "other", Date(), sessionId]
            )
        }
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

    private func callLLM(transcript: String, sessionId: Int64) async -> SummaryResult? {
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

        guard let raw = await LLMBridge.generateJSON(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            label: "ConversationSummaryBackfill[\(sessionId)]"
        ) else {
            return nil
        }

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
            log("ConversationSummaryBackfillService: session \(sessionId) — JSON parse failed (\(raw.prefix(200))): \(error.localizedDescription)")
            return nil
        }
    }
}
