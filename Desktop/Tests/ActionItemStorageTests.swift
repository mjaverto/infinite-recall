import XCTest
import GRDB
@testable import Omi_Computer

/// Tests for `ActionItemStorage` reconciliation safety against an in-memory
/// GRDB instance. The production singleton owns a per-user database file we
/// don't want to touch from tests; instead we run the EXACT filter logic
/// `hardDeleteAbsentTasks` and `markAbsentTasksAsStaged` use against a
/// minimal schema and assert the invariants the production methods promise.
///
/// Source of truth: `ActionItemStorage.hardDeleteAbsentTasks`,
/// `ActionItemStorage.markAbsentTasksAsStaged`. If you change one, change
/// the other.
///
/// Invariant under test: rows whose `backendId` is null/empty (e.g.
/// conversation-derived tasks that never round-trip through the API) MUST be
/// preserved. Only synced rows whose `backendId` is missing from the API set
/// are deleted.
final class ActionItemStorageTests: XCTestCase {

    // MARK: - Harness

    /// Minimal in-memory schema covering the columns the reconciliation
    /// filter reads + a primary key.
    private func makeQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE action_items (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    backendId TEXT,
                    backendSynced INTEGER NOT NULL DEFAULT 0,
                    description TEXT NOT NULL,
                    completed INTEGER NOT NULL DEFAULT 0,
                    deleted INTEGER NOT NULL DEFAULT 0,
                    source TEXT,
                    fromStaged INTEGER NOT NULL DEFAULT 0,
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL
                )
                """)
        }
        return queue
    }

    @discardableResult
    private func insertRow(
        _ queue: DatabaseQueue,
        backendId: String?,
        backendSynced: Bool,
        source: String?,
        fromStaged: Bool = false,
        completed: Bool = false,
        deleted: Bool = false
    ) throws -> Int64 {
        return try queue.write { db -> Int64 in
            try db.execute(
                sql: """
                    INSERT INTO action_items
                        (backendId, backendSynced, description, completed, deleted,
                         source, fromStaged, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    backendId,
                    backendSynced,
                    "test row \(UUID().uuidString)",
                    completed,
                    deleted,
                    source,
                    fromStaged,
                    Date(),
                    Date(),
                ]
            )
            return db.lastInsertedRowID
        }
    }

    private func rowExists(_ queue: DatabaseQueue, id: Int64) throws -> Bool {
        return try queue.read { db in
            let n = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM action_items WHERE id = ?",
                arguments: [id]
            ) ?? 0
            return n > 0
        }
    }

    /// Mirrors the SQL the production `hardDeleteAbsentTasks` runs:
    /// fetch synced records with non-null/non-empty backendId, then delete
    /// those whose backendId is NOT in the supplied API set.
    private func runHardDeleteAbsent(_ queue: DatabaseQueue, apiIds: Set<String>) throws -> Int {
        // Mirror the production safety guard: empty API set is a no-op.
        guard !apiIds.isEmpty else { return 0 }

        return try queue.write { db -> Int in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, backendId FROM action_items
                 WHERE completed = 0
                   AND deleted = 0
                   AND backendId IS NOT NULL
                   AND backendId != ''
                   AND backendSynced = 1
                """)
            var count = 0
            for row in rows {
                guard let id: Int64 = row["id"],
                      let backendId: String = row["backendId"],
                      !backendId.isEmpty else { continue }
                if !apiIds.contains(backendId) {
                    try db.execute(sql: "DELETE FROM action_items WHERE id = ?", arguments: [id])
                    count += 1
                }
            }
            return count
        }
    }

    /// Mirrors the SQL the production `markAbsentTasksAsStaged` runs (which
    /// is a hard delete despite the name).
    private func runMarkAbsentAsStaged(_ queue: DatabaseQueue, apiIds: Set<String>) throws -> Int {
        guard !apiIds.isEmpty else { return 0 }

        return try queue.write { db -> Int in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, backendId FROM action_items
                 WHERE completed = 0
                   AND deleted = 0
                   AND backendId IS NOT NULL
                   AND backendId != ''
                """)
            var count = 0
            for row in rows {
                guard let id: Int64 = row["id"],
                      let backendId: String = row["backendId"],
                      !backendId.isEmpty else { continue }
                if !apiIds.contains(backendId) {
                    try db.execute(sql: "DELETE FROM action_items WHERE id = ?", arguments: [id])
                    count += 1
                }
            }
            return count
        }
    }

    // MARK: - hardDeleteAbsentTasks

    func testHardDeleteAbsent_preservesConversationDerivedRowWithNullBackendId() throws {
        let queue = try makeQueue()
        // Synced row that's still present on the API → should survive.
        let stillSyncedId = try insertRow(
            queue, backendId: "abc", backendSynced: true, source: "task"
        )
        // Conversation-derived local-only row (no backendId, fromStaged=false).
        // The bug: under the old filter, this row was deleted because its
        // backendId is missing from the API set.
        let conversationId = try insertRow(
            queue, backendId: nil, backendSynced: false, source: "conversation",
            fromStaged: false
        )
        // Synced row whose backend twin no longer exists → should be deleted.
        let orphanSyncedId = try insertRow(
            queue, backendId: "deleted-on-server", backendSynced: true, source: "task"
        )

        let deleted = try runHardDeleteAbsent(queue, apiIds: ["abc"])

        XCTAssertEqual(deleted, 1, "Only the orphan synced row should be deleted")
        XCTAssertTrue(try rowExists(queue, id: stillSyncedId), "Currently-synced row must survive")
        XCTAssertTrue(
            try rowExists(queue, id: conversationId),
            "Conversation-derived local-only row (null backendId) must NOT be deleted by API reconciliation"
        )
        XCTAssertFalse(
            try rowExists(queue, id: orphanSyncedId),
            "Orphan synced row (backendId not in API set) must be deleted"
        )
    }

    func testHardDeleteAbsent_preservesRowWithEmptyStringBackendId() throws {
        let queue = try makeQueue()
        // Defensive: some pipelines write "" instead of NULL.
        let emptyBackendIdRow = try insertRow(
            queue, backendId: "", backendSynced: false, source: "conversation"
        )

        let deleted = try runHardDeleteAbsent(queue, apiIds: ["something"])

        XCTAssertEqual(deleted, 0)
        XCTAssertTrue(
            try rowExists(queue, id: emptyBackendIdRow),
            "Row with empty-string backendId must NOT be deleted"
        )
    }

    func testHardDeleteAbsent_emptyApiSetIsNoOp() throws {
        let queue = try makeQueue()
        let id = try insertRow(
            queue, backendId: "abc", backendSynced: true, source: "task"
        )

        let deleted = try runHardDeleteAbsent(queue, apiIds: [])

        XCTAssertEqual(deleted, 0, "Safety guard: empty API set must never delete anything")
        XCTAssertTrue(try rowExists(queue, id: id))
    }

    func testHardDeleteAbsent_skipsUnsyncedRowsEvenWithBackendId() throws {
        // backendSynced=false means a local edit hasn't pushed yet. The
        // reconciliation should not touch it.
        let queue = try makeQueue()
        let id = try insertRow(
            queue, backendId: "pending-push", backendSynced: false, source: "task"
        )

        let deleted = try runHardDeleteAbsent(queue, apiIds: ["something-else"])

        XCTAssertEqual(deleted, 0)
        XCTAssertTrue(try rowExists(queue, id: id))
    }

    // MARK: - markAbsentTasksAsStaged

    func testMarkAbsentAsStaged_preservesConversationDerivedRow() throws {
        let queue = try makeQueue()
        let conversationId = try insertRow(
            queue, backendId: nil, backendSynced: false, source: "conversation"
        )
        let orphanId = try insertRow(
            queue, backendId: "orphan", backendSynced: true, source: "task"
        )

        let deleted = try runMarkAbsentAsStaged(queue, apiIds: ["other"])

        XCTAssertEqual(deleted, 1)
        XCTAssertTrue(try rowExists(queue, id: conversationId))
        XCTAssertFalse(try rowExists(queue, id: orphanId))
    }
}
