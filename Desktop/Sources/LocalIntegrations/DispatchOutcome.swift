import Foundation

/// Shared result type for both webhook and filesystem dispatches.
///
/// The drain service branches uniformly on this enum: `.success` deletes
/// the outbox row, `.retry` reschedules with backoff, `.permanentFailure`
/// pushes the row's `nextRetryAt` far out and surfaces `lastError` to the
/// user (manual "Retry now" still works).
enum DispatchOutcome {
  /// Delivered. Drainer deletes the outbox row.
  case success
  /// Transient failure (network blip, 5xx, 429, transient I/O,
  /// iCloud not yet downloaded, stale bookmark we successfully refreshed).
  /// Drainer applies exponential backoff.
  case retry(reason: String)
  /// Non-recoverable failure (4xx other than 429, unresolvable bookmark,
  /// malformed URL, etc.). Drainer pushes `nextRetryAt` far out and
  /// surfaces the error.
  case permanentFailure(reason: String)
}
