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
/// 2. Registers handlers for `.transcribe` and `.ocr` work kinds.
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
        // and run a one-shot WhisperKit batchTranscribe per chunk. Emit
        // synthetic segments via the foreground TranscriptionService (if one
        // is alive) so the UI updates the same as a live pass.
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
        }

        log("PowerWorkBridge: Started — registered .transcribe, .ocr, and .summarize handlers")
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

    /// Decode a .transcribe payload and run WhisperKit on every audio_chunks
    /// row whose `startedAt` falls within the queued window. Errors are logged
    /// but never thrown out — throwing would leave the work item in the queue
    /// and stall the drain. Per-row failures are tolerable; we move on.
    fileprivate static func handleTranscribe(_ work: PendingWork) async throws {
        struct Payload: Decodable {
            let started_at: String
            let ended_at: String
            let duration_sec: Double?
            let language: String?
            let mode: String?
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: work.payload, options: []),
            let dict = json as? [String: Any],
            let startedStr = dict["started_at"] as? String,
            let endedStr = dict["ended_at"] as? String,
            let started = ISO8601DateFormatter().date(from: startedStr),
            let ended = ISO8601DateFormatter().date(from: endedStr)
        else {
            // Corrupt payload is non-recoverable; logError so we get telemetry
            // visibility without leaving the row stuck. We still ack/return.
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
            // Throwing leaves work item in place per scheduler contract.
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
}

extension Notification.Name {
    /// Fires when `PowerWorkBridge` finishes transcribing a deferred audio
    /// chunk. `userInfo`: `audio_chunk_id` (Int64), `started_at` (Date),
    /// `duration_sec` (Double), `text` (String).
    static let powerWorkBridgeDeferredTranscript =
        Notification.Name("PowerWorkBridgeDeferredTranscript")
}
