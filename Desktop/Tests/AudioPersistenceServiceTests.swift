import GRDB
import XCTest

@testable import Omi_Computer

final class AudioPersistenceServiceTests: XCTestCase {
    private var testUserId = ""
    private var previousRetentionDays = AudioPersistenceService.retentionDays

    override func setUp() async throws {
        try await super.setUp()
        testUserId = "test-audio-persistence-\(UUID().uuidString)"
        previousRetentionDays = AudioPersistenceService.retentionDays
        AudioPersistenceService.retentionDays = 7
        await RewindDatabase.shared.configure(userId: testUserId)
        try await RewindDatabase.shared.initialize()
        await AudioPersistenceService.shared.resetStateForTests()
    }

    override func tearDown() async throws {
        await AudioPersistenceService.shared.resetStateForTests()
        AudioPersistenceService.retentionDays = previousRetentionDays
        await RewindDatabase.shared.close()
        try await super.tearDown()
    }

    func testStopFlushesPartialChunkWithSessionId() async throws {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }
        let now = Date()
        let sessionId = try await insertSession(dbQueue: dbQueue, startedAt: now)

        await AudioPersistenceService.shared.start(source: "mixed", transcriptionSessionId: sessionId)
        await AudioPersistenceService.shared.append(Data(repeating: 1, count: 3_200))
        await AudioPersistenceService.shared.stop()

