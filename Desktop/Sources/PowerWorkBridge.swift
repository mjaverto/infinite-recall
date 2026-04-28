import Foundation
import GRDB

/// Wires `BatteryAwareScheduler` up to the actual heavy-ML consumers in the
/// app: WhisperKit transcription and Vision-framework OCR.
///
/// Sprint M shipped the scheduler + queue + power monitor; this bridge is the
/// minimum glue that turns "I have AC and a queue" into "go transcribe these
/// audio chunks / OCR these screenshots". It is intentionally a separate file
/// from `TranscriptionService.swift` and `RewindIndexer.swift` because
/// `Desktop/Sources/Power/` is owned by Sprint M and we don't want to add
/// per-consumer knowledge there.
///
/// Lifecycle: `PowerWorkBridge.shared.start()` is called once from
/// `AppDelegate.applicationDidFinishLaunching`. It:
/// 1. Starts `BatteryAwareScheduler.shared` (which itself starts
///    `PowerStateMonitor.shared`).
/// 2. Registers per-kind handlers (`.transcribe`, `.ocr`, `.summarize`, `.extractKG`).
///
/// Handlers are stored as `@Sendable` closures on the scheduler. They MUST NOT
/// strong-capture this bridge (or `TranscriptionService` / `RewindIndexer`
/// instances) — the scheduler can outlive any individual capture session.
@MainActor
final class PowerWorkBridge {
    static let shared = PowerWorkBridge()

    private var started: Bool = false

    /// Single shared extractor instance used by the `.extractKG` handler.
    /// Constructed lazily so the LLM bridge isn't touched at app launch.
    fileprivate static let kgExtractor: KGExtractor = KGExtractor()

    private init() {}

    /// Idempotent. Call once at app launch.
    func start() {
        guard !started else { return }
        started = true

        // Make sure the scheduler is running and observing power transitions.
        BatteryAwareScheduler.shared.start()

        // .transcribe — pull audio_chunks rows that overlap the queued window
        // and run a one-shot WhisperKit batchTranscribe per chunk. Posts
        // `.powerWorkBridgeDeferredTranscript` for the foreground UI to
        // consume; no direct call back into TranscriptionService.
        BatteryAwareScheduler.shared.registerHandler(for: .transcribe) { work in
            try await PowerWorkBridge.handleTranscribe(work)
        }

        // .ocr — pull the screenshot row by id and run Vision OCR through the
        // existing RewindOCRService, then update the DB row in place.
        BatteryAwareScheduler.shared.registerHandler(for: .ocr) { work in
            try await PowerWorkBridge.handleOCR(work)
        }

        // .summarize — autonomous title/overview generation. Decode the
        // session_id payload and route through Agent A's
        // `ConversationSummaryBackfillService.processSummary(sessionId:autonomous:)`.
        // The `autonomous: true` flag forces the LLM call through
        // `LocalLLMClient.chatAutonomous` so Memory Saver can still unload the
        // model after the queue drains.
        BatteryAwareScheduler.shared.registerHandler(for: .summarize) { work in
            try await PowerWorkBridge.handleSummarize(work)
        }

        // .extractKG — autonomous brain-map extraction. Decodes a
        // `{"memory_id": Int64}` payload, runs `KGExtractor`, and either
        // upserts nodes/edges via `KnowledgeGraphStorage.upsert(...)` or
        // marks the memory's `kg_extraction_status` as empty/failed.
        BatteryAwareScheduler.shared.registerHandler(for: .extractKG) { work in
            try await PowerWorkBridge.handleExtractKG(work)
        }

        // .extractActionItems — pull task-shaped items from a finished
        // conversation's transcript. Decodes `{"session_id": Int64}` and
        // routes through `LLMBridge.generateJSON` (NOT `chatAutonomous`):
        // this kind only requires `allowHeavyWork`, so the user may still be
        // active and Memory Saver must be allowed to keep the model warm.
        BatteryAwareScheduler.shared.registerHandler(for: .extractActionItems) { work in
            try await PowerWorkBridge.handleExtractActionItems(work)
        }

        // Start the periodic sweeper that reclaims expired leases and GCs old rows.
        PendingWorkSweeper.shared.start()

        // Wire the dead-letter callback so summary jobs that exhaust their
        // retry budget surface a structured "Summary Unavailable" placeholder
        // instead of leaving a permanently-pending UI row. The callback is
        // `@Sendable` and runs from inside `PendingWorkStorage.fail()` after
        // the SQL transition completes.
        Task {
            await PendingWorkStorage.shared.setDeadLetterCallback { workType, payload in
                await PowerWorkBridge.handleDeadLetter(workType: workType, payload: payload)
            }
        }

        // Summary backfill launch hooks (moved from AppState.init so they run
        // strictly AFTER `BatteryAwareScheduler.shared.start()` and the
        // `.summarize` handler registration above). Fire-and-forget — both
        // calls are async + idempotent and tolerate DB-not-yet-initialized
        // by retrying lazily inside their own implementations.
        Task { @MainActor in
            do {
                let repaired = try await TranscriptionStorage.shared.repairFinishedInProgressSessions()
                if repaired > 0 {
                    log("PowerWorkBridge: repaired \(repaired) finished non-terminal session(s) on launch")
                }
            } catch {
                logError("PowerWorkBridge: repairFinishedInProgressSessions failed", error: error)
            }
            await ConversationSummaryBackfillService.shared
                .enqueueHistoricalSummariesIfNeeded(reason: "launch")
            await ConversationTranscribeBackfillService.shared
                .enqueueHistoricalTranscribesIfNeeded(reason: "launch")
            await ConversationActionItemsBackfillService.shared
                .enqueueHistoricalActionItemsIfNeeded(reason: "launch")
        }

        log("PowerWorkBridge: Started — registered .transcribe, .ocr, .summarize, .extractKG, and .extractActionItems handlers")
    }

