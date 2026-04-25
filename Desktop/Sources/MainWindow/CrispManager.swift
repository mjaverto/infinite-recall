import AppKit
import Foundation

// Infinite Recall fork: this service no longer talks to a remote backend.
// Public API kept for compile compat; bodies are no-ops.

/// Fetches Crisp operator messages on app activation and Cmd+R,
/// fires macOS notifications, and tracks unread count for the sidebar badge.
@MainActor
class CrispManager: ObservableObject {
    static let shared = CrispManager()

    /// Number of unread operator messages (shown as badge in sidebar)
    @Published private(set) var unreadCount = 0

    /// Whether the user is currently viewing the Help tab
    var isViewingHelp = false {
        didSet {
            if isViewingHelp {
                unreadCount = 0
                // Update lastSeenTimestamp so these messages aren't re-notified
                lastSeenTimestamp = latestOperatorTimestamp
            }
        }
    }

    /// Timestamp of the most recent operator message we've already notified about.
    /// Persisted to UserDefaults so unread messages survive app restarts.
    /// Stored as Double because UserDefaults can't round-trip UInt64.
    /// Non-`private` so `CrispManagerLifecycleTests` can assert `markAsRead()` advances it.
    var lastSeenTimestamp: UInt64 {
        get { UInt64(UserDefaults.standard.double(forKey: "crisp_lastSeenTimestamp")) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "crisp_lastSeenTimestamp") }
    }

    /// Track the latest operator message timestamp from any poll.
    /// Persisted to UserDefaults so we don't re-notify after restart.
    /// Non-`private` so `CrispManagerLifecycleTests` can seed it before `markAsRead()`.
    var latestOperatorTimestamp: UInt64 {
        get { UInt64(UserDefaults.standard.double(forKey: "crisp_latestOperatorTimestamp")) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "crisp_latestOperatorTimestamp") }
    }

    /// Track message texts we've already sent notifications for (to avoid duplicates)
    private var notifiedMessages = Set<String>()

    /// Whether start() has been called. Non-`private` so lifecycle tests can
    /// assert idempotency after calling `start()` twice.
    var isStarted = false

    /// Non-`private` so lifecycle tests can assert `stop()` clears both observers.
    var activationObserver: NSObjectProtocol?
    var refreshAllObserver: NSObjectProtocol?

    /// Counter bumped at the top of `pollForMessages()`, before the auth-backoff
    /// guard and the network task. Lets `CrispManagerLifecycleTests` prove that
    /// posting `didBecomeActive` / `.refreshAllData` actually reaches the poll
    /// method — if an observer subscribes to the wrong notification name or a
    /// future edit drops the wiring, the counter stays flat and the test fails.
    /// Deliberately **not** `@Published` — publishing on every activation/Cmd+R
    /// refresh would emit `objectWillChange` and invalidate any SwiftUI view
    /// observing `CrispManager`, which is a pure production cost for a value
    /// nothing drives UI from.
    private(set) var pollInvocations: Int = 0

    /// Call once after sign-in to fetch Crisp messages and listen for activation/Cmd+R.
    ///
    /// - Parameter performInitialPoll: If `true` (default), kicks off an immediate
    ///   `pollForMessages()` call that hits `APIClient.shared`. Pass `false` only
    ///   from lifecycle unit tests that want to exercise observer registration
    ///   without touching the network, auth state, or firing real notifications.
    func start(performInitialPoll: Bool = true) {
        log("[backend-stripped] CrispManager.start: no-op (local-first)")
        // Disabled for local-first fork: no observers, no initial poll, no badge updates.
        // Mark started so callers behave as if start() succeeded.
        isStarted = true
    }

    /// Mark messages as read (called when user opens Help tab)
    func markAsRead() {
        unreadCount = 0
        lastSeenTimestamp = latestOperatorTimestamp
    }

    /// Stop observing (called on sign-out)
    func stop() {
        if let obs = activationObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = refreshAllObserver { NotificationCenter.default.removeObserver(obs) }
        activationObserver = nil
        refreshAllObserver = nil
        isStarted = false
        unreadCount = 0
        // Clear persisted timestamps so next sign-in starts fresh
        UserDefaults.standard.removeObject(forKey: "crisp_lastSeenTimestamp")
        UserDefaults.standard.removeObject(forKey: "crisp_latestOperatorTimestamp")
        notifiedMessages.removeAll()
    }

    // MARK: - Private

    private func pollForMessages() {
        // Disabled for local-first fork: poll loop removed (no remote backend).
        log("[backend-stripped] CrispManager.pollForMessages: no-op (local-first)")
        pollInvocations += 1
        return
    }

    private struct CrispUnreadResponse: Codable {
        let unread_count: Int
        let messages: [CrispOperatorMessage]
    }

    private struct CrispOperatorMessage: Codable {
        let text: String
        let timestamp: UInt64
        let from: String
    }

    private func fetchUnreadMessages() async throws -> [CrispOperatorMessage] {
        // Disabled for local-first fork: would have hit `\(baseURL)v1/crisp/unread`.
        return []
    }
}
