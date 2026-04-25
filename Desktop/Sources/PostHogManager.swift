import Foundation

// Infinite Recall fork: telemetry disabled. All public methods are no-ops.
// PostHog SPM dep removed; `import PostHog` dropped along with it.

/// Singleton manager for PostHog analytics with Session Replay
/// Complements MixpanelManager - both track the same events
@MainActor
class PostHogManager {
    static let shared = PostHogManager()

    private var isInitialized = false

    // PostHog configuration (kept for reference; never used in this fork)
    private let apiKey = "phc_z3qUFhGUgYIOMYnfxVSrLmYISQvbgph8iREQv3sez3Y"
    private let host = "https://us.i.posthog.com"

    private init() {}

    // MARK: - Initialization

    /// Initialize PostHog with analytics
    func initialize() {
        log("[telemetry-stripped] PostHogManager.initialize: no-op (Infinite Recall is local-first)")
        // Disabled for local-first fork: let config = PostHogConfig(apiKey: apiKey, host: host)
        // Disabled for local-first fork: config.captureApplicationLifecycleEvents = false
        // Disabled for local-first fork: config.captureScreenViews = true
        // Disabled for local-first fork: config.preloadFeatureFlags = true
        // Disabled for local-first fork: PostHogSDK.shared.setup(config)
        return
    }

    // MARK: - User Identification

    /// Identify the current user after sign-in
    func identify() {
        // Disabled for local-first fork: PostHogSDK.shared.identify(uid, userProperties: properties)
    }

    /// Set a specific user property
    func setUserProperty(key: String, value: Any) {
        // Disabled for local-first fork: PostHogSDK.shared.identify(PostHogSDK.shared.getDistinctId(), userProperties: [key: value])
    }

    // MARK: - Event Tracking

    /// Track an event with optional properties
    func track(_ eventName: String, properties: [String: Any]? = nil) {
        // Disabled for local-first fork: PostHogSDK.shared.capture(eventName, properties: properties)
    }

    // MARK: - Screen Tracking

    /// Track a screen view
    func screen(_ screenName: String, properties: [String: Any]? = nil) {
        // Disabled for local-first fork: PostHogSDK.shared.screen(screenName, properties: properties)
    }

    // MARK: - Opt In/Out

    /// Opt in to tracking
    func optIn() {
        // Disabled for local-first fork: PostHogSDK.shared.optIn()
    }

    /// Opt out of tracking
    func optOut() {
        // Disabled for local-first fork: PostHogSDK.shared.optOut()
    }

    /// Check if tracking is opted out
    var hasOptedOut: Bool {
        return true
    }

    // MARK: - Reset

    /// Reset the user (call on sign out)
    func reset() {
        // Disabled for local-first fork: PostHogSDK.shared.reset()
    }

    // MARK: - Feature Flags

    /// Check if a feature flag is enabled
    func isFeatureEnabled(_ flag: String) -> Bool {
        // Disabled for local-first fork: return PostHogSDK.shared.isFeatureEnabled(flag)
        return false
    }

    /// Get feature flag value
    func getFeatureFlag(_ flag: String) -> Any? {
        // Disabled for local-first fork: return PostHogSDK.shared.getFeatureFlag(flag)
        return nil
    }

    /// Reload feature flags
    func reloadFeatureFlags() {
        // Disabled for local-first fork: PostHogSDK.shared.reloadFeatureFlags()
    }
}

// MARK: - Analytics Events

extension PostHogManager {

    // MARK: - Onboarding Events

    func onboardingStepCompleted(step: Int, stepName: String) {}
    func onboardingCompleted() {}

    // MARK: - Authentication Events

    func signInStarted(provider: String) {}
    func signInCompleted(provider: String) {}
    func signInFailed(provider: String, error: String) {}
    func signedOut() {}

    // MARK: - Monitoring Events

    func monitoringStarted() {}
    func monitoringStopped() {}
    func distractionDetected(app: String, windowTitle: String?) {}
    func focusRestored(app: String) {}

    // MARK: - Recording Events

    func transcriptionStarted() {}
    func transcriptionStopped(wordCount: Int) {}
    func recordingError(error: String) {}

    // MARK: - Permission Events

    func permissionRequested(permission: String, extraProperties: [String: Any] = [:]) {}
    func permissionGranted(permission: String, extraProperties: [String: Any] = [:]) {}
    func permissionDenied(permission: String, extraProperties: [String: Any] = [:]) {}
    func permissionSkipped(permission: String, extraProperties: [String: Any] = [:]) {}

    /// Track when ScreenCaptureKit broken state is detected
    func screenCaptureBrokenDetected() {}

    /// Track when user clicks reset button or notification
    func screenCaptureResetClicked(source: String) {}