    // MARK: - Dead-letter handler

    /// Called by `PendingWorkStorage` when a row exhausts `maxAttempts` and
    /// transitions to `dead`. For `.summarize` work, decode the payload and
    /// write a structured "Summary Unavailable" placeholder so the row stops
    /// rendering as indefinitely-pending in the UI; then post a list-refresh
    /// notification.
    @Sendable
    fileprivate static func handleDeadLetter(workType: String, payload: Data) async {
        switch workType {
        case PendingWork.Kind.summarize.rawValue:
            await handleDeadLetterSummarize(payload: payload)
        case PendingWork.Kind.extractKG.rawValue:
            await handleDeadLetterExtractKG(payload: payload)
        case PendingWork.Kind.extractActionItems.rawValue:
            await handleDeadLetterExtractActionItems(payload: payload)
        default:
            return
        }
    }

    @Sendable
    fileprivate static func handleDeadLetterSummarize(payload: Data) async {
        struct Payload: Decodable { let session_id: Int64 }
        let sessionId: Int64
        do {
            sessionId = try JSONDecoder().decode(Payload.self, from: payload).session_id
        } catch {
            logError("PowerWorkBridge: dead-letter payload undecodable for summarize", error: error)
            return
        }

        do {
            try await ConversationSummaryBackfillService.shared.writeUnavailablePlaceholder(sessionId: sessionId)
            log("PowerWorkBridge: dead-letter — wrote Summary Unavailable placeholder for session \(sessionId)")
        } catch {
            logError("PowerWorkBridge: dead-letter — placeholder write failed for session \(sessionId)", error: error)
        }

        await MainActor.run {
            NotificationCenter.default.post(
                name: .conversationsListNeedsRefresh,
                object: nil,
                userInfo: ["session_id": sessionId]
            )
        }
    }

    /// Cluster E1: when an `.extractKG` row exhausts its retry budget,
    /// transition the memory's `kg_extraction_status` to `.failed` so the
    /// progress publisher counts it correctly (otherwise it'd remain NULL
    /// and forever inflate the "remaining memories" denominator).
    @Sendable
    fileprivate static func handleDeadLetterExtractKG(payload: Data) async {
        struct Payload: Decodable { let memory_id: Int64 }
        let memoryId: Int64
        do {
            memoryId = try JSONDecoder().decode(Payload.self, from: payload).memory_id
        } catch {
            // Payload was undecodable when we tried to extract too; nothing
            // we can do at dead-letter time. Logged in the handler already.
            logError("PowerWorkBridge: dead-letter — extractKG payload undecodable", error: error)
            return
        }
        do {
            try await MemoryStorage.shared.setKGExtractionStatus(id: memoryId, status: .failed)
            log("PowerWorkBridge: dead-letter — marked memory \(memoryId) kg_extraction_status='failed'")
        } catch {
            logError("PowerWorkBridge: dead-letter — failed to write kg_extraction_status for memory \(memoryId)", error: error)
        }
        await KGProgressPublisher.shared.tick()
    }

    // MARK: - Transcribe handler

    /// Decode a .transcribe payload and run WhisperKit on the matching
    /// audio_chunks rows. Two payload shapes are accepted on the same workType:
    ///
    /// 1. Window-shaped (`{started_at, ended_at, language?, ...}`) — produced
    ///    by `TranscriptionService` when live Whisper is gated by
    ///    battery/thermal. Drains by wall-clock window and emits transcripts
    ///    via `.powerWorkBridgeDeferredTranscript`.
    /// 2. Session-shaped (`{session_id}`) — produced by
    ///    `ConversationTranscribeBackfillService` for finished sessions whose
    ///    audio_chunks were never transcribed (e.g. status='failed' mid-
    ///    lifecycle). Drains by session and persists to `transcription_segments`.
    ///
    /// Per-row failures are tolerable and we move on so one bad chunk doesn't
    /// stall the drain. Malformed JSON throws so the row stays queued for
    /// retry/inspection rather than being silently ack'd as `done`.
    fileprivate static func handleTranscribe(_ work: PendingWork) async throws {
        let json = try JSONSerialization.jsonObject(with: work.payload, options: [])
        guard let dict = json as? [String: Any] else {
            throw NSError(
                domain: "PowerWorkBridge", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "transcribe payload not a JSON object"]
            )
        }

