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

        // Start the periodic sweeper that reclaims expired leases and GCs old rows.
        PendingWorkSweeper.shared.start()

        log("PowerWorkBridge: Started — registered .transcribe and .ocr handlers")
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
            log("PowerWorkBridge: .transcribe payload undecodable, dropping")
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
            log("PowerWorkBridge: .ocr payload undecodable, dropping")
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
}

extension Notification.Name {
    /// Fires when `PowerWorkBridge` finishes transcribing a deferred audio
    /// chunk. `userInfo`: `audio_chunk_id` (Int64), `started_at` (Date),
    /// `duration_sec` (Double), `text` (String).
    static let powerWorkBridgeDeferredTranscript =
        Notification.Name("PowerWorkBridgeDeferredTranscript")
}
