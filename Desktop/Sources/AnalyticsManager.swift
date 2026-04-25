import AppKit
import Foundation

// Infinite Recall fork: telemetry disabled. All public methods are no-ops.
// Mixpanel SPM dep removed; `import Mixpanel` dropped along with it.

/// Unified analytics manager that sends events to both Mixpanel and PostHog
/// Use this instead of calling MixpanelManager and PostHogManager directly
@MainActor
class AnalyticsManager {
  static let shared = AnalyticsManager()

  /// Returns true for non-production Omi bundles so test apps don't pollute production analytics.
  nonisolated static var isDevBuild: Bool {
    AppBuild.isNonProduction
  }

  private init() {}

  // MARK: - Initialization

  func initialize() {
    log("[telemetry-stripped] AnalyticsManager.initialize: no-op (Infinite Recall is local-first)")
    // Disabled for local-first fork: MixpanelManager.shared.initialize()
    // Disabled for local-first fork: PostHogManager.shared.initialize()
    // Disabled for local-first fork: HeapManager.shared.initialize()
    return
  }

  // MARK: - User Identification

  func identify() {}
  func reset() {}

  // MARK: - Opt In/Out

  func optInTracking() {}
  func optOutTracking() {}

  // MARK: - Onboarding Events

  func onboardingStepCompleted(step: Int, stepName: String) {}
  func onboardingHowDidYouHear(source: String) {}
  func onboardingCompleted() {}
  func onboardingChatToolUsed(tool: String, properties: [String: Any] = [:]) {}
  func onboardingChatMessage(role: String, step: String) {}

  /// Track full onboarding chat message content for debugging user issues.
  func onboardingChatMessageDetailed(
    role: String, text: String, step: String, toolCalls: [String]? = nil, model: String? = nil,
    error: String? = nil
  ) {}

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

  /// Track Bluetooth state changes for debugging
  func bluetoothStateChanged(
    oldState: String, newState: String, oldStateRaw: Int, newStateRaw: Int, authorization: String,
    authorizationRaw: Int
  ) {}

  /// Track when ScreenCaptureKit broken state is detected (TCC granted but capture failing)
  func screenCaptureBrokenDetected() {}

  /// Track when user clicks reset button or notification to reset screen capture
  func screenCaptureResetClicked(source: String) {}

  /// Track when screen capture reset completes (success or failure)
  func screenCaptureResetCompleted(success: Bool) {}

  /// Track when notification repair is triggered (auto-repair or error-triggered)
  func notificationRepairTriggered(reason: String, previousStatus: String, currentStatus: String) {}

  /// Track notification settings status (auth, alertStyle, sound, badge)
  func notificationSettingsChecked(
    authStatus: String,
    alertStyle: String,
    soundEnabled: Bool,
    badgeEnabled: Bool,
    bannersDisabled: Bool
  ) {}

  // MARK: - Crash Detection

  /// Detect if the previous session crashed and report.
  /// Crash reports are telemetry — disabled for local-first fork.
  func detectAndReportCrash() {
    // Disabled for local-first fork: PostHogManager.shared.track("App Crash Detected", ...)
  }

  // MARK: - App Lifecycle Events

  func appLaunched() {}

  func trackStartupTiming(
    dbInitMs: Double, timeToInteractiveMs: Double, hadUncleanShutdown: Bool,
    databaseInitFailed: Bool
  ) {}

  /// Track first launch with comprehensive system diagnostics.
  func trackFirstLaunchIfNeeded() {}

  func appBecameActive() {}
  func appResignedActive() {}

  // MARK: - Conversation Events

  func conversationCreated(conversationId: String, source: String, durationSeconds: Int? = nil) {}
  func memoryDeleted(conversationId: String) {}
  func memoryShareButtonClicked(conversationId: String) {}
  func shareAction(category: String, properties: [String: Any] = [:]) {}
  func memoryListItemClicked(conversationId: String) {}

  // MARK: - Chat Events

  func chatMessageSent(messageLength: Int, hasContext: Bool = false, source: String) {}

  // MARK: - Search Events

  func searchQueryEntered(query: String) {}
  func searchBarFocused() {}

  // MARK: - Settings Events

  func settingsPageOpened() {}

  // MARK: - Page/Screen Views

  func pageViewed(_ pageName: String) {}

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
  func chatSessionCreated() {}
  func chatSessionDeleted() {}
  func messageRated(rating: Int) {}
  func initialMessageGenerated(hasApp: Bool) {}
  func sessionTitleGenerated() {}
  func chatStarredFilterToggled(enabled: Bool) {}
  func sessionRenamed() {}

  // MARK: - Claude Agent Events

  func chatAgentQueryCompleted(
    durationMs: Int,
    toolCallCount: Int,
    toolNames: [String],
    costUsd: Double,
    messageLength: Int
  ) {}

  func chatToolCallCompleted(toolName: String, durationMs: Int) {}

  func chatAgentError(error: String, rawError: String? = nil) {}

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
  func updateCheckFailed(
    error: String, errorDomain: String, errorCode: Int, underlyingError: String? = nil,
    underlyingDomain: String? = nil, underlyingCode: Int? = nil
  ) {}

  // MARK: - Notification Events

  func notificationSent(notificationId: String, title: String, assistantId: String, surface: String)
  {}
  func notificationClicked(
    notificationId: String, title: String, assistantId: String, surface: String
  ) {}
  func notificationDismissed(
    notificationId: String, title: String, assistantId: String, surface: String
  ) {}
  func notificationWillPresent(notificationId: String, title: String) {}
  func notificationDelegateReady() {}

  // MARK: - Menu Bar Events

  func menuBarOpened() {}
  func menuBarActionClicked(action: String) {}

  // MARK: - Tier Events

  func tierChanged(tier: Int, reason: String) {}
  func chatBridgeModeChanged(from oldMode: String, to newMode: String) {}

  // MARK: - Settings State

  func trackSettingsState(
    screenshotsEnabled: Bool, memoryExtractionEnabled: Bool, memoryNotificationsEnabled: Bool
  ) {}

  /// Report comprehensive settings state on app launch.
  func reportAllSettingsIfNeeded() {}

  // MARK: - Floating Bar Events

  func floatingBarToggled(visible: Bool, source: String) {}
  func floatingBarAskOmiOpened(source: String) {}
  func floatingBarAskOmiClosed() {}
  func floatingBarQuerySent(messageLength: Int, hasScreenshot: Bool) {}
  func floatingBarPTTStarted(mode: String) {}
  func floatingBarPTTEnded(mode: String, hadTranscript: Bool, transcriptLength: Int) {}

  // MARK: - Knowledge Graph Events

  func knowledgeGraphBuildStarted(filesIndexed: Int, hadExistingGraph: Bool) {}
  func knowledgeGraphBuildCompleted(
    nodeCount: Int, edgeCount: Int, pollAttempts: Int, hadExistingGraph: Bool
  ) {}
  func knowledgeGraphBuildFailed(reason: String, pollAttempts: Int, filesIndexed: Int) {}

  // MARK: - Display Info

  func trackDisplayInfo() {}
}
