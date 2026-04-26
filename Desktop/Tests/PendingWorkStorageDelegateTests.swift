import XCTest
@testable import Omi_Computer

/// Tests for the frozen `PendingWorkStorageDelegate` (interface I3) wired into
/// `PendingWorkStorage`. The contract:
///   - Every mutator (`enqueue`, `claimNext`, `ack`, `releaseClaim`, `fail`)
///     fires `pendingWorkStorageDidMutate` exactly once after the
///     transaction commits, on the actor's own serial executor.
///   - Read-only methods (`depthSummary`, `pendingCount`, `healthCounts`)
///     never fire the delegate.
///
/// Lane 4 will conform `BatteryAwareScheduler` (or a thin wrapper) to this
/// protocol; this test isolates the storage half by using a stub delegate
/// that just counts calls.
///
/// We exercise the real `PendingWorkStorage.shared` singleton against the
/// real `RewindDatabase.shared`, because the fire-after-commit ordering is
/// the actual contract under test. Each test drains the queue first (with
/// the delegate unset) so we own the rows we mutate afterwards.
final class PendingWorkStorageDelegateTests: XCTestCase {

    /// Strong reference so the weak `delegate` property on the storage actor
    /// doesn't immediately deallocate it; the test owns the lifetime.
    private final class StubDelegate: PendingWorkStorageDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _count
        }
        func reset() {
            lock.lock(); defer { lock.unlock() }
            _count = 0
        }
        func pendingWorkStorageDidMutate(_ storage: PendingWorkStorage) {
            lock.lock(); defer { lock.unlock() }
            _count += 1
        }
    }

    /// Use `.transcribe` because it's a real `PendingWork.Kind` raw value the
    /// `claimNext` path will accept (it validates `Kind(rawValue:)`).
    private let workType = PendingWork.Kind.transcribe.rawValue

    /// Drain everything currently claimable in the shared queue. Called with
    /// the delegate UNSET so these housekeeping mutations don't pollute the
    /// per-test counts. Runs claim+ack until the queue returns nil; bounded
    /// to avoid infinite loop in case of an environment glitch.
    private func drainQueue() async throws {
        let storage = PendingWorkStorage.shared
        await storage.setDelegate(nil)
        for _ in 0..<2_000 {
            guard let work = try await storage.claimNext(claimedBy: "delegate-test-drain"),
                  let sid = work.storageId else {
                return
            }
            try? await storage.ack(storageId: sid)
        }
    }

    override func tearDown() async throws {
        // Always clear the delegate so the singleton doesn't carry a stale
        // reference into the next test class.
        await PendingWorkStorage.shared.setDelegate(nil)
        try await super.tearDown()
    }

    // MARK: - Mutators each fire exactly once

    func test_enqueue_claim_ack_eachFireDelegateOnce() async throws {
        try await drainQueue()
        let storage = PendingWorkStorage.shared
        let stub = StubDelegate()
        await storage.setDelegate(stub)

        // 1. enqueue → +1.
        // (Note: the row id returned by `enqueue` is opaque here — the GRDB
        // record's `didInsert` path is not the test contract; the delegate
        // count is.)
        _ = try await storage.enqueue(
            workType: workType,
            payload: Data("delegate-test-enqueue".utf8),
            dedupKey: "delegate-test-\(UUID().uuidString)"
        )
        XCTAssertEqual(stub.count, 1, "enqueue must fire the delegate exactly once")

        // 2. claimNext → +1. We just enqueued, so claim must succeed.
        stub.reset()
        let claimed = try await storage.claimNext(claimedBy: "delegate-test-worker")
        XCTAssertEqual(stub.count, 1, "claimNext must fire the delegate exactly once")
        XCTAssertNotNil(claimed, "claimNext should return our just-enqueued row")

        // 3. ack → +1.
        stub.reset()
        guard let storageId = claimed?.storageId else {
            return XCTFail("claimed row missing storageId")
        }
        try await storage.ack(storageId: storageId)
        XCTAssertEqual(stub.count, 1, "ack must fire the delegate exactly once")
    }

    func test_releaseClaim_firesDelegateOnce() async throws {
        try await drainQueue()
        let storage = PendingWorkStorage.shared
        let stub = StubDelegate()
        await storage.setDelegate(stub)

        // Enqueue + claim a fresh row to release. Both pre-steps fire the
        // delegate; we reset just before the call under test.
        _ = try await storage.enqueue(
            workType: workType,
            payload: Data("delegate-test-release".utf8),
            dedupKey: "delegate-release-\(UUID().uuidString)"
        )
        guard let claimed = try await storage.claimNext(claimedBy: "delegate-test-worker"),
              let sid = claimed.storageId else {
            return XCTFail("expected to claim our just-enqueued row")
        }

        stub.reset()
        try await storage.releaseClaim(storageId: sid)
        XCTAssertEqual(stub.count, 1, "releaseClaim must fire the delegate exactly once")

        // Cleanup: claim + ack so the released row doesn't linger.
        if let again = try await storage.claimNext(claimedBy: "delegate-test-worker"),
           let aSid = again.storageId {
            try? await storage.ack(storageId: aSid)
        }
    }

    func test_fail_firesDelegateOnce_forFailedTransition() async throws {
        try await drainQueue()
        let storage = PendingWorkStorage.shared
        let stub = StubDelegate()
        await storage.setDelegate(stub)

        // Enqueue + claim a fresh row.
        _ = try await storage.enqueue(
            workType: workType,
            payload: Data("delegate-test-fail".utf8),
            dedupKey: "delegate-fail-\(UUID().uuidString)"
        )
        guard let claimed = try await storage.claimNext(claimedBy: "delegate-test-worker"),
              let sid = claimed.storageId else {
            return XCTFail("expected to claim our just-enqueued row")
        }

        stub.reset()
        struct DeliberateError: Error {}
        try await storage.fail(storageId: sid, error: DeliberateError())
        XCTAssertEqual(
            stub.count, 1,
            "fail must fire the delegate exactly once (failed-state transition)"
        )

        // Cleanup: this row is now `failed` with a future scheduledFor; the
        // sweeper will eventually GC it. Leaving as-is is harmless for tests.
    }

    // MARK: - Maintenance sweep fires delegate

    /// Locks in #44: the sweeper's lease-reclaim path goes through the storage
    /// actor, so the delegate fires and the Activity panel sees the
    /// `claimed → queued` (or `claimed → dead`) transition immediately.
    func test_runMaintenanceSweep_firesDelegateOnce_afterReclaimingExpiredLease() async throws {
        try await drainQueue()
        let storage = PendingWorkStorage.shared

        // Set up a row in `claimed` state with an already-expired lease so the
        // sweep's UPDATE actually changes something.
        _ = try await storage.enqueue(
            workType: workType,
            payload: Data("delegate-test-sweep".utf8),
            dedupKey: "delegate-sweep-\(UUID().uuidString)"
        )
        guard let claimed = try await storage.claimNext(claimedBy: "delegate-test-worker"),
              claimed.storageId != nil else {
            return XCTFail("expected to claim our just-enqueued row")
        }

        // Run the sweep with `now` 1 hour in the future so the 10-minute lease
        // is guaranteed expired. Attach the delegate AFTER the setup mutators
        // so we count only the sweep's notification.
        let stub = StubDelegate()
        await storage.setDelegate(stub)

        let result = try await storage.runMaintenanceSweep(now: Date().addingTimeInterval(3600))
        XCTAssertGreaterThanOrEqual(result.recovered, 1, "sweep should reclaim the expired-lease row")
        XCTAssertEqual(stub.count, 1, "runMaintenanceSweep must fire the delegate exactly once")

        // Cleanup: the row is now `queued` (or `dead`); claim+ack to drain.
        if let again = try await storage.claimNext(claimedBy: "delegate-test-worker"),
           let aSid = again.storageId {
            try? await storage.ack(storageId: aSid)
        }
    }

    // MARK: - Read methods do NOT fire

    func test_readMethods_doNotFireDelegate() async throws {
        let storage = PendingWorkStorage.shared
        let stub = StubDelegate()
        await storage.setDelegate(stub)

        stub.reset()
        _ = try await storage.depthSummary()
        _ = await storage.pendingCount()
        _ = try await storage.healthCounts()

        XCTAssertEqual(
            stub.count, 0,
            "depthSummary / pendingCount / healthCounts must never fire the delegate"
        )
    }
}
