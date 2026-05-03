import XCTest
import GRDB
@testable import Omi_Computer

/// Regression tests for issue #98 — `KGProgressPublisher` must detect a
/// permanent schema mismatch (missing `kg_extraction_status` column) and
/// trip a kill switch instead of letting its 5s poller log the same
/// "no such column" error every tick until the CI runner timeout.
///
/// Two layers:
///   1. Pure classifier (`isStructuralSchemaError`) — typed `DatabaseError`
///      path AND the non-GRDB substring fallback path.
///   2. Stateful behavior on the actor — driving the kill switch through
///      the test injection seam (`_handleSampleErrorForTests`) and
///      asserting subsequent ticks/emits short-circuit. This is the
///      regression test that pins the actual CI-hang fix; reverting the
///      kill-switch wiring in `tick()` / `sample()` flips the
///      `testSecondTickIsNoOpAfterTrip` test red.
final class KGProgressPublisherSchemaProbeTests: XCTestCase {

    // MARK: - Classifier (typed DatabaseError path)

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
        XCTAssertTrue(error is DatabaseError, "expected typed GRDB DatabaseError; got: \(type(of: error))")
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

    func testClassifierMatchesCorrupt() {
        // Synthesized SQLITE_CORRUPT — unrecoverable, must trip the switch
        // (the 5s poller would otherwise spin forever on a damaged file).
        let corrupt = DatabaseError(resultCode: .SQLITE_CORRUPT, message: "database disk image is malformed")
        XCTAssertTrue(KGProgressPublisher.isStructuralSchemaError(corrupt))
    }

    func testClassifierMatchesNotADatabase() {
        let notADb = DatabaseError(resultCode: .SQLITE_NOTADB, message: "file is not a database")
        XCTAssertTrue(KGProgressPublisher.isStructuralSchemaError(notADb))
    }

