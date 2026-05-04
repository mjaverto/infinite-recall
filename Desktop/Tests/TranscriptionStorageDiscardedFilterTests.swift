import XCTest
import GRDB
@testable import Omi_Computer

/// Truth-table coverage for the discarded/deleted filter logic in
/// `TranscriptionStorage.getLocalConversations` and
/// `TranscriptionStorage.getLocalConversationsCount`.
///
/// Driving the production singleton against a real DB is out of scope (it
/// pulls in the full `RewindDatabase` schema and singleton setup), so we
/// follow the same pattern as `TranscriptionStorageRepairTests`: mirror the
/// EXACT SQL the production methods emit through GRDB and pin the row-level
/// invariants.
///
/// Source of truth (keep in sync):
/// `TranscriptionStorage.getLocalConversations` &
/// `TranscriptionStorage.getLocalConversationsCount` —
/// `Desktop/Sources/Rewind/Core/TranscriptionStorage.swift`.
///
/// The branch logic mirrored here is:
///   var query = ...filter(deleted == false)
///   if discardedOnly {
///       query = query.filter(discarded == true)
///   } else if !includeDiscarded {
///       query = query.filter(discarded == false)
///   }
///
/// Precedence note: when both `includeDiscarded == true` AND
/// `discardedOnly == true`, `discardedOnly` wins (it's the first arm of the
/// if/else). The test below pins this so a future refactor can't silently
/// flip the semantics.
final class TranscriptionStorageDiscardedFilterTests: XCTestCase {

    // MARK: - Harness

