// Activity Tab — Phase 0 stub.
//
// TODO: Stream H. Singleton observer that polls Rust pause store every 5s
// and on `ActivityNotifications.pauseChanged`. Exposes:
//   - `isPaused(_ id: String) -> Bool`
//   - `pausedUntil(_ id: String) -> Date?`
// A/H/G read this; F's UI calls through it for snappy local state too.

import Foundation
