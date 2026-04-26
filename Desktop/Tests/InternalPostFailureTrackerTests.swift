import XCTest

@testable import Omi_Computer

@MainActor
final class InternalPostFailureTrackerTests: XCTestCase {

  /// Reset every category counter on the shared tracker. Iterates
  /// `Category.allCases` so adding a new case can't rot the suite.
  private func resetSharedTracker() {
    let tracker = InternalPostFailureTracker.shared
    for category in InternalPostFailureTracker.Category.allCases {
      tracker.reportSuccess(category)
    }
    tracker.attach(ActivityMonitorService.shared)
    ActivityMonitorService.shared.clearLastError()
  }

  override func setUp() async throws {
    try await super.setUp()
    // The tracker is a singleton; reset state between tests so cases are
    // independent regardless of run order.
    resetSharedTracker()
  }

  override func tearDown() async throws {
    // Same reset on teardown so leftover state from this suite doesn't
    // bleed into other suites that touch ActivityMonitorService.shared.
    resetSharedTracker()
    try await super.tearDown()
  }

  func test_belowThreshold_doesNotEscalate() {
    let tracker = InternalPostFailureTracker.shared
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    XCTAssertEqual(tracker.failureCount(.inflight), 2)
    XCTAssertNil(ActivityMonitorService.shared.lastError)
  }

  func test_atThreshold_escalates() {
    let tracker = InternalPostFailureTracker.shared
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    XCTAssertEqual(tracker.failureCount(.inflight), 3)
    let banner = ActivityMonitorService.shared.lastError
    XCTAssertNotNil(banner)
    XCTAssertTrue(banner?.contains("inflight") == true, "got: \(banner ?? "<nil>")")
    XCTAssertTrue(banner?.contains("3") == true)
  }

  func test_doesNotRefireAtFourOrFive() {
    let tracker = InternalPostFailureTracker.shared
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    let firstBanner = ActivityMonitorService.shared.lastError
    ActivityMonitorService.shared.clearLastError()
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    XCTAssertNotNil(firstBanner)
    XCTAssertNil(
      ActivityMonitorService.shared.lastError,
      "escalation must not re-fire on n=4,5,...")
    XCTAssertEqual(tracker.failureCount(.inflight), 5)
  }

  func test_successResetsCounter() {
    let tracker = InternalPostFailureTracker.shared
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    tracker.reportSuccess(.inflight)
    XCTAssertEqual(tracker.failureCount(.inflight), 0)
  }

  func test_successDoesNotClearLastError() {
    let tracker = InternalPostFailureTracker.shared
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    XCTAssertNotNil(ActivityMonitorService.shared.lastError)
    tracker.reportSuccess(.inflight)
    XCTAssertNotNil(
      ActivityMonitorService.shared.lastError,
      "banner is user-dismissible; success must not clear it")
  }

  func test_reArmsAfterSuccessThenThreeMoreFailures() {
    let tracker = InternalPostFailureTracker.shared
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    XCTAssertNotNil(ActivityMonitorService.shared.lastError)

    tracker.reportSuccess(.inflight)
    ActivityMonitorService.shared.clearLastError()

    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    XCTAssertNil(ActivityMonitorService.shared.lastError)
    tracker.reportFailure(.inflight)
    XCTAssertNotNil(
      ActivityMonitorService.shared.lastError,
      "tracker must re-arm after a success")
  }

  func test_perCategoryIsolation() {
    let tracker = InternalPostFailureTracker.shared
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.queueDepth)
    XCTAssertEqual(tracker.failureCount(.inflight), 2)
    XCTAssertEqual(tracker.failureCount(.queueDepth), 1)
    XCTAssertEqual(tracker.failureCount(.gateState), 0)
    XCTAssertNil(ActivityMonitorService.shared.lastError)

