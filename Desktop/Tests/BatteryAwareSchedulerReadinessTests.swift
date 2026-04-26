import XCTest
@testable import Omi_Computer

/// Unit tests for `BatteryAwareScheduler.allowAutonomousAIWork` — the
/// stricter readiness gate that ONLY .summarize work consults.
///
/// These exercise the boolean lattice:
///
///   allowAutonomousAIWork =
///     allowHeavyWork && (isScreenLocked || systemIdleSeconds >= threshold)
///
/// where `allowHeavyWork` is committedSource == .ac
///                         && !isLowPowerMode
///                         && thermalState < .serious.
///
/// We can drive lock state, AC state, and thermal/low-power directly via
/// `_testInject` / `_testCommitSource` / `_testSetScreenLocked`. The system
/// idle reading is Quartz-backed and not mockable from a unit test, so we
/// rely on lock-state to exercise the "idle-safe window" branch (lock and
/// idle are equivalent for the gate's truth value).
///
/// These tests run against the singleton `BatteryAwareScheduler.shared`.
/// We never call `start()`, so no real notification observers / pollers
/// fire — we just exercise pure state transitions on the readiness props.
@MainActor
final class BatteryAwareSchedulerReadinessTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Reset to a known-good baseline: AC, normal thermals, unlocked, no override.
        let scheduler = BatteryAwareScheduler.shared
        scheduler._testCommitSource(.ac)
        scheduler._testInject(isLowPowerMode: false, thermalState: .nominal)
        scheduler._testSetScreenLocked(false)
        scheduler.userOverride = false
    }

    override func tearDown() {
        // Restore a quiescent state so other tests aren't affected.
        let scheduler = BatteryAwareScheduler.shared
        scheduler._testCommitSource(.ac)
        scheduler._testInject(isLowPowerMode: false, thermalState: .nominal)
        scheduler._testSetScreenLocked(false)
        scheduler.userOverride = false
        super.tearDown()
    }

    // MARK: - allowHeavyWork preservation (existing behavior must be unchanged)

    func test_allowHeavyWork_unchanged_AC_normal() {
        let s = BatteryAwareScheduler.shared
        s._testCommitSource(.ac)
        s._testInject(isLowPowerMode: false, thermalState: .nominal)
        XCTAssertTrue(s.allowHeavyWork, "AC + normal thermals + !low-power should keep allowHeavyWork true")
    }

    func test_allowHeavyWork_false_on_battery() {
        let s = BatteryAwareScheduler.shared
        s._testCommitSource(.battery)
        XCTAssertFalse(s.allowHeavyWork)
    }

    func test_allowHeavyWork_false_on_thermal_serious() {
        let s = BatteryAwareScheduler.shared
        s._testCommitSource(.ac)
        s._testInject(thermalState: .serious)
        XCTAssertFalse(s.allowHeavyWork)
    }

    func test_allowHeavyWork_false_on_lowpower() {
        let s = BatteryAwareScheduler.shared
        s._testCommitSource(.ac)
        s._testInject(isLowPowerMode: true)
        XCTAssertFalse(s.allowHeavyWork)
    }

    // MARK: - allowAutonomousAIWork: AC + active user (no lock, no idle threshold met)

    /// AC + thermals fine, BUT user is active (unlocked, no idle-time hint
    /// from the system). The gate is strict — autonomous work must wait.
    /// Note: this assumes `IdleAIController.systemIdleSeconds()` returns < threshold
    /// during the test, which is true in CI (input idle starts fresh).
    func test_allowAutonomousAIWork_false_when_AC_and_user_active() {
        let s = BatteryAwareScheduler.shared
        s._testCommitSource(.ac)
        s._testInject(isLowPowerMode: false, thermalState: .nominal)
        s._testSetScreenLocked(false)

        // We cannot fake systemIdleSeconds() to be small in a sandboxed CI
        // run reliably — but we CAN raise the threshold so it's effectively
        // unreachable (1 hour). With unlocked + no real idle time, the gate
        // must be false.
        let original = IdleAIController.shared.idleTimeoutMinutes
        IdleAIController.shared.idleTimeoutMinutes = 60  // 60-minute threshold
        defer { IdleAIController.shared.idleTimeoutMinutes = original }

        XCTAssertTrue(s.allowHeavyWork, "preconditions: heavy work IS allowed")
        XCTAssertFalse(
            s.allowAutonomousAIWork,
            "AC + active user (unlocked, no idle window) must NOT allow autonomous .summarize drain"
        )
    }

    // MARK: - allowAutonomousAIWork: AC + locked

    func test_allowAutonomousAIWork_true_when_AC_and_locked() {
        let s = BatteryAwareScheduler.shared
        s._testCommitSource(.ac)
        s._testInject(isLowPowerMode: false, thermalState: .nominal)
        s._testSetScreenLocked(true)

        XCTAssertTrue(s.allowHeavyWork)
        XCTAssertTrue(
            s.allowAutonomousAIWork,
            "AC + screen locked must enable autonomous .summarize drain"
        )
    }

    // MARK: - allowAutonomousAIWork: AC + idle (proxied via locked, since
    // we can't stub Quartz idle; but we cover the explicit threshold-met path
    // by setting idleTimeoutMinutes to 0 so any system idle time qualifies).

    func test_allowAutonomousAIWork_true_when_AC_and_idle_threshold_met() {
        let s = BatteryAwareScheduler.shared
        s._testCommitSource(.ac)
        s._testInject(isLowPowerMode: false, thermalState: .nominal)
        s._testSetScreenLocked(false)

        // Drop the idle threshold to 0 minutes. Any non-negative
        // `systemIdleSeconds()` reading >= 0 passes — equivalent to "user
        // is idle long enough". This is the lattice case we care about.
        let original = IdleAIController.shared.idleTimeoutMinutes
        IdleAIController.shared.idleTimeoutMinutes = 0
        defer { IdleAIController.shared.idleTimeoutMinutes = original }

        XCTAssertTrue(s.allowHeavyWork)
        XCTAssertTrue(
            s.allowAutonomousAIWork,
            "AC + idle threshold met must enable autonomous .summarize drain"
        )
    }

    // MARK: - allowAutonomousAIWork: battery + locked → still false (heavy gate dominates)

    func test_allowAutonomousAIWork_false_when_battery_even_if_locked() {
        let s = BatteryAwareScheduler.shared
        s._testCommitSource(.battery)
        s._testSetScreenLocked(true)

        XCTAssertFalse(s.allowHeavyWork, "battery → heavy work blocked")
        XCTAssertFalse(
            s.allowAutonomousAIWork,
            "battery + locked must NOT drain autonomous work; allowHeavyWork dominates"
        )
    }

    // MARK: - allowAutonomousAIWork: thermal serious → false even when locked

    func test_allowAutonomousAIWork_false_on_thermal_serious_even_if_locked() {
        let s = BatteryAwareScheduler.shared
        s._testCommitSource(.ac)
        s._testInject(thermalState: .serious)
        s._testSetScreenLocked(true)

        XCTAssertFalse(s.allowHeavyWork, "thermal .serious → heavy work blocked")
        XCTAssertFalse(
            s.allowAutonomousAIWork,
            "thermal .serious must block autonomous drain regardless of lock"
        )
    }

    // MARK: - Per-kind drain gate symmetry (allowHeavyWork still governs .transcribe / .ocr)

    /// We can't run the actual `drain()` loop here without registering
    /// handlers and exercising PendingWorkStorage, but we CAN assert that
    /// the kind classifier — the only place autonomous gating leaks into
    /// `drain()` — leaves non-autonomous kinds untouched. This is an indirect
    /// check via the public reflection point: `allowHeavyWork` and
    /// `allowAutonomousAIWork` must return INDEPENDENT booleans for the
    /// idle-but-active scenario.
    func test_allowHeavyWork_true_while_allowAutonomousAIWork_false_isReachable() {
        let s = BatteryAwareScheduler.shared
        s._testCommitSource(.ac)
        s._testInject(isLowPowerMode: false, thermalState: .nominal)
        s._testSetScreenLocked(false)

        // High threshold + unlocked → autonomous gate must be false while
        // heavy gate stays true. This is the classic "AC + actively typing"
        // scenario where .transcribe should drain but .summarize should not.
        let original = IdleAIController.shared.idleTimeoutMinutes
        IdleAIController.shared.idleTimeoutMinutes = 60
        defer { IdleAIController.shared.idleTimeoutMinutes = original }

        XCTAssertTrue(s.allowHeavyWork, ".transcribe / .ocr must be allowed (allowHeavyWork)")
        XCTAssertFalse(s.allowAutonomousAIWork, ".summarize must NOT be allowed (gate stricter)")
    }

    // MARK: - userOverride preserves heavy-work but doesn't bypass autonomous gate

    /// `userOverride` historically bypasses battery/thermal/low-power for the
    /// `allowHeavyWork` gate. The autonomous gate is built on top, so it
    /// inherits the override on the heavy-work side BUT still requires
    /// lock/idle. This documents that override does NOT silently turn into
    /// "drain all summaries while I'm typing on battery."
    func test_userOverride_does_not_bypass_autonomous_lock_or_idle_requirement() {
        let s = BatteryAwareScheduler.shared
        s._testCommitSource(.battery)
        s._testInject(isLowPowerMode: true, thermalState: .serious)
        s._testSetScreenLocked(false)
        s.userOverride = true
        defer { s.userOverride = false }

        let original = IdleAIController.shared.idleTimeoutMinutes
        IdleAIController.shared.idleTimeoutMinutes = 60
        defer { IdleAIController.shared.idleTimeoutMinutes = original }

        XCTAssertTrue(s.allowHeavyWork, "override forces allowHeavyWork true")
        XCTAssertFalse(
            s.allowAutonomousAIWork,
            "override does not bypass the autonomous lock/idle requirement"
        )
    }
}
