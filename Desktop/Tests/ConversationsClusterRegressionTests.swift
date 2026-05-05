import XCTest
import GRDB
@testable import Omi_Computer

/// Regression coverage for the local-first Conversations fixes shipped in the
/// `gh-conversations-cluster` PR (#136 #138 #139 #140 #141 #142).
///
/// We mirror the production SQL inline rather than driving the full
/// `TranscriptionStorage` singleton + `RewindDatabase` migration chain — the
/// same approach taken by `TranscriptionStorageDiscardedFilterTests`. This
/// keeps the test suite hermetic and pins the row-level invariants that each
/// issue's fix relies on.
///
/// Sources of truth (keep in sync):
///   - `getLocalConversations` / `getLocalConversationsCount` startDate/endDate
///     filter (issue #138)
///   - `searchConversationsLocally` LIKE join over segments (issue #139)
///   - `mergeConversationsLocally` re-parent + soft-delete (issue #140)
///   - `deleteByBackendId` soft-delete write (issue #136)
///     in `Desktop/Sources/Rewind/Core/TranscriptionStorage.swift`.
final class ConversationsClusterRegressionTests: XCTestCase {

    // MARK: - Harness

    /// Minimal in-memory schema covering only the columns the cluster fixes
    /// touch. Production schema has many more columns; we only need what the
    /// SQL under test reads/writes.
    private func makeQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE transcription_sessions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    backendId TEXT,
                    title TEXT,
                    overview TEXT,
                    deleted INTEGER NOT NULL DEFAULT 0,
                    discarded INTEGER NOT NULL DEFAULT 0,
                    startedAt DATETIME NOT NULL,
                    finishedAt DATETIME,
                    updatedAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                )
                """)
            try db.execute(sql: """
                CREATE TABLE transcription_segments (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    sessionId INTEGER NOT NULL,
                    text TEXT NOT NULL,
                    segmentOrder INTEGER NOT NULL DEFAULT 0,
                    startTime DOUBLE NOT NULL DEFAULT 0
                )
                """)
        }
        return queue
    }

    @discardableResult
    private func insertSession(
        _ queue: DatabaseQueue,
        backendId: String? = nil,
        title: String? = nil,
        overview: String? = nil,
        deleted: Bool = false,
        discarded: Bool = false,
        startedAt: Date,
        finishedAt: Date? = nil
    ) throws -> Int64 {
        try queue.write { db -> Int64 in
            try db.execute(
                sql: """
                    INSERT INTO transcription_sessions
                        (backendId, title, overview, deleted, discarded, startedAt, finishedAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    backendId, title, overview, deleted, discarded,
                    startedAt, finishedAt, Date(),
                ]
            )
            return db.lastInsertedRowID
        }
    }

    @discardableResult
    private func insertSegment(
        _ queue: DatabaseQueue,
        sessionId: Int64,
        text: String,
        order: Int = 0,
        startTime: Double = 0
    ) throws -> Int64 {
        try queue.write { db -> Int64 in
            try db.execute(
                sql: """
                    INSERT INTO transcription_segments
                        (sessionId, text, segmentOrder, startTime)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [sessionId, text, order, startTime]
            )
            return db.lastInsertedRowID
        }
    }

    // MARK: - Issue #138 — date-filter window

    /// Mirrors the production `getLocalConversations` date predicate:
    /// `startedAt >= startDate AND startedAt < endDate`. Half-open window.
    private func fetchInDateWindow(
        _ queue: DatabaseQueue,
        startDate: Date?,
        endDate: Date?
    ) throws -> Set<Int64> {
        try queue.read { db in
            var sql = "SELECT id FROM transcription_sessions WHERE deleted = 0 AND discarded = 0"
            var args: [DatabaseValueConvertible?] = []
            if let s = startDate {
                sql += " AND startedAt >= ?"
                args.append(s)
            }
            if let e = endDate {
                sql += " AND startedAt < ?"
                args.append(e)
            }
            sql += " ORDER BY startedAt DESC"
            let ids = try Int64.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return Set(ids)
        }
    }

    /// A date filter for "today" must return only today's session even when
    /// other sessions exist in the store. This is the exact scenario from
    /// issue #138 — picking a date in the chip before the fix returned the
    /// most-recent N rows ignoring the date entirely.
    func testDateFilter_OnlyReturnsRowsInWindow() throws {
        let queue = try makeQueue()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!

        let todayId = try insertSession(queue, startedAt: today.addingTimeInterval(3600))
        _ = try insertSession(queue, startedAt: yesterday.addingTimeInterval(3600))
        _ = try insertSession(queue, startedAt: twoDaysAgo.addingTimeInterval(3600))

        let endOfToday = calendar.date(byAdding: .day, value: 1, to: today)!
        let ids = try fetchInDateWindow(queue, startDate: today, endDate: endOfToday)

        XCTAssertEqual(ids, [todayId], "date-filter must restrict to the picked day")
    }

    /// Picking a date with no recordings must yield an empty result, NOT the
    /// fallback "most recent rows" the pre-fix behavior returned.
    func testDateFilter_EmptyForDayWithNoRecordings() throws {
        let queue = try makeQueue()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        _ = try insertSession(queue, startedAt: today.addingTimeInterval(3600))

        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!
        let dayAfter = calendar.date(byAdding: .day, value: 1, to: twoDaysAgo)!
        let ids = try fetchInDateWindow(queue, startDate: twoDaysAgo, endDate: dayAfter)

        XCTAssertTrue(ids.isEmpty, "filter on a day with no rows must yield zero results")
    }

    /// Nil window means no date filter — every active row surfaces.
    func testDateFilter_NilWindowReturnsAllActiveRows() throws {
        let queue = try makeQueue()
        let now = Date()
        let a = try insertSession(queue, startedAt: now)
        let b = try insertSession(queue, startedAt: now.addingTimeInterval(-86_400))

        let ids = try fetchInDateWindow(queue, startDate: nil, endDate: nil)

        XCTAssertEqual(ids, [a, b])
    }

    // MARK: - Issue #139 — local search

    /// Mirrors the production `searchConversationsLocally` SQL.
    private func searchLocally(
        _ queue: DatabaseQueue,
        query: String,
        includeDiscarded: Bool = false
    ) throws -> [Int64] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        let discardedClause = includeDiscarded ? "" : "AND s.discarded = 0"

        return try queue.read { db in
            let sql = """
                SELECT DISTINCT s.id
                  FROM transcription_sessions s
                  LEFT JOIN transcription_segments seg ON seg.sessionId = s.id
                 WHERE s.deleted = 0
                   \(discardedClause)
                   AND (
                        s.title    LIKE ? ESCAPE '\\'
                     OR s.overview LIKE ? ESCAPE '\\'
                     OR seg.text   LIKE ? ESCAPE '\\'
                   )
                 ORDER BY s.startedAt DESC
                """
            return try Int64.fetchAll(db, sql: sql, arguments: [pattern, pattern, pattern])
        }
    }

    /// Search must match a word that lives only inside a segment, not in the
    /// session's title/overview. This is the exact repro from issue #139.
    func testSearch_MatchesWordInSegment() throws {
        let queue = try makeQueue()
        let now = Date()
        let target = try insertSession(queue, title: "Catch-up", startedAt: now)
        try insertSegment(queue, sessionId: target, text: "Discussed mortgage rates today")

        let other = try insertSession(queue, title: "Standup", startedAt: now.addingTimeInterval(-3600))
        try insertSegment(queue, sessionId: other, text: "Talked about deploys")

        let ids = try searchLocally(queue, query: "mortgage")
        XCTAssertEqual(ids, [target])
    }

    /// Search should also match against title and overview directly.
    func testSearch_MatchesTitleAndOverview() throws {
        let queue = try makeQueue()
        let now = Date()
        let titleHit = try insertSession(queue, title: "Mortgage discussion", startedAt: now)
        let overviewHit = try insertSession(
            queue,
            title: "Q3 plan",
            overview: "Includes mortgage strategy",
            startedAt: now.addingTimeInterval(-3600)
        )
        let miss = try insertSession(queue, title: "Standup", startedAt: now.addingTimeInterval(-7200))
        try insertSegment(queue, sessionId: miss, text: "no relevant text")

        let ids = try searchLocally(queue, query: "mortgage")
        XCTAssertEqual(Set(ids), [titleHit, overviewHit])
    }

    /// Empty / whitespace queries must short-circuit to no results, never
    /// "match every row" (which would happen if `%%` were passed to LIKE).
    func testSearch_EmptyQueryReturnsNothing() throws {
        let queue = try makeQueue()
        _ = try insertSession(queue, title: "Catch-up", startedAt: Date())

        XCTAssertTrue(try searchLocally(queue, query: "").isEmpty)
        XCTAssertTrue(try searchLocally(queue, query: "   ").isEmpty)
    }

    /// Soft-deleted rows must never appear in search results.
    func testSearch_IgnoresDeletedRows() throws {
        let queue = try makeQueue()
        let now = Date()
        _ = try insertSession(
            queue,
            title: "Mortgage",
            deleted: true,
            startedAt: now
        )

        let ids = try searchLocally(queue, query: "mortgage")
        XCTAssertTrue(ids.isEmpty)
    }

    // MARK: - Issue #136 — soft-delete by backendId

    /// `deleteByBackendId` is implemented as a single UPDATE — assert the
    /// invariant: row stays in the table but `deleted == 1`, and is therefore
    /// no longer surfaced by the conversation list query.
    func testDeleteByBackendId_FlipsDeletedFlag() throws {
        let queue = try makeQueue()
        let now = Date()
        let id = try insertSession(queue, backendId: "local-1", startedAt: now)

        try queue.write { db in
            try db.execute(
                sql: "UPDATE transcription_sessions SET deleted = 1, updatedAt = ? WHERE backendId = ?",
                arguments: [Date(), "local-1"]
            )
        }

        // Row still exists in the table…
        let stillExists = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM transcription_sessions WHERE id = ?",
                arguments: [id]
            ) ?? 0
        }
        XCTAssertEqual(stillExists, 1)

        // …but is filtered out of the active conversation list.
        let visible = try fetchInDateWindow(queue, startDate: nil, endDate: nil)
        XCTAssertFalse(visible.contains(id))
    }

    // MARK: - Issue #140 — local merge

    /// Re-parent semantics: every segment from the source sessions must end
    /// up pointing at the target sessionId, and the source sessions must be
    /// soft-deleted. This is the only invariant the production code relies on
    /// to keep the merged transcript intact and the originals out of the list.
    func testMerge_ReparentsSegmentsAndSoftDeletesSources() throws {
        let queue = try makeQueue()
        let now = Date()
        let earlier = now.addingTimeInterval(-3600)

        let target = try insertSession(queue, backendId: "local-1", startedAt: earlier)
        let source = try insertSession(queue, backendId: "local-2", startedAt: now)
        try insertSegment(queue, sessionId: target, text: "first half")
        try insertSegment(queue, sessionId: source, text: "second half")

        // Mirror the merge SQL: re-parent then soft-delete the source.
        try queue.write { db in
            try db.execute(
                sql: "UPDATE transcription_segments SET sessionId = ? WHERE sessionId IN (?)",
                arguments: [target, source]
            )
            try db.execute(
                sql: "UPDATE transcription_sessions SET deleted = 1, updatedAt = ? WHERE id IN (?)",
                arguments: [Date(), source]
            )
        }

        let segCount = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM transcription_segments WHERE sessionId = ?",
                arguments: [target]
            ) ?? 0
        }
        XCTAssertEqual(segCount, 2, "all segments must re-parent onto target")

        // Source no longer surfaces; target still does.
        let visible = try fetchInDateWindow(queue, startDate: nil, endDate: nil)
        XCTAssertEqual(visible, [target])
    }
}
