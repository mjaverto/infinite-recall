import XCTest
@testable import Omi_Computer

/// Verifies that `BatteryAwareScheduler`'s `PendingWorkStorageDelegate`
/// conformance coalesces a burst of mutations into exactly one
/// queue-depth push. We don't talk to the daemon — the scheduler exposes
/// `_testQueueDepthHook` so the debounce-fire path runs without hitting
/// `PendingWorkStorage.depthSummary()` or `APIClient.reportQueueDepth(_:)`.
@MainActor
final class BatteryAwareSchedulerQueueDepthDebounceTests: XCTestCase {

    override func tearDown() {
        BatteryAwareScheduler.shared._testQueueDepthHook = nil
        super.tearDown()
    }

    /// Fire the delegate method N times rapidly within the 250 ms window
    /// and assert the debounced fire block runs exactly once. The
    /// scheduler's `pendingWorkStorageDidMutate` is `nonisolated` so
    /// production callers (the storage actor) and this test path use the
    /// identical entry.
    func test_rapidMutationsCoalesceToSingleFire() async throws {
        let scheduler = BatteryAwareScheduler.shared
        let fireCount = FireCounter()
        scheduler._testQueueDepthHook = { fireCount.increment() }

        // Burst 10 mutations well under the 250 ms debounce window.
        for _ in 0..<10 {
            scheduler.pendingWorkStorageDidMutate(PendingWorkStorage.shared)
        }

        // Wait long enough for the debounce to elapse and the fire block
        // to run on the main actor (debounce + scheduling slack).
        try await Task.sleep(nanoseconds: 600_000_000)

        XCTAssertEqual(fireCount.value, 1,
                       "10 rapid mutations within the debounce window must produce exactly one push")
    }

    /// A second burst after the first has fired should produce a second
    /// push — the debouncer is rearmable, not one-shot.
    func test_secondBurstFiresAgain() async throws {
        let scheduler = BatteryAwareScheduler.shared
        let fireCount = FireCounter()
        scheduler._testQueueDepthHook = { fireCount.increment() }

        for _ in 0..<5 {
            scheduler.pendingWorkStorageDidMutate(PendingWorkStorage.shared)
        }
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(fireCount.value, 1)

        for _ in 0..<5 {
            scheduler.pendingWorkStorageDidMutate(PendingWorkStorage.shared)
        }
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(fireCount.value, 2,
                       "A second burst after the debounce closes must produce a second push")
    }
}

/// Thread-safe counter shared between the scheduler's debounce queue and
/// the test's `@MainActor` assertion.
private final class FireCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}
