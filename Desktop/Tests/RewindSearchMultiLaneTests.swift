import GRDB
import XCTest

@testable import Omi_Computer

/// Regression tests for #119 — Rewind search must span OCR text,
/// vision-model summaries (`visual_activity.visualSummary`), and spoken
/// transcript text (`transcription_segments.text`). Pre-fix the search
/// path joined only `screenshots_fts`, leaving VLM and transcript hits
/// invisible despite the doc promising all three.
final class RewindSearchMultiLaneTests: XCTestCase {
    private var testUserId = ""

    override func setUp() async throws {
        try await super.setUp()
        testUserId = "test-rewind-search-\(UUID().uuidString)"
        await RewindDatabase.shared.configure(userId: testUserId)
        try await RewindDatabase.shared.initialize()
    }

    override func tearDown() async throws {
        await RewindDatabase.shared.close()
        try await super.tearDown()
    }

    func testSearchMatchesViaOCRTextLane() async throws {
        let now = Date()
        let id = try await RewindDatabase.shared.insertScreenshot(Screenshot(
            timestamp: now,
            appName: "Safari",
            windowTitle: "Tab",
            imagePath: "",
            ocrText: "tutorial bingo zebra",
            isIndexed: true
        )).id

        let results = try await RewindDatabase.shared.search(query: "bingo")
        XCTAssertTrue(results.contains(where: { $0.id == id }), "OCR-text match must surface")
    }

    func testSearchMatchesViaVisualActivitySummary() async throws {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }
        let now = Date()
        let id = try await RewindDatabase.shared.insertScreenshot(Screenshot(
            timestamp: now,
            appName: "Safari",
            windowTitle: "Tab",
            imagePath: "",
            ocrText: nil,
            isIndexed: true
        )).id!

        // Insert a visual_activity row whose summary contains a unique token
        // that is NOT present anywhere in the screenshots table — only the
        // visual_activity_fts lane can find it.
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO visual_activity(
                        screenshotId, sampledAt, appName, windowTitle,
                        visualSummary, uiState, ocrTextSnapshot, perceptualHash, createdAt
                    )
                    VALUES (?, ?, 'Safari', 'Tab', ?, NULL, NULL, NULL, ?)
                    """,
                arguments: [id, now, "User watching swiftui flamingotutorial on screen", now]
            )
        }

        let results = try await RewindDatabase.shared.search(query: "flamingotutorial")
        XCTAssertTrue(
            results.contains(where: { $0.id == id }),
            "Vision-model summary match must surface — visual_activity_fts lane"
        )
    }

    func testSearchMatchesViaTranscriptSegmentText() async throws {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }
        // Frame at t=10 inside a session that started at t=0; a segment
        // covering 5..15 says "quokka roadmap" — the screenshot must show
        // up when searching for "quokka".
        let sessionStart = Date(timeIntervalSince1970: 1_700_000_000)
        let frameTime = sessionStart.addingTimeInterval(10)

        let id = try await RewindDatabase.shared.insertScreenshot(Screenshot(
            timestamp: frameTime,
            appName: "Zoom",
            windowTitle: "Standup",
            imagePath: "",
            ocrText: nil,
            isIndexed: true
        )).id!

        let sessionId = try await dbQueue.write { db -> Int64 in
            try db.execute(
                sql: """
                    INSERT INTO transcription_sessions(
                        startedAt, source, language, timezone, status, retryCount,
                        backendSynced, createdAt, updatedAt, summary_state
                    )
                    VALUES (?, 'desktop', 'en', 'UTC', 'recording', 0, 0, ?, ?, 'pending')
                    """,
                arguments: [sessionStart, sessionStart, sessionStart]
            )
            return db.lastInsertedRowID
        }

        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO transcription_segments(
                        sessionId, speaker, text, startTime, endTime, segmentOrder, createdAt
                    )
                    VALUES (?, 0, ?, 5.0, 15.0, 0, ?)
                    """,
                arguments: [sessionId, "let's lock the quokka roadmap", sessionStart]
            )
        }

        let results = try await RewindDatabase.shared.search(query: "quokka")
        XCTAssertTrue(
            results.contains(where: { $0.id == id }),
            "Transcript-text match must surface — transcription_segments_fts lane"
        )
    }
}
