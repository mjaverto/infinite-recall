import XCTest
import GRDB
@testable import Omi_Computer

/// Regression tests for issue #98 — `KGProgressPublisher` must detect a
/// permanent schema mismatch (missing `kg_extraction_status` column) and
/// trip a kill switch instead of letting its 5s poller log the same
/// "no such column" error every tick until the CI runner timeout.
///
/// These tests are pure unit checks against the structural-error
/// classifier. They don't touch `RewindDatabase.shared` because the
/// singleton already runs the full migrator in test setup; reproducing
/// the missing-column condition there is intentionally hard. The real
/// failure mode (test fixture that opens a DB without migrations) is
/// covered by the classifier behaving correctly on a synthesized
/// SQLite error, which is what these assertions pin.
final class KGProgressPublisherSchemaProbeTests: XCTestCase {

    // MARK: - Classifier

    func testClassifierMatchesNoSuchColumn() throws {
        // Synthesize a real GRDB error against an in-memory DB that lacks
        // the column. This is the exact error shape the production
        // sampler would see on a partially-migrated test fixture.
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE memories (id INTEGER PRIMARY KEY, deleted INTEGER NOT NULL DEFAULT 0)")
        }

        var caught: Error?
        do {
            try queue.read { db in
                _ = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM memories WHERE deleted = 0 AND kg_extraction_status IS NOT NULL"
                )
            }
            XCTFail("expected DB read against missing column to throw")
        } catch {
            caught = error
        }

        guard let error = caught else { return XCTFail("expected error") }
        XCTAssertTrue(
            KGProgressPublisher.isStructuralSchemaError(error),
            "classifier must recognize 'no such column: kg_extraction_status' as structural; got: \(error)"
        )
    }

    func testClassifierMatchesNoSuchTable() throws {
        let queue = try DatabaseQueue()
        var caught: Error?
        do {
            try queue.read { db in
                _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM definitely_not_a_table")
            }
            XCTFail("expected query against missing table to throw")
        } catch {
            caught = error
        }

        guard let error = caught else { return XCTFail("expected error") }
        XCTAssertTrue(
            KGProgressPublisher.isStructuralSchemaError(error),
            "classifier must recognize 'no such table' as structural; got: \(error)"
        )
    }

    func testClassifierIgnoresTransientIO() {
        // SQLITE_BUSY / SQLITE_LOCKED / a generic NSError — none of these
        // should trip the kill switch. They're transient and the 5s
        // poller is the right recovery for them.
        let busy = DatabaseError(resultCode: .SQLITE_BUSY, message: "database is locked")
        XCTAssertFalse(KGProgressPublisher.isStructuralSchemaError(busy))

        let generic = NSError(domain: "TestDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: "transient hiccup"])
        XCTAssertFalse(KGProgressPublisher.isStructuralSchemaError(generic))
    }
}
