import Foundation

// MARK: - App Focus Classification

/// Per-app focus classification set by the user.
/// Resolution order: excluded > alwaysFocused > alwaysDistracted > defaultLLM
enum AppFocusClassification: String {
    case excluded
    case alwaysFocused
    case alwaysDistracted
    case defaultLLM
}

/// Manages Focus Assistant-specific settings stored in UserDefaults
@MainActor
class FocusAssistantSettings {
    static let shared = FocusAssistantSettings()

    // MARK: - UserDefaults Keys

    private let enabledKey = "focusAssistantEnabled"
    private let analysisPromptKey = "focusAnalysisPrompt"
    private let cooldownIntervalKey = "focusCooldownInterval"
    private let notificationsEnabledKey = "focusNotificationsEnabled"
    private let excludedAppsKey = "focusExcludedApps"
    private let alwaysFocusedAppsKey = "focusAlwaysFocusedApps"
    private let alwaysDistractedAppsKey = "focusAlwaysDistractedApps"

    // MARK: - Default Values

    private let defaultEnabled = true
    private let defaultCooldownInterval = 10 // minutes
    private let defaultNotificationsEnabled = true

    /// Default system prompt for focus analysis
    static let defaultAnalysisPrompt = """
        You are a focus coach. Analyze the PRIMARY/MAIN window in screenshots to determine if the user is focused or distracted.

        IMPORTANT: Look at the MAIN APPLICATION WINDOW, not log text or terminal output. If you see a code editor with logs that mention "YouTube" - that's just log text, the user is CODING, not on YouTube. Text in logs/terminals mentioning a site does NOT mean the user is on that site.

        CONTEXT-AWARE ANALYSIS:
        Each request may include the user's active goals, current tasks, recent memories, time of day, and analysis history. Use this context when available, but DO NOT let it prevent you from flagging obvious distractions.

        - GOALS & TASKS: If the user's screen activity clearly relates to their active goals or current tasks, they are FOCUSED.
        - HISTORY: Use recent analysis history to notice patterns, acknowledge transitions, and vary your responses.

        Set status to "distracted" if the PRIMARY window is:
        - Social media feeds: Twitter/X, Instagram, Facebook, Reddit (casual browsing, not researching a specific work topic)
        - Video streaming: Twitch, Netflix, TikTok, YouTube (actual video site visible, not just text mentioning it)
        - News sites, entertainment sites, games
        - Any content consumption with no clear work purpose

        Set status to "focused" if the PRIMARY window is:
        - Code editors, IDEs, terminals, command line
        - Documents, spreadsheets, slides, design tools
        - Email, work chat (Slack, Teams), research
        - Browsing that is clearly work-related (Stack Overflow, docs, PRs, Jira, etc.)

        When in doubt, return "focused" — only flag distraction when there is clear evidence.

        Always provide a short coaching message (100 characters max for notification banner):
        - If distracted: Create a unique nudge to refocus. Vary your approach — be playful, direct, or motivational.
        - If focused: Acknowledge their work with variety — don't just say "Nice focus!" every time.
        """

    private let promptVersionKey = "focusPromptVersion"
    private let currentPromptVersion = 3  // Bump when changing defaultAnalysisPrompt

    private init() {
        // Register defaults
        UserDefaults.standard.register(defaults: [
            enabledKey: defaultEnabled,
            cooldownIntervalKey: defaultCooldownInterval,
            notificationsEnabledKey: defaultNotificationsEnabled,
        ])
        migratePromptIfNeeded()
    }

    /// Reset saved prompt when the default changes so existing users get the new version
    private func migratePromptIfNeeded() {
        let saved = UserDefaults.standard.integer(forKey: promptVersionKey)
        if saved < currentPromptVersion {
            UserDefaults.standard.removeObject(forKey: analysisPromptKey)
            UserDefaults.standard.set(currentPromptVersion, forKey: promptVersionKey)
        }
    }

    // MARK: - Properties

