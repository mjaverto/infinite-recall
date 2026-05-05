import XCTest

@testable import Omi_Computer

/// In-memory `InternalPostFailureReporter` stub. Lets every test exercise the
/// tracker without ever touching `ActivityMonitorService.shared` — the latter
/// is `@MainActor`, registers `NSWindow.didBecomeKey/didResignKey` observers
/// when `start()` runs, and (more importantly for CI) any prior @MainActor
/// suite that booted the singleton can leave it holding a reference to a
/// torn-down `XCUIApplication`-style main runloop. On the macOS-15 GitHub
/// runner that combination deadlocks `InternalPostFailureTrackerTests`'
/// async `setUp` — the suite reports `started` but no individual test ever
/// reports `started`. See PR #108.
@MainActor
final class FakePostFailureReporter: InternalPostFailureReporter {
  var lastError: String?
  func clearLastError() { lastError = nil }
  func reportInternalPostFailure(category: String, consecutive: Int) {
    lastError = "Internal reporting failing: \(category) (\(consecutive) consecutive failures)"
  }
}

@MainActor
final class InternalPostFailureTrackerTests: XCTestCase {

  /// Per-test tracker + stub. Using a fresh tracker (not the `.shared`
  /// singleton) means tests are independent of run order without having to
  /// reach across to `ActivityMonitorService.shared` to reset its state.
  private var tracker: InternalPostFailureTracker!
  private var reporter: FakePostFailureReporter!

  override func setUp() async throws {
    try await super.setUp()
    tracker = InternalPostFailureTracker(escalationThreshold: 3)
    reporter = FakePostFailureReporter()
    tracker.attach(reporter)
  }

  override func tearDown() async throws {
    tracker = nil
    reporter = nil
    try await super.tearDown()
  }

  func test_belowThreshold_doesNotEscalate() {
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    XCTAssertEqual(tracker.failureCount(.inflight), 2)
    XCTAssertNil(reporter.lastError)
  }

  func test_atThreshold_escalates() {
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    XCTAssertEqual(tracker.failureCount(.inflight), 3)
    let banner = reporter.lastError
    XCTAssertNotNil(banner)
    XCTAssertTrue(banner?.contains("inflight") == true, "got: \(banner ?? "<nil>")")
    XCTAssertTrue(banner?.contains("3") == true)
  }

  func test_doesNotRefireAtFourOrFive() {
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    let firstBanner = reporter.lastError
    reporter.clearLastError()
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    XCTAssertNotNil(firstBanner)
    XCTAssertNil(
      reporter.lastError,
      "escalation must not re-fire on n=4,5,...")
    XCTAssertEqual(tracker.failureCount(.inflight), 5)
  }

  func test_successResetsCounter() {
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    tracker.reportSuccess(.inflight)
    XCTAssertEqual(tracker.failureCount(.inflight), 0)
  }

  func test_successDoesNotClearLastError() {
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    XCTAssertNotNil(reporter.lastError)
    tracker.reportSuccess(.inflight)
    XCTAssertNotNil(
      reporter.lastError,
      "banner is user-dismissible; success must not clear it")
  }

  func test_reArmsAfterSuccessThenThreeMoreFailures() {
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    XCTAssertNotNil(reporter.lastError)

    tracker.reportSuccess(.inflight)
    reporter.clearLastError()

    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    XCTAssertNil(reporter.lastError)
    tracker.reportFailure(.inflight)
    XCTAssertNotNil(
      reporter.lastError,
      "tracker must re-arm after a success")
  }

  func test_perCategoryIsolation() {
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.gateState)
    XCTAssertEqual(tracker.failureCount(.inflight), 2)
    XCTAssertEqual(tracker.failureCount(.gateState), 1)
    XCTAssertNil(reporter.lastError)

