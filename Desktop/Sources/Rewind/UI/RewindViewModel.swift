import Foundation
import SwiftUI
import Combine

/// View model for the Rewind page
@MainActor
class RewindViewModel: ObservableObject {
    // MARK: - Published State

    @Published var screenshots: [Screenshot] = []
    @Published var selectedScreenshot: Screenshot? = nil
    @Published var searchQuery: String = ""
    @Published var selectedApp: String? = nil
    @Published var selectedDate: Date = Date()
    @Published var availableApps: [String] = []

    @Published var isLoading = false
    @Published var isSearching = false
    @Published var errorMessage: String? = nil

    @Published var stats: (total: Int, indexed: Int, storageSize: Int64)? = nil

    /// The active search query (trimmed, non-empty) for highlighting
    @Published var activeSearchQuery: String? = nil

    // MARK: - Recovery Status

    /// Whether the database was recovered from corruption on this launch
    @Published var didRecoverFromCorruption = false

    /// Number of records recovered (0 if fresh database created)
    @Published var recoveredRecordCount = 0

    /// Whether the recovery banner should be shown
    @Published var showRecoveryBanner = false

    /// Whether a database rebuild is in progress
    @Published var isRebuilding = false

    /// Progress of database rebuild (0.0 to 1.0)
    @Published var rebuildProgress: Double = 0.0

    /// Time window in seconds for grouping search results
    var searchGroupingTimeWindow: TimeInterval = 30

    /// Grouped search results (computed from screenshots when searching)
    var groupedSearchResults: [SearchResultGroup] {
        guard activeSearchQuery != nil else { return [] }
        return screenshots.groupedByContext(timeWindowSeconds: searchGroupingTimeWindow)
    }

    /// Total number of individual screenshots across all groups
    var totalScreenshotCount: Int {
        screenshots.count
    }

    // MARK: - Private State

    private var searchTask: Task<Void, Never>?
    private var loadWatchdogTask: Task<Void, Never>?
    private var loadStatsTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// Whether initial data has been loaded (prevents race condition with
    /// debounced search). Also used by the watchdog re-check guard so a
    /// successful load can never trip the "Loading timed out" banner after
    /// the fact (see `loadInitialData`).
    private var isInitialized = false

    // TODO: testing seam needed — `loadInitialData` reaches into
    // `RewindDatabase.shared` and `RewindIndexer.shared` directly. Adding a
    // `RewindViewModelTests` covering the watchdog/defer interaction (per
    // the second-pass review) requires injecting a database-and-indexer pair
    // into `RewindViewModel` (e.g. struct of closures with `.live` /
    // `.testing` cases, or a protocol-typed dependency). Out of scope for
    // this batch fix — flagged here as the follow-up.

    /// Set by RewindPage when the transcript/notes panel is expanded.
    /// Auto-refresh skips when true so the view tree stays stable and @State is preserved.
    var isTranscriptExpanded = false

    // MARK: - Initialization

