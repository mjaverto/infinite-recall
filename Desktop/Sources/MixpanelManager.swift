import Foundation
import Mixpanel
import FirebaseAuth

// Infinite Recall fork: telemetry disabled. All public methods are no-ops.
// SDK imports are kept so the rest of the codebase compiles.

/// Singleton manager for MixPanel analytics
/// Mirrors the functionality from the Flutter app's MixpanelManager
@MainActor
class MixpanelManager {
    static let shared = MixpanelManager()

    private var isInitialized = false

    // Environment variable key for MixPanel token
    private let tokenKey = "MIXPANEL_PROJECT_TOKEN"

    private init() {}

    // MARK: - Initialization

    /// Initialize MixPanel with the project token from environment
    func initialize() {
        log("[telemetry-stripped] MixpanelManager.initialize: no-op (Infinite Recall is local-first)")
        // Disabled for local-first fork: Mixpanel.initialize(token: token, flushInterval: 10)
        // Disabled for local-first fork: Mixpanel.mainInstance().loggingEnabled = false
        return
    }

    /// Get the MixPanel token from environment or .env file
    private func getToken() -> String? {
        return nil
    }

    // MARK: - User Identification

    /// Identify the current user after sign-in
    func identify() {
        // Disabled for local-first fork: Mixpanel.mainInstance().identify(distinctId: uid)
    }

    /// Set user profile properties
    private func setPeopleValues(email: String?, name: String?) {
        // Disabled for local-first fork: Mixpanel.mainInstance().people.set(properties: properties)
    }

    /// Set a specific user property
    func setUserProperty(key: String, value: MixpanelType) {
        // Disabled for local-first fork: Mixpanel.mainInstance().people.set(property: key, to: value)
    }

    // MARK: - Event Tracking

    /// Track an event with optional properties
    func track(_ eventName: String, properties: [String: MixpanelType]? = nil) {
        // Disabled for local-first fork: Mixpanel.mainInstance().track(event: eventName, properties: properties)
    }

    /// Flush events to server immediately
    func flush() {
        // Disabled for local-first fork: Mixpanel.mainInstance().flush()
    }

    /// Start timing an event (call track with same name to finish)
    func startTimingEvent(_ eventName: String) {
        // Disabled for local-first fork: Mixpanel.mainInstance().time(event: eventName)
    }

    // MARK: - Opt In/Out

    /// Opt in to tracking
    func optInTracking() {
        // Disabled for local-first fork: Mixpanel.mainInstance().optInTracking()
    }

    /// Opt out of tracking
    func optOutTracking() {
        // Disabled for local-first fork: Mixpanel.mainInstance().optOutTracking()
    }

    /// Check if tracking is opted out
    var hasOptedOut: Bool {
        return true
    }

    // MARK: - Reset

    /// Reset the user (call on sign out)
    func reset() {
        // Disabled for local-first fork: Mixpanel.mainInstance().reset()
    }
}

// MARK: - Analytics Events

extension MixpanelManager {

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

    // MARK: - Recording Events (matches Flutter: Phone Mic Recording)

    func transcriptionStarted() {}
    func transcriptionStopped(wordCount: Int) {}
    func recordingError(error: String) {}

    // MARK: - Permission Events

    func permissionRequested(permission: String, extraProperties: [String: MixpanelType] = [:]) {}
    func permissionGranted(permission: String, extraProperties: [String: MixpanelType] = [:]) {}
    func permissionDenied(permission: String, extraProperties: [String: MixpanelType] = [:]) {}
    func permissionSkipped(permission: String, extraProperties: [String: MixpanelType] = [:]) {}

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