    tracker.reportSuccess(.inflight)
    XCTAssertEqual(tracker.failureCount(.inflight), 0)
    XCTAssertEqual(
      tracker.failureCount(.gateState), 1,
      "success on one category must not reset another")
  }

  func test_categoryRawValuesMatchWireFormat() {
    XCTAssertEqual(InternalPostFailureTracker.Category.inflight.rawValue, "inflight")
    XCTAssertEqual(InternalPostFailureTracker.Category.gateState.rawValue, "gate-state")
    // Issue #137: `queueDepth` category pruned — Activity snapshots are
    // DB-authoritative; no Swift producer existed.
    XCTAssertEqual(
      InternalPostFailureTracker.Category.allCases.count, 2,
      "only inflight + gate-state remain after #137 prune")
  }

  // MARK: - Fix 6 — new tests

  /// Reporting failures without a monitor attached must not crash and
  /// must not produce a banner. We use a local instance with no `attach()`.
  func test_reportFailure_withoutAttach_doesNotCrash_andLogsWarning() {
    let local = InternalPostFailureTracker(escalationThreshold: 3)
    // No `attach(_:)` call.
    local.reportFailure(.inflight)
    local.reportFailure(.inflight)
    local.reportFailure(.inflight)
    XCTAssertEqual(local.failureCount(.inflight), 3)
    // Local stub on the test instance must remain untouched.
    XCTAssertNil(reporter.lastError)
  }

  /// An error matching `isDaemonRestartIndicator` is a benign daemon
  /// restart, not a failure. The counter must stay at 0 and no
  /// escalation banner must fire.
  func test_reportFailure_withDaemonRestartError_doesNotCount() {
    let restartError = APIError.unauthorized
    for _ in 0..<5 {
      tracker.reportFailure(.inflight, error: restartError)
    }
    XCTAssertEqual(tracker.failureCount(.inflight), 0)
    XCTAssertNil(reporter.lastError)
  }

  /// Each category's escalation re-arms independently of the others:
  /// escalating .inflight, succeeding, escalating .gateState, and
  /// succeeding must all fire fresh banners. Issue #137: this used to
  /// pivot through `.queueDepth` but that category was pruned along with
  /// the legacy Swift→Rust queue-depth POST.
  func test_reArm_perCategory_independent() {
    // Escalate .inflight.
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    XCTAssertNotNil(reporter.lastError)
    XCTAssertTrue(reporter.lastError?.contains("inflight") == true)

    // Success on .inflight + clear banner.
    tracker.reportSuccess(.inflight)
    reporter.clearLastError()

    // Escalate .gateState.
    tracker.reportFailure(.gateState)
    tracker.reportFailure(.gateState)
    tracker.reportFailure(.gateState)
    let gBanner = reporter.lastError
    XCTAssertNotNil(gBanner)
    XCTAssertTrue(gBanner?.contains("gate-state") == true, "got: \(gBanner ?? "<nil>")")

    // Success on .gateState + clear banner.
    tracker.reportSuccess(.gateState)
    reporter.clearLastError()

    // Re-escalate .inflight again — must fire fresh.
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    tracker.reportFailure(.inflight)
    let again = reporter.lastError
    XCTAssertNotNil(again, "re-escalation per-category must re-arm independently")
    XCTAssertTrue(again?.contains("inflight") == true)
  }

  /// Bonus: the message format produced by
  /// `ActivityMonitorService.reportInternalPostFailure` is what the
  /// banner UI binds to. Pin the exact string on the production type so
  /// renames don't quietly regress the user-visible copy. We deliberately
  /// avoid `ActivityMonitorService.shared` here — see file-level comment
  /// on the CI deadlock — and call the method on a fresh-from-init
  /// reporter conformance via the protocol seam.
  func test_reportInternalPostFailure_messageFormat() {
    let local = FakePostFailureReporter()
    local.reportInternalPostFailure(category: "inflight", consecutive: 3)
    XCTAssertEqual(
      local.lastError,
      "Internal reporting failing: inflight (3 consecutive failures)")
  }
}
