// Activity Tab — daemon-restart error classification.
//
// Single source of truth for "is this error a transient daemon-restart /
// daemon-startup race indicator?". Three call sites previously kept
// byte-identical private copies of this predicate, which drifted easily:
//
//   - `ActivityMonitorService.isTransientStartupError` (cold-start grace, #104)
//   - `InternalPostFailureTracker.isDaemonRestartIndicator` (POST failure
//     escalation filter)
//   - `ProcessingGateReporter.isDaemonRestartIndicator` (gate-state cache
//     invalidation on daemon restart)
//
// They are all now thin wrappers around `DaemonErrorClassifier.isTransient(_:)`.
// Behavior is unchanged: an error is transient when it matches any of:
//   - `APIError.unauthorized` (401 — token rotated on daemon restart)
//   - `APIError.httpError` with code 502/503/504 (gateway-class)
//   - `NSURLErrorDomain` with code `cannotConnectToHost`,
//     `networkConnectionLost`, `notConnectedToInternet`, or `timedOut`
//
// Note on 401: in IR's local-only deployment, the daemon and Swift app share
// a per-launch token. A daemon restart rotates that token, so the *very next*
// Swift POST gets a 401 even though the token is "valid in spirit" — the
// daemon just hasn't re-stamped it yet. This is the only realistic source of
// 401 (there is no remote auth provider that can be "broken"), so we treat
// 401 as a daemon-restart indicator. If a real auth-config bug ever surfaces
// it would persist past `coldStartGraceAttempts` and surface to the user.

import Foundation

enum DaemonErrorClassifier {
    /// True when `error` is a transient daemon-restart / daemon-startup race
    /// indicator — see file header for the exact set.
    static func isTransient(_ error: Error) -> Bool {
        if let api = error as? APIError {
            switch api {
            case .unauthorized:
                return true
            case .httpError(let code) where code == 502 || code == 503 || code == 504:
                return true
            default:
                break
            }
        }
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain {
            switch nsErr.code {
            case NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorTimedOut:
                return true
            default:
                break
            }
        }
        return false
    }
}
