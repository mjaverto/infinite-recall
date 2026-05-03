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
}
