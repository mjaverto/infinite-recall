// Activity Tab — Issue #32.
//
// Pure-function tests for `computeGateState(_:now:)`. The reporter's
// network I/O is not exercised here (no Rust daemon in the unit-test
// process); these tests cover priority ordering, threshold arithmetic,
// and the "empty queue + battery = Allowed" carve-out described in the
// `ProcessingGateInputs` docstring.

import XCTest

@testable import Omi_Computer

final class ProcessingGateReporterTests: XCTestCase {

  // MARK: - Helpers

  /// Build a baseline "everything's fine, user is idle" inputs struct.
  /// Tests mutate the fields they care about.
  private func baseline(
    now: Date = Date(timeIntervalSince1970: 1_700_000_000),
    idleSeconds: TimeInterval = 300,
    threshold: TimeInterval = 120,
    pending: Int = 0
  ) -> ProcessingGateInputs {
    ProcessingGateInputs(
      isScreenLocked: false,
      lockedSince: nil,
      onBattery: false,
      isLowPowerMode: false,
      batterySince: nil,
      thermalState: .nominal,
      thermalSince: nil,
      systemIdleSeconds: idleSeconds,
      activeSince: now.addingTimeInterval(-idleSeconds),
      idleThresholdSeconds: threshold,
      pendingWorkCount: pending
    )
  }

  // MARK: - Allowed

  func test_allowed_when_idle_above_threshold() {
    let now = Date()
    let inputs = baseline(now: now, idleSeconds: 200, threshold: 120)
    let state = computeGateState(inputs, now: now)
    XCTAssertTrue(state.isAllowed, "expected Allowed; got \(state)")
  }

  func test_allowed_carves_out_battery_when_queue_is_empty() {
    // On battery + LPM but the queue is empty → Allowed (no point
    // showing "waiting for AC" when there's nothing to do).
    let now = Date()
    var inputs = baseline(now: now, idleSeconds: 300, threshold: 120, pending: 0)
    inputs.onBattery = true
    inputs.isLowPowerMode = true
    let state = computeGateState(inputs, now: now)
    XCTAssertTrue(state.isAllowed, "empty queue + battery should be Allowed; got \(state)")
  }

  // MARK: - Priority ordering

  func test_locked_beats_thermal() {
    let now = Date()
    var inputs = baseline(now: now)
    inputs.isScreenLocked = true
    inputs.lockedSince = now.addingTimeInterval(-30)
    inputs.thermalState = .critical
    inputs.thermalSince = now.addingTimeInterval(-60)

    let state = computeGateState(inputs, now: now)
    XCTAssertEqual(state.blockReason, .locked)
    XCTAssertEqual(state.waitingFor, .unlock)
  }

  func test_thermal_beats_battery() {
    let now = Date()
    var inputs = baseline(now: now, pending: 5)
    inputs.thermalState = .serious
    inputs.thermalSince = now.addingTimeInterval(-15)
    inputs.onBattery = true
    inputs.isLowPowerMode = true
    inputs.batterySince = now.addingTimeInterval(-300)

    let state = computeGateState(inputs, now: now)
    XCTAssertEqual(state.blockReason, .thermal)
    XCTAssertEqual(state.waitingFor, .thermalCooldown)
  }

  func test_battery_beats_device_active() {
    // On battery + LPM + queue non-empty + user active → battery wins
    // because the AC issue is the longer-lived blocker.
    let now = Date()
    var inputs = baseline(now: now, idleSeconds: 5, threshold: 120, pending: 3)
    inputs.onBattery = true
    inputs.isLowPowerMode = true
    inputs.batterySince = now.addingTimeInterval(-60)

    let state = computeGateState(inputs, now: now)
    XCTAssertEqual(state.blockReason, .onBattery)
    XCTAssertEqual(state.waitingFor, .acPower)
  }

  // MARK: - Specific reasons