    init() {
        // Debounce search queries
        $searchQuery
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] query in
                Task { await self?.performSearch(query: query) }
            }
            .store(in: &cancellables)

        // Listen for new frame captures to update stats live
        NotificationCenter.default.publisher(for: .rewindFrameCaptured)
            .throttle(for: .seconds(2), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                Task { await self?.updateStatsOnly() }
            }
            .store(in: &cancellables)

        // Auto-refresh timeline every 3 seconds when viewing today
        Timer.publish(every: 3.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { await self?.refreshTimelineIfViewingToday() }
            }
            .store(in: &cancellables)
    }

    /// Refresh timeline only if viewing today and not actively searching.
    /// Uses a silent path that never sets isLoading and only updates screenshots
    /// when the data actually changed, preventing view-tree destruction.
    private func refreshTimelineIfViewingToday() async {
        // Skip if not initialized or currently loading
        guard isInitialized, !isLoading, !isSearching else { return }

        // Skip if there's an active search query
        guard activeSearchQuery == nil else { return }

        // Skip if transcript/notes panel is expanded — refreshing would
        // destroy the expanded view tree and lose @State (typed notes).
        guard !isTranscriptExpanded else { return }

        // Only refresh if viewing today
        let calendar = Calendar.current
        guard calendar.isDateInToday(selectedDate) else { return }

        // Silent refresh: don't set isLoading, and only update if data changed
        await silentLoadScreenshotsForDate(selectedDate)
    }

    /// Update only the stats (for live frame count updates)
    private func updateStatsOnly() async {
        if let indexerStats = await RewindIndexer.shared.getStats() {
            stats = indexerStats
        }
    }

    // MARK: - Loading

    func loadInitialData() async {
        isLoading = true
        errorMessage = nil

        // `defer` runs on every exit path so the spinner can never get stuck
        // "Loading screenshots…" forever — even if the await chain throws or
        // is cancelled.
        defer {
            isLoading = false
            loadWatchdogTask?.cancel()
            loadWatchdogTask = nil

            log("RewindViewModel: Posting rewindPageDidLoad notification")
            NotificationCenter.default.post(name: .rewindPageDidLoad, object: nil)
        }

        // Watchdog: surfaces a visible error/retry if work hasn't completed in
        // 30s. First-launch DB init on a cold APFS cache can legitimately take
        // longer than the previous 15s. The Task inherits MainActor isolation
        // from the surrounding @MainActor context, so direct property writes
        // are safe — no nested `MainActor.run` hop needed.
        loadWatchdogTask?.cancel()
        loadWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            // Re-check `isInitialized`: if `loadInitialData` already finished
            // (success OR error path), `defer` may not yet have flipped
            // `isLoading` to false in this MainActor turn. Without this guard
            // the watchdog spuriously sets "Loading timed out" right after a
            // legitimate load — including the error path, where
            // `errorMessage` is set but `isLoading` is still `true`.
            guard self.isLoading
                && self.errorMessage == nil
                && !self.isInitialized
            else { return }
            self.errorMessage = "Loading timed out. Tap retry."
            self.isLoading = false
            logError("RewindViewModel: loadInitialData watchdog fired after 30s")
        }

        do {
            // Configure database for the current user BEFORE anything touches the DB.
            // Without this, RewindIndexer.initialize() opens the DB for "anonymous",
            // then ViewModelContainer.loadAllData() detects the user mismatch, closes
            // the DB, and re-opens — leaving us with a nil dbQueue mid-use.
            let userId = UserDefaults.standard.string(forKey: "auth_userId")
            await RewindDatabase.shared.configure(userId: userId)

            // Initialize the indexer if needed
            try await RewindIndexer.shared.initialize()

            // Ensure database is ready — RewindIndexer.initialize() may return early
            // (already initialized) while the database is being re-opened for a different
            // user by ViewModelContainer. This call waits for any in-progress init.
            try await RewindDatabase.shared.initialize()

            // Check if database was recovered from corruption
            let recovered = await RewindDatabase.shared.didRecoverFromCorruption
            let recoveredCount = await RewindDatabase.shared.recoveredRecordCount

            if recovered {
                didRecoverFromCorruption = true
                recoveredRecordCount = recoveredCount
                showRecoveryBanner = true
                log("RewindViewModel: Database was recovered from corruption, \(recoveredCount) records salvaged")
            }

            // Load today's screenshots (date filter is always active).
            // Propagates DB errors so the catch below surfaces them to the UI
            // instead of silently leaving the spinner running.
            try await loadScreenshotsForDate(selectedDate)

            // Load available apps for filtering
            availableApps = try await RewindDatabase.shared.getUniqueAppNames()

            // Mark as initialized after successful load
            isInitialized = true

            // Flash-of-timeout fix: if the 30s watchdog fired moments before
            // we got here, clear the stale banner so the user sees the loaded
            // data, not a misleading timeout message.
            errorMessage = nil

            // Stats fetch only on success — previously this was in the defer
            // and fired on watchdog timeouts and errors too. Cancel any prior
            // stats task so a slow earlier fetch can't clobber a fresh one.
            loadStatsTask?.cancel()
            loadStatsTask = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                if let indexerStats = await RewindIndexer.shared.getStats() {
                    guard !Task.isCancelled else { return }
                    self.stats = indexerStats
                }
            }
        } catch {
            errorMessage = "Couldn't open Rewind database: \(error.localizedDescription)"
            logError("RewindViewModel: Failed to load initial data: \(error)")
        }
    }

    /// Dismiss the recovery banner
    func dismissRecoveryBanner() {
        showRecoveryBanner = false
    }

    func refresh() async {
        await loadInitialData()
    }

    // MARK: - Search


    private func performSearch(query: String) async {
        // Skip if not yet initialized (prevents race condition with debounced publisher)
        guard isInitialized else { return }

        // Cancel any existing search
        searchTask?.cancel()

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedQuery.isEmpty {
            // Reset to date-filtered view (date filter is always active).
            // Silent reload: a transient DB error here should log and move on,
            // not block the search-clear UX.
            isSearching = false
            activeSearchQuery = nil
            await reloadScreenshotsSilently(selectedDate)
            return
        }

        isSearching = true
        activeSearchQuery = trimmedQuery

        // Track rewind search
        AnalyticsManager.shared.rewindSearchPerformed(queryLength: trimmedQuery.count)

        // Calculate date range (date filter is always active)
        let calendar = Calendar.current
        let startDate = calendar.startOfDay(for: selectedDate)
        let endDate = calendar.date(byAdding: .day, value: 1, to: startDate)!

        searchTask = Task {
            do {
                // Run FTS and vector search in parallel
                async let ftsResults = RewindDatabase.shared.search(
                    query: trimmedQuery,
                    appFilter: selectedApp,
                    startDate: startDate,
                    endDate: endDate,
                    limit: 100
                )
                async let vectorResults = OCREmbeddingService.shared.searchSimilar(
                    query: trimmedQuery,
                    startDate: startDate,
                    endDate: endDate,
                    appFilter: selectedApp,
                    topK: 50
                )

                let fts = try await ftsResults
                // Vector search failures are non-fatal — FTS results still show
                let vector = (try? await vectorResults) ?? []

                if !Task.isCancelled {
                    // Merge: FTS first, then add vector-only results above threshold
                    let ftsIds = Set(fts.compactMap { $0.id })
                    var merged = fts
                    for result in vector where result.similarity > 0.5 && !ftsIds.contains(result.screenshotId) {
                        if let screenshot = try? await RewindDatabase.shared.getScreenshot(id: result.screenshotId) {
                            merged.append(screenshot)
                        }
                    }
                    screenshots = merged
                }
            } catch {
                if !Task.isCancelled {
                    logError("RewindViewModel: Search failed: \(error)")
                }
            }

            if !Task.isCancelled {
                isSearching = false
            }
        }
    }

    // MARK: - Filtering

    func filterByApp(_ app: String?) async {
        selectedApp = app

        if !searchQuery.isEmpty {
            await performSearch(query: searchQuery)
        } else {
            // Silent: post-init filter change, transient DB error should not stick.
            await reloadScreenshotsSilently(selectedDate)
        }
    }

    func filterByDate(_ date: Date) async {
        selectedDate = date

        if !searchQuery.isEmpty {
            await performSearch(query: searchQuery)
        } else {
            // Silent: post-init date change, transient DB error should not stick.
            await reloadScreenshotsSilently(date)
        }
    }

    /// Loads screenshots for a date and propagates any DB error.
    /// Callers that need to surface failures to the user (init / retry path)
    /// should `try` this. Callers that prefer fire-and-forget should use
    /// `reloadScreenshotsSilently(_:)` instead — silent-swallow is intentional
    /// there but must NOT leak back into init paths.
    ///
    /// Note: this does NOT touch `isLoading`. The caller owns that state — see
    /// `loadInitialData` (manages isLoading via top-level defer) and
    /// `reloadScreenshotsSilently` (sets it around the call for filter/search).
    private func loadScreenshotsForDate(_ date: Date) async throws {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        var results = try await RewindDatabase.shared.getScreenshotsSampled(
            from: startOfDay,
            to: endOfDay,
            targetCount: 500
        )

        // Filter out frames from the active (unfinalized) video chunk — they can't be displayed yet
        let activeChunk = await VideoChunkEncoder.shared.currentChunkPath
        if let activeChunk = activeChunk {
            results = results.filter { $0.videoChunkPath != activeChunk }
        }

        // Apply app filter if set
        if let app = selectedApp {
            results = results.filter { $0.appName == app }
        }

        screenshots = results
    }

    /// Silent variant: swallows DB errors and just logs them. Use only for
    /// background/user-driven reloads (filter change, date change, search
    /// clear) where a transient failure should not block the UI. Never use
    /// this on the init path — it would re-introduce the "spinner forever"
    /// bug. Manages `isLoading` so the spinner shows during the reload but
    /// always clears, even on thrown error.
    private func reloadScreenshotsSilently(_ date: Date) async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await loadScreenshotsForDate(date)
        } catch {
            logError("RewindViewModel: Failed to reload screenshots for date: \(error)")
        }
    }

    /// Silent variant for auto-refresh: never touches isLoading, and only
    /// updates `screenshots` when the fetched IDs differ from the current set.
    /// This prevents unnecessary SwiftUI view-tree rebuilds that destroy @State.
    private func silentLoadScreenshotsForDate(_ date: Date) async {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        do {
            var results = try await RewindDatabase.shared.getScreenshotsSampled(
                from: startOfDay,
                to: endOfDay,
                targetCount: 500
            )

            // Filter out frames from the active (unfinalized) video chunk
            let activeChunk = await VideoChunkEncoder.shared.currentChunkPath
            if let activeChunk = activeChunk {
                results = results.filter { $0.videoChunkPath != activeChunk }
            }

            // Apply app filter if set
            if let app = selectedApp {
                results = results.filter { $0.appName == app }
            }

            // Only update if the data actually changed (compare by IDs)
            let oldIds = screenshots.compactMap { $0.id }
            let newIds = results.compactMap { $0.id }
            if oldIds != newIds {
                screenshots = results
            }

        } catch {
            logError("RewindViewModel: Failed to silently refresh screenshots: \(error)")
        }
    }

    // MARK: - Screenshot Selection

    func selectScreenshot(_ screenshot: Screenshot) {
        selectedScreenshot = screenshot
        AnalyticsManager.shared.rewindScreenshotViewed(timestamp: screenshot.timestamp)
    }

    func selectNextScreenshot() {
        guard let current = selectedScreenshot,
              let currentIndex = screenshots.firstIndex(where: { $0.id == current.id }),
              currentIndex < screenshots.count - 1 else { return }

        selectedScreenshot = screenshots[currentIndex + 1]
        AnalyticsManager.shared.rewindTimelineNavigated(direction: "next")
    }

    func selectPreviousScreenshot() {
        guard let current = selectedScreenshot,
              let currentIndex = screenshots.firstIndex(where: { $0.id == current.id }),
              currentIndex > 0 else { return }

        selectedScreenshot = screenshots[currentIndex - 1]
        AnalyticsManager.shared.rewindTimelineNavigated(direction: "previous")
    }

    // MARK: - Search Result Helpers

    /// Get a context snippet for the current search query on a screenshot
    func contextSnippet(for screenshot: Screenshot) -> String? {
        guard let query = activeSearchQuery else { return nil }
        return screenshot.contextSnippet(for: query)
    }

    /// Get matching text blocks for highlighting
    func matchingBlocks(for screenshot: Screenshot) -> [OCRTextBlock] {
        guard let query = activeSearchQuery else { return [] }
        return screenshot.matchingBlocks(for: query)
    }

    // MARK: - Delete

    func deleteScreenshot(_ screenshot: Screenshot) async {
        guard let id = screenshot.id else { return }

        do {
            // Delete from database (returns storage info)
            if let result = try await RewindDatabase.shared.deleteScreenshot(id: id) {
                // Delete legacy JPEG if present
                if let imagePath = result.imagePath {
                    try await RewindStorage.shared.deleteScreenshot(relativePath: imagePath)
                }
                // Delete video chunk if this was the last frame in it
                if result.isLastFrameInChunk, let videoChunkPath = result.videoChunkPath {
                    try await RewindStorage.shared.deleteVideoChunk(relativePath: videoChunkPath)
                }
            }

            // Remove from local array
            screenshots.removeAll { $0.id == id }

            // Clear selection if deleted
            if selectedScreenshot?.id == id {
                selectedScreenshot = nil
            }

        } catch {
            logError("RewindViewModel: Failed to delete screenshot: \(error)")
        }
    }

    // MARK: - Stats

    func refreshStats() async {
        if let indexerStats = await RewindIndexer.shared.getStats() {
            stats = indexerStats
        }
    }
}
