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
    static let retentionDaysKey = "audioChunksRetentionDays"
    static let defaultRetentionDays = 7

    /// 30 seconds @ 16kHz mono Int16 = 16000 * 2 * 30 = 960_000 bytes.
    private let chunkDurationSeconds: Double = 30.0
    private let sampleRate: Int = 16000
    private let bytesPerSample: Int = 2
    private var targetChunkBytes: Int { Int(chunkDurationSeconds) * sampleRate * bytesPerSample }
    private static let retentionCleanupIntervalNanoseconds: UInt64 = 60 * 60 * 1_000_000_000

    private var buffer = Data()
    private var bufferStartedAt: Date?
    private var captureStartedAt: Date?
    private var linkWindowStartedAt: Date?
    private var nextChunkStartedAt: Date?
    private var sessionId: Int64?
    private var source: String = "mixed"
    private var lastPurgeAt: Date?
    private var retentionCleanupTask: Task<Void, Never>?
    private static let operationQueue = DispatchQueue(label: "com.omi.audioPersistence.operations")

    private init() {}

    // MARK: - Lifecycle

    nonisolated func enqueueStart(
        source: String = "mixed",
        transcriptionSessionId: Int64? = nil,
        captureStartedAt: Date = Date()
    ) {
        enqueue {
            await self.start(
                source: source,
                transcriptionSessionId: transcriptionSessionId,
                captureStartedAt: captureStartedAt
            )
        }
    }

    nonisolated func enqueueAppend(_ data: Data) {
        guard !data.isEmpty else { return }
        enqueue {
            await self.append(data)
        }
    }

    nonisolated func enqueueSetTranscriptionSessionId(_ id: Int64?) {
        enqueue {
            await self.setTranscriptionSessionId(id)
        }
    }

    nonisolated func flushQueued() async {
        await performQueued {
            await self.flush()
        }
    }

    nonisolated func enqueueStop() {
        enqueue {
            await self.stop()
        }
    }

    nonisolated func stopQueued() async {
        await performQueued {
            await self.stop()
        }
    }

    /// Begin a new always-on capture window. Safe to call repeatedly — flushes any
    /// in-flight buffer first.
    func start(
        source: String = "mixed",
        transcriptionSessionId: Int64? = nil,
        captureStartedAt: Date = Date()
    ) async {
        await flush()
        await purgeExpiredChunksIfNeeded()
        ensureRetentionCleanupTask()
        self.buffer = Data()
        self.bufferStartedAt = nil
        self.captureStartedAt = captureStartedAt
        self.linkWindowStartedAt = captureStartedAt
        self.nextChunkStartedAt = captureStartedAt
        self.source = source
        self.sessionId = transcriptionSessionId
        log("AudioPersistenceService: Started (source=\(source), session=\(transcriptionSessionId.map(String.init) ?? "nil"))")
    }

    /// Update the transcription session id mid-capture (e.g. when a session is created
    /// after Whisper finally loads).
    func setTranscriptionSessionId(_ id: Int64?) async {
        self.sessionId = id
        guard let id else {
            linkWindowStartedAt = nextChunkStartedAt ?? Date()
            return
        }
        await linkOrphanedChunks(to: id)
    }

    /// Append mixed mono Int16 PCM bytes. Flushes a chunk to SQLite when ~30s of
    /// audio have accumulated.
    func append(_ data: Data) async {
        guard !data.isEmpty else { return }
        if buffer.isEmpty {
            bufferStartedAt = nextChunkStartedAt ?? captureStartedAt ?? Date()
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
        nextChunkStartedAt = endedAt

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

    // MARK: - Playback

    func reviewAudioWAV(conversationId: String, startTime: Double, endTime: Double) async -> Data? {
        guard endTime > startTime else { return nil }
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return nil }

        struct ChunkRow {
            let startedAt: Date
            let endedAt: Date
            let sampleRate: Int
            let channels: Int
            let pcm: Data
        }

        do {
            let payload: (audioStartedAt: Date, rows: [ChunkRow])? = try await dbQueue.read { db in
                guard let session = try Row.fetchOne(
                    db,
                    sql: "SELECT id, startedAt FROM transcription_sessions WHERE backendId = ?",
                    arguments: [conversationId]
                ) else { return nil }

                let sessionId: Int64 = session["id"]
                let audioStartedAt: Date = session["startedAt"]
                let requestedStart = audioStartedAt.addingTimeInterval(startTime)
                let requestedEnd = audioStartedAt.addingTimeInterval(endTime)
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT startedAt, endedAt, sampleRate, channels, pcm
                        FROM audio_chunks
                        WHERE transcriptionSessionId = ?
                          AND startedAt < ?
                          AND endedAt > ?
                        ORDER BY startedAt ASC
                        """,
                    arguments: [sessionId, requestedEnd, requestedStart]
                ).map { row in
                    ChunkRow(
                        startedAt: row["startedAt"],
                        endedAt: row["endedAt"],
                        sampleRate: row["sampleRate"] ?? 16000,
                        channels: row["channels"] ?? 1,
                        pcm: row["pcm"] ?? Data()
                    )
                }
                return (audioStartedAt, rows)
            }
            guard let payload, !payload.rows.isEmpty else { return nil }

            let requestedStart = payload.audioStartedAt.addingTimeInterval(startTime)
            let requestedEnd = payload.audioStartedAt.addingTimeInterval(endTime)
            var pcm = Data()
            var detectedSampleRate = sampleRate
            var detectedChannels = 1

            for row in payload.rows {
                guard row.sampleRate > 0, row.channels > 0, !row.pcm.isEmpty else { continue }
                detectedSampleRate = row.sampleRate
                detectedChannels = row.channels
                let bytesPerFrame = bytesPerSample * row.channels
                let overlapStart = max(row.startedAt, requestedStart)
                let overlapEnd = min(row.endedAt, requestedEnd)
                guard overlapEnd > overlapStart else { continue }

                let startFrame = max(0, Int(overlapStart.timeIntervalSince(row.startedAt) * Double(row.sampleRate)))
                let endFrame = max(startFrame, Int(overlapEnd.timeIntervalSince(row.startedAt) * Double(row.sampleRate)))
                let startByte = min(row.pcm.count, startFrame * bytesPerFrame)
                let endByte = min(row.pcm.count, endFrame * bytesPerFrame)
                guard endByte > startByte else { continue }
                pcm.append(row.pcm[startByte..<endByte])
            }

            guard !pcm.isEmpty else { return nil }
            return Self.wavData(
                pcm: pcm,
                sampleRate: detectedSampleRate,
                channels: detectedChannels,
                bitsPerSample: 16
            )
        } catch {
            logError("AudioPersistenceService: Failed to fetch review audio", error: error)
            await RewindDatabase.shared.reportQueryError(error)
            return nil
        }
    }

    // MARK: - Retention

    static var retentionDays: Int {
        get {
            let stored = UserDefaults.standard.object(forKey: retentionDaysKey) as? Int
            return max(1, stored ?? defaultRetentionDays)
        }
        set {
            UserDefaults.standard.set(max(1, newValue), forKey: retentionDaysKey)
        }
    }

    @discardableResult
    func purgeExpiredChunks(now: Date = Date()) async -> Int {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 24 * 60 * 60)
        do {
            let deleted = try await dbQueue.write { db -> Int in
                try db.execute(
                    sql: "DELETE FROM audio_chunks WHERE endedAt < ?",
                    arguments: [cutoff]
                )
                return db.changesCount
            }
            lastPurgeAt = now
            if deleted > 0 {
                log("AudioPersistenceService: Purged \(deleted) expired audio chunk(s)")
            }
            return deleted
        } catch {
            logError("AudioPersistenceService: Failed to purge expired chunks", error: error)
            await RewindDatabase.shared.reportQueryError(error)
            return 0
        }
    }

    @discardableResult
    func purgeExpiredChunksIfNeeded(now: Date = Date()) async -> Int {
        if let lastPurgeAt, now.timeIntervalSince(lastPurgeAt) < 60 * 60 {
            return 0
        }
        return await purgeExpiredChunks(now: now)
    }

    func resetStateForTests() async {
        await stop()
        retentionCleanupTask?.cancel()
        retentionCleanupTask = nil
        lastPurgeAt = nil
        captureStartedAt = nil
        linkWindowStartedAt = nil
        nextChunkStartedAt = nil
    }

    private func linkOrphanedChunks(to id: Int64) async {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return }
        let windowStart = linkWindowStartedAt ?? captureStartedAt ?? .distantPast
        let src = source
        do {
            let updated = try await dbQueue.write { db -> Int in
                try db.execute(
                    sql: """
                        UPDATE audio_chunks
                           SET transcriptionSessionId = ?
                         WHERE transcriptionSessionId IS NULL
                           AND source = ?
                           AND endedAt > ?
                        """,
                    arguments: [id, src, windowStart]
                )
                return db.changesCount
            }
            if updated > 0 {
                log("AudioPersistenceService: Linked \(updated) orphaned chunk(s) to session \(id)")
            }
        } catch {
            logError("AudioPersistenceService: Failed to link orphaned chunks", error: error)
            await RewindDatabase.shared.reportQueryError(error)
        }
    }

    private func ensureRetentionCleanupTask() {
        guard retentionCleanupTask == nil else { return }
        retentionCleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.retentionCleanupIntervalNanoseconds)
                } catch {
                    break
                }
                await self?.purgeExpiredChunksIfNeeded()
            }
        }
    }

    private nonisolated func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        Self.operationQueue.async {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await operation()
                semaphore.signal()
            }
            semaphore.wait()
        }
    }

    private nonisolated func performQueued(_ operation: @escaping @Sendable () async -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            enqueue {
                await operation()
                continuation.resume()
            }
        }
    }

    private static func wavData(
        pcm: Data,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int
    ) -> Data {
        var data = Data()
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let subchunk2Size = UInt32(pcm.count)
        let chunkSize = UInt32(36 + pcm.count)

        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(chunkSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(channels))
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(byteRate))
        data.appendLittleEndian(UInt16(blockAlign))
        data.appendLittleEndian(UInt16(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(subchunk2Size)
        data.append(pcm)
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: MemoryLayout<UInt32>.size))
    }
}