  func test_blocked_locked_uses_lockedSince() {
    let now = Date()
    let lockedAt = now.addingTimeInterval(-45)
    var inputs = baseline(now: now)
    inputs.isScreenLocked = true
    inputs.lockedSince = lockedAt

    let state = computeGateState(inputs, now: now)
    XCTAssertEqual(state.blockReason, .locked)
    XCTAssertEqual(state.since.timeIntervalSince1970, lockedAt.timeIntervalSince1970, accuracy: 0.001)
  }

  func test_blocked_thermal_serious_and_critical_both_block() {
    let now = Date()
    for ts in [ProcessInfo.ThermalState.serious, .critical] {
      var inputs = baseline(now: now)
      inputs.thermalState = ts
      inputs.thermalSince = now.addingTimeInterval(-10)
      let state = computeGateState(inputs, now: now)
      XCTAssertEqual(state.blockReason, .thermal, "thermal=\(ts) should block")
    }
  }

  func test_blocked_thermal_fair_does_not_block() {
    let now = Date()
    var inputs = baseline(now: now)
    inputs.thermalState = .fair
    let state = computeGateState(inputs, now: now)
    XCTAssertTrue(state.isAllowed, "fair thermal should not block")
  }

  func test_blocked_battery_only_when_lpm_engaged() {
    // On battery without low-power-mode = no block (matches
    // `BatteryAwareScheduler`'s allowHeavyWork policy).
    let now = Date()
    var inputs = baseline(now: now, pending: 5)
    inputs.onBattery = true
    inputs.isLowPowerMode = false
    let state = computeGateState(inputs, now: now)
    XCTAssertTrue(state.isAllowed, "on battery without LPM should be Allowed; got \(state)")
  }

  func test_blocked_device_active_remaining_clamped_above_zero() {
    // User went from idle 119s with threshold 120s — remaining = 1s,
    // not 0 (UI never shows "waiting 0 seconds").
    let now = Date()
    var inputs = baseline(now: now, idleSeconds: 119.5, threshold: 120)
    let state = computeGateState(inputs, now: now)
    XCTAssertEqual(state.blockReason, .deviceActive)
    if case .idleFor(let secs) = state.waitingFor {
      XCTAssertGreaterThanOrEqual(secs, 1, "remaining must be ≥ 1")
    } else {
      XCTFail("expected idleFor; got \(String(describing: state.waitingFor))")
    }
  }

  func test_blocked_device_active_remaining_rounds_up() {
    let now = Date()
    var inputs = baseline(now: now, idleSeconds: 30, threshold: 120)
    let state = computeGateState(inputs, now: now)
    XCTAssertEqual(state.blockReason, .deviceActive)
    if case .idleFor(let secs) = state.waitingFor {
      // 120 - 30 = 90s remaining
      XCTAssertEqual(secs, 90)
    } else {
      XCTFail("expected idleFor; got \(String(describing: state.waitingFor))")
    }
  }

  func test_blocked_device_active_uses_activeSince() {
    let now = Date()
    let active = now.addingTimeInterval(-30)
    var inputs = baseline(now: now, idleSeconds: 30, threshold: 120)
    inputs.activeSince = active
    let state = computeGateState(inputs, now: now)
    XCTAssertEqual(
      state.since.timeIntervalSince1970, active.timeIntervalSince1970, accuracy: 0.001)
  }

  // MARK: - `since` for Allowed

  func test_allowed_since_is_when_user_crossed_threshold() {
    // idle = 200s, threshold = 120s → user has been "above the bar"
    // for 80s, so `since` should be `now - 80s` (not `now - 200s`,
    // which is when they LAST touched the device).
    let now = Date()
    let inputs = baseline(now: now, idleSeconds: 200, threshold: 120)
    let state = computeGateState(inputs, now: now)
    if case .allowed(let since) = state {
      XCTAssertEqual(since.timeIntervalSince1970, now.addingTimeInterval(-80).timeIntervalSince1970, accuracy: 1.0)
    } else {
      XCTFail("expected Allowed; got \(state)")
    }
  }
}
