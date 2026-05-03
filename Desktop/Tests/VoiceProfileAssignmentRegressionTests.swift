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

    func testAssignSegmentsBackfillsOnlyOverlappingEmbeddings() async throws {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }

        // Seed one session with two segments that share a speaker cluster but are far apart in time.
        let now = Date()
        let sessionId: Int64 = try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcription_sessions(startedAt, source, language, timezone, status, retryCount, backendSynced, createdAt, updatedAt, summary_state)
                    VALUES(?, 'desktop', 'en', 'UTC', 'completed', 0, 0, ?, ?, 'pending')
                    """,
                arguments: [now, now, now]
            )
            return db.lastInsertedRowID
        }

        // Force stable local backendId so PeopleStore paths can resolve.
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE transcription_sessions SET backendId = ? WHERE id = ?", arguments: ["local-\(sessionId)", sessionId])
        }

        // Segment order 0: 0-1s. Segment order 1: 10-11s.
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcription_segments(sessionId, speaker, text, startTime, endTime, segmentOrder, createdAt, segmentId, speakerLabel, isUser, personId)
                    VALUES(?, 1, 'a', 0.0, 1.0, 0, ?, 'seg0', 'SPEAKER_01', 0, NULL)
                    """,
                arguments: [sessionId, now]
            )
            try db.execute(
                sql: """
                    INSERT INTO transcription_segments(sessionId, speaker, text, startTime, endTime, segmentOrder, createdAt, segmentId, speakerLabel, isUser, personId)
                    VALUES(?, 1, 'b', 10.0, 11.0, 1, ?, 'seg1', 'SPEAKER_01', 0, NULL)
                    """,
                arguments: [sessionId, now]
            )
        }

        // Two embeddings, same speakerId=1 but different time windows.
        let e0 = SpeakerEmbeddingRecord.encode([0.1, 0.2, 0.3])
        let e1 = SpeakerEmbeddingRecord.encode([0.2, 0.2, 0.2])
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO speaker_embeddings(sessionId, chunkId, embedding, embeddingDim, startTime, endTime, speakerId, personId, createdAt, assignmentSource, matchConfidence, embeddingModel, embeddingVersion, isTrainingSample)
                    VALUES(?, NULL, ?, 3, 0.0, 1.0, 1, NULL, ?, NULL, NULL, 'mfcc', 1, 0)
                    """,
                arguments: [sessionId, e0, now]
            )
            try db.execute(
                sql: """
                    INSERT INTO speaker_embeddings(sessionId, chunkId, embedding, embeddingDim, startTime, endTime, speakerId, personId, createdAt, assignmentSource, matchConfidence, embeddingModel, embeddingVersion, isTrainingSample)
                    VALUES(?, NULL, ?, 3, 10.0, 11.0, 1, NULL, ?, NULL, NULL, 'mfcc', 1, 0)
                    """,
                arguments: [sessionId, e1, now]
            )
        }

        // Seed people.
        let pid = UUID().uuidString
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO people(id, displayName, defaultEmoji, createdAt, updatedAt) VALUES(?, 'Test', NULL, ?, ?)",
                arguments: [pid, now, now]
            )
        }

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
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }

        let now = Date()
        let sessionId: Int64 = try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcription_sessions(startedAt, source, language, timezone, status, retryCount, backendSynced, createdAt, updatedAt, summary_state)
                    VALUES(?, 'desktop', 'en', 'UTC', 'completed', 0, 0, ?, ?, 'pending')
                    """,
                arguments: [now, now, now]
            )
            return db.lastInsertedRowID
        }

        let pid = UUID().uuidString
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO people(id, displayName, defaultEmoji, createdAt, updatedAt) VALUES(?, 'Test', NULL, ?, ?)",
                arguments: [pid, now, now]
            )
        }

        let e = SpeakerEmbeddingRecord.encode([1, 0, 0])
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO speaker_embeddings(sessionId, chunkId, embedding, embeddingDim, startTime, endTime, speakerId, personId, createdAt, assignmentSource, matchConfidence, embeddingModel, embeddingVersion, isTrainingSample)
                    VALUES(?, NULL, ?, 3, 0.0, 1.0, 1, NULL, ?, NULL, NULL, 'speakerkit-synthetic', 1, 0)
                    """,
                arguments: [sessionId, e, now]
            )
        }

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
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }

        let now = Date()
        let sessionId: Int64 = try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcription_sessions(startedAt, source, language, timezone, status, retryCount, backendSynced, createdAt, updatedAt, summary_state)
                    VALUES(?, 'desktop', 'en', 'UTC', 'completed', 0, 0, ?, ?, 'pending')
                    """,
                arguments: [now, now, now]
            )
            return db.lastInsertedRowID
        }
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE transcription_sessions SET backendId = ? WHERE id = ?", arguments: ["local-\(sessionId)", sessionId])
        }

        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcription_segments(sessionId, speaker, text, startTime, endTime, segmentOrder, createdAt, segmentId, speakerLabel, isUser, personId)
                    VALUES(?, 1, 'short noisy clip', 0.0, 0.3, 0, ?, 'seg-short', 'SPEAKER_01', 0, NULL)
                    """,
                arguments: [sessionId, now]
            )
        }

        let e = SpeakerEmbeddingRecord.encode([1, 0, 0])
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO speaker_embeddings(sessionId, chunkId, embedding, embeddingDim, startTime, endTime, speakerId, personId, createdAt, assignmentSource, matchConfidence, embeddingModel, embeddingVersion, isTrainingSample)
                    VALUES(?, NULL, ?, 3, 0.0, 1.0, 1, NULL, ?, NULL, NULL, 'mfcc', 1, 0)
                    """,
                arguments: [sessionId, e, now]
            )
        }

        let pid = UUID().uuidString
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO people(id, displayName, defaultEmoji, createdAt, updatedAt) VALUES(?, 'Short Clip', NULL, ?, ?)",
                arguments: [pid, now, now]
            )
        }

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
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }

        let now = Date()
        let sessionId: Int64 = try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcription_sessions(startedAt, source, language, timezone, status, retryCount, backendSynced, createdAt, updatedAt, summary_state)
                    VALUES(?, 'desktop', 'en', 'UTC', 'completed', 0, 0, ?, ?, 'pending')
                    """,
                arguments: [now, now, now]
            )
            return db.lastInsertedRowID
        }
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE transcription_sessions SET backendId = ? WHERE id = ?", arguments: ["local-\(sessionId)", sessionId])
        }

        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcription_segments(sessionId, speaker, text, startTime, endTime, segmentOrder, createdAt, segmentId, speakerLabel, isUser, personId)
                    VALUES(?, 1, 'ok', 0.0, 0.5, 0, ?, 'seg-short', 'SPEAKER_01', 0, NULL)
                    """,
                arguments: [sessionId, now]
            )
            try db.execute(
                sql: """
                    INSERT INTO transcription_segments(sessionId, speaker, text, startTime, endTime, segmentOrder, createdAt, segmentId, speakerLabel, isUser, personId)
                    VALUES(?, 1, '(gentle music)', 1.0, 5.0, 1, ?, 'seg-music', 'SPEAKER_01', 0, NULL)
                    """,
                arguments: [sessionId, now]
            )
            try db.execute(
                sql: """
                    INSERT INTO transcription_segments(sessionId, speaker, text, startTime, endTime, segmentOrder, createdAt, segmentId, speakerLabel, isUser, personId)
                    VALUES(?, 1, 'This is a clean reviewable speaker turn.', 6.0, 10.0, 2, ?, 'seg-reviewable', 'SPEAKER_01', 0, NULL)
                    """,
                arguments: [sessionId, now]
            )
        }

        let embedding = SpeakerEmbeddingRecord.encode([1, 0, 0])
        try await dbQueue.write { db in
            for (start, end) in [(0.0, 0.5), (1.0, 5.0), (6.0, 10.0)] {
                try db.execute(
                    sql: """
                        INSERT INTO speaker_embeddings(sessionId, chunkId, embedding, embeddingDim, startTime, endTime, speakerId, personId, createdAt, assignmentSource, matchConfidence, embeddingModel, embeddingVersion, isTrainingSample)
                        VALUES(?, NULL, ?, 3, ?, ?, 1, NULL, ?, NULL, NULL, 'mfcc', 1, 0)
                        """,
                    arguments: [sessionId, embedding, start, end, now]
                )
            }
        }

        let pid = UUID().uuidString
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO people(id, displayName, defaultEmoji, createdAt, updatedAt) VALUES(?, 'Cluster Person', NULL, ?, ?)",
                arguments: [pid, now, now]
            )
        }

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
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }

        let now = Date()
        let sessionId: Int64 = try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcription_sessions(startedAt, source, language, timezone, status, retryCount, backendSynced, createdAt, updatedAt, summary_state)
                    VALUES(?, 'desktop', 'en', 'UTC', 'completed', 0, 0, ?, ?, 'pending')
                    """,
                arguments: [now, now, now]
            )
            return db.lastInsertedRowID
        }

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

        let pid = UUID().uuidString
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO people(id, displayName, defaultEmoji, createdAt, updatedAt) VALUES(?, 'Known', NULL, ?, ?)",
                arguments: [pid, now, now]
            )
        }

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
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }

        let now = Date()
        let sessionId: Int64 = try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcription_sessions(startedAt, source, language, timezone, status, retryCount, backendSynced, createdAt, updatedAt, summary_state)
                    VALUES(?, 'desktop', 'en', 'UTC', 'completed', 0, 0, ?, ?, 'pending')
                    """,
                arguments: [now, now, now]
            )
            return db.lastInsertedRowID
        }

        let sourceId = UUID().uuidString
        let targetId = UUID().uuidString
        try await dbQueue.write { db in
            try db.execute(sql: "INSERT INTO people(id, displayName, defaultEmoji, createdAt, updatedAt) VALUES(?, 'Source', NULL, ?, ?)", arguments: [sourceId, now, now])
            try db.execute(sql: "INSERT INTO people(id, displayName, defaultEmoji, createdAt, updatedAt) VALUES(?, 'Target', NULL, ?, ?)", arguments: [targetId, now, now])
        }

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
