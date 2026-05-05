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

        // Issue #128: `.manualPause` pruned (no producer existed). The
        // remaining "Run now hidden" reasons are thermal + screen-locked.
        for reason in [BlockReason.thermal, .locked] {
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

    /// Issue #105: A snapshot gate of `.blocked(.onBattery, …)` can be stale
    /// (e.g. cached from before the user plugged in). When `resources` reports
    /// the device is on AC and not in low-power, the corrected gate must
    /// downgrade to `.allowed` so the Activity banner doesn't read
    /// "Waiting for AC power" while the user is already on AC.
    func test_correctedGateDowngradesStaleOnBatteryWhenResourcesSayOnAC() {
        let res = resources(onBattery: false, lowPower: false)
        let staleSnapshotGate = GateState.blocked(
            reason: .onBattery,
            since: now,
            waitingFor: .acPower
        )

        let corrected = activityCorrectedGate(
            snapshotGate: staleSnapshotGate,
            resources: res,
            queued: 5,
            thermalState: .nominal,
            isRunOnceActive: false,
            runOnceStartedAt: nil,
            now: now
        )

        XCTAssertTrue(
            corrected.isAllowed,
            "Stale snapshot .onBattery must be downgraded to .allowed when resources report on-AC and not low-power."
        )
        // The downgrade preserves the original `since` so the UI's
        // "blocked-for" timer doesn't reset across the transition.
        XCTAssertEqual(
            corrected.since,
            staleSnapshotGate.since,
            "Downgrade must preserve the snapshot's `since` so the elapsed-state timer is continuous."
        )
    }

    /// Issue #105 negative case: snapshot gate is `.onBattery` AND
    /// resources confirm Low Power Mode is on. The downgrade predicate
    /// must NOT fire — the user still needs to know LPM is the blocker.
    func test_correctedGateDoesNotDowngradeWhenLowPowerMode() {
        let res = resources(onBattery: false, lowPower: true)
        let snapshotGate = GateState.blocked(
            reason: .onBattery,
            since: now,
            waitingFor: .acPower
        )

        let corrected = activityCorrectedGate(
            snapshotGate: snapshotGate,
            resources: res,
            queued: 4,
            thermalState: .nominal,
            isRunOnceActive: false,
            runOnceStartedAt: nil,
            now: now
        )

        XCTAssertEqual(
            corrected.blockReason,
            .onBattery,
            "Low Power Mode must keep the .onBattery block; the downgrade only fires for AC + non-LPM."
        )
    }

    /// Issue #105 negative case: snapshot gate is `.onBattery` and resources
    /// agree we're genuinely on battery. The downgrade must NOT fire — the
    /// snapshot is correct, not stale.
    func test_correctedGateDoesNotDowngradeWhenGenuinelyOnBattery() {
        let res = resources(onBattery: true, lowPower: false)
        let snapshotGate = GateState.blocked(
            reason: .onBattery,
            since: now,
            waitingFor: .acPower
        )

        let corrected = activityCorrectedGate(
            snapshotGate: snapshotGate,
            resources: res,
            queued: 4,
            thermalState: .nominal,
            isRunOnceActive: false,
            runOnceStartedAt: nil,
            now: now
        )

        XCTAssertEqual(
            corrected.blockReason,
            .onBattery,
            "Genuine on-battery state must keep the .onBattery block; the downgrade only fires when resources contradict the snapshot."
        )
    }

    /// Issue #105 guard: the downgrade `if case` matches `.onBattery`
    /// exclusively. Other block reasons (e.g. `.thermal`) must pass through
    /// unchanged even when resources report on-AC and not low-power.
    /// Guards against accidentally widening the predicate later.
    func test_correctedGateLeavesNonOnBatteryBlocksAlone() {
        let res = resources(onBattery: false, lowPower: false)
        let snapshotGate = GateState.blocked(
            reason: .thermal,
            since: now,
            waitingFor: .thermalCooldown
        )

        let corrected = activityCorrectedGate(
            snapshotGate: snapshotGate,
            resources: res,
            queued: 4,
            // Thermal-state arg is `.nominal` so the early-return thermal
            // override doesn't fire — we want to exercise the late branches.
            thermalState: .nominal,
            isRunOnceActive: false,
            runOnceStartedAt: nil,
            now: now
        )

        XCTAssertEqual(
            corrected.blockReason,
            .thermal,
            "Non-onBattery snapshot blocks must pass through unchanged regardless of resources."
        )
    }

    // MARK: - Issue #134: lightweight-work-active predicate

    private func kindRow(
        _ kind: WorkKind,
        queued: UInt32 = 0,
        inFlight: InFlight? = nil
    ) -> KindRow {
        KindRow(
            kind: kind,
            inFlight: inFlight,
            queued: queued,
            failed: 0,
            lastDoneAt: nil,
            pausedUntil: nil
        )
    }

    /// Issue #134 regression: with `Blocked(.deviceActive)` and a queued
    /// `transcribe` row (a non-autonomous kind), the helper must report
    /// "lightweight active" so the banner doesn't say "Waiting for idle"
    /// while the In-flight section shows transcribe running.
    func test_lightweightActive_trueForQueuedTranscribe() {
        let kinds = [
            kindRow(.transcribe, queued: 1),
            kindRow(.summarize, queued: 5),
        ]
        XCTAssertTrue(activityLightweightWorkActive(kinds: kinds))
    }

    /// In-flight (not just queued) lightweight work must also count.
    func test_lightweightActive_trueForInFlightOcr() {
        let kinds = [
            kindRow(
                .ocr,
                queued: 0,
                inFlight: InFlight(label: "OCR", startedAt: now)
            ),
        ]
        XCTAssertTrue(activityLightweightWorkActive(kinds: kinds))
    }

    /// Heavy-only queues (`.summarize` / `.extractKG`) must NOT trigger
    /// the lightweight banner copy — those genuinely wait for idle.
    func test_lightweightActive_falseWhenOnlyHeavyKindsQueued() {
        let kinds = [
            kindRow(.summarize, queued: 3),
            kindRow(.extractKG, queued: 2),
        ]
        XCTAssertFalse(activityLightweightWorkActive(kinds: kinds))
    }

    /// Empty kinds list — no work of any sort active.
    func test_lightweightActive_falseForEmpty() {
        XCTAssertFalse(activityLightweightWorkActive(kinds: []))
    }

    /// Pin the kind classification: only `.summarize` / `.extractKG`
    /// require autonomous (idle) readiness; the other four are
    /// lightweight. Drift between this and `BatteryAwareScheduler.drain()`
    /// is the original #134 bug class.
    func test_workKindRequiresAutonomousReadinessClassification() {
        XCTAssertTrue(WorkKind.summarize.requiresAutonomousReadiness)
        XCTAssertTrue(WorkKind.extractKG.requiresAutonomousReadiness)
        XCTAssertFalse(WorkKind.transcribe.requiresAutonomousReadiness)
        XCTAssertFalse(WorkKind.ocr.requiresAutonomousReadiness)
        XCTAssertFalse(WorkKind.extractMemory.requiresAutonomousReadiness)
        XCTAssertFalse(WorkKind.extractActionItems.requiresAutonomousReadiness)
    }
}