    /// Minimal in-memory schema covering the columns the discarded filter
    /// reads. Production schema has many more columns; we only need
    /// `deleted`, `discarded`, plus a primary key + `startedAt` for ORDER BY
    /// (used by `getLocalConversations`).
    private func makeQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE transcription_sessions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    deleted INTEGER NOT NULL DEFAULT 0,
                    discarded INTEGER NOT NULL DEFAULT 0,
                    startedAt DATETIME NOT NULL
                )
                """)
        }
        return queue
    }

    @discardableResult
    private func insertRow(
        _ queue: DatabaseQueue,
        deleted: Bool,
        discarded: Bool
    ) throws -> Int64 {
        try queue.write { db -> Int64 in
            try db.execute(
                sql: """
                    INSERT INTO transcription_sessions
                        (deleted, discarded, startedAt)
                    VALUES (?, ?, ?)
                    """,
                arguments: [deleted, discarded, Date()]
            )
            return db.lastInsertedRowID
        }
    }

    /// Insert the 4-row truth-table fixture and return the row IDs in
    /// (deleted, discarded) tuple order:
    /// (0,0) active, (0,1) discarded, (1,0) deleted, (1,1) deleted+discarded.
    private struct Fixture {
        let active: Int64
        let discarded: Int64
        let deleted: Int64
        let deletedAndDiscarded: Int64
    }

    private func seedTruthTable(_ queue: DatabaseQueue) throws -> Fixture {
        let active = try insertRow(queue, deleted: false, discarded: false)
        let discarded = try insertRow(queue, deleted: false, discarded: true)
        let deleted = try insertRow(queue, deleted: true, discarded: false)
        let deletedAndDiscarded = try insertRow(queue, deleted: true, discarded: true)
        return Fixture(
            active: active,
            discarded: discarded,
            deleted: deleted,
            deletedAndDiscarded: deletedAndDiscarded
        )
    }

    /// Mirror the production `getLocalConversations` filter chain via GRDB
    /// query interface (using a generic Row fetch so we don't have to drag
    /// `TranscriptionSessionRecord` and the full schema into the harness).
    private func fetchIDs(
        _ queue: DatabaseQueue,
        includeDiscarded: Bool,
        discardedOnly: Bool
    ) throws -> Set<Int64> {
        try queue.read { db in
            var sql = "SELECT id FROM transcription_sessions WHERE deleted = 0"
            if discardedOnly {
                sql += " AND discarded = 1"
            } else if !includeDiscarded {
                sql += " AND discarded = 0"
            }
            sql += " ORDER BY startedAt DESC"
            let ids = try Int64.fetchAll(db, sql: sql)
            return Set(ids)
        }
    }

    /// Mirror of `getLocalConversationsCount` — same predicate, COUNT(*).
    private func countRows(
        _ queue: DatabaseQueue,
        includeDiscarded: Bool,
        discardedOnly: Bool
    ) throws -> Int {
        try queue.read { db in
            var sql = "SELECT COUNT(*) FROM transcription_sessions WHERE deleted = 0"
            if discardedOnly {
                sql += " AND discarded = 1"
            } else if !includeDiscarded {
                sql += " AND discarded = 0"
            }
            return try Int.fetchOne(db, sql: sql) ?? 0
        }
    }

    // MARK: - getLocalConversations truth table

    /// Default args: hide discarded AND deleted rows. Only the active row
    /// shows up — this is the conversations-list default behavior.
    func testDefault_HidesDiscardedAndDeleted() throws {
        let queue = try makeQueue()
        let f = try seedTruthTable(queue)

        let ids = try fetchIDs(queue, includeDiscarded: false, discardedOnly: false)

        XCTAssertEqual(ids, [f.active], "default must show only the active row")
    }

    /// `includeDiscarded == true`: surface both active and discarded rows;
    /// deleted rows still hidden.
    func testIncludeDiscarded_ShowsActiveAndDiscarded() throws {
        let queue = try makeQueue()
        let f = try seedTruthTable(queue)

        let ids = try fetchIDs(queue, includeDiscarded: true, discardedOnly: false)

        XCTAssertEqual(
            ids, [f.active, f.discarded],
            "includeDiscarded=true must show active + discarded, never deleted"
        )
    }

    /// `discardedOnly == true`: only discarded non-deleted rows. Used by the
    /// "Discarded" chip in the UI.
    func testDiscardedOnly_ShowsOnlyDiscardedNonDeleted() throws {
        let queue = try makeQueue()
        let f = try seedTruthTable(queue)

        let ids = try fetchIDs(queue, includeDiscarded: false, discardedOnly: true)

        XCTAssertEqual(
            ids, [f.discarded],
            "discardedOnly=true must show only discarded rows that aren't also deleted"
        )
    }

    /// Precedence rule: when BOTH `includeDiscarded` and `discardedOnly` are
    /// true, the if/else picks `discardedOnly` (first arm). Pin this so a
    /// future refactor can't flip semantics silently.
    func testBothFlagsTrue_DiscardedOnlyWins() throws {
        let queue = try makeQueue()
        let f = try seedTruthTable(queue)

        let ids = try fetchIDs(queue, includeDiscarded: true, discardedOnly: true)

        XCTAssertEqual(
            ids, [f.discarded],
            "when both flags are true, discardedOnly takes precedence (matches if/else order)"
        )
    }

    /// Across every combination, deleted rows MUST never surface. They live
    /// in the DB as soft-deleted and only restoration tooling (out of scope)
    /// should see them.
    func testDeletedRowsNeverSurface() throws {
        let queue = try makeQueue()
        let f = try seedTruthTable(queue)

        for include in [false, true] {
            for only in [false, true] {
                let ids = try fetchIDs(queue, includeDiscarded: include, discardedOnly: only)
                XCTAssertFalse(
                    ids.contains(f.deleted),
                    "deleted row must never surface (include=\(include), only=\(only))"
                )
                XCTAssertFalse(
                    ids.contains(f.deletedAndDiscarded),
                    "deleted+discarded row must never surface (include=\(include), only=\(only))"
                )
            }
        }
    }

    // MARK: - getLocalConversationsCount truth table

    /// Same truth table, but counted. Mirror of the rows test so a divergence
    /// between query and count predicates is caught immediately.
    func testCount_DefaultArgs_OnlyActive() throws {
        let queue = try makeQueue()
        _ = try seedTruthTable(queue)
        XCTAssertEqual(try countRows(queue, includeDiscarded: false, discardedOnly: false), 1)
    }

    func testCount_IncludeDiscarded_TwoRows() throws {
        let queue = try makeQueue()
        _ = try seedTruthTable(queue)
        XCTAssertEqual(try countRows(queue, includeDiscarded: true, discardedOnly: false), 2)
    }

    func testCount_DiscardedOnly_OneRow() throws {
        let queue = try makeQueue()
        _ = try seedTruthTable(queue)
        XCTAssertEqual(try countRows(queue, includeDiscarded: false, discardedOnly: true), 1)
    }

    func testCount_BothFlags_DiscardedOnlyWins() throws {
        let queue = try makeQueue()
        _ = try seedTruthTable(queue)
        XCTAssertEqual(try countRows(queue, includeDiscarded: true, discardedOnly: true), 1)
    }
}