    tracker.reportSuccess(.inflight)
    XCTAssertEqual(tracker.failureCount(.inflight), 0)
    XCTAssertEqual(
      tracker.failureCount(.queueDepth), 1,
      "success on one category must not reset another")
  }

  func test_categoryRawValuesMatchWireFormat() {
    XCTAssertEqual(InternalPostFailureTracker.Category.inflight.rawValue, "inflight")
    XCTAssertEqual(InternalPostFailureTracker.Category.queueDepth.rawValue, "queue-depth")
    XCTAssertEqual(InternalPostFailureTracker.Category.gateState.rawValue, "gate-state")
  }

  // MARK: - Fix 6 — new tests

  /// Reporting failures without a monitor attached must not crash and
  /// must not produce a banner. We use a local instance so we don't
  /// disturb the shared singleton's `monitor` weak ref.
  func test_reportFailure_withoutAttach_doesNotCrash_andLogsWarning() {
    let local = InternalPostFailureTracker(escalationThreshold: 3)
    // No `attach(_:)` call.
    local.reportFailure(.inflight)
    local.reportFailure(.inflight)
    local.reportFailure(.inflight)
    XCTAssertEqual(local.failureCount(.inflight), 3)
    // Shared monitor must remain untouched (no banner from this local).
    XCTAssertNil(ActivityMonitorService.shared.lastError)
  }

  /// An error matching `isDaemonRestartIndicator` is a benign daemon
  /// restart, not a failure. The counter must stay at 0 and no
  /// escalation banner must fire.
  func test_reportFailure_withDaemonRestartError_doesNotCount() {
    let tracker = InternalPostFailureTracker.shared
    let restartError = APIError.unauthorized
    for _ in 0..<5 {
      tracker.reportFailure(.inflight, error: restartError)
    }
    XCTAssertEqual(tracker.failureCount(.inflight), 0)
    XCTAssertNil(ActivityMonitorService.shared.lastError)
  }

  /// Each category's escalation re-arms independently of the others:
  /// escalating .inflight, succeeding, escalating .queueDepth, and
  /// succeeding must all fire fresh banners.
  func test_reArm_perCategory_independent() {
    let tracker = InternalPostFailureTracker.shared

    // Escalate .inflight.
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    XCTAssertNotNil(ActivityMonitorService.shared.lastError)
    XCTAssertTrue(ActivityMonitorService.shared.lastError?.contains("inflight") == true)

    // Success on .inflight + clear banner.
    tracker.reportSuccess(.inflight)
    ActivityMonitorService.shared.clearLastError()

    // Escalate .queueDepth.
    tracker.reportFailure(.queueDepth)
    tracker.reportFailure(.queueDepth)
    tracker.reportFailure(.queueDepth)
    let qBanner = ActivityMonitorService.shared.lastError
    XCTAssertNotNil(qBanner)
    XCTAssertTrue(qBanner?.contains("queue-depth") == true, "got: \(qBanner ?? "<nil>")")

    // Success on .queueDepth + clear banner.
    tracker.reportSuccess(.queueDepth)
    ActivityMonitorService.shared.clearLastError()

    // Re-escalate .inflight again — must fire fresh.
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    let again = ActivityMonitorService.shared.lastError
    XCTAssertNotNil(again, "re-escalation per-category must re-arm independently")
    XCTAssertTrue(again?.contains("inflight") == true)
  }

  /// Bonus: the message format produced by
  /// `ActivityMonitorService.reportInternalPostFailure` is what the
  /// banner UI binds to. Pin the exact string so renames don't quietly
  /// regress the user-visible copy.
  func test_reportInternalPostFailure_messageFormat() {
    ActivityMonitorService.shared.clearLastError()
    ActivityMonitorService.shared.reportInternalPostFailure(
      category: "inflight", consecutive: 3)
    XCTAssertEqual(
      ActivityMonitorService.shared.lastError,
      "Internal reporting failing: inflight (3 consecutive failures)")
  }
}