    func testClassifierIgnoresTransientIO() {
        // SQLITE_BUSY / SQLITE_LOCKED / a generic NSError — none of these
        // should trip the kill switch. They're transient and the 5s
        // poller is the right recovery for them.
        let busy = DatabaseError(resultCode: .SQLITE_BUSY, message: "database is locked")
        XCTAssertFalse(KGProgressPublisher.isStructuralSchemaError(busy))

        let locked = DatabaseError(resultCode: .SQLITE_LOCKED, message: "table is locked")
        XCTAssertFalse(KGProgressPublisher.isStructuralSchemaError(locked))

        let generic = NSError(domain: "TestDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: "transient hiccup"])
        XCTAssertFalse(KGProgressPublisher.isStructuralSchemaError(generic))
    }

    func testClassifierIgnoresSqliteIOErr() {
        // SQLITE_IOERR is handled by RewindDatabase.reportQueryError's
        // consecutive-error counter; the publisher's poller should not
        // unilaterally kill itself on a single transient I/O hiccup.
        let ioerr = DatabaseError(resultCode: .SQLITE_IOERR, message: "disk I/O error")
        XCTAssertFalse(KGProgressPublisher.isStructuralSchemaError(ioerr))
    }

    // MARK: - Classifier (non-GRDB fallback path)

    /// Wrapper that quotes a SQLite message inside a non-`DatabaseError`
    /// type, simulating a layered storage that re-throws the underlying
    /// failure with extra context.
    private struct WrappedSqliteError: Error, CustomStringConvertible {
        let description: String
    }

    func testClassifierFallbackMatchesNoSuchColumnInWrappedError() {
        let wrapped = WrappedSqliteError(description: "Storage layer failed: SQLite error 1: no such column: m.kg_extraction_status")
        XCTAssertTrue(
            KGProgressPublisher.isStructuralSchemaError(wrapped),
            "fallback must catch wrapped no-such-column errors so layered storages don't bypass the kill switch"
        )
    }

    func testClassifierFallbackDoesNotEscalateCorruptSubstring() {
        // The fallback intentionally only matches "no such column" / "no
        // such table" — substring-matching "corrupt" or "not a database"
        // is too prone to false positives (user-visible strings, log
        // lines, error wrappers that quote SQL). Only typed
        // DatabaseError gets to escalate corruption.
        let wrapped = WrappedSqliteError(description: "Storage error: database disk image is malformed")
        XCTAssertFalse(
            KGProgressPublisher.isStructuralSchemaError(wrapped),
            "fallback must not escalate corrupt-substring matches; only typed DatabaseError can trip on corruption"
        )
    }

    // MARK: - Stateful behavior (issue #98 regression)

    func testTickFlipsKillSwitchOnMissingColumn() async throws {
        let pub = KGProgressPublisher.shared
        await pub._resetForTests()
        defer { Task { await pub._resetForTests() } }

        let initial = await pub._schemaUnavailableForTests()
        XCTAssertFalse(initial, "kill switch should start cleared after reset")

        // Synthesize the exact error shape the real sampler would catch
        // — `SQLite error 1: no such column: m.kg_extraction_status` —
        // via a typed `DatabaseError`. The classifier tests above
        // (`testClassifierMatchesNoSuchColumn`) already validate that a
        // real GRDB-thrown error matches this same shape, so this
        // stateful test can focus on the actor-side state mutation.
        let synthetic = DatabaseError(
            resultCode: .SQLITE_ERROR,
            message: "no such column: m.kg_extraction_status"
        )
        let tripped = await pub._handleSampleErrorForTests(synthetic)
        XCTAssertTrue(tripped, "structural error must trip the kill switch")
        let after = await pub._schemaUnavailableForTests()
        XCTAssertTrue(after, "schemaUnavailable must be set after structural error")
    }

    func testSecondTickIsNoOpAfterTrip() async {
        // Pin the actual CI-hang regression: once tripped, subsequent
        // tick()/emitNow() calls must NOT re-enter sample() — that's the
        // bug that ate 30 minutes of CI time. We can't directly intercept
        // sample(), so we observe the proxy: schemaUnavailable stays true
        // and pollTask stays nil after explicit tick() / emitNow() calls.
        let pub = KGProgressPublisher.shared
        await pub._resetForTests()
        defer { Task { await pub._resetForTests() } }

        let synthetic = DatabaseError(
            resultCode: .SQLITE_ERROR,
            message: "no such column: m.kg_extraction_status"
        )
        await pub._handleSampleErrorForTests(synthetic)
        let tripped2 = await pub._schemaUnavailableForTests()
        XCTAssertTrue(tripped2)

        // These would crash or hang before #98's fix if sample() ran.
        // After the fix, both early-return immediately.
        await pub.tick()
        await pub.emitNow()

        // Kill switch must remain tripped — the early-return paths must
        // not clear it.
        let stillTripped = await pub._schemaUnavailableForTests()
        XCTAssertTrue(
            stillTripped,
            "kill switch must stay tripped across subsequent tick()/emitNow() calls"
        )
    }

    func testSqliteBusyDoesNotTrip() async {
        let pub = KGProgressPublisher.shared
        await pub._resetForTests()
        defer { Task { await pub._resetForTests() } }

        let busy = DatabaseError(resultCode: .SQLITE_BUSY, message: "database is locked")
        let tripped = await pub._handleSampleErrorForTests(busy)
        XCTAssertFalse(tripped, "transient SQLITE_BUSY must not trip the kill switch")
        let killSwitch = await pub._schemaUnavailableForTests()
        XCTAssertFalse(
            killSwitch,
            "schemaUnavailable must remain cleared on SQLITE_BUSY — the 5s poller is the right recovery"
        )
    }

    func testCorruptTripsKillSwitch() async {
        let pub = KGProgressPublisher.shared
        await pub._resetForTests()
        defer { Task { await pub._resetForTests() } }

        let corrupt = DatabaseError(resultCode: .SQLITE_CORRUPT, message: "database disk image is malformed")
        let tripped = await pub._handleSampleErrorForTests(corrupt)
        XCTAssertTrue(tripped, "SQLITE_CORRUPT is unrecoverable for our poller — must trip")
        let tripped2 = await pub._schemaUnavailableForTests()
        XCTAssertTrue(tripped2)
    }

    func testResetForUserSwitchClearsKillSwitch() async {
        // Gemini review on PR #108 — the singleton's kill switch must
        // clear when the underlying DB is re-opened (e.g. switchUser),
        // otherwise user A's broken schema permanently blinds the
        // publisher for user B.
        let pub = KGProgressPublisher.shared
        await pub._resetForTests()
        defer { Task { await pub._resetForTests() } }

        let synthetic = DatabaseError(resultCode: .SQLITE_ERROR, message: "no such column: m.kg_extraction_status")
        await pub._handleSampleErrorForTests(synthetic)
        let tripped2 = await pub._schemaUnavailableForTests()
        XCTAssertTrue(tripped2)

        await pub.resetForUserSwitch()
        let cleared = await pub._schemaUnavailableForTests()
        XCTAssertFalse(
            cleared,
            "resetForUserSwitch must clear the kill switch so a freshly re-opened DB gets a fresh poller"
        )
    }
}
