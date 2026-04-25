import Foundation
import GRDB

/// Task extraction assistant that identifies tasks and action items from screen content.
/// Local-fork: drives a JSON-mode tool loop on the local LLM (no vision); decision
/// tools are search_similar / search_keywords / read_screenshot_ocr / extract_task /
/// reject_task / no_task_found.
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
        // AIProviderRegistry. The legacy Gemini search-loop (vision + function
        // calling) is replaced with a JSON-mode tool loop driven by
        // `LLMBridge.runToolLoop`. The local model doesn't see the screenshot;
        // it relies on the screenshot's window title + active task list +
        // search tools to decide whether to extract a task.

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
        return try await extractTaskSingleStage(from: jpegData, appName: appName, windowTitle: nil, screenshotId: nil)
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
            let (result, searchCount) = try await extractTaskSingleStage(from: frame.jpegData, appName: frame.appName, windowTitle: frame.windowTitle, screenshotId: frame.screenshotId)
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

    /// Loop-based extraction running against the local JSON-mode tool loop.
    ///
    /// Local Qwen 2.5-32B has no vision, so the model decides task extraction
    /// from the active task list (passed in the prompt for dedup) plus
    /// `search_similar` / `search_keywords` results plus the screenshot's
    /// OCR text (fetched on demand via the screenshot id). Decision tools are
    /// `extract_task`, `reject_task`, or `no_task_found`.
    ///
    /// `jpegData` is currently ignored — wired through only so the call sites
    /// keep working unchanged.
    /// Returns (result, searchCount).
    private func extractTaskSingleStage(
        from jpegData: Data,
        appName: String,
        windowTitle: String?,
        screenshotId: Int64?
    ) async throws -> (TaskExtractionResult?, Int) {
        guard await LLMBridge.currentClient() != nil else {
            log("[TaskAssistant] no LLM client available — skipping task extraction")
            return (nil, 0)
        }

        // 1) Gather context (active / completed / deleted tasks, goals).
        let context = await refreshContext()

        // 2) Build user prompt mirroring the legacy phrasing.
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd (EEEE)"
        let todayStr = dateFormatter.string(from: Date())

        var prompt = "Screenshot from \(appName)."
        if let wt = windowTitle, !wt.isEmpty {
            prompt += " Window: \"\(wt)\"."
        }
        prompt += " Today is \(todayStr). Analyze for any unaddressed request directed at the user.\n\n"

        let messagingApps: Set<String> = ["Telegram", "WhatsApp", "\u{200E}WhatsApp", "Messages", "Slack", "Discord"]
        if messagingApps.contains(appName) {
            prompt += """
            REMINDER — THIS IS A MESSAGING APP:
            - If the screenshot likely shows a chat sidebar/conversation list rather than an open conversation, call no_task_found.
            - If it shows an open conversation, look for where the user AGREED or COMMITTED to doing something the other person asked.
            - Also look for incoming requests the user hasn't responded to yet.
            - The task title should describe what was asked for, naming the other person in the conversation.

            """
        }

        if let profile = await AIUserProfileService.shared.getLatestProfile() {
            prompt += "USER PROFILE (who this user is — use for context, not as a task source):\n"
            prompt += profile.profileText + "\n\n"
        }

        if !context.activeTasks.isEmpty {
            let scoreRange = try? await ActionItemStorage.shared.getRelevanceScoreRange()
            let rangeStr = scoreRange.map { "Score range: \($0.min)–\($0.max). " } ?? ""
            prompt += "ACTIVE TASKS (user is already tracking these — relevance_score 1 = most important):\n"
            prompt += "\(rangeStr)Use these scores to place any new task appropriately.\n"
            for (i, task) in context.activeTasks.enumerated() {
                let pri = task.priority.map { " [\($0)]" } ?? ""
                let score = task.relevanceScore.map { " [score:\($0)]" } ?? ""
                prompt += "\(i + 1).\(score) \(task.description)\(pri)\n"
            }
            prompt += "\n"
        }

        if !context.completedTasks.isEmpty {
            prompt += "RECENTLY COMPLETED TASKS (similar shapes are good — just don't dup):\n"
            for (i, task) in context.completedTasks.enumerated() {
                prompt += "\(i + 1). \(task.description)\n"
            }
            prompt += "\n"
        }

        if !context.deletedTasks.isEmpty {
            prompt += "USER-DELETED TASKS (user explicitly rejected these — do not re-extract similar):\n"
            for (i, task) in context.deletedTasks.enumerated() {
                prompt += "\(i + 1). \(task.description)\n"
            }
            prompt += "\n"
        }

        if !context.goals.isEmpty {
            prompt += "ACTIVE GOALS:\n"
            for (i, goal) in context.goals.enumerated() {
                prompt += "\(i + 1). \(goal.title)"
                if let desc = goal.description {
                    prompt += " — \(desc)"
                }
                prompt += "\n"
            }
            prompt += "\n"
        }

        prompt += """

            You don't see the image directly. To inspect what was on screen, call read_screenshot_ocr \
            (returns OCR text + window title). If you see a potential request, search for duplicates \
            via search_similar / search_keywords first. If clearly no request (~90% of screenshots), \
            call no_task_found immediately.
            """

        // 3) Tools — local JSON-mode catalog mirroring the legacy 5 tools plus
        //    a read_screenshot_ocr replacement for the missing vision path.
        let tools = buildLocalTaskTools(hasScreenshotId: screenshotId != nil)

        // 4) Drive the loop. Like Insight, terminal tools (extract_task /
        //    reject_task / no_task_found) stash a result and ack the model.
        var searchCount = 0
        var terminalResult: TaskExtractionResult?
        let frameAppName = appName
        let capturedScreenshotId = screenshotId

        let answer: String?
        do {
            answer = try await LLMBridge.runToolLoop(
                systemPrompt: await systemPrompt,
                userPrompt: prompt,
                tools: tools,
                maxIterations: 6,
                executeTool: { [weak self] name, args in
                    guard let self else { return "" }
                    switch name {
                    case "search_similar":
                        let query = args["query"] as? String ?? ""
                        searchCount += 1
                        log("Task: search_similar \"\(query)\"")
                        let results = await self.executeVectorSearch(query: query)
                        return Self.encodeSearchResults(results)

                    case "search_keywords":
                        let query = args["query"] as? String ?? ""
                        searchCount += 1
                        log("Task: search_keywords \"\(query)\"")
                        let results = await self.executeKeywordSearch(query: query)
                        return Self.encodeSearchResults(results)

                    case "read_screenshot_ocr":
                        guard let sid = capturedScreenshotId else {
                            return "No screenshot id available for this frame."
                        }
                        return await Self.readScreenshotOcr(id: sid)

                    case "no_task_found":
                        let cs = args["context_summary"] as? String ?? "No task on screen"
                        let ca = args["current_activity"] as? String ?? "Unknown"
                        log("Task: no_task_found — \(cs)")
                        terminalResult = TaskExtractionResult(
                            hasNewTask: false,
                            task: nil,
                            contextSummary: cs,
                            currentActivity: ca
                        )
                        return "ACK. Now respond with {\"action\":\"final_answer\",\"text\":\"done\"}."

                    case "reject_task":
                        let reason = args["reason"] as? String ?? "Unknown"
                        let cs = args["context_summary"] as? String ?? ""
                        let ca = args["current_activity"] as? String ?? ""
                        log("Task: reject_task — \(reason)")
                        terminalResult = TaskExtractionResult(
                            hasNewTask: false,
                            task: nil,
                            contextSummary: cs,
                            currentActivity: ca
                        )
                        return "ACK. Now respond with {\"action\":\"final_answer\",\"text\":\"done\"}."

                    case "extract_task":
                        if let parsed = await self.parseExtractTaskArgs(args, fallbackApp: frameAppName) {
                            terminalResult = parsed
                            return "ACK: task recorded. Now respond with {\"action\":\"final_answer\",\"text\":\"done\"}."
                        } else {
                            // Validation failure — feed back to model to retry.
                            let title = args["title"] as? String ?? ""
                            let words = title.split(separator: " ").count
                            let err = Self.validateTaskTitle(title, wordCount: words) ?? "title validation failed"
                            return """
                                REJECTED: \(err). Your title was: "\(title)" (\(words) words). \
                                Either rewrite with 6+ words including a specific person/project name and concrete action, \
                                or call no_task_found if you cannot be more specific.
                                """
                        }

                    default:
                        return "Error: unknown tool '\(name)'"
                    }
                }
            )
        } catch {
            log("[TaskAssistant] tool loop threw: \(error.localizedDescription)")
            return (nil, searchCount)
        }

        if answer == nil && terminalResult == nil {
            log("[TaskAssistant] tool loop produced no terminal result (malformed JSON or maxIterations)")
            return (nil, searchCount)
        }

        return (terminalResult, searchCount)
    }

    // MARK: - Local tool catalog (JSON-mode)

    /// Tool catalog for the local task-extraction loop. Mirrors the 5
    /// legacy Gemini tools plus a `read_screenshot_ocr` helper that exposes
    /// the screenshot's OCR text in lieu of vision.
    private func buildLocalTaskTools(hasScreenshotId: Bool) -> [ToolDefinition] {
        let priorityEnum: [Any] = ["high", "medium", "low"]
        let sourceCategoryEnum: [Any] = [
            "direct_request", "self_generated", "calendar_driven",
            "reactive", "external_system", "other"
        ]
        let sourceSubcategoryEnum: [Any] = [
            "message", "meeting", "mention", "commitment",
            "idea", "reminder", "goal_subtask",
            "event_prep", "recurring", "deadline",
            "error", "notification", "observation",
            "project_tool", "alert", "documentation", "other"
        ]

        var tools: [ToolDefinition] = []

        if hasScreenshotId {
            tools.append(ToolDefinition(
                name: "read_screenshot_ocr",
                description: "Read OCR text from the screenshot under analysis. Returns up to ~4KB of extracted text plus window title. Call once before deciding whether to extract a task.",
                parametersJSONSchema: [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ))
        }

        tools.append(contentsOf: [
            ToolDefinition(
                name: "search_similar",
                description: "Search for semantically similar existing tasks via vector similarity. Use after you've spotted a potential request to check for duplicates.",
                parametersJSONSchema: [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Concise description of the potential task to search for"
                        ]
                    ],
                    "required": ["query"]
                ]
            ),
            ToolDefinition(
                name: "search_keywords",
                description: "FTS5 keyword search across existing tasks. Complements search_similar with precise keyword matching.",
                parametersJSONSchema: [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Keywords to match in existing tasks"
                        ]
                    ],
                    "required": ["query"]
                ]
            ),
            ToolDefinition(
                name: "no_task_found",
                description: "Call when there is no actionable request on screen (~90% of screenshots).",
                parametersJSONSchema: [
                    "type": "object",
                    "properties": [
                        "context_summary": [
                            "type": "string",
                            "description": "Brief summary of what the user is looking at"
                        ],
                        "current_activity": [
                            "type": "string",
                            "description": "What the user is actively doing"
                        ]
                    ],
                    "required": ["context_summary", "current_activity"]
                ]
            ),
            ToolDefinition(
                name: "extract_task",
                description: "Extract a new task that is not already tracked. Call ONLY after searching for duplicates. Title must be 6–15 words and include a concrete action plus a specific person/project/artifact.",
                parametersJSONSchema: [
                    "type": "object",
                    "properties": [
                        "title": [
                            "type": "string",
                            "description": "Verb-first task title, 6–15 words. Must name a specific person/project/artifact."
                        ],
                        "description": [
                            "type": "string",
                            "description": "Additional context. Empty string if none."
                        ],
                        "priority": [
                            "type": "string",
                            "enum": priorityEnum
                        ],
                        "tags": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "1–3 relevant tags"
                        ],
                        "source_app": [
                            "type": "string",
                            "description": "App where the task was found"
                        ],
                        "inferred_deadline": [
                            "type": "string",
                            "description": "Deadline in yyyy-MM-dd format (resolve relative refs to a real date). Empty string if no deadline."
                        ],
                        "confidence": [
                            "type": "number",
                            "description": "0.0–1.0"
                        ],
                        "context_summary": [
                            "type": "string",
                            "description": "Brief summary of what user is looking at"
                        ],
                        "current_activity": [
                            "type": "string",
                            "description": "What the user is actively doing"
                        ],
                        "source_category": [
                            "type": "string",
                            "enum": sourceCategoryEnum
                        ],
                        "source_subcategory": [
                            "type": "string",
                            "enum": sourceSubcategoryEnum
                        ],
                        "relevance_score": [
                            "type": "integer",
                            "description": "Where this task ranks vs existing tasks (1 = most important; positive integer)."
                        ]
                    ],
                    "required": [
                        "title", "description", "priority", "tags",
                        "source_app", "inferred_deadline", "confidence",
                        "context_summary", "current_activity",
                        "source_category", "source_subcategory", "relevance_score"
                    ]
                ]
            ),
            ToolDefinition(
                name: "reject_task",
                description: "Reject task extraction — duplicate / completed / previously rejected.",
                parametersJSONSchema: [
                    "type": "object",
                    "properties": [
                        "reason": [
                            "type": "string",
                            "description": "Why this task was rejected"
                        ],
                        "context_summary": [
                            "type": "string"
                        ],
                        "current_activity": [
                            "type": "string"
                        ]
                    ],
                    "required": ["reason", "context_summary", "current_activity"]
                ]
            ),
        ])

        return tools
    }

    /// Parse the extract_task tool arguments into a TaskExtractionResult.
    /// Returns nil on validation failure so the caller can feed the rejection
    /// back to the model and let it retry.
    private func parseExtractTaskArgs(_ args: [String: Any], fallbackApp: String) -> TaskExtractionResult? {
        let title = args["title"] as? String ?? ""
        let words = title.split(separator: " ").count
        if Self.validateTaskTitle(title, wordCount: words) != nil {
            return nil
        }

        let description = args["description"] as? String
        let priorityStr = args["priority"] as? String ?? "medium"
        let priority = TaskPriority(rawValue: priorityStr) ?? .medium

        let tags: [String]
        if let arr = args["tags"] as? [Any] {
            tags = arr.compactMap { $0 as? String }
        } else if let s = args["tags"] as? String {
            tags = [s]
        } else {
            tags = []
        }

        let sourceApp = args["source_app"] as? String ?? fallbackApp
        let inferredDeadline = args["inferred_deadline"] as? String
        let confidence: Double
        if let v = args["confidence"] as? Double {
            confidence = v
        } else if let v = args["confidence"] as? Int {
            confidence = Double(v)
        } else if let s = args["confidence"] as? String, let v = Double(s) {
            confidence = v
        } else {
            confidence = 0.5
        }
        let sourceCategory = args["source_category"] as? String ?? "other"
        let sourceSubcategory = args["source_subcategory"] as? String ?? "other"
        let relevanceScore: Int?
        if let v = args["relevance_score"] as? Int {
            relevanceScore = v
        } else if let v = args["relevance_score"] as? Double {
            relevanceScore = Int(v)
        } else if let s = args["relevance_score"] as? String, let v = Int(s) {
            relevanceScore = v
        } else {
            relevanceScore = nil
        }
        let contextSummary = args["context_summary"] as? String ?? ""
        let currentActivity = args["current_activity"] as? String ?? ""

        let task = ExtractedTask(
            title: title,
            description: description?.isEmpty == true ? nil : description,
            priority: priority,
            sourceApp: sourceApp,
            inferredDeadline: inferredDeadline?.isEmpty == true ? nil : inferredDeadline,
            confidence: confidence,
            tags: tags,
            sourceCategory: sourceCategory,
            sourceSubcategory: sourceSubcategory,
            relevanceScore: relevanceScore
        )

        log("Task: extract_task — \"\(title)\" (conf=\(confidence), pri=\(priorityStr), score=\(relevanceScore.map { String($0) } ?? "nil"))")

        return TaskExtractionResult(
            hasNewTask: true,
            task: task,
            contextSummary: contextSummary,
            currentActivity: currentActivity
        )
    }

    /// Encode a list of TaskSearchResult to a compact JSON string for tool
    /// result feedback. Falls back to `[]` on encode failure.
    private static func encodeSearchResults(_ results: [TaskSearchResult]) -> String {
        if let data = try? JSONEncoder().encode(results),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "[]"
    }

    /// Read OCR + window title for a given screenshot id. Truncates to 3000
    /// chars to keep tool feedback turns bounded.
    private static func readScreenshotOcr(id: Int64) async -> String {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            return "Error: database unavailable"
        }
        do {
            return try await dbQueue.read { db in
                if let row = try GRDB.Row.fetchOne(
                    db,
                    sql: "SELECT appName, windowTitle, ocrText FROM screenshots WHERE id = ?",
                    arguments: [id]
                ) {
                    let app = row["appName"] as? String ?? "?"
                    let win = row["windowTitle"] as? String ?? ""
                    let ocr = row["ocrText"] as? String ?? ""
                    let truncated = ocr.count > 3000 ? String(ocr.prefix(3000)) + "... (truncated)" : ocr
                    return """
                        app: \(app)
                        windowTitle: \(win)
                        ocrText:
                        \(truncated)
                        """
                }
                return "No screenshot row for id=\(id)"
            }
        } catch {
            return "Error reading screenshot: \(error.localizedDescription)"
        }
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