    /// Track when screen capture reset completes
    func screenCaptureResetCompleted(success: Bool) {}

    func notificationRepairTriggered(reason: String, previousStatus: String, currentStatus: String) {}

    func notificationSettingsChecked(
        authStatus: String,
        alertStyle: String,
        soundEnabled: Bool,
        badgeEnabled: Bool,
        bannersDisabled: Bool
    ) {}

    // MARK: - App Lifecycle Events

    func appLaunched() {}

    /// Track first launch with comprehensive system diagnostics
    func firstLaunch(diagnostics: [String: Any]) {}

    func appBecameActive() {}
    func appResignedActive() {}

    // MARK: - Page/Screen Views (PostHog specific)

    func pageViewed(_ pageName: String) {}

    // MARK: - Conversation Events

    func conversationCreated(conversationId: String, source: String, durationSeconds: Int? = nil) {}
    func memoryDeleted(conversationId: String) {}
    func memoryShareButtonClicked(conversationId: String) {}
    func memoryListItemClicked(conversationId: String) {}

    // MARK: - Chat Events

    func chatMessageSent(messageLength: Int, hasContext: Bool = false, source: String) {}

    // MARK: - Search Events

    func searchQueryEntered(query: String) {}
    func searchBarFocused() {}

    // MARK: - Settings Events

    func settingsPageOpened() {}

    // MARK: - Account Events

    func deleteAccountClicked() {}
    func deleteAccountConfirmed() {}
    func deleteAccountCancelled() {}

    // MARK: - Navigation Events

    func tabChanged(tabName: String) {}
    func conversationDetailOpened(conversationId: String) {}

    // MARK: - Chat Events (Additional)

    func chatAppSelected(appId: String?, appName: String?) {}
    func chatCleared() {}

    // MARK: - Conversation Events (Additional)

    func conversationReprocessed(conversationId: String, appId: String) {}

    // MARK: - Settings Events (Additional)

    func settingToggled(setting: String, enabled: Bool) {}
    func languageChanged(language: String) {}

    // MARK: - Launch At Login Events

    func launchAtLoginStatusChecked(enabled: Bool) {}
    func launchAtLoginChanged(enabled: Bool, source: String) {}

    // MARK: - Feedback Events

    func feedbackOpened() {}
    func feedbackSubmitted(feedbackLength: Int) {}

    // MARK: - Rewind Events (Desktop-specific)

    func rewindSearchPerformed(queryLength: Int) {}
    func rewindScreenshotViewed(timestamp: Date) {}
    func ffmpegResolved(source: String, path: String) {}
    func rewindTimelineNavigated(direction: String) {}

    // MARK: - Proactive Assistant Events (Desktop-specific)

    func focusAlertShown(app: String) {}
    func focusAlertDismissed(app: String, action: String) {}
    func taskExtracted(taskCount: Int) {}
    func taskPromoted(taskCount: Int) {}
    func taskCompleted(source: String?) {}
    func taskDeleted(source: String?) {}
    func taskAdded() {}
    func memoryExtracted(memoryCount: Int) {}
    func insightGenerated(category: String?) {}

    // MARK: - Apps Events

    func appEnabled(appId: String, appName: String) {}
    func appDisabled(appId: String, appName: String) {}
    func appDetailViewed(appId: String, appName: String) {}

    // MARK: - Update Events

    func updateCheckStarted() {}
    func updateAvailable(version: String) {}
    func updateInstalled(version: String) {}
    func updateNotFound() {}
    func updateCheckFailed(error: String, errorDomain: String, errorCode: Int, underlyingError: String? = nil, underlyingDomain: String? = nil, underlyingCode: Int? = nil) {}

    // MARK: - Notification Events

    func notificationSent(notificationId: String, title: String, assistantId: String, surface: String) {}
    func notificationClicked(notificationId: String, title: String, assistantId: String, surface: String) {}
    func notificationDismissed(notificationId: String, title: String, assistantId: String, surface: String) {}
    func notificationWillPresent(notificationId: String, title: String) {}
    func notificationDelegateReady() {}

    // MARK: - Menu Bar Events

    func menuBarOpened() {}
    func menuBarActionClicked(action: String) {}

    // MARK: - Tier Events

    func tierChanged(tier: Int, reason: String) {}
    func chatBridgeModeChanged(from oldMode: String, to newMode: String) {}

    // MARK: - Settings State

    func settingsStateTracked(screenshotsEnabled: Bool, memoryExtractionEnabled: Bool, memoryNotificationsEnabled: Bool) {}

    /// Comprehensive all-settings snapshot (fired on app launch, at most once per day)
    func allSettingsStateTracked(properties: [String: Any]) {}

    // MARK: - Display Info

    func displayInfoTracked(info: [String: Any]) {}
}
