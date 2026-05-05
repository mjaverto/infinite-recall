import GRDB
import XCTest

@testable import Omi_Computer

/// Regression tests for #123 — historical frames must surface the
/// transcript that was being recorded at their timestamp. Pre-fix, the
/// expanded transcript area always showed the live monitor and never
/// loaded by-timestamp segments.
final class RewindHistoricalTranscriptTests: XCTestCase {
    private var testUserId = ""

    override func setUp() async throws {
        try await super.setUp()
        testUserId = "test-historical-transcript-\(UUID().uuidString)"
        await RewindDatabase.shared.configure(userId: testUserId)
        try await RewindDatabase.shared.initialize()
    }

    override func tearDown() async throws {
        await RewindDatabase.shared.close()
        try await super.tearDown()
    }

    func testReturnsSegmentsOverlappingFrameTimestamp() async throws {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }

        // Session begins at t=0. Three segments cover 0..5, 6..10, 12..15.
        // A frame at sessionStart + 8 should match only the middle segment
        // when window is small (1s).
        let sessionStart = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionId = try await insertSession(dbQueue: dbQueue, startedAt: sessionStart)
        try await insertSegment(
            dbQueue: dbQueue, sessionId: sessionId, order: 0,
            text: "first", startTime: 0, endTime: 5
        )
        try await insertSegment(
            dbQueue: dbQueue, sessionId: sessionId, order: 1,
            text: "middle", startTime: 6, endTime: 10
        )
        try await insertSegment(
            dbQueue: dbQueue, sessionId: sessionId, order: 2,
            text: "third", startTime: 12, endTime: 15
        )

        let segments = try await RewindDatabase.shared.transcriptSegments(
            around: sessionStart.addingTimeInterval(8),
            window: 1
        )
        XCTAssertEqual(segments.map(\.text), ["middle"])
    }

    func testReturnsAdjacentSegmentsWithinWindow() async throws {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }

        let sessionStart = Date(timeIntervalSince1970: 1_700_001_000)
        let sessionId = try await insertSession(dbQueue: dbQueue, startedAt: sessionStart)
        try await insertSegment(
            dbQueue: dbQueue, sessionId: sessionId, order: 0,
            text: "before", startTime: 0, endTime: 5
        )
        try await insertSegment(
            dbQueue: dbQueue, sessionId: sessionId, order: 1,
            text: "after", startTime: 12, endTime: 18
        )

        // Frame at t=8: with window=10 both segments overlap.
        let segments = try await RewindDatabase.shared.transcriptSegments(
            around: sessionStart.addingTimeInterval(8),
            window: 10
        )
        XCTAssertEqual(Set(segments.map(\.text)), Set(["before", "after"]))
    }

    func testEmptyWhenNoOverlap() async throws {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }

        let sessionStart = Date(timeIntervalSince1970: 1_700_002_000)
        let sessionId = try await insertSession(dbQueue: dbQueue, startedAt: sessionStart)
        try await insertSegment(
            dbQueue: dbQueue, sessionId: sessionId, order: 0,
            text: "lonely", startTime: 0, endTime: 5
        )

        // Frame far outside any segment.
        let segments = try await RewindDatabase.shared.transcriptSegments(
            around: sessionStart.addingTimeInterval(60 * 60),
            window: 5
        )
        XCTAssertEqual(segments.count, 0)
    }

    // MARK: - Helpers

    private func insertSession(dbQueue: DatabasePool, startedAt: Date) async throws -> Int64 {
        try await dbQueue.write { db -> Int64 in
            try db.execute(
                sql: """
                    INSERT INTO transcription_sessions(
                        startedAt, source, language, timezone, status, retryCount,
                        backendSynced, createdAt, updatedAt, summary_state
                    )
                    VALUES (?, 'desktop', 'en', 'UTC', 'recording', 0, 0, ?, ?, 'pending')
                    """,
                arguments: [startedAt, startedAt, startedAt]
            )
            return db.lastInsertedRowID
        }
    }

    private func insertSegment(
        dbQueue: DatabasePool,
        sessionId: Int64,
        order: Int,
        text: String,
        startTime: Double,
        endTime: Double
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcription_segments(
                        sessionId, speaker, text, startTime, endTime,
                        segmentOrder, createdAt
                    )
                    VALUES (?, 0, ?, ?, ?, ?, ?)
                    """,
                arguments: [sessionId, text, startTime, endTime, order, Date()]
            )
        }
    }
}
