// Activity Tab — Phase 0 stub.
//
// TODO: Stream H. Singleton observer that polls Rust pause store every 5s
// and on `ActivityNotifications.pauseChanged`. Exposes:
//   - `isPaused(_ id: String) -> Bool`
//   - `pausedUntil(_ id: String) -> Date?`
// A/H/G read this; F's UI calls through it for snappy local state too.

import Foundation

// === activity:G stub ===
// Minimal no-op singleton so Stream G's pause-gate check compiles before
// Stream H lands the real polling implementation. Stream H MUST replace this
// entire `// === activity:G stub ===` block with the real `CapturePauseGate`.
public final class CapturePauseGate: @unchecked Sendable {
    public static let shared = CapturePauseGate()
    private init() {}

    /// No-op until Stream H lands. Always returns false (= not paused).
    /// Signature accepts `target: PauseTarget` and an `id: String` so the
    /// caller in BatteryAwareScheduler can pass `target: .kind, id: kind.rawValue`
    /// and the Stream H replacement will be source-compatible.
    public func isPaused(target: PauseTarget, id: String) -> Bool {
        return false
    }

    /// No-op until Stream H lands. Always returns nil.
    public func pausedUntil(target: PauseTarget, id: String) -> Date? {
        return nil
    }
}
// === /activity:G stub ===
