// Singleton-fixer S6: rate-limited error logger for the Swift→Rust
// in-flight reporting path.
//
// `BatteryAwareScheduler` posts to `/v1/activity/_internal/inflight`
// every time a unit of work starts and finishes. The previous code wrapped
// every call in `Task { try? await ... }` — every HTTP failure was
// silently swallowed. Combined with the S1 401 bug, the user saw no
// in-flight rows AND no log breadcrumb explaining why.
//
// This logger:
//   - logs the FIRST failure of a (context, error message) pair immediately,
//   - then suppresses identical errors for 60s,
//   - on the next allowed log, appends "(N suppressed in last 60s)".
//
// We keep the data structure small — at most a handful of distinct
// (context, error message) pairs ever appear in practice — so we don't
// bother with eviction.

import Foundation

@MainActor
final class ActivityReportLogger {
  static let shared = ActivityReportLogger()

  /// Window during which identical errors are suppressed after the first
  /// log. Tuned to "user can read a notification before another one fires"
  /// without being so long that an hour-long outage logs only once.
  private static let suppressionWindow: TimeInterval = 60

  private var lastLogged: [String: Date] = [:]
  private var suppressed: [String: Int] = [:]

  private init() {}

  /// Log an error from an Activity-tab background reporter. Identical
  /// (context, error description) pairs within the suppression window are
  /// counted but not emitted, then summarised on the next allowed log.
  func log(error: Error, context: String) {
    let key = "\(context)|\(error.localizedDescription)"
    let now = Date()

    if let last = lastLogged[key],
      now.timeIntervalSince(last) < Self.suppressionWindow
    {
      suppressed[key, default: 0] += 1
      return
    }

    let count = suppressed.removeValue(forKey: key) ?? 0
    let suffix = count > 0 ? " (\(count) suppressed in last 60s)" : ""
    logError("\(context): \(error.localizedDescription)\(suffix)", error: error)
    lastLogged[key] = now
  }

  /// Test/diagnostic hook: forget all suppression state.
  func resetForTesting() {
    lastLogged.removeAll()
    suppressed.removeAll()
  }
}
