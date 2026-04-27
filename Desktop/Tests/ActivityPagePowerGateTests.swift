import XCTest
@testable import Omi_Computer

final class ActivityPagePowerGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func resources(onBattery: Bool = false, lowPower: Bool = false) -> ResourceSample {
        ResourceSample(
            cpuPercent: 0,
            memMb: 0,
            gpuSystemPercent: nil,
            thermalState: .nominal,
            onBattery: onBattery,
            lowPower: lowPower,
            processBreakdown: []
        )
    }

    func test_acLowPowerQueuedCorrectsAllowedGateBeforeDuringAndAfterRunOnce() {
        let res = resources(onBattery: false, lowPower: true)
        let allowed = GateState.allowed(since: now)

        let before = activityCorrectedGate(
            snapshotGate: allowed,
            resources: res,
            queued: 3,
            thermalState: .nominal,
            isRunOnceActive: false,
            runOnceStartedAt: nil,
            now: now
        )
        XCTAssertEqual(before.blockReason, .onBattery)
        XCTAssertEqual(before.waitingFor, .acPower)

        let during = activityCorrectedGate(
            snapshotGate: allowed,
            resources: res,
            queued: 3,
            thermalState: .nominal,
            isRunOnceActive: true,
            runOnceStartedAt: now,
            now: now
        )
        XCTAssertTrue(during.isAllowed)

        let after = activityCorrectedGate(
            snapshotGate: allowed,
            resources: res,
            queued: 3,
            thermalState: .nominal,
            isRunOnceActive: false,
            runOnceStartedAt: nil,
            now: now
        )
        XCTAssertEqual(after.blockReason, .onBattery)
    }

    func test_runNowButtonUsesPowerPredicateForAcLowPowerQueuedWork() {
        let res = resources(onBattery: false, lowPower: true)
        let corrected = GateState.blocked(reason: .onBattery, since: now, waitingFor: .acPower)

        XCTAssertTrue(activityShouldShowRunNowButton(
            snapshotGate: .allowed(since: now),
            correctedGate: corrected,
            resources: res,
            queued: 2,
            isThermalBlocked: false,
            isRunOnceActive: false
        ))
    }

    func test_runNowButtonHiddenForNonPowerBlocksEvenWhenAcLowPowerQueued() {
        let res = resources(onBattery: false, lowPower: true)
        let corrected = GateState.blocked(reason: .onBattery, since: now, waitingFor: .acPower)

        for reason in [BlockReason.thermal, .locked, .manualPause] {
            let snapshotGate = GateState.blocked(
                reason: reason,
                since: now,
                waitingFor: .manual
            )
            XCTAssertFalse(activityShouldShowRunNowButton(
                snapshotGate: snapshotGate,
                correctedGate: corrected,
                resources: res,
                queued: 2,
                isThermalBlocked: reason == .thermal,
                isRunOnceActive: false
            ), "Run now should stay hidden for \(reason)")
        }
    }

    func test_runNowButtonShownForDeviceActiveWithQueuedWork() {
        let res = resources(onBattery: false, lowPower: false)
        let snapshotGate = GateState.blocked(
            reason: .deviceActive,
            since: now,
            waitingFor: .idleFor(seconds: 60)
        )

        XCTAssertTrue(activityShouldShowRunNowButton(
            snapshotGate: snapshotGate,
            correctedGate: snapshotGate,
            resources: res,
            queued: 2,
            isThermalBlocked: false,
            isRunOnceActive: false
        ), "Run now should be visible when device is active so the user can override the idle gate.")
    }

    func test_runNowButtonHiddenForDeviceActiveWhenQueueEmpty() {
        let res = resources(onBattery: false, lowPower: false)
        let snapshotGate = GateState.blocked(
            reason: .deviceActive,
            since: now,
            waitingFor: .idleFor(seconds: 60)
        )

        XCTAssertFalse(activityShouldShowRunNowButton(
            snapshotGate: snapshotGate,
            correctedGate: snapshotGate,
            resources: res,
            queued: 0,
            isThermalBlocked: false,
            isRunOnceActive: false
        ), "Run now should stay hidden when device is active but the queue is empty — nothing to process.")
    }

    func test_correctedGateOverridesInitializingForAcLowPower() {
        let res = resources(onBattery: false, lowPower: true)
        let snapshotGate = GateState.blocked(
            reason: .initializing,
            since: now,
            waitingFor: .manual
        )

        let corrected = activityCorrectedGate(
            snapshotGate: snapshotGate,
            resources: res,
            queued: 3,
            thermalState: .nominal,
            isRunOnceActive: false,
            runOnceStartedAt: nil,
            now: now
        )

        XCTAssertEqual(corrected.blockReason, .onBattery, ".initializing must NOT dominate the power block — corrected gate should swap to .onBattery.")
        XCTAssertEqual(corrected.waitingFor, .acPower)
    }

    func test_runNowButtonVisibleDuringRunOnceWhileDeviceActive() {
        let res = resources(onBattery: false, lowPower: false)
        let snapshotGate = GateState.blocked(
            reason: .deviceActive,
            since: now,
            waitingFor: .idleFor(seconds: 60)
        )

        XCTAssertTrue(activityShouldShowRunNowButton(
            snapshotGate: snapshotGate,
            correctedGate: .allowed(since: now),
            resources: res,
            queued: 2,
            isThermalBlocked: false,
            isRunOnceActive: true
        ), "Run now should remain visible during run-once even when the snapshot gate is still .deviceActive.")
    }

    func test_runNowButtonHiddenForThermalReasonEvenWhenThermalFlagFalse() {
        let res = resources(onBattery: false, lowPower: false)
        let snapshotGate = GateState.blocked(
            reason: .thermal,
            since: now,
            waitingFor: .thermalCooldown
        )

        XCTAssertFalse(activityShouldShowRunNowButton(
            snapshotGate: snapshotGate,
            correctedGate: snapshotGate,
            resources: res,
            queued: 2,
            isThermalBlocked: false,
            isRunOnceActive: false
        ), "Run now must hide for .thermal via disablesRunNowOverride alone, independent of the isThermalBlocked flag.")
    }
}
