import XCTest
@testable import Omi_Computer

final class ActivityPagePowerGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func resources(onBattery: Bool = false, lowPower: Bool = false) -> ResourceSample {
        ResourceSample(
            cpuPercent: 0,
            rssMb: 0,
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

        for reason in [BlockReason.thermal, .locked, .deviceActive, .manualPause] {
            let snapshotGate = GateState.blocked(
                reason: reason,
                since: now,
                waitingFor: reason == .deviceActive ? .idleFor(seconds: 60) : .manual
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
}
