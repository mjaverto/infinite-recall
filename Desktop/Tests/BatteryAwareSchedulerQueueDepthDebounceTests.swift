import XCTest
@testable import Omi_Computer

/// Queue depth is no longer pushed through BatteryAwareScheduler. Activity
/// snapshots read `pending_work` directly, so this file now guards the old
/// bug: battery run-once state must be transient and must not flip the
/// persistent user override.
@MainActor
final class BatteryAwareSchedulerQueueDepthDebounceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        let scheduler = BatteryAwareScheduler.shared
        scheduler._testCommitSource(.ac)
        scheduler._testInject(isLowPowerMode: false, thermalState: .nominal)
        scheduler._testSetScreenLocked(false)
        scheduler.userOverride = false
    }

    override func tearDown() {
        let scheduler = BatteryAwareScheduler.shared
        scheduler._testEndRunOnceIgnoringPower()
        scheduler._testCommitSource(.ac)
        scheduler._testInject(isLowPowerMode: false, thermalState: .nominal)
        scheduler._testSetScreenLocked(false)
        scheduler.userOverride = false
        super.tearDown()
    }

    func test_runOnceOverrideAllowsHeavyAndAutonomousWorkWithoutPersistingUserOverride() {
        let scheduler = BatteryAwareScheduler.shared
        scheduler._testCommitSource(.battery)

        XCTAssertFalse(scheduler.allowHeavyWork)
        scheduler._testBeginRunOnceIgnoringPower()

        XCTAssertTrue(scheduler.isRunOnceIgnoringPowerActive)
        XCTAssertTrue(scheduler.isRunOnceActive)
        XCTAssertNotNil(scheduler.runOnceStartedAt)
        XCTAssertTrue(scheduler.allowHeavyWork)
        XCTAssertTrue(scheduler.allowAutonomousAIWork)
        XCTAssertFalse(scheduler.userOverride)
    }

    func test_runOnceOverrideDoesNotBypassSeriousThermal() {
        let scheduler = BatteryAwareScheduler.shared
        scheduler._testCommitSource(.battery)
        scheduler._testInject(thermalState: .serious)
        scheduler._testBeginRunOnceIgnoringPower()

        XCTAssertTrue(scheduler.isRunOnceActive)
        XCTAssertFalse(scheduler.allowHeavyWork)
        XCTAssertFalse(scheduler.allowAutonomousAIWork)
        XCTAssertFalse(scheduler.userOverride)
    }

    func test_runOnceOverrideStaysActiveWhenACReconnectsMidDrain() {
        let scheduler = BatteryAwareScheduler.shared
        scheduler._testCommitSource(.battery)
        scheduler._testBeginRunOnceIgnoringPower()

        scheduler._testInject(source: .ac)
        scheduler._testCommitSource(.ac)

        XCTAssertTrue(scheduler.isRunOnceIgnoringPowerActive)
        XCTAssertTrue(scheduler.isRunOnceActive)
        XCTAssertNotNil(scheduler.runOnceStartedAt)
        XCTAssertTrue(scheduler.allowHeavyWork)
        XCTAssertFalse(scheduler.userOverride)
    }

    func test_runOnceOverrideClearsBackToBatteryGate() {
        let scheduler = BatteryAwareScheduler.shared
        scheduler._testCommitSource(.battery)
        scheduler._testBeginRunOnceIgnoringPower()
        scheduler._testEndRunOnceIgnoringPower()

        XCTAssertFalse(scheduler.isRunOnceIgnoringPowerActive)
        XCTAssertFalse(scheduler.isRunOnceActive)
        XCTAssertNil(scheduler.runOnceStartedAt)
        XCTAssertFalse(scheduler.userOverride)
        XCTAssertFalse(scheduler.allowHeavyWork)
    }
}
