import Foundation

/// Task extraction assistant that identifies tasks and action items from screen content
/// Uses single-stage Gemini tool calling with vector + FTS5 search for deduplication
actor TaskAssistant: ProactiveAssistant {
    // MARK: - ProactiveAssistant Protocol

    nonisolated let identifier = "task-extraction"
    nonisolated let displayName = "Task Extractor"

    var isEnabled: Bool {
        get async {
            await MainActor.run {
                TaskAssistantSettings.shared.isEnabled
            }
        }
    }

    // MARK: - Properties

    private var isRunning = false
    private var previousTasks: [ExtractedTask] = [] // Last 10 extracted tasks for context
    private let maxPreviousTasks = 10
    private var currentApp: String?
    private var processingTask: Task<Void, Never>?

    // MARK: - Event-Driven Trigger System
    private enum TriggerEvent {
        case contextSwitch(CapturedFrame)  // departing frame from context being left
        case timerFallback(CapturedFrame)  // latest frame after extraction interval
    }

    private let triggerStream: AsyncStream<TriggerEvent>
    private let triggerContinuation: AsyncStream<TriggerEvent>.Continuation

    /// Always holds the most recent frame for fallback timer use
    private var latestFrame: CapturedFrame?
    /// Fallback timer that fires after extractionInterval if no context switch occurs
    private var fallbackTimerTask: Task<Void, Never>?
    /// Timestamp of last context switch yield, for throttling rapid switches
    private var lastContextSwitchYieldTime: Date = .distantPast

    // Cached goals (refreshed every 5 minutes)
    private var cachedGoals: [Goal] = []
    private var lastGoalsRefresh: Date = .distantPast
    private let goalsRefreshInterval: TimeInterval = 300

    // MARK: - Due Date Helpers

    /// Parse an inferred deadline string into a Date, or default to end of today.
    /// Tries ISO8601, then common natural language patterns.
    private func parseDueDate(from inferredDeadline: String?) -> Date? {
        guard let deadline = inferredDeadline, !deadline.isEmpty else {
            return nil
        }
        let startOfToday = Calendar.current.startOfDay(for: Date())

        // Try ISO8601 first (e.g. "2025-10-04T14:00:00Z")
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: deadline) {
            if date < startOfToday {
                log("Task: Rejected past due date '\(deadline)' → \(date). Today is \(Date()). Due dates must be today or in the future.")
                return nil
            }
            return date
        }
        // Try common date formats
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd",
            "MM/dd/yyyy",
            "MMMM d, yyyy",
            "MMM d, yyyy",
            "MMMM d",
            "MMM d"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: deadline) {
                if date < startOfToday {
                    log("Task: Rejected past due date '\(deadline)' → \(date). Today is \(Date()). Due dates must be today or in the future.")
                    return nil
                }
                return date
            }
        }

        // Fallback: try macOS natural language date parsing (handles "Thursday", "next week", etc.)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        if let match = detector?.firstMatch(in: deadline, range: NSRange(deadline.startIndex..., in: deadline)),
           let date = match.date {
            // Validate that the parsed date is not in the past
            let startOfToday = Calendar.current.startOfDay(for: Date())
            if date < startOfToday {
                log("Task: Rejected past due date '\(deadline)' → \(date). Today is \(Date()). Due dates must be today or in the future.")
                return nil
            }
            return date
        }

        log("Task: Could not parse inferred_deadline '\(deadline)', skipping deadline")
        return nil
    }

    /// Returns 11:59 PM today in the user's local timezone
    private static func endOfToday() -> Date {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        return calendar.date(bySettingHour: 23, minute: 59, second: 0, of: startOfDay) ?? startOfDay
    }

    /// Get the current system prompt from settings (accessed on MainActor for thread safety)
    private var systemPrompt: String {
        get async {
            await MainActor.run {
                TaskAssistantSettings.shared.analysisPrompt
            }
        }
    }

    /// Get the extraction interval from settings
    private var extractionInterval: TimeInterval {
        get async {
            await MainActor.run {
                TaskAssistantSettings.shared.extractionInterval
            }
        }
    }

    /// Get the minimum confidence threshold from settings
    private var minConfidence: Double {
        get async {
            await MainActor.run {
                TaskAssistantSettings.shared.minConfidence
            }
        }
    }

    // MARK: - Initialization

    init(apiKey: String? = nil) throws {
        // Infinite Recall fork: LLM client is resolved lazily per-call via
        // AIProviderRegistry; constructor never fails on missing provider.
        // NOTE: this assistant relies on multi-turn tool calling + vision, which
        // the v1 local provider doesn't yet support. The processing loop logs
        // and skips extraction until tool-calling support lands.
        // TODO(local-tools): wire the search_similar / extract_task tool loop
        // through a local function-calling model.

        let (stream, continuation) = AsyncStream.makeStream(of: TriggerEvent.self, bufferingPolicy: .bufferingNewest(1))
        self.triggerStream = stream
        self.triggerContinuation = continuation

        // Start processing loop + embedding index
        Task {
            await self.startProcessing()
            await self.initializeEmbeddings()
        }
    }

    // MARK: - Embedding Lifecycle

    /// Load embedding index and kick off backfill
    private func initializeEmbeddings() async {
        await EmbeddingService.shared.loadIndex()
        // Backfill in background
        Task {
            await EmbeddingService.shared.backfillIfNeeded()
        }
    }

    // MARK: - Processing

    private func startProcessing() {
        isRunning = true
        processingTask = Task {
            await processLoop()
        }
    }

    private func processLoop() async {
        log("Task assistant started (event-driven)")

        for await trigger in triggerStream {
            guard isRunning else { break }

            let (frame, triggerType): (CapturedFrame, String) = {
                switch trigger {
                case .contextSwitch(let f): return (f, "context_switch")
                case .timerFallback(let f): return (f, "timer_fallback")
                }
            }()

            log("Task: Processing \(triggerType) trigger from \(frame.appName) (window: \(frame.windowTitle ?? "nil"))")

            // Cancel fallback timer before processing
            fallbackTimerTask?.cancel()
            fallbackTimerTask = nil

            await processFrame(frame)

            // Start a new fallback timer after processing
            startFallbackTimer()
        }

        log("Task assistant stopped")
    }

    /// Start (or restart) the fallback timer that fires after extractionInterval
    private func startFallbackTimer() {
        fallbackTimerTask?.cancel()
        fallbackTimerTask = Task {
            let interval = await self.extractionInterval
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let frame = self.latestFrame else { return }
            log("Task: Fallback timer fired after \(Int(interval))s")
            self.triggerContinuation.yield(.timerFallback(frame))
        }
    }

    // MARK: - Test Analysis (for test runner)

    /// Run the extraction pipeline on arbitrary JPEG data without side effects (no saving, no events).
    /// Used by the test runner to replay past screenshots.
    /// Returns (result, searchCount) where searchCount is the number of search tool calls made.
    func testAnalyze(jpegData: Data, appName: String) async throws -> (TaskExtractionResult?, Int) {
        return try await extractTaskSingleStage(from: jpegData, appName: appName)
    }

    // MARK: - ProactiveAssistant Protocol Methods

    func shouldAnalyze(frameNumber: Int, timeSinceLastAnalysis: TimeInterval) -> Bool {
        return true
    }

    func analyze(frame: CapturedFrame) async -> AssistantResult? {
        // Only analyze apps on the whitelist
        let allowed = await MainActor.run { TaskAssistantSettings.shared.isAppAllowed(frame.appName) }
        if !allowed {
            return nil
        }

        // For browser apps, also check window title against enabled heuristics
        let windowAllowed = await MainActor.run {
            TaskAssistantSettings.shared.isWindowAllowed(appName: frame.appName, windowTitle: frame.windowTitle)
        }
        if !windowAllowed {
            return nil
        }

        // Store as latest frame (used by fallback timer and context switch)
        latestFrame = frame

        // Start fallback timer if not already running
        if fallbackTimerTask == nil {
            startFallbackTimer()
        }

        return nil
    }

    func handleResult(_ result: AssistantResult, sendEvent: @escaping (String, [String: Any]) -> Void) async {
        guard let taskResult = result as? TaskExtractionResult else { return }
        await handleResultWithScreenshot(taskResult, screenshotId: nil, appName: "Unknown", sendEvent: sendEvent)
    }

    /// Handle result with screenshot ID for SQLite storage
    private func handleResultWithScreenshot(
        _ taskResult: TaskExtractionResult,
        screenshotId: Int64?,
        appName: String,
        windowTitle: String? = nil,
        sendEvent: @escaping (String, [String: Any]) -> Void
    ) async {
        // Save observation for every result (fire-and-forget)
        let observationApp = taskResult.task?.sourceApp ?? appName
        let observation = ObservationRecord(
            screenshotId: screenshotId,
            appName: observationApp,
            contextSummary: taskResult.contextSummary,
            currentActivity: taskResult.currentActivity,
            hasTask: taskResult.hasNewTask,
            taskTitle: taskResult.task?.title,
            sourceCategory: taskResult.task?.sourceCategory,
            sourceSubcategory: taskResult.task?.sourceSubcategory,
            createdAt: Date()
        )
        Task {
            do {
                try await ActionItemStorage.shared.insertObservation(observation)
            } catch {
                logError("Task: Failed to insert observation", error: error)
            }
        }

        guard taskResult.hasNewTask, let task = taskResult.task else {
            return
        }

        let threshold = await minConfidence
        let confidencePercent = Int(task.confidence * 100)

        guard task.confidence >= threshold else {
            log("Task: [\(confidencePercent)% < \(Int(threshold * 100))%] Filtered: \"\(task.title)\"")
            return
        }

        log("Task: [\(confidencePercent)% conf.] \"\(task.title)\"")

        previousTasks.insert(task, at: 0)
        if previousTasks.count > maxPreviousTasks {
            previousTasks.removeLast()
        }

        // Save to staged_tasks SQLite + generate embedding
        let extractionRecord = await saveTaskToSQLite(
            task: task,
            screenshotId: screenshotId,
            contextSummary: taskResult.contextSummary,
            windowTitle: windowTitle
        )

        // Generate embedding for new staged task in background
        if let recordId = extractionRecord?.id {
            Task {
                await self.generateEmbeddingForTask(id: recordId, text: task.title)
            }
        }

        // Sync to backend (staged_tasks)
        if let backendId = await syncTaskToBackend(task: task, taskResult: taskResult, windowTitle: windowTitle) {
            if let recordId = extractionRecord?.id {
                do {
                    try await StagedTaskStorage.shared.markSynced(id: recordId, backendId: backendId)
                } catch {
                    logError("Task: Failed to update sync status", error: error)
                }
            }
        }

        await MainActor.run {
            AnalyticsManager.shared.taskExtracted(taskCount: 1)
        }

        sendEvent("taskExtracted", [
            "assistant": identifier,
            "task": task.toDictionary(),
            "contextSummary": taskResult.contextSummary
        ])
    }

    /// Generate embedding for a newly saved staged task and store it
    private func generateEmbeddingForTask(id: Int64, text: String) async {
        do {
            let embedding = try await EmbeddingService.shared.embed(text: text)
            let data = await EmbeddingService.shared.floatsToData(embedding)
            try await StagedTaskStorage.shared.updateEmbedding(id: id, embedding: data)
            await EmbeddingService.shared.addToIndex(id: id, embedding: embedding)
            log("Task: Generated embedding for staged task \(id)")
        } catch {
            logError("Task: Failed to generate embedding for staged task \(id)", error: error)
        }
    }

    /// Save extracted task to staged_tasks SQLite table
    private func saveTaskToSQLite(
        task: ExtractedTask,
        screenshotId: Int64?,
        contextSummary: String,
        windowTitle: String? = nil
    ) async -> StagedTaskRecord? {
        var metadata: [String: Any] = [
            "tags": task.tags,
            "context_summary": contextSummary,
            "source_category": task.sourceCategory,
            "source_subcategory": task.sourceSubcategory
        ]
        if let primaryTag = task.primaryTag {
            metadata["category"] = primaryTag
        }
        if let deadline = task.inferredDeadline {
            metadata["inferred_deadline"] = deadline
        }
        if let windowTitle = windowTitle {
            metadata["window_title"] = windowTitle
        }

        let metadataJson: String?
        if let data = try? JSONSerialization.data(withJSONObject: metadata),
           let json = String(data: data, encoding: .utf8) {
            metadataJson = json
        } else {
            metadataJson = nil
        }

        let tagsJson: String?
        if let data = try? JSONEncoder().encode(task.tags),
           let json = String(data: data, encoding: .utf8) {
            tagsJson = json
        } else {
            tagsJson = nil
        }

        let dueAt = parseDueDate(from: task.inferredDeadline)

        let record = StagedTaskRecord(
            backendSynced: false,
            description: task.title,
            source: "screenshot",
            priority: task.priority.rawValue,
            category: task.primaryTag,
            tagsJson: tagsJson,
            dueAt: dueAt,
            screenshotId: screenshotId,
            confidence: task.confidence,
            sourceApp: task.sourceApp,
            windowTitle: windowTitle,
            contextSummary: contextSummary,
            metadataJson: metadataJson,
            relevanceScore: task.relevanceScore,
            scoredAt: task.relevanceScore != nil ? Date() : nil
        )

        do {
            let inserted: StagedTaskRecord
            if task.relevanceScore != nil {
                inserted = try await StagedTaskStorage.shared.insertWithScoreShift(record)
            } else {
                inserted = try await StagedTaskStorage.shared.insertLocalStagedTask(record)
            }
            log("Task: Saved to staged_tasks (id: \(inserted.id ?? -1), score: \(task.relevanceScore.map { String($0) } ?? "nil"))")
            return inserted
        } catch {
            logError("Task: Failed to save to staged_tasks", error: error)
            return nil
        }
    }

    /// Sync task to backend API, returns backend ID if successful
    private func syncTaskToBackend(task: ExtractedTask, taskResult: TaskExtractionResult, windowTitle: String? = nil) async -> String? {
        do {
            var metadata: [String: Any] = [
                "source_app": task.sourceApp,
                "confidence": task.confidence,
                "context_summary": taskResult.contextSummary,
                "current_activity": taskResult.currentActivity,
                "tags": task.tags,
                "source_category": task.sourceCategory,
                "source_subcategory": task.sourceSubcategory
            ]
            if let primaryTag = task.primaryTag {
                metadata["category"] = primaryTag
            }
            if let reasoning = task.description {
                metadata["reasoning"] = reasoning
            }
            if let deadline = task.inferredDeadline {
                metadata["inferred_deadline"] = deadline
            }
            if let windowTitle = windowTitle {
                metadata["window_title"] = windowTitle
            }

            let dueAt = parseDueDate(from: task.inferredDeadline)

            let response = try await APIClient.shared.createStagedTask(
                description: task.title,
                dueAt: dueAt,
                source: "screenshot",
                priority: task.priority.rawValue,
                category: task.primaryTag,
                metadata: metadata,
                relevanceScore: task.relevanceScore
            )

            log("Task: Synced to staged_tasks backend (id: \(response.id))")
            return response.id
        } catch {
            logError("Task: Failed to sync to backend", error: error)
            return nil
        }
    }

    func onAppSwitch(newApp: String) async {
        if newApp != currentApp {
            if let currentApp = currentApp {
                log("Task: APP SWITCH: \(currentApp) -> \(newApp)")
            } else {
                log("Task: Active app: \(newApp)")
            }
            currentApp = newApp
        }
    }

    func onContextSwitch(departingFrame: CapturedFrame?, newApp: String, newWindowTitle: String?) async {
        // Use latestFrame if departing frame is unavailable or stale (from a different app due to delay periods)
        let frame: CapturedFrame? = {
            if let departing = departingFrame {
                return departing
            }
            return latestFrame
        }()

        guard let frame = frame else {
            log("Task: Context switch but no frame available")
            return
        }

        // Check frame's app is on the whitelist
        let allowed = await MainActor.run { TaskAssistantSettings.shared.isAppAllowed(frame.appName) }
        if !allowed {
            log("Task: Context switch from non-whitelisted app '\(frame.appName)', skipping")
            // Still cancel fallback timer on any context switch
            fallbackTimerTask?.cancel()
            fallbackTimerTask = nil
            return
        }

        // Check window is allowed for browser apps
        let windowAllowed = await MainActor.run {
            TaskAssistantSettings.shared.isWindowAllowed(appName: frame.appName, windowTitle: frame.windowTitle)
        }
        if !windowAllowed {
            log("Task: Context switch from filtered browser window, skipping")
            fallbackTimerTask?.cancel()
            fallbackTimerTask = nil
            return
        }

        log("Task: Context switch from \(frame.appName) (window: \(frame.windowTitle ?? "nil")) -> \(newApp)")

        // Throttle context switch yields using the analysis delay setting
        let analysisDelay = await MainActor.run { AssistantSettings.shared.analysisDelay }
        if analysisDelay > 0 {
            let elapsed = Date().timeIntervalSince(lastContextSwitchYieldTime)
            if elapsed < TimeInterval(analysisDelay) {
                log("Task: Context switch throttled (\(Int(elapsed))s < \(analysisDelay)s delay)")
                // Still cancel fallback timer so it resets
                fallbackTimerTask?.cancel()
                fallbackTimerTask = nil
                return
            }
        }

        // Cancel fallback timer — context switch replaces it
        fallbackTimerTask?.cancel()
        fallbackTimerTask = nil

        // Yield context switch trigger with the frame
        lastContextSwitchYieldTime = Date()
        triggerContinuation.yield(.contextSwitch(frame))
    }

    func clearPendingWork() async {
        fallbackTimerTask?.cancel()
        fallbackTimerTask = nil
        log("Task: Cleared fallback timer")
    }

    func stop() async {
        isRunning = false
        fallbackTimerTask?.cancel()
        fallbackTimerTask = nil
        triggerContinuation.finish()
        processingTask?.cancel()
        latestFrame = nil
    }

    // MARK: - Single-Stage Analysis with Tool Calling

    private func processFrame(_ frame: CapturedFrame) async {
        let enabled = await isEnabled
        guard enabled else {
            log("Task: Skipping analysis (disabled)")
            return
        }

        log("Task: Analyzing frame from \(frame.appName)...")
        do {
            let (result, searchCount) = try await extractTaskSingleStage(from: frame.jpegData, appName: frame.appName)
            guard let result = result else {
                log("Task: Analysis returned no result")
                return
            }

            log("Task: Analysis complete - hasNewTask: \(result.hasNewTask), context: \(result.contextSummary), searches: \(searchCount)")

            await handleResultWithScreenshot(result, screenshotId: frame.screenshotId, appName: frame.appName, windowTitle: frame.windowTitle) { type, data in
                Task { @MainActor in
                    AssistantCoordinator.shared.sendEvent(type: type, data: data)
                }
            }
        } catch {
            logError("Task extraction error", error: error)
        }
    }

    /// Loop-based extraction: image analysis + iterative tool calling for search + terminal tool for decision
    /// Returns (result, searchCount) where searchCount is the number of search tool calls made.
    private func extractTaskSingleStage(from jpegData: Data, appName: String) async throws -> (TaskExtractionResult?, Int) {
        // Infinite Recall fork: this flow requires multi-turn tool calling
        // (search_similar / search_keywords / extract_task) plus vision, which
        // the v1 local LLM provider doesn't expose. Bail out cleanly until a
        // tool-capable provider lands in AIProviderRegistry.
        // TODO(local-tools): re-implement with a local function-calling model.
        guard await LLMBridge.currentClient() != nil else {
            log("[TaskAssistant] no LLM client available — skipping task extraction")
            return (nil, 0)
        }
        log("[TaskAssistant] tool-calling not supported by current LLM provider — skipping task extraction (TODO: local tool calls)")
        return (nil, 0)
    }

    // MARK: - Title Validation

    /// Validates a task title for minimum specificity. Returns an error message if invalid, nil if OK.
    private static func validateTaskTitle(_ title: String, wordCount: Int) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // Must not be empty
        if trimmed.isEmpty {
            return "Title is empty"
        }

        // Minimum 6 words
        if wordCount < 6 {
            return "Title too short (\(wordCount) words, minimum 6)"
        }

        // Reject titles that are purely generic verbs with no specifics
        let genericPatterns: [String] = [
            "investigate", "check logs", "clean up", "look into",
            "look through", "update to", "fix the", "review the",
            "check the", "modify the", "track the"
        ]
        let lowered = trimmed.lowercased()
        for pattern in genericPatterns {
            // If the entire title is just a generic pattern (possibly with 1-2 filler words), reject
            if lowered == pattern || (wordCount <= 4 && lowered.hasPrefix(pattern)) {
                return "Title too generic (matches vague pattern '\(pattern)')"
            }
        }

        // Must contain at least one capitalized proper noun (person, project, app name)
        // Heuristic: after the first word (verb), there should be at least one word starting with uppercase
        let words = trimmed.split(separator: " ")
        let hasProperNoun = words.dropFirst().contains { word in
            guard let first = word.first else { return false }
            return first.isUppercase
        }
        if !hasProperNoun {
            return "Title lacks a specific name (person, project, or app) — no proper nouns found after the verb"
        }

        return nil
    }

    // MARK: - Context & Search

    /// Refresh context from local SQLite + cached goals
    private func refreshContext() async -> TaskExtractionContext {
        var topRelevanceTasks: [(id: Int64, description: String, priority: String?, relevanceScore: Int?)] = []
        var recentTasks: [(id: Int64, description: String, priority: String?, relevanceScore: Int?)] = []
        var completedTasks: [(id: Int64, description: String)] = []
        var deletedTasks: [(id: Int64, description: String)] = []

        // Query both action_items (promoted + manual) and staged_tasks for full context
        do {
            topRelevanceTasks = try await ActionItemStorage.shared.getTopRelevanceTasks(limit: 30)
        } catch {
            logError("Task: Failed to load top relevance tasks", error: error)
        }

        do {
            recentTasks = try await ActionItemStorage.shared.getRecentActiveTasks(limit: 30)
        } catch {
            logError("Task: Failed to load recent tasks", error: error)
        }

        // Also include staged tasks for dedup context
        do {
            let stagedTasks = try await StagedTaskStorage.shared.getAllStagedTasks(limit: 30)
            let stagedAsTuples = stagedTasks.map { task in
                (id: Int64(0), description: task.description, priority: task.priority, relevanceScore: task.relevanceScore)
            }
            recentTasks.append(contentsOf: stagedAsTuples)
        } catch {
            logError("Task: Failed to load staged tasks for context", error: error)
        }

        // Merge: top relevance tasks first, then recent ones not already included
        let topIds = Set(topRelevanceTasks.map { $0.id })
        let activeTasks = topRelevanceTasks + recentTasks.filter { !topIds.contains($0.id) }

        do {
            completedTasks = try await ActionItemStorage.shared.getRecentCompletedTasks(limit: 10)
        } catch {
            logError("Task: Failed to load completed tasks", error: error)
        }

        do {
            deletedTasks = try await ActionItemStorage.shared.getRecentDeletedTasks(limit: 10, deletedBy: "user")
        } catch {
            logError("Task: Failed to load deleted tasks", error: error)
        }

        // Refresh goals if stale
        let timeSinceGoals = Date().timeIntervalSince(lastGoalsRefresh)
        if timeSinceGoals >= goalsRefreshInterval {
            do {
                cachedGoals = try await APIClient.shared.getGoals()
                lastGoalsRefresh = Date()
                log("Task: Refreshed \(cachedGoals.count) goals")
            } catch {
                logError("Task: Failed to refresh goals", error: error)
            }
        }

        return TaskExtractionContext(
            activeTasks: activeTasks,
            completedTasks: completedTasks,
            deletedTasks: deletedTasks,
            goals: cachedGoals
        )
    }

    /// Execute vector similarity search
    private func executeVectorSearch(query: String) async -> [TaskSearchResult] {
        var results: [TaskSearchResult] = []

        do {
            let queryEmbedding = try await EmbeddingService.shared.embed(text: query)
            let vectorResults = await EmbeddingService.shared.searchSimilar(query: queryEmbedding, topK: 10)

            for result in vectorResults where result.similarity > 0.3 {
                if let record = try await ActionItemStorage.shared.getActionItem(id: result.id) {
                    let status: String
                    if record.deleted { status = "deleted" }
                    else if record.completed { status = "completed" }
                    else { status = "active" }

                    results.append(TaskSearchResult(
                        id: result.id,
                        description: record.description,
                        status: status,
                        similarity: Double(result.similarity),
                        matchType: "vector",
                        relevanceScore: record.relevanceScore
                    ))
                } else if let staged = try await StagedTaskStorage.shared.getStagedTask(id: result.id) {
                    // Fallback: ID belongs to a staged task (shared embedding index)
                    let status: String
                    if staged.deleted { status = "deleted" }
                    else if staged.completed { status = "completed" }
                    else { status = "active" }

                    results.append(TaskSearchResult(
                        id: result.id,
                        description: staged.description,
                        status: status,
                        similarity: Double(result.similarity),
                        matchType: "vector",
                        relevanceScore: staged.relevanceScore
                    ))
                }
            }
        } catch {
            logError("Task: Vector search failed", error: error)
        }

        return results.sorted { ($0.similarity ?? 0) > ($1.similarity ?? 0) }
    }

    /// Execute FTS5 keyword search (searches both action_items and staged_tasks)
    private func executeKeywordSearch(query: String) async -> [TaskSearchResult] {
        var results: [TaskSearchResult] = []

        do {
            let words = query.components(separatedBy: .whitespaces)
                .map { $0.filter { $0.isLetter || $0.isNumber } }  // Strip FTS5 special chars (- : * " etc.)
                .filter { $0.count >= 3 }
            let ftsQuery = words.map { "\($0)*" }.joined(separator: " OR ")

            if !ftsQuery.isEmpty {
                // Search action_items (promoted + manual)
                let ftsResults = try await ActionItemStorage.shared.searchFTS(
                    query: ftsQuery,
                    limit: 10,
                    includeCompleted: true,
                    includeDeleted: true
                )

                for result in ftsResults {
                    let status: String
                    if result.deleted { status = "deleted" }
                    else if result.completed { status = "completed" }
                    else { status = "active" }

                    results.append(TaskSearchResult(
                        id: result.id,
                        description: result.description,
                        status: status,
                        similarity: nil,
                        matchType: "fts",
                        relevanceScore: result.relevanceScore
                    ))
                }

                // Also search staged_tasks
                let stagedResults = try await StagedTaskStorage.shared.searchFTS(
                    query: ftsQuery,
                    limit: 10
                )
                for result in stagedResults {
                    results.append(TaskSearchResult(
                        id: result.id,
                        description: result.description,
                        status: "active",
                        similarity: nil,
                        matchType: "fts",
                        relevanceScore: result.relevanceScore
                    ))
                }
            }
        } catch {
            logError("Task: FTS search failed", error: error)
        }

        return results
    }
}
