import Foundation
import GRDB

/// Persists mixed microphone+system audio chunks to the local SQLite `audio_chunks`
/// table in ~30 second blobs. Runs always-on while audio capture is active and is
/// independent of transcription state — we keep the recording even if WhisperKit
/// fails to load.
///
/// Format: 16kHz mono Int16 PCM (matches what `AudioMixer` emits for the mono mode).
actor AudioPersistenceService {
    static let shared = AudioPersistenceService()

    /// 30 seconds @ 16kHz mono Int16 = 16000 * 2 * 30 = 960_000 bytes.
    private let chunkDurationSeconds: Double = 30.0
    private let sampleRate: Int = 16000
    private let bytesPerSample: Int = 2
    private var targetChunkBytes: Int { Int(chunkDurationSeconds) * sampleRate * bytesPerSample }

    private var buffer = Data()
    private var bufferStartedAt: Date?
    private var sessionId: Int64?
    private var source: String = "mixed"

    private init() {}

    // MARK: - Lifecycle

    /// Begin a new always-on capture window. Safe to call repeatedly — flushes any
    /// in-flight buffer first.
    func start(source: String = "mixed", transcriptionSessionId: Int64? = nil) async {
        await flush()
        self.buffer = Data()
        self.bufferStartedAt = nil
        self.source = source
        self.sessionId = transcriptionSessionId
        log("AudioPersistenceService: Started (source=\(source), session=\(transcriptionSessionId.map(String.init) ?? "nil"))")
    }

    /// Update the transcription session id mid-capture (e.g. when a session is created
    /// after Whisper finally loads).
    func setTranscriptionSessionId(_ id: Int64?) {
        self.sessionId = id
    }

    /// Append mixed mono Int16 PCM bytes. Flushes a chunk to SQLite when ~30s of
    /// audio have accumulated.
    func append(_ data: Data) async {
        guard !data.isEmpty else { return }
        if buffer.isEmpty {
            bufferStartedAt = Date()
        }
        buffer.append(data)

        if buffer.count >= targetChunkBytes {
            await flush()
        }
    }

    /// Flush any buffered audio to SQLite. Called on stop and on chunk boundary.
    func flush() async {
        guard !buffer.isEmpty, let startedAt = bufferStartedAt else { return }
        let chunk = buffer
        buffer = Data()
        bufferStartedAt = nil

        let durationSec = Double(chunk.count / bytesPerSample) / Double(sampleRate)
        let endedAt = startedAt.addingTimeInterval(durationSec)

        do {
            guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
                log("AudioPersistenceService: Database not initialized, dropping \(chunk.count) bytes")
                return
            }
            let src = source
            let sid = sessionId
            try await dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO audio_chunks
                          (startedAt, endedAt, durationSeconds, source, sampleRate, channels, pcm, transcriptionSessionId, createdAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        startedAt,
                        endedAt,
                        durationSec,
                        src,
                        16000,
                        1,
                        chunk,
                        sid,
                        Date(),
                    ]
                )
            }
            log(
                "AudioPersistenceService: Persisted chunk \(String(format: "%.1f", durationSec))s "
                    + "(\(chunk.count) bytes, source=\(src), session=\(sid.map(String.init) ?? "nil"))"
            )
        } catch {
            logError("AudioPersistenceService: Failed to persist chunk", error: error)
        }
    }

    /// Stop and flush. Call on toggle-off / app quit.
    func stop() async {
        await flush()
        sessionId = nil
        log("AudioPersistenceService: Stopped")
    }
}
