import XCTest
import GRDB

@testable import Omi_Computer

final class VoiceProfileAssignmentRegressionTests: XCTestCase {
    private var testUserId: String = ""

    override func setUp() async throws {
        try await super.setUp()
        testUserId = "test-voice-profile-\(UUID().uuidString)"
        await RewindDatabase.shared.configure(userId: testUserId)
        try await RewindDatabase.shared.initialize()
    }

    override func tearDown() async throws {
        await RewindDatabase.shared.close()
        try await super.tearDown()
    }

    private func requireDatabaseQueue() async throws -> DatabasePool {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }
        return dbQueue
    }

    private func insertSession(in dbQueue: DatabasePool, now: Date) async throws -> Int64 {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcription_sessions(startedAt, source, language, timezone, status, retryCount, backendSynced, createdAt, updatedAt, summary_state)
                    VALUES(?, 'desktop', 'en', 'UTC', 'completed', 0, 0, ?, ?, 'pending')
                    """,
                arguments: [now, now, now]
            )
            return db.lastInsertedRowID
        }
    }

    private func assignStableBackendId(_ sessionId: Int64, in dbQueue: DatabasePool) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE transcription_sessions SET backendId = ? WHERE id = ?",
                arguments: ["local-\(sessionId)", sessionId]
            )
        }
    }

    @discardableResult
    private func insertPerson(
        in dbQueue: DatabasePool,
        name: String,
        now: Date,
        id: String = UUID().uuidString
    ) async throws -> String {
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO people(id, displayName, defaultEmoji, createdAt, updatedAt) VALUES(?, ?, NULL, ?, ?)",
                arguments: [id, name, now, now]
            )
        }
        return id
    }

    private func insertSegment(
        in dbQueue: DatabasePool,
        sessionId: Int64,
        text: String,
        start: Double,
        end: Double,
        order: Int,
        now: Date,
        speakerId: Int = 1,
        segmentId: String? = nil
    ) async throws {
        let resolvedSegmentId = segmentId ?? "seg-\(order)"
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcription_segments(sessionId, speaker, text, startTime, endTime, segmentOrder, createdAt, segmentId, speakerLabel, isUser, personId)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL)
                    """,
                arguments: [
                    sessionId,
                    speakerId,
                    text,
                    start,
                    end,
                    order,
                    now,
                    resolvedSegmentId,
                    String(format: "SPEAKER_%02d", speakerId)
                ]
            )
        }
    }

    private func insertEmbedding(
        in dbQueue: DatabasePool,
        sessionId: Int64,
        embedding: Data,
        start: Double,
        end: Double,
        now: Date,
        speakerId: Int = 1,
        embeddingModel: String = "mfcc"
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO speaker_embeddings(sessionId, chunkId, embedding, embeddingDim, startTime, endTime, speakerId, personId, createdAt, assignmentSource, matchConfidence, embeddingModel, embeddingVersion, isTrainingSample)
                    VALUES(?, NULL, ?, 3, ?, ?, ?, NULL, ?, NULL, NULL, ?, 1, 0)
                    """,
                arguments: [sessionId, embedding, start, end, speakerId, now, embeddingModel]
            )
        }
    }

    func testAssignSegmentsBackfillsOnlyOverlappingEmbeddings() async throws {
        let dbQueue = try await requireDatabaseQueue()
        // Seed one session with two segments that share a speaker cluster but are far apart in time.
        let now = Date()
        let sessionId = try await insertSession(in: dbQueue, now: now)

        // Force stable local backendId so PeopleStore paths can resolve.
        try await assignStableBackendId(sessionId, in: dbQueue)

        // Segment order 0: 0-1s. Segment order 1: 10-11s.
        try await insertSegment(in: dbQueue, sessionId: sessionId, text: "a", start: 0.0, end: 1.0, order: 0, now: now, segmentId: "seg0")
        try await insertSegment(in: dbQueue, sessionId: sessionId, text: "b", start: 10.0, end: 11.0, order: 1, now: now, segmentId: "seg1")

        // Two embeddings, same speakerId=1 but different time windows.
        let e0 = SpeakerEmbeddingRecord.encode([0.1, 0.2, 0.3])
        let e1 = SpeakerEmbeddingRecord.encode([0.2, 0.2, 0.2])
        try await insertEmbedding(in: dbQueue, sessionId: sessionId, embedding: e0, start: 0.0, end: 1.0, now: now)
        try await insertEmbedding(in: dbQueue, sessionId: sessionId, embedding: e1, start: 10.0, end: 11.0, now: now)

        // Seed people.
        let pid = try await insertPerson(in: dbQueue, name: "Test", now: now)

        // Assign only segment order 0.
        let ok = await PeopleStore.shared.assignSegments(
            sessionId: sessionId,
            segmentIds: ["#index:0"],
            personId: pid,
            isUser: false
        )
        XCTAssertTrue(ok)

        // Only the 0-1 embedding should get personId.
        let rows: [(Double, String?, Int)] = try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT startTime, personId, isTrainingSample FROM speaker_embeddings WHERE sessionId = ? ORDER BY startTime ASC",
                arguments: [sessionId]
            ).map { ($0["startTime"], $0["personId"], $0["isTrainingSample"] ?? 0) }
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].0, 0.0)
        XCTAssertEqual(rows[0].1, pid)
        XCTAssertEqual(rows[0].2, 1)
        XCTAssertEqual(rows[1].0, 10.0)
        XCTAssertNil(rows[1].1, "Non-overlapping embedding must not be contaminated")
        XCTAssertEqual(rows[1].2, 0)
    }

    func testNonMFCCEmbeddingsNeverBecomeTrainingSamplesOnManualAssignment() async throws {
        let dbQueue = try await requireDatabaseQueue()
        let now = Date()
        let sessionId = try await insertSession(in: dbQueue, now: now)

        let pid = try await insertPerson(in: dbQueue, name: "Test", now: now)

        let e = SpeakerEmbeddingRecord.encode([1, 0, 0])
        try await insertEmbedding(
            in: dbQueue,
            sessionId: sessionId,
            embedding: e,
            start: 0.0,
            end: 1.0,
            now: now,
            embeddingModel: "speakerkit-synthetic"
        )

        try await SpeakerEmbeddingStore.shared.assignPersonToEmbeddings(sessionId: sessionId, speakerId: 1, personId: pid)

        let training: Int = try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT isTrainingSample FROM speaker_embeddings WHERE sessionId = ?",
                arguments: [sessionId]
            ) ?? 0
        }
        XCTAssertEqual(training, 0)
    }

    func testShortManualOverlapAssignsPersonButDoesNotTrainVoiceProfile() async throws {
        let dbQueue = try await requireDatabaseQueue()
        let now = Date()
        let sessionId = try await insertSession(in: dbQueue, now: now)
        try await assignStableBackendId(sessionId, in: dbQueue)

        try await insertSegment(
            in: dbQueue,
            sessionId: sessionId,
            text: "short noisy clip",
            start: 0.0,
            end: 0.3,
            order: 0,
            now: now,
            segmentId: "seg-short"
        )

        let e = SpeakerEmbeddingRecord.encode([1, 0, 0])
        try await insertEmbedding(in: dbQueue, sessionId: sessionId, embedding: e, start: 0.0, end: 1.0, now: now)

        let pid = try await insertPerson(in: dbQueue, name: "Short Clip", now: now)

        let ok = await PeopleStore.shared.assignSegments(
            sessionId: sessionId,
            segmentIds: ["#index:0"],
            personId: pid,
            isUser: false
        )
        XCTAssertTrue(ok)

        let row: (String?, Int) = try await dbQueue.read { db in
            let r = try Row.fetchOne(
                db,
                sql: "SELECT personId, isTrainingSample FROM speaker_embeddings WHERE sessionId = ?",
                arguments: [sessionId]
            )
            return (r?["personId"], r?["isTrainingSample"] ?? 0)
        }

        XCTAssertEqual(row.0, pid)
        XCTAssertEqual(row.1, 0, "Short selected overlap should not train the voice profile")
    }

    func testFullClusterAssignmentLabelsExcludedSegmentsButOnlyReviewableRangesTrain() async throws {
        let dbQueue = try await requireDatabaseQueue()
        let now = Date()
        let sessionId = try await insertSession(in: dbQueue, now: now)
        try await assignStableBackendId(sessionId, in: dbQueue)

        try await insertSegment(in: dbQueue, sessionId: sessionId, text: "ok", start: 0.0, end: 0.5, order: 0, now: now, segmentId: "seg-short")
        try await insertSegment(in: dbQueue, sessionId: sessionId, text: "(gentle music)", start: 1.0, end: 5.0, order: 1, now: now, segmentId: "seg-music")
        try await insertSegment(
            in: dbQueue,
            sessionId: sessionId,
            text: "This is a clean reviewable speaker turn.",
            start: 6.0,
            end: 10.0,
            order: 2,
            now: now,
            segmentId: "seg-reviewable"
        )

        let embedding = SpeakerEmbeddingRecord.encode([1, 0, 0])
        for (start, end) in [(0.0, 0.5), (1.0, 5.0), (6.0, 10.0)] {
            try await insertEmbedding(in: dbQueue, sessionId: sessionId, embedding: embedding, start: start, end: end, now: now)
        }

        let pid = try await insertPerson(in: dbQueue, name: "Cluster Person", now: now)

        let ok = await PeopleStore.shared.assignSegments(
            sessionId: sessionId,
            segmentIds: ["#index:0", "#index:1", "#index:2"],
            personId: pid,
            isUser: false
        )
        XCTAssertTrue(ok)

        let segmentPeople: [String?] = try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT personId FROM transcription_segments WHERE sessionId = ? ORDER BY segmentOrder",
                arguments: [sessionId]
            ).map { $0["personId"] }
        }
        XCTAssertEqual(segmentPeople, [pid, pid, pid])

        let embeddings: [(Double, String?, Int)] = try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT startTime, personId, isTrainingSample FROM speaker_embeddings WHERE sessionId = ? ORDER BY startTime",
                arguments: [sessionId]
            ).map { ($0["startTime"], $0["personId"], $0["isTrainingSample"] ?? 0) }
        }
        XCTAssertEqual(embeddings.map(\.1), [pid, pid, pid])
        XCTAssertEqual(embeddings.map(\.2), [0, 0, 1])
    }

    func testRecordEmbeddingDoesNotPersistConfidenceWithoutAppliedPerson() async throws {
        let dbQueue = try await requireDatabaseQueue()
        let now = Date()
        let sessionId = try await insertSession(in: dbQueue, now: now)

        _ = await SpeakerEmbeddingStore.shared.recordEmbedding(
            sessionId: sessionId,
            chunkId: nil,
            embedding: [1, 0, 0],
            startTime: 0,
            endTime: 1,
            speakerId: 1,
            personId: nil,
            assignmentSource: nil,
            matchConfidence: 0.77
        )

        let pid = try await insertPerson(in: dbQueue, name: "Known", now: now)

        _ = await SpeakerEmbeddingStore.shared.recordEmbedding(
            sessionId: sessionId,
            chunkId: nil,
            embedding: [0, 1, 0],
            startTime: 1,
            endTime: 2,
            speakerId: 2,
            personId: pid,
            assignmentSource: .autoHighConfidence,
            matchConfidence: 0.91,
            isTrainingSample: false
        )

        let rows: [(String?, Double?)] = try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT personId, matchConfidence FROM speaker_embeddings WHERE sessionId = ? ORDER BY startTime",
                arguments: [sessionId]
            ).map { ($0["personId"], $0["matchConfidence"]) }
        }

        XCTAssertEqual(rows.count, 2)
        XCTAssertNil(rows[0].0)
        XCTAssertNil(rows[0].1)
        XCTAssertEqual(rows[1].0, pid)
        XCTAssertNotNil(rows[1].1)
        XCTAssertEqual(rows[1].1!, 0.91, accuracy: 0.0001)
    }

    func testMergePersonIsAtomicAcrossSegmentsEmbeddingsAndPeople() async throws {
        let dbQueue = try await requireDatabaseQueue()
        let now = Date()
        let sessionId = try await insertSession(in: dbQueue, now: now)

        let sourceId = UUID().uuidString
        let targetId = UUID().uuidString
        try await insertPerson(in: dbQueue, name: "Source", now: now, id: sourceId)
        try await insertPerson(in: dbQueue, name: "Target", now: now, id: targetId)

        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcription_segments(sessionId, speaker, text, startTime, endTime, segmentOrder, createdAt, segmentId, speakerLabel, isUser, personId)
                    VALUES(?, 1, 'a', 0.0, 1.0, 0, ?, 'seg', 'SPEAKER_01', 0, ?)
                    """,
                arguments: [sessionId, now, sourceId]
            )
        }

        let e = SpeakerEmbeddingRecord.encode([0.1, 0.2, 0.3])
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO speaker_embeddings(sessionId, chunkId, embedding, embeddingDim, startTime, endTime, speakerId, personId, createdAt, assignmentSource, matchConfidence, embeddingModel, embeddingVersion, isTrainingSample)
                    VALUES(?, NULL, ?, 3, 0.0, 1.0, 1, ?, ?, 'auto_high_confidence', NULL, 'mfcc', 1, 1)
                    """,
                arguments: [sessionId, e, sourceId, now]
            )
        }

        let ok = await PeopleStore.shared.mergePerson(sourcePersonId: sourceId, into: targetId)
        XCTAssertTrue(ok)

        let peopleCount: Int = try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM people WHERE id = ?", arguments: [sourceId]) ?? 0
        }
        XCTAssertEqual(peopleCount, 0)

        let segPerson: String? = try await dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT personId FROM transcription_segments WHERE sessionId = ?", arguments: [sessionId])
        }
        XCTAssertEqual(segPerson, targetId)

        let embPerson: String? = try await dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT personId FROM speaker_embeddings WHERE sessionId = ?", arguments: [sessionId])
        }
        XCTAssertEqual(embPerson, targetId)

        let assignmentSource: String? = try await dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT assignmentSource FROM speaker_embeddings WHERE sessionId = ?", arguments: [sessionId])
        }
        XCTAssertEqual(assignmentSource, VoiceProfileAssignmentSource.autoHighConfidence.rawValue)
    }
}