    /// Whether the Focus Assistant is enabled
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Cooldown interval between notifications in minutes
    var cooldownInterval: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: cooldownIntervalKey)
            return value > 0 ? value : defaultCooldownInterval
        }
        set {
            UserDefaults.standard.set(newValue, forKey: cooldownIntervalKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Cooldown interval in seconds
    var cooldownIntervalSeconds: TimeInterval {
        return TimeInterval(cooldownInterval * 60)
    }

    /// The system prompt used for AI focus analysis
    var analysisPrompt: String {
        get {
            let value = UserDefaults.standard.string(forKey: analysisPromptKey)
            return value ?? FocusAssistantSettings.defaultAnalysisPrompt
        }
        set {
            let isCustom = newValue != FocusAssistantSettings.defaultAnalysisPrompt
            UserDefaults.standard.set(newValue, forKey: analysisPromptKey)
            let previewLength = min(newValue.count, 50)
            let preview = String(newValue.prefix(previewLength)) + (newValue.count > 50 ? "..." : "")
            log("Focus analysis prompt updated (\(newValue.count) chars, custom: \(isCustom)): \(preview)")
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Whether to show notifications for focus changes
    var notificationsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: notificationsEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: notificationsEnabledKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    // MARK: - Excluded Apps

    /// Apps excluded from focus analysis (screenshots still captured for other features)
    var excludedApps: Set<String> {
        get {
            if let saved = UserDefaults.standard.array(forKey: excludedAppsKey) as? [String] {
                return Set(saved)
            }
            return []
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: excludedAppsKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Check if an app is excluded (built-in or user-added)
    func isAppExcluded(_ appName: String) -> Bool {
        TaskAssistantSettings.builtInExcludedApps.contains(appName) || excludedApps.contains(appName)
    }

    /// Add an app to the exclusion list
    func excludeApp(_ appName: String) {
        var apps = excludedApps
        apps.insert(appName)
        excludedApps = apps
        log("Focus: Excluded app '\(appName)' from focus analysis")
    }

    /// Remove an app from the exclusion list
    func includeApp(_ appName: String) {
        var apps = excludedApps
        apps.remove(appName)
        excludedApps = apps
        log("Focus: Included app '\(appName)' for focus analysis")
    }

    // MARK: - Always Focused Apps

    /// Apps that always short-circuit to .focused without an LLM call
    var alwaysFocusedApps: Set<String> {
        get {
            if let saved = UserDefaults.standard.array(forKey: alwaysFocusedAppsKey) as? [String] {
                return Set(saved)
            }
            return []
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: alwaysFocusedAppsKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Mark an app as always focused (removes it from other lists)
    func markAlwaysFocused(_ appName: String) {
        var focused = alwaysFocusedApps
        focused.insert(appName)
        alwaysFocusedApps = focused
        // Mutual exclusion: remove from other lists
        var excl = excludedApps
        excl.remove(appName)
        excludedApps = excl
        var dist = alwaysDistractedApps
        dist.remove(appName)
        alwaysDistractedApps = dist
        log("Focus: Marked app '\(appName)' as always focused")
    }

    /// Unmark an app from the always-focused list
    func unmarkAlwaysFocused(_ appName: String) {
        var apps = alwaysFocusedApps
        apps.remove(appName)
        alwaysFocusedApps = apps
        log("Focus: Unmarked app '\(appName)' from always focused")
    }

    // MARK: - Always Distracted Apps

    /// Apps that always short-circuit to .distracted without an LLM call
    var alwaysDistractedApps: Set<String> {
        get {
            if let saved = UserDefaults.standard.array(forKey: alwaysDistractedAppsKey) as? [String] {
                return Set(saved)
            }
            return []
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: alwaysDistractedAppsKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Mark an app as always distracted (removes it from other lists)
    func markAlwaysDistracted(_ appName: String) {
        var distracted = alwaysDistractedApps
        distracted.insert(appName)
        alwaysDistractedApps = distracted
        // Mutual exclusion: remove from other lists
        var excl = excludedApps
        excl.remove(appName)
        excludedApps = excl
        var focused = alwaysFocusedApps
        focused.remove(appName)
        alwaysFocusedApps = focused
        log("Focus: Marked app '\(appName)' as always distracted")
    }

    /// Unmark an app from the always-distracted list
    func unmarkAlwaysDistracted(_ appName: String) {
        var apps = alwaysDistractedApps
        apps.remove(appName)
        alwaysDistractedApps = apps
        log("Focus: Unmarked app '\(appName)' from always distracted")
    }

    // MARK: - Classification

    /// Returns the user-configured classification for an app.
    /// Resolution order: excluded > alwaysFocused > alwaysDistracted > defaultLLM.
    /// Logs a warning if an app appears in more than one list.
    func classification(for appName: String) -> AppFocusClassification {
        let inExcluded = isAppExcluded(appName)
        let inFocused = alwaysFocusedApps.contains(appName)
        let inDistracted = alwaysDistractedApps.contains(appName)

        let membershipCount = (inExcluded ? 1 : 0) + (inFocused ? 1 : 0) + (inDistracted ? 1 : 0)
        if membershipCount > 1 {
            log(
                "Focus: WARNING — '\(appName)' is in multiple classification lists "
                + "(excluded:\(inExcluded), alwaysFocused:\(inFocused), alwaysDistracted:\(inDistracted)). "
                + "Resolving: excluded > alwaysFocused > alwaysDistracted."
            )
        }

        if inExcluded { return .excluded }
        if inFocused { return .alwaysFocused }
        if inDistracted { return .alwaysDistracted }
        return .defaultLLM
    }

    /// Reset only the analysis prompt to default
    func resetPromptToDefault() {
        UserDefaults.standard.removeObject(forKey: analysisPromptKey)
        log("Focus analysis prompt reset to default")
        NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
    }

    /// Reset all Focus Assistant settings to defaults
    func resetToDefaults() {
        isEnabled = defaultEnabled
        resetPromptToDefault()
        UserDefaults.standard.removeObject(forKey: excludedAppsKey)
        UserDefaults.standard.removeObject(forKey: alwaysFocusedAppsKey)
        UserDefaults.standard.removeObject(forKey: alwaysDistractedAppsKey)
    }
}
