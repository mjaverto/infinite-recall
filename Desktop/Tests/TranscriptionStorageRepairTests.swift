import XCTest
import GRDB
@testable import Omi_Computer

/// Tests the SQL semantics of `TranscriptionStorage.repairFinishedInProgressSessions`.
///
/// We can't drive the production singleton against a temp DB without
/// touching files outside this task's MODIFY scope, so instead we run the
/// EXACT SQL the repair method runs against a minimal in-memory schema and
/// assert the row-level invariants required by the contract:
///
///   UPDATE transcription_sessions
///      SET conversationStatus = 'completed', updatedAt = ?
///    WHERE finishedAt IS NOT NULL
///      AND conversationStatus = 'in_progress'
///      AND status != 'recording'
///
/// Source of truth: `TranscriptionStorage.repairFinishedInProgressSessions`.
/// If you change one, change the other.
final class TranscriptionStorageRepairTests: XCTestCase {

    /// The literal SQL run by the repair method. Mirrored here for the
    /// in-memory test harness.
    private static let repairSQL = """
        UPDATE transcription_sessions
           SET conversationStatus = 'completed',
               updatedAt = ?
         WHERE finishedAt IS NOT NULL
           AND conversationStatus = 'in_progress'
           AND status != 'recording'
        """

    // MARK: - Harness

    /// Minimal in-memory schema covering the columns the repair touches.
    /// Production schema has many more columns; we only need the four the
    /// repair filter reads + a primary key.
    private func makeQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE transcription_sessions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    finishedAt DATETIME,
                    status TEXT NOT NULL,
                    conversationStatus TEXT NOT NULL,
                    updatedAt DATETIME NOT NULL
                )
                """)
        }
        return queue
    }

    private func insertRow(
        _ queue: DatabaseQueue,
        finishedAt: Date?,
        status: String,
        conversationStatus: String
    ) throws -> Int64 {
        return try queue.write { db -> Int64 in
            try db.execute(
                sql: """
                    INSERT INTO transcription_sessions
                        (finishedAt, status, conversationStatus, updatedAt)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [finishedAt, status, conversationStatus, Date()]
            )
            return db.lastInsertedRowID
        }
    }

    private func conversationStatus(_ queue: DatabaseQueue, id: Int64) throws -> String? {
        try queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT conversationStatus FROM transcription_sessions WHERE id = ?",
                arguments: [id]
            )
        }
    }

    // MARK: - Required behaviours

    /// Stuck row: finished, but conversationStatus is still 'in_progress' and
    /// the recording is no longer active. Must flip to 'completed'.
    func testRepairFlipsFinishedInProgressToCompleted() throws {
        let queue = try makeQueue()
        let id = try insertRow(
            queue,
            finishedAt: Date(),
            status: "completed",
            conversationStatus: "in_progress"
        )

        try queue.write { db in
            try db.execute(sql: Self.repairSQL, arguments: [Date()])
        }

        XCTAssertEqual(try conversationStatus(queue, id: id), "completed")
    }

    /// Active recording: even if conversationStatus shows 'in_progress', the
    /// repair MUST NOT touch it. Otherwise we'd close out a live recording.
    func testRepairLeavesRecordingRowsUntouched() throws {
        let queue = try makeQueue()
        let id = try insertRow(
            queue,
            finishedAt: nil,
            status: "recording",
            conversationStatus: "in_progress"
        )

        try queue.write { db in
            try db.execute(sql: Self.repairSQL, arguments: [Date()])
        }

        XCTAssertEqual(
            try conversationStatus(queue, id: id),
            "in_progress",
            "Active recording rows must not be normalized by the repair"
        )
    }

    /// Active recording with a defensive non-null finishedAt set somehow:
    /// status='recording' is the hard guard, so this row must STILL be
    /// untouched.
    func testRepairLeavesRecordingRowsUntouchedEvenWithFinishedAtSet() throws {
        let queue = try makeQueue()
        let id = try insertRow(
            queue,
            finishedAt: Date(),
            status: "recording",
            conversationStatus: "in_progress"
        )

        try queue.write { db in
            try db.execute(sql: Self.repairSQL, arguments: [Date()])
        }

        XCTAssertEqual(
            try conversationStatus(queue, id: id),
            "in_progress",
            "status='recording' must protect rows from the repair"
        )
    }

    /// Already-completed conversations should be left alone.
    func testRepairLeavesCompletedRowsAlone() throws {
        let queue = try makeQueue()
        let id = try insertRow(
            queue,
            finishedAt: Date(),
            status: "completed",
            conversationStatus: "completed"
        )

        try queue.write { db in
            try db.execute(sql: Self.repairSQL, arguments: [Date()])
        }

        XCTAssertEqual(try conversationStatus(queue, id: id), "completed")
    }

    /// Idempotent: a second run after the first must change nothing further.
    func testRepairIsIdempotent() throws {
        let queue = try makeQueue()
        let stuck = try insertRow(
            queue,
            finishedAt: Date(),
            status: "completed",
            conversationStatus: "in_progress"
        )

        try queue.write { db in
            try db.execute(sql: Self.repairSQL, arguments: [Date()])
        }
        XCTAssertEqual(try conversationStatus(queue, id: stuck), "completed")

        // Second pass: row is already 'completed' — UPDATE WHERE clause no
        // longer matches, no further mutation occurs.
        let changed = try queue.write { db -> Int in
            try db.execute(sql: Self.repairSQL, arguments: [Date()])
            return db.changesCount
        }
        XCTAssertEqual(changed, 0, "Repair must be idempotent on the second run")
    }

    /// Mixed dataset: ensures the repair flips ONLY the rows the contract
    /// targets, leaving every other row untouched.
    func testRepairOnlyAffectsTargetRows() throws {
        let queue = try makeQueue()
        let stuck = try insertRow(queue, finishedAt: Date(), status: "completed",   conversationStatus: "in_progress")
        let live  = try insertRow(queue, finishedAt: nil,    status: "recording",   conversationStatus: "in_progress")
        let done  = try insertRow(queue, finishedAt: Date(), status: "completed",   conversationStatus: "completed")
        let upl   = try insertRow(queue, finishedAt: nil,    status: "pending_upload", conversationStatus: "in_progress")

        try queue.write { db in
            try db.execute(sql: Self.repairSQL, arguments: [Date()])
        }

        XCTAssertEqual(try conversationStatus(queue, id: stuck), "completed", "stuck row → completed")
        XCTAssertEqual(try conversationStatus(queue, id: live),  "in_progress", "active recording → unchanged")
        XCTAssertEqual(try conversationStatus(queue, id: done),  "completed", "already-done → unchanged")
        // pending_upload with no finishedAt: falls outside the WHERE clause
        // (finishedAt IS NULL) → must NOT flip.
        XCTAssertEqual(try conversationStatus(queue, id: upl), "in_progress", "pending_upload w/ null finishedAt → unchanged")
    }
}