        let row = try await dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT transcriptionSessionId, source, sampleRate, channels, LENGTH(pcm) AS byteCount
                    FROM audio_chunks
                    WHERE transcriptionSessionId = ?
                    """,
                arguments: [sessionId]
            )
        }
        XCTAssertEqual(row?["transcriptionSessionId"] as Int64?, sessionId)
        XCTAssertEqual(row?["source"] as String?, "mixed")
        XCTAssertEqual(row?["sampleRate"] as Int?, 16000)
        XCTAssertEqual(row?["channels"] as Int?, 1)
        XCTAssertEqual(row?["byteCount"] as Int?, 3_200)
    }

    func testPreSessionChunksAreLinkedWhenSessionIdArrives() async throws {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }
        let captureStartedAt = Date()

        await AudioPersistenceService.shared.start(
            source: "mixed",
            transcriptionSessionId: nil,
            captureStartedAt: captureStartedAt
        )
        await AudioPersistenceService.shared.append(Data(repeating: 2, count: 3_200))
        await AudioPersistenceService.shared.flush()

        let orphanCount = try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audio_chunks WHERE transcriptionSessionId IS NULL") ?? 0
        }
        XCTAssertEqual(orphanCount, 1)

        let sessionId = try await insertSession(
            dbQueue: dbQueue,
            startedAt: captureStartedAt.addingTimeInterval(30)
        )
        await AudioPersistenceService.shared.setTranscriptionSessionId(sessionId)

        let linkedCount = try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM audio_chunks WHERE transcriptionSessionId = ?",
                arguments: [sessionId]
            ) ?? 0
        }
        XCTAssertEqual(linkedCount, 1)
    }

    func testReviewAudioWAVSlicesAcrossChunksUsingAudioAnchor() async throws {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }
        let audioStartedAt = Date()
        let sessionId = try await insertSession(
            dbQueue: dbQueue,
            startedAt: audioStartedAt.addingTimeInterval(60)
        )
        let conversationId = "local-\(sessionId)"

        try await insertAudioChunk(
            dbQueue: dbQueue,
            startedAt: audioStartedAt,
            endedAt: audioStartedAt.addingTimeInterval(1),
            sessionId: sessionId,
            sampleRate: 4,
            pcm: pcmData([0, 1, 2, 3])
        )
        try await insertAudioChunk(
            dbQueue: dbQueue,
            startedAt: audioStartedAt.addingTimeInterval(1),
            endedAt: audioStartedAt.addingTimeInterval(2),
            sessionId: sessionId,
            sampleRate: 4,
            pcm: pcmData([4, 5, 6, 7])
        )

        let wav = await AudioPersistenceService.shared.reviewAudioWAV(
            conversationId: conversationId,
            startTime: 0.5,
            endTime: 1.5
        )
        let pcm = try XCTUnwrap(wav.map(wavPCM))
        XCTAssertEqual(pcm, pcmData([2, 3, 4, 5]))
    }

    func testRetentionPurgeDeletesOnlyExpiredChunks() async throws {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }
        AudioPersistenceService.retentionDays = 7
        let now = Date()
        let oldStart = now.addingTimeInterval(-9 * 24 * 60 * 60)
        let freshStart = now.addingTimeInterval(-2 * 24 * 60 * 60)

        try await insertAudioChunk(dbQueue: dbQueue, startedAt: oldStart, endedAt: oldStart.addingTimeInterval(1))
        try await insertAudioChunk(dbQueue: dbQueue, startedAt: freshStart, endedAt: freshStart.addingTimeInterval(1))

        let deleted = await AudioPersistenceService.shared.purgeExpiredChunks(now: now)
        XCTAssertEqual(deleted, 1)

        let remaining = try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audio_chunks") ?? 0
        }
        XCTAssertEqual(remaining, 1)
    }

    func testRetentionPurgeIfNeededIsDeterministicAndThrottled() async throws {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }
        AudioPersistenceService.retentionDays = 7
        let now = Date()
        let oldStart = now.addingTimeInterval(-9 * 24 * 60 * 60)

        try await insertAudioChunk(dbQueue: dbQueue, startedAt: oldStart, endedAt: oldStart.addingTimeInterval(1))
        let firstDeleted = await AudioPersistenceService.shared.purgeExpiredChunksIfNeeded(now: now)
        XCTAssertEqual(firstDeleted, 1)

        try await insertAudioChunk(dbQueue: dbQueue, startedAt: oldStart, endedAt: oldStart.addingTimeInterval(1))
        let throttledDeleted = await AudioPersistenceService.shared.purgeExpiredChunksIfNeeded(
            now: now.addingTimeInterval(10)
        )
        XCTAssertEqual(throttledDeleted, 0)

        let secondDeleted = await AudioPersistenceService.shared.purgeExpiredChunksIfNeeded(
            now: now.addingTimeInterval(60 * 60 + 1)
        )
        XCTAssertEqual(secondDeleted, 1)
    }

    func testAudioMixerEmitsMicOnlyChunksWhenSystemAudioIsAbsent() {
        let mixer = AudioMixer()
        let micOnlyPCM = pcmData(Array(repeating: 42, count: 1_600))
        var chunks: [Data] = []

        mixer.start { chunk in
            chunks.append(chunk)
        }
        mixer.setMicAudio(micOnlyPCM)
        mixer.stop()

        XCTAssertEqual(chunks.first, micOnlyPCM)
    }

    private func insertSession(dbQueue: DatabasePool, startedAt: Date) async throws -> Int64 {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcription_sessions(startedAt, source, language, timezone, status, retryCount, backendSynced, createdAt, updatedAt, summary_state)
                    VALUES(?, 'desktop', 'en', 'UTC', 'recording', 0, 0, ?, ?, 'pending')
                    """,
                arguments: [startedAt, startedAt, startedAt]
            )
            let id = db.lastInsertedRowID
            try db.execute(sql: "UPDATE transcription_sessions SET backendId = ? WHERE id = ?", arguments: ["local-\(id)", id])
            return id
        }
    }

    private func insertAudioChunk(
        dbQueue: DatabasePool,
        startedAt: Date,
        endedAt: Date,
        sessionId: Int64? = nil,
        sampleRate: Int = 16000,
        pcm: Data = Data(repeating: 1, count: 8)
    ) async throws {
        let duration = endedAt.timeIntervalSince(startedAt)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audio_chunks(startedAt, endedAt, durationSeconds, source, sampleRate, channels, pcm, transcriptionSessionId, createdAt)
                    VALUES(?, ?, ?, 'mixed', ?, 1, ?, ?, ?)
                    """,
                arguments: [startedAt, endedAt, duration, sampleRate, pcm, sessionId, Date()]
            )
        }
    }

    private func pcmData(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func wavPCM(_ wav: Data) -> Data {
        guard wav.count >= 44 else { return Data() }
        return Data(wav.dropFirst(44))
    }
}
