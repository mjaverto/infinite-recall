import XCTest
@testable import Omi_Computer

/// Regression coverage for issue #104: on cold start the first
/// `getActivitySnapshot` request can race the Rust daemon's bind/init and
/// time out, surfacing "snapshot failed: The request timed out." in the
/// Activity tab. The fix swallows transient daemon-startup errors during the
/// initial polling grace; this verifies the classifier used to decide which
/// errors qualify.
final class ActivityMonitorServiceColdStartGraceTests: XCTestCase {

    func testTimeoutIsTransient() {
        let err = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "The request timed out."]
        )
        XCTAssertTrue(ActivityMonitorService.isTransientStartupError(err))
    }

    func testCannotConnectIsTransient() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        XCTAssertTrue(ActivityMonitorService.isTransientStartupError(err))
    }

    func testNetworkConnectionLostIsTransient() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        XCTAssertTrue(ActivityMonitorService.isTransientStartupError(err))
    }

    func testNotConnectedIsTransient() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertTrue(ActivityMonitorService.isTransientStartupError(err))
    }

    func testHTTP502503504AreTransient() {
        for code in [502, 503, 504] {
            XCTAssertTrue(
                ActivityMonitorService.isTransientStartupError(APIError.httpError(statusCode: code)),
                "HTTP \(code) should be classified as transient"
            )
        }
    }

    func testUnauthorizedIsTransient() {
        // Daemon-restart races commonly surface as 401 while the auth header
        // is being rotated; treat as transient (matches
        // InternalPostFailureTracker).
        XCTAssertTrue(ActivityMonitorService.isTransientStartupError(APIError.unauthorized))
    }

    func testHTTP500IsNotTransient() {
        XCTAssertFalse(
            ActivityMonitorService.isTransientStartupError(APIError.httpError(statusCode: 500))
        )
    }

    func testHTTP404IsNotTransient() {
        XCTAssertFalse(
            ActivityMonitorService.isTransientStartupError(APIError.httpError(statusCode: 404))
        )
    }

    func testInvalidResponseIsNotTransient() {
        XCTAssertFalse(ActivityMonitorService.isTransientStartupError(APIError.invalidResponse))
    }

    func testCancelledIsNotTransient() {
        // User-initiated cancellation should not be silenced as a startup race.
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertFalse(ActivityMonitorService.isTransientStartupError(err))
    }

    func testRandomErrorIsNotTransient() {
        struct Boom: Error {}
        XCTAssertFalse(ActivityMonitorService.isTransientStartupError(Boom()))
    }

    func testGraceAttemptsIsPositive() {
        // Sanity guard: if someone sets this to 0 the grace becomes a no-op
        // and the bug regresses silently.
        XCTAssertGreaterThan(ActivityMonitorService.coldStartGraceAttempts, 0)
    }

    // MARK: - Shared classifier parity (DaemonErrorClassifier)
    //
    // ActivityMonitorService.isTransientStartupError now delegates to
    // DaemonErrorClassifier.isTransient. Pin the two to identical results
    // across the full transient/non-transient matrix so a future drift
    // (e.g. someone tweaking only one site) fails CI loudly.

    func testClassifierParityForTransientCases() {
        let cases: [Error] = [
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
            APIError.unauthorized,
            APIError.httpError(statusCode: 502),
            APIError.httpError(statusCode: 503),
            APIError.httpError(statusCode: 504),
        ]
        for err in cases {
            XCTAssertTrue(DaemonErrorClassifier.isTransient(err), "shared classifier disagrees for \(err)")
            XCTAssertEqual(
                DaemonErrorClassifier.isTransient(err),
                ActivityMonitorService.isTransientStartupError(err),
                "drift between shared and service classifier for \(err)"
            )
        }
    }

    func testClassifierParityForNonTransientCases() {
        let cases: [Error] = [
            APIError.httpError(statusCode: 500),
            APIError.httpError(statusCode: 404),
            APIError.invalidResponse,
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
        ]
        for err in cases {
            XCTAssertFalse(DaemonErrorClassifier.isTransient(err), "shared classifier should reject \(err)")
            XCTAssertEqual(
                DaemonErrorClassifier.isTransient(err),
                ActivityMonitorService.isTransientStartupError(err),
                "drift between shared and service classifier for \(err)"
            )
        }
    }

    // MARK: - Behavioral grace-window state machine
    //
    // These exercise the actual stateful code path in `fetchOnce` via the
    // narrow `_test*` seams. Introducing a full APIClient DI seam was out
    // of scope for #104 (see PR comment + service-level docstring); the
    // seams replay the exact branches in `fetchOnce` so behavior we
    // simulate here matches behavior at runtime.

    @MainActor
    func testGraceWindowSuppressesFirst5TransientFailures() {
        let svc = ActivityMonitorService.shared
        svc._testResetStartGrace()
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        for tick in 1...5 {
            let suppressed = svc._testHandleFetchError(timeout)
            XCTAssertTrue(suppressed, "tick \(tick) should be suppressed during grace")
            XCTAssertNil(svc.lastError, "lastError must remain nil during grace (tick \(tick))")
        }
        // Restore for next test.
        svc._testResetStartGrace()
    }

    @MainActor
    func testSixthTransientFailureSurfacesError() {
        let svc = ActivityMonitorService.shared
        svc._testResetStartGrace()
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        // Burn the 5-tick grace window.
        for _ in 1...5 { _ = svc._testHandleFetchError(timeout) }
        // Sixth failure should surface.
        let suppressed = svc._testHandleFetchError(timeout)
        XCTAssertFalse(suppressed, "tick 6 must surface")
        XCTAssertNotNil(svc.lastError)
        XCTAssertTrue(svc.lastError?.contains("snapshot failed") ?? false)
        svc._testResetStartGrace()
    }

    @MainActor
    func testTransientErrorAfterFirstSuccessSurfacesImmediately() {
        let svc = ActivityMonitorService.shared
        svc._testResetStartGrace()
        // First success exits the cold-start phase.
        svc._testHandleFetchSuccess()
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let suppressed = svc._testHandleFetchError(timeout)
        XCTAssertFalse(suppressed, "post-success transient must surface immediately")
        XCTAssertNotNil(svc.lastError)
        svc._testResetStartGrace()
    }

    @MainActor
    func testStopThenStartReArmsGraceFromZero() {
        let svc = ActivityMonitorService.shared
        svc._testResetStartGrace()
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        // Exhaust grace — surface on tick 6.
        for _ in 1...6 { _ = svc._testHandleFetchError(timeout) }
        XCTAssertNotNil(svc.lastError)
        // Simulate stop()→start() by re-arming via the same hook `start()`
        // uses on the `!isStarted` path.
        svc._testResetStartGrace()
        // 5 fresh suppressed ticks.
        for tick in 1...5 {
            let suppressed = svc._testHandleFetchError(timeout)
            XCTAssertTrue(suppressed, "post-restart tick \(tick) should be suppressed")
            XCTAssertNil(svc.lastError, "post-restart lastError must remain nil during fresh grace (tick \(tick))")
        }
        svc._testResetStartGrace()
    }

    @MainActor
    func testDaemonNotConfiguredSurfacesDuringGrace() {
        let svc = ActivityMonitorService.shared
        svc._testResetStartGrace()
        // First-ever tick, configuration error → must surface immediately,
        // grace must NOT swallow it.
        let suppressed = svc._testHandleFetchError(APIError.daemonNotConfigured)
        XCTAssertFalse(suppressed)
        XCTAssertEqual(
            svc.lastError,
            APIError.daemonNotConfigured.localizedDescription,
            "daemonNotConfigured must surface its distinct configuration message"
        )
        svc._testResetStartGrace()
    }
}