        // If `session_id` is present at all, commit to the session branch.
        // A type mismatch throws so the row stays for retry rather than
        // silently falling through to the window decoder and getting ack-dropped.
        if let rawSessionId = dict["session_id"] {
            let sessionId: Int64
            if let v = rawSessionId as? Int64 {
                sessionId = v
            } else if let v = rawSessionId as? Int {
                sessionId = Int64(v)
            } else {
                throw NSError(
                    domain: "PowerWorkBridge", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "transcribe session_id has unsupported type \(type(of: rawSessionId))"]
                )
            }
            try await handleTranscribeSession(sessionId: sessionId)
            return
        }

        guard
            let startedStr = dict["started_at"] as? String,
            let endedStr = dict["ended_at"] as? String,
            let started = ISO8601DateFormatter().date(from: startedStr),
            let ended = ISO8601DateFormatter().date(from: endedStr)
        else {
            logError(
                "PowerWorkBridge: .transcribe payload undecodable, dropping",
                error: NSError(domain: "PowerWorkBridge", code: 2,
                               userInfo: [NSLocalizedDescriptionKey: "transcribe payload undecodable"])
            )
            return
        }
        let language = (dict["language"] as? String) ?? "en"

        // Fetch matching audio_chunks rows from GRDB.
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            log("PowerWorkBridge: .transcribe — DB not initialized, leaving in queue")
            throw NSError(domain: "PowerWorkBridge", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Database not initialized for transcribe drain"
            ])
        }

        let rows: [(id: Int64, startedAt: Date, pcm: Data)]
        do {
            rows = try await dbQueue.read { db -> [(id: Int64, startedAt: Date, pcm: Data)] in
                let cursor = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT id, startedAt, pcm FROM audio_chunks
                        WHERE startedAt >= ? AND startedAt <= ?
                        ORDER BY startedAt ASC
                        """,
                    arguments: [started, ended]
                )
                var out: [(id: Int64, startedAt: Date, pcm: Data)] = []
                while let row = try cursor.next() {
                    let id: Int64 = row["id"] ?? 0
                    let s: Date = row["startedAt"] ?? Date()
                    let pcm: Data = row["pcm"] ?? Data()
                    out.append((id, s, pcm))
                }
                return out
            }
        } catch {
            logError("PowerWorkBridge: .transcribe — DB read failed", error: error)
            throw error
        }

        if rows.isEmpty {
            log("PowerWorkBridge: .transcribe — no audio_chunks in window \(started)…\(ended); marking done")
            return
        }

        var transcribedCount = 0
        for row in rows {
            do {
                let text = try await TranscriptionService.batchTranscribe(
                    audioData: row.pcm,
                    language: language,
                    apiKey: nil
                )
                guard let text = text, !text.isEmpty else { continue }
                transcribedCount += 1

                // Emit a synthetic BackendSegment so any live UI path that
                // observes transcript updates (LiveTranscriptMonitor etc.)
                // sees the deferred result. We don't have a foreground
                // TranscriptionService callback here, so we post a global
                // notification with the transcript text + id and let
                // interested observers pick it up.
                let chunkDuration: Double = {
                    let samples = row.pcm.count / 2
                    if samples <= 0 { return 0 }
                    return Double(samples) / 16000.0
                }()
                let info: [String: Any] = [
                    "audio_chunk_id": row.id,
                    "started_at": row.startedAt,
                    "duration_sec": chunkDuration,
                    "text": text,
                ]
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .powerWorkBridgeDeferredTranscript,
                        object: nil,
                        userInfo: info
                    )
                }
            } catch {
                logError(
                    "PowerWorkBridge: .transcribe — chunk \(row.id) failed",
                    error: error
                )
                // Continue with next chunk; don't fail the whole drain.
            }
        }

        log("PowerWorkBridge: .transcribe — drained \(transcribedCount)/\(rows.count) chunks for window \(started)…\(ended)")
    }

    /// Session-shaped `.transcribe` drain: load every audio_chunk linked to
    /// the session via `transcriptionSessionId`, run WhisperKit per chunk,
    /// and persist the result as a `transcription_segments` row. Used by
    /// `ConversationTranscribeBackfillService` to recover finished sessions
    /// that never produced live segments.
    fileprivate static func handleTranscribeSession(sessionId: Int64) async throws {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            log("PowerWorkBridge: .transcribe(session) — DB not initialized, leaving in queue")
            throw NSError(domain: "PowerWorkBridge", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Database not initialized for transcribe drain"
            ])
        }

        struct SessionInfo {
            let startedAt: Date
            let language: String
        }

        let sessionInfo: SessionInfo?
        do {
            sessionInfo = try await dbQueue.read { db -> SessionInfo? in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT startedAt, language FROM transcription_sessions WHERE id = ? AND deleted = 0",
                    arguments: [sessionId]
                ) else { return nil }
                let started: Date = row["startedAt"] ?? Date()
                let language: String = row["language"] ?? "en"
                return SessionInfo(startedAt: started, language: language)
            }
        } catch {
            logError("PowerWorkBridge: .transcribe(session) — DB read failed for session \(sessionId)", error: error)
            throw error
        }

        guard let info = sessionInfo else {
            log("PowerWorkBridge: .transcribe(session) — session \(sessionId) missing or deleted, ack-and-skip")
            return
        }

        // Bail if non-empty segments already exist. `transcription_segments`
        // has no uniqueness constraint, so re-running per-chunk Whisper would
        // double the rows for any happy-path session that slipped past the
        // enqueue-side guard (race between concurrent finishConversation calls,
        // out-of-order drains, etc.). Predicate MUST match the
        // `text IS NOT NULL AND TRIM(text) <> ''` filter used by
        // `ConversationTranscribeBackfillService.sessionHasSegments` and
        // `fetchEligibleSessionIds` — a session with only empty-text rows
        // must remain eligible to drain, not be silently ack-skipped.
        let existingSegmentCount: Int
        do {
            existingSegmentCount = try await dbQueue.read { db -> Int in
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
        } catch {
            logError("PowerWorkBridge: .transcribe(session) — segment-count check failed for session \(sessionId)", error: error)
            throw error
        }
        if existingSegmentCount > 0 {
            log("PowerWorkBridge: .transcribe(session) — session \(sessionId) already has \(existingSegmentCount) non-empty segment(s), ack-and-skip")
            return
        }

        let rows: [(id: Int64, startedAt: Date, durationSeconds: Double, pcm: Data)]
        do {
            rows = try await dbQueue.read { db -> [(id: Int64, startedAt: Date, durationSeconds: Double, pcm: Data)] in
                let cursor = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT id, startedAt, durationSeconds, pcm FROM audio_chunks
                        WHERE transcriptionSessionId = ?
                        ORDER BY startedAt ASC
                        """,
                    arguments: [sessionId]
                )
                var out: [(id: Int64, startedAt: Date, durationSeconds: Double, pcm: Data)] = []
                while let row = try cursor.next() {
                    let id: Int64 = row["id"] ?? 0
                    let s: Date = row["startedAt"] ?? Date()
                    let dur: Double = row["durationSeconds"] ?? 0
                    let pcm: Data = row["pcm"] ?? Data()
                    out.append((id, s, dur, pcm))
                }
                return out
            }
        } catch {
            logError("PowerWorkBridge: .transcribe(session) — audio_chunks read failed for session \(sessionId)", error: error)
            throw error
        }

        if rows.isEmpty {
            log("PowerWorkBridge: .transcribe(session) — no audio_chunks for session \(sessionId); marking done")
            return
        }

        var transcribedCount = 0
        // FIXME: speaker hardcoded to 0 — diarization gap for the backfill case.
        for row in rows {
            do {
                let text = try await TranscriptionService.batchTranscribe(
                    audioData: row.pcm,
                    language: info.language,
                    apiKey: nil
                )
                guard let text = text, !text.isEmpty else {
                    // Surface this so we can audit how often Whisper drains to
                    // empty on real audio (vs. ambient/silence).
                    logError(
                        "PowerWorkBridge: .transcribe(session) — chunk \(row.id) produced empty transcript for session \(sessionId)",
                        error: NSError(domain: "PowerWorkBridge", code: 5,
                                       userInfo: [NSLocalizedDescriptionKey: "empty Whisper output"])
                    )
                    continue
                }

                let startTime = row.startedAt.timeIntervalSince(info.startedAt)
                let endTime = startTime + row.durationSeconds
                _ = try await TranscriptionStorage.shared.appendSegment(
                    sessionId: sessionId,
                    speaker: 0,
                    text: text,
                    startTime: startTime,
                    endTime: endTime
                )
                transcribedCount += 1
            } catch {
                logError(
                    "PowerWorkBridge: .transcribe(session) — chunk \(row.id) failed",
                    error: error
                )
            }
        }

        if transcribedCount == 0 {
            // Audit signal: a session-shaped drain that processed chunks but
            // wrote zero segments. The eligibility query already guards against
            // re-enqueuing this session (it excludes `done` rows for the same
            // dedup key), but the cohort itself is worth tracking.
            logError(
                "PowerWorkBridge: .transcribe(session) — session \(sessionId) drained \(rows.count) chunk(s) to zero segments",
                error: NSError(domain: "PowerWorkBridge", code: 6,
                               userInfo: [NSLocalizedDescriptionKey: "zero segments after Whisper pass"])
            )
        } else {
            log("PowerWorkBridge: .transcribe(session) — drained \(transcribedCount)/\(rows.count) chunks for session \(sessionId)")
        }

        // After segments land, the summary backfill (queries on
        // summary_state='pending' + finishedAt + segments-exist) picks this
        // session up automatically.
        await MainActor.run {
            NotificationCenter.default.post(
                name: .conversationsListNeedsRefresh,
                object: nil,
                userInfo: ["session_id": sessionId]
            )
        }
    }

    // MARK: - OCR handler

    /// Decode an .ocr payload (screenshot id) and run RewindOCRService on it.
    /// Updates the row in place, clearing `skippedForBattery`.
    fileprivate static func handleOCR(_ work: PendingWork) async throws {
        guard
            let json = try? JSONSerialization.jsonObject(with: work.payload, options: []),
            let dict = json as? [String: Any],
            let id = (dict["screenshot_id"] as? Int64) ?? (dict["screenshot_id"] as? Int).map(Int64.init)
        else {
            logError(
                "PowerWorkBridge: .ocr payload undecodable, dropping",
                error: NSError(domain: "PowerWorkBridge", code: 3,
                               userInfo: [NSLocalizedDescriptionKey: "ocr payload undecodable"])
            )
            return
        }

        let screenshot: Screenshot?
        do {
            screenshot = try await RewindDatabase.shared.getScreenshot(id: id)
        } catch {
            logError("PowerWorkBridge: .ocr — DB read failed for id \(id)", error: error)
            throw error
        }

        guard let shot = screenshot else {
            // Row was deleted (retention cleanup, etc.) — no work to do.
            log("PowerWorkBridge: .ocr — screenshot \(id) no longer exists, skipping")
            return
        }

        do {
            let nsImage = try await RewindStorage.shared.loadScreenshotImage(for: shot)
            guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                log("PowerWorkBridge: .ocr — could not get CGImage for screenshot \(id)")
                try? await RewindDatabase.shared.clearSkippedForBattery(id: id)
                return
            }

            let ocrResult = try await Task(priority: .utility) {
                try await RewindOCRService.shared.extractTextWithBounds(from: cgImage)
            }.value

            try await RewindDatabase.shared.updateOCRResult(id: id, ocrResult: ocrResult)
        } catch RewindError.screenshotNotFound {
            try? await RewindDatabase.shared.clearSkippedForBattery(id: id)
        } catch let RewindError.corruptedVideoChunk(path) {
            log("PowerWorkBridge: .ocr — corrupted chunk \(path) for screenshot \(id)")
            try? await RewindDatabase.shared.clearSkippedForBattery(id: id)
        } catch {
            logError("PowerWorkBridge: .ocr — failed for screenshot \(id)", error: error)
            // Clear the flag so we don't retry forever on a permanently broken
            // row. (Same defensive policy as the legacy backfill path.)
            try? await RewindDatabase.shared.clearSkippedForBattery(id: id)
        }
    }

    // MARK: - Summarize handler

    /// Decode a `.summarize` payload (`{"session_id": Int64}`) and invoke
    /// `ConversationSummaryBackfillService.shared.processSummary(sessionId:autonomous:)`
    /// with `autonomous: true`. Throws on retryable failure so PendingWork
    /// retry/backoff can take over. Posts `.conversationsListNeedsRefresh`
    /// after a successful processing pass so the conversations list updates
    /// without an app relaunch.
    fileprivate static func handleSummarize(_ work: PendingWork) async throws {
        try await _handleSummarizePayload(
            work.payload,
            processor: { sessionId in
                try await ConversationSummaryBackfillService.shared.processSummary(
                    sessionId: sessionId,
                    autonomous: true
                )
            },
            notify: { sessionId in
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .conversationsListNeedsRefresh,
                        object: nil,
                        userInfo: ["session_id": sessionId]
                    )
                }
            }
        )
    }

    /// Testable seam for `handleSummarize`. Decodes the payload, invokes the
    /// injected `processor`, then `notify`. Mirrors the production semantics:
    /// undecodable payload → no throw, no notify, no processor call;
    /// processor throw → re-thrown, no notify; success → notify called.
    /// Visible to tests via `@testable import`.
    static func _handleSummarizePayload(
        _ payload: Data,
        processor: (Int64) async throws -> Void,
        notify: (Int64) async -> Void
    ) async throws {
        struct Payload: Decodable {
            let session_id: Int64
        }

        let sessionId: Int64
        do {
            sessionId = try JSONDecoder().decode(Payload.self, from: payload).session_id
        } catch {
            // Undecodable payload is not retryable. logError so we get
            // telemetry visibility, then return so the row gets ack'd and
            // removed from the queue.
            logError("PowerWorkBridge: .summarize payload undecodable, dropping", error: error)
            return
        }

        do {
            try await processor(sessionId)
        } catch {
            // Re-throw so the scheduler calls PendingWorkStorage.fail() and
            // backoff/retry kicks in. Per Agent A's design, processSummary
            // throws ONLY on retryable failures (LLM unreachable, transient
            // DB error). Non-retryable conditions return normally.
            logError("PowerWorkBridge: .summarize — session \(sessionId) failed (will retry)", error: error)
            throw error
        }

        // Success path — let the conversations list refresh.
        await notify(sessionId)
        log("PowerWorkBridge: .summarize — session \(sessionId) done")
    }

    // MARK: - Extract KG handler

    /// Decode an `.extractKG` payload (`{"memory_id": Int64}`), load the
    /// memory, run `KGExtractor`, and persist the outcome.
    ///
    /// Outcome routing:
    /// - `.parsed | .recovered | .truncatedRetried` with rows → upsert via
    ///   `KnowledgeGraphStorage.upsert(...)` and mark `kg_extraction_status =
    ///   'succeeded'`.
    /// - `.empty(*)` → mark `kg_extraction_status = 'empty'`, no rows.
    /// - `.failed(*)` → mark `kg_extraction_status = 'failed'` and rethrow so
    ///   the scheduler applies retry/backoff (and ultimately dead-letters).
    /// - Memory deleted mid-drain (`getMemory` returns nil) → ack and return
    ///   without an error log; same defensive pattern as the OCR handler at
    ///   the top of this file.
    fileprivate static func handleExtractKG(_ work: PendingWork) async throws {
        struct Payload: Decodable { let memory_id: Int64 }

        let memoryId: Int64
        do {
            memoryId = try JSONDecoder().decode(Payload.self, from: work.payload).memory_id
        } catch {
            // Cluster G: an undecodable payload previously logged + returned
            // success → row ack'd → memory's `kg_extraction_status` stays
            // NULL forever. Throw instead so the row enters retry/backoff
            // and eventually dead-letters. We can't surface a memoryId
            // because the payload didn't yield one; the dead-letter callback
            // skips when the workType doesn't match a known kind.
            logError(
                "PowerWorkBridge: .extractKG payload undecodable; throwing to dead-letter",
                error: error
            )
            throw error
        }

        let record: MemoryRecord?
        do {
            record = try await MemoryStorage.shared.getMemory(id: memoryId)
        } catch {
            logError("PowerWorkBridge: .extractKG — DB read failed for memory \(memoryId)", error: error)
            throw error
        }

        // Cluster J: distinguish "memory not found" from "memory soft-deleted"
        // in the log so production telemetry can tell DB-vs-soft-delete apart.
        if record == nil {
            log("PowerWorkBridge: .extractKG — memory \(memoryId) not found, ack-and-skip")
            return
        }
        if record?.deleted == true {
            log("PowerWorkBridge: .extractKG — memory \(memoryId) soft-deleted, ack-and-skip")
            return
        }
        guard let memory = record, let realId = memory.id else {
            log("PowerWorkBridge: .extractKG — memory \(memoryId) record missing id, ack-and-skip")
            return
        }

        let drainStart = Date()
        let extraction: KGExtraction
        do {
            extraction = try await Self.kgExtractor.extract(
                memoryId: realId,
                content: memory.content,
                sourceApp: memory.sourceApp
            )
        } catch {
            // Extractor itself threw (LLM unreachable, etc.). Mark failed and
            // rethrow so PendingWork retry/backoff takes over.
            // Cluster C3: log when status write fails so silent drops are visible.
            do {
                try await MemoryStorage.shared.setKGExtractionStatus(id: realId, status: .failed)
            } catch let statusError {
                logError("PowerWorkBridge: .extractKG — setKGExtractionStatus(.failed) failed for memory \(realId) (will be re-extracted on retry)", error: statusError)
            }
            await KGProgressPublisher.shared.tick()
            throw error
        }

        switch extraction.outcome {
        case .parsed, .recovered, .truncatedRetried:
            if extraction.nodes.isEmpty && extraction.edges.isEmpty {
                // Defensive: shouldn't happen because the extractor collapses
                // an empty success into `.empty(...)`, but keep the status
                // writeable just in case.
                do {
                    try await MemoryStorage.shared.setKGExtractionStatus(id: realId, status: .empty)
                } catch let statusError {
                    logError("PowerWorkBridge: .extractKG — setKGExtractionStatus(.empty/defensive) failed for memory \(realId)", error: statusError)
                }
            } else {
                do {
                    // Cluster B2: upsert + status now ride in the same
                    // transaction so a crash between them is impossible.
                    _ = try await KnowledgeGraphStorage.shared.upsert(
                        memoryId: realId,
                        nodes: extraction.nodes,
                        edges: extraction.edges,
                        terminalStatus: .succeeded
                    )
                } catch {
                    // Upsert failure is retryable (DB transient) — mark failed
                    // out-of-band (best-effort; if THIS write also fails the
                    // row will simply be re-extracted on retry, which is fine).
                    do {
                        try await MemoryStorage.shared.setKGExtractionStatus(id: realId, status: .failed)
                    } catch let statusError {
                        logError("PowerWorkBridge: .extractKG — setKGExtractionStatus(.failed) failed for memory \(realId) after upsert failure", error: statusError)
                    }
                    await KGProgressPublisher.shared.tick()
                    throw error
                }
            }
        case .empty:
            do {
                try await MemoryStorage.shared.setKGExtractionStatus(id: realId, status: .empty)
            } catch let statusError {
                logError("PowerWorkBridge: .extractKG — setKGExtractionStatus(.empty) failed for memory \(realId)", error: statusError)
            }
        case .failed(let reason):
            do {
                try await MemoryStorage.shared.setKGExtractionStatus(id: realId, status: .failed)
            } catch let statusError {
                logError("PowerWorkBridge: .extractKG — setKGExtractionStatus(.failed) failed for memory \(realId)", error: statusError)
            }
            await KGProgressPublisher.shared.tick()
            // Cluster F: surface the underlying LLM error detail so
            // PendingWorkStorage.fail() captures it in `lastError` and the
            // dead-letter log shows what actually went wrong.
            let detail = extraction.llmErrorDetail.map { ": \($0)" } ?? ""
            throw NSError(
                domain: "PowerWorkBridge", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "extractKG failed: \(reason.rawValue)\(detail)"]
            )
        }

        let drainDuration = Date().timeIntervalSince(drainStart)
        await KGProgressPublisher.shared.recordDrainSample(seconds: drainDuration)
        await KGProgressPublisher.shared.tick()

        log("PowerWorkBridge: .extractKG — memory \(realId) outcome=\(extraction.outcome) in \(String(format: "%.2f", drainDuration))s")
    }

    // MARK: - Extract Action Items handler

    // Note: transcript length thresholds live on `ConversationTranscriptLoader`
    // (single source of truth shared with `ConversationSummaryBackfillService`).
    // Use `ConversationTranscriptLoader.minTranscriptLength` /
    // `.maxTranscriptLength` directly here so a future tuning change to those
    // constants applies to both summary + action-item paths in lock-step.

    /// Decode an `.extractActionItems` payload (`{"session_id": Int64}`),
    /// load the transcript, run the LLM, and persist any extracted items via
    /// `ActionItemStorage.shared.insertLocalActionItem(...)`.
    ///
    /// LLM path uses `LLMBridge.generateJSON` (NOT `chatAutonomous`): this
    /// kind only requires `allowHeavyWork`, so the user may still be active
    /// and Memory Saver must be allowed to track the call.
    ///
    /// Outcome routing:
    /// - Undecodable payload → log + ack (return). Mirrors `.summarize`.
    /// - Empty/short transcript → mark extracted + ack (no insert).
    /// - LLM returned nil OR JSON parse failure → throw (lets PendingWork retry).
    /// - Successful empty array `[]` → mark extracted + ack.
    /// - Successful items → insert each + mark extracted + post refresh.
    fileprivate static func handleExtractActionItems(_ work: PendingWork) async throws {
        try await _handleExtractActionItemsPayload(
            work.payload,
            processor: { sessionId in
                try await processExtractActionItems(sessionId: sessionId)
            },
            notify: { sessionId in
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .actionItemsListNeedsRefresh,
                        object: nil,
                        userInfo: ["session_id": sessionId]
                    )
                }
            }
        )
    }

    /// Testable seam for `handleExtractActionItems`. Same contract as
    /// `_handleSummarizePayload`: undecodable payload → no throw, no notify,
    /// no processor call; processor throw → re-thrown, no notify; success →
    /// notify called.
    static func _handleExtractActionItemsPayload(
        _ payload: Data,
        processor: (Int64) async throws -> Void,
        notify: (Int64) async -> Void
    ) async throws {
        struct Payload: Decodable {
            let session_id: Int64
        }

        let sessionId: Int64
        do {
            sessionId = try JSONDecoder().decode(Payload.self, from: payload).session_id
        } catch {
            logError("PowerWorkBridge: .extractActionItems payload undecodable, dropping", error: error)
            return
        }

        do {
            try await processor(sessionId)
        } catch {
            logError("PowerWorkBridge: .extractActionItems — session \(sessionId) failed (will retry)", error: error)
            throw error
        }

        await notify(sessionId)
        log("PowerWorkBridge: .extractActionItems — session \(sessionId) done")
    }

    /// Production processor: load transcript, call LLM, insert items, mark
    /// session extracted. Throws on retryable failure (LLM unreachable, JSON
    /// parse failure, partial-insert failure) so PendingWork retry/backoff
    /// takes over.
    fileprivate static func processExtractActionItems(sessionId: Int64) async throws {
        try await _processExtractActionItems(
            sessionId: sessionId,
            loadTranscript: { id in
                try await ConversationTranscriptLoader.loadAssembled(sessionId: id)
            },
            extractItems: { transcript, id in
                try await callExtractActionItemsLLM(truncated: transcript, sessionId: id)
            },
            insert: { record in
                _ = try await ActionItemStorage.shared.insertLocalActionItem(record)
            },
            markExtracted: { id in
                try await ConversationActionItemsBackfillService.shared.markSessionExtracted(sessionId: id)
            }
        )
    }

    /// Testable seam: same body as `processExtractActionItems` but with all
    /// side-effecting collaborators (transcript load, LLM call, insert, mark)
    /// injected so tests can drive each branch (all-success, mid-loop
    /// failure, all-fail, short-transcript, empty-result) without touching
    /// the real DB or LLM.
    ///
    /// `loadTranscript` returns the assembled transcript (may be nil/empty —
    /// short-transcript branch handles both as "too short").
    /// `extractItems` runs the LLM on a (truncated) transcript and returns
    /// the decoded array; throws on parse / I/O failure so the whole job
    /// retries. Returns an empty array on a successful "no items" response.
    static func _processExtractActionItems(
        sessionId: Int64,
        loadTranscript: (Int64) async throws -> String?,
        extractItems: (String, Int64) async throws -> [LLMActionItem],
        insert: (ActionItemRecord) async throws -> Void,
        markExtracted: (Int64) async throws -> Void
    ) async throws {
        let transcript = (try await loadTranscript(sessionId)) ?? ""

        if transcript.count < ConversationTranscriptLoader.minTranscriptLength {
            log("PowerWorkBridge: .extractActionItems — session \(sessionId) transcript too short (\(transcript.count) chars), marking extracted")
            // FIX 7: don't propagate mark-failure here. The LLM didn't run, so
            // re-throwing only buys us another drain re-checking the same
            // too-short transcript. Eligibility query naturally re-picks the
            // row next launch if it's still unmarked.
            do {
                try await markExtracted(sessionId)
            } catch {
                logError("PowerWorkBridge: .extractActionItems — markSessionExtracted failed for short-transcript session \(sessionId); ack-ing anyway", error: error)
            }
            return
        }

        let truncated = transcript.count > ConversationTranscriptLoader.maxTranscriptLength
            ? String(transcript.prefix(ConversationTranscriptLoader.maxTranscriptLength)) + "..."
            : transcript

        let decoded: [LLMActionItem] = try await extractItems(truncated, sessionId)

        if decoded.isEmpty {
            log("PowerWorkBridge: .extractActionItems — session \(sessionId) yielded zero items, marking extracted")
            // FIX 7: same rationale as the short-transcript branch — the LLM
            // already ran and returned an empty result. If markSessionExtracted
            // fails, the eligibility query will pick the session back up next
            // launch; re-throwing here only burns another LLM call right now.
            do {
                try await markExtracted(sessionId)
            } catch {
                logError("PowerWorkBridge: .extractActionItems — markSessionExtracted failed for empty-result session \(sessionId); ack-ing anyway", error: error)
            }
            return
        }

        // Insert-then-mark is NOT atomic. Track per-item failures and bail
        // BEFORE marking the session done if any insert threw — otherwise
        // a partial-failure would silently lose those items forever (the
        // eligibility query excludes "extracted" sessions, no recovery).
        //
        // TODO: insert is not idempotent on retry — there's no unique
        // constraint on (conversationId, description). A retry after
        // mid-loop failure can re-insert items that already landed
        // successfully. Acceptable trade-off vs. permanent silent loss; a
        // follow-up should add a `(conversationId, hash(description))`
        // upsert.
        let validPriorities: Set<String> = ["high", "medium", "low"]
        var inserted = 0
        var anyInsertFailed = false
        var firstFailure: Error?
        for item in decoded {
            let description = item.description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !description.isEmpty else { continue }

            let priority: String? = {
                guard let p = item.priority?.lowercased() else { return nil }
                return validPriorities.contains(p) ? p : nil
            }()

            let tagsJson: String? = {
                guard let tags = item.tags, !tags.isEmpty else { return nil }
                guard let data = try? JSONEncoder().encode(tags),
                      let json = String(data: data, encoding: .utf8) else { return nil }
                return json
            }()

            let record = ActionItemRecord(
                description: description,
                source: "conversation",
                conversationId: String(sessionId),
                priority: priority,
                category: item.category,
                tagsJson: tagsJson,
                dueAt: item.dueAt,
                fromStaged: false
            )
            do {
                try await insert(record)
                inserted += 1
            } catch {
                anyInsertFailed = true
                if firstFailure == nil { firstFailure = error }
                logError("PowerWorkBridge: .extractActionItems — insert failed for session \(sessionId) (will retry whole job)", error: error)
            }
        }

        if anyInsertFailed {
            log("PowerWorkBridge: .extractActionItems — session \(sessionId) inserted \(inserted)/\(decoded.count) before failure; re-throwing so PendingWork can retry (NOT marking extracted)")
            throw firstFailure ?? NSError(domain: "PowerWorkBridge", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "extractActionItems: at least one insert failed for session \(sessionId)"
            ])
        }

        try await markExtracted(sessionId)
        log("PowerWorkBridge: .extractActionItems — session \(sessionId) inserted \(inserted)/\(decoded.count) item(s)")
    }

    /// Runs the action-item extraction LLM call against `LLMBridge` and
    /// decodes the envelope. Throws on nil result, non-UTF-8 bytes, or JSON
    /// parse failure so the calling job retries via PendingWork backoff.
    ///
    /// Extracted from `_processExtractActionItems` so the seam can stub the
    /// LLM out in tests while the production path still routes through this
    /// single function.
    fileprivate static func callExtractActionItemsLLM(
        truncated: String,
        sessionId: Int64
    ) async throws -> [LLMActionItem] {
        // LLMBridge.generateJSON appends a stock instruction telling the model
        // to "respond ONLY with a single valid JSON object". Asking for a bare
        // array on top of that contradicts the augment and noticeably trips
        // the local 4-bit Qwen. So we wrap the array in an envelope object
        // (`{"items": [...]}`) and decode that. Every other LLMBridge caller
        // already returns an object — keeping the bridge contract uniform.
        let systemPrompt = """
            You are an action-item extractor. Read a conversation transcript and \
            output a JSON object containing concrete tasks the speakers committed \
            to. Output ONLY a single valid JSON object of the form \
            `{"items": [...]}` — no code fences, no prose, no commentary. If the \
            transcript contains no actionable tasks, output exactly {"items": []}.

            Each element of the "items" array is an object with these fields:
            - "description": string, required, a concise one-sentence task description \
              (imperative voice, e.g. "Send the design review notes to Mike")
            - "priority": string, optional, one of: "high", "medium", "low"
            - "dueAt": string, optional, an ISO 8601 date-time (UTC, e.g. \
              "2026-05-01T17:00:00Z") if the speakers named a specific deadline
            - "category": string, optional, a short category label (e.g. "work", \
              "personal", "follow-up")
            - "tags": array of strings, optional, free-form labels

            Be conservative: only emit items the speakers actually committed to doing. \
            Skip aspirations, rhetorical questions, and hypotheticals.
            """

        let userPrompt = "Transcript:\n\n\(truncated)"
        let label = "ConversationActionItemsBackfill[\(sessionId)]"

        guard let raw = await LLMBridge.generateJSON(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            label: label
        ) else {
            throw NSError(domain: "PowerWorkBridge", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "extractActionItems: LLM returned nil for session \(sessionId)"
            ])
        }

        guard let data = raw.data(using: .utf8) else {
            throw NSError(domain: "PowerWorkBridge", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "extractActionItems: response not UTF-8 for session \(sessionId)"
            ])
        }

        do {
            return try JSONDecoder.iso8601().decode(LLMActionItemEnvelope.self, from: data).items
        } catch {
            let snippet = String(raw.prefix(500))
            logError("PowerWorkBridge: .extractActionItems — JSON parse failed for session \(sessionId); raw (first 500): \(snippet)", error: error)
            throw error
        }
    }

    /// Envelope wrapping the array of extracted action items. Required
    /// because `LLMBridge.generateJSON` appends a "respond ONLY with a single
    /// valid JSON object" instruction to the prompt — asking for a bare
    /// array would contradict that. Adapter pattern: only this caller needs
    /// the envelope, so we keep the bridge contract uniform across callers
    /// and unwrap inside the decode here.
    struct LLMActionItemEnvelope: Decodable {
        let items: [LLMActionItem]
    }

    /// Codable mirror for the LLM's per-item response. Internal (not
    /// `private`) so the testable seam `_processExtractActionItems` can
    /// surface this type to test stubs.
    struct LLMActionItem: Decodable {
        let description: String
        let priority: String?
        let dueAt: Date?
        let category: String?
        let tags: [String]?

        init(
            description: String,
            priority: String? = nil,
            dueAt: Date? = nil,
            category: String? = nil,
            tags: [String]? = nil
        ) {
            self.description = description
            self.priority = priority
            self.dueAt = dueAt
            self.category = category
            self.tags = tags
        }
    }

    /// Dead-letter for `.extractActionItems`: mark the session extracted so
    /// it stops re-qualifying on launch. No user-visible placeholder needed —
    /// "no tasks for this conversation" is indistinguishable from a real
    /// empty result. Surfaces in logs only.
    @Sendable
    fileprivate static func handleDeadLetterExtractActionItems(payload: Data) async {
        struct Payload: Decodable { let session_id: Int64 }
        let sessionId: Int64
        do {
            sessionId = try JSONDecoder().decode(Payload.self, from: payload).session_id
        } catch {
            logError("PowerWorkBridge: dead-letter — extractActionItems payload undecodable", error: error)
            return
        }

        do {
            try await ConversationActionItemsBackfillService.shared.markSessionExtracted(sessionId: sessionId)
            log("PowerWorkBridge: dead-letter — marked session \(sessionId) action_items_extracted_at to break re-enqueue loop")
        } catch {
            logError("PowerWorkBridge: dead-letter — failed to mark session \(sessionId) extracted", error: error)
        }
    }
}

private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension Notification.Name {
    /// Fires when `PowerWorkBridge` finishes transcribing a deferred audio
    /// chunk. `userInfo`: `audio_chunk_id` (Int64), `started_at` (Date),
    /// `duration_sec` (Double), `text` (String).
    static let powerWorkBridgeDeferredTranscript =
        Notification.Name("PowerWorkBridgeDeferredTranscript")
}
