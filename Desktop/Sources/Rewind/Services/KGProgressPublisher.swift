import Foundation
import GRDB

/// Snapshot of brain-map build progress, surfaced to the UI.
///
/// Denominator (`totalMemories`) is the count of non-deleted local memories.
/// Numerator (`processedMemories`) is the count of distinct memoryIds with
/// any provenance row recorded — i.e. memories the extractor has touched at
/// least once, regardless of outcome.
struct KGBuildProgress: Sendable, Equatable {
    let totalMemories: Int
    let processedMemories: Int
    let succeededMemories: Int
    let totalNodes: Int
    let state: BuildState
    let etaSeconds: Int?

    /// Saturating init: enforces `processed ≤ total` and `succeeded ≤ processed`.
    /// Lane C originally took counts from independent SQL reads — a window
    /// between reads could legitimately produce `processed > total` (e.g. a
    /// memory got soft-deleted between the two queries). Clamp here so the
    /// pill never renders "5/3 memories" and so the empty-state classifier
    /// can trust its inputs. Logs when clamping fires so we still see the
    /// underlying source of drift.
    init(
        totalMemories: Int,
        processedMemories: Int,
        succeededMemories: Int,
        totalNodes: Int,
        state: BuildState,
        etaSeconds: Int?
    ) {
        let clampedProcessed = min(max(0, processedMemories), max(0, totalMemories))
        let clampedSucceeded = min(max(0, succeededMemories), clampedProcessed)
        if clampedProcessed != processedMemories || clampedSucceeded != succeededMemories {
            log("KGBuildProgress: clamped counters total=\(totalMemories) processed=\(processedMemories)→\(clampedProcessed) succeeded=\(succeededMemories)→\(clampedSucceeded)")
        }
        self.totalMemories = max(0, totalMemories)
        self.processedMemories = clampedProcessed
        self.succeededMemories = clampedSucceeded
        self.totalNodes = max(0, totalNodes)
        self.state = state
        self.etaSeconds = etaSeconds
    }
}

/// Build-time state. The UI's precedence ladder maps these to user-visible
/// strings; see `MemoryGraphPage.BuildPillState`.
enum BuildState: Sendable, Equatable {
    case idleNoWork
    case building
    case pausedThermal
    case pausedBattery
    case pausedNotIdle
    case modelNotReady
}

/// Empty-state copy mode. Pure function of (state, totalNodes, totalMemories)
/// so the test suite can assert it without rendering SwiftUI.
enum EmptyStateMode: Sendable, Equatable {
    /// "Building your brain map. This runs while your Mac is idle."
    case backfillNotStarted
    /// "Building — 0 / N memories"
    case backfillRunningNoNodesYet
    /// "No entities found yet. ..."
    case backfillCompleteEmpty
}

/// Pure mapping used by both the UI and tests.
///
/// Caller is expected to invoke this only when the populated graph is not
/// being shown (i.e. `totalNodes == 0` or the VM has elected to suppress
/// the SceneKit view because there's nothing to render yet). The
/// `totalNodes` parameter was removed in the consensus review pass — it
/// duplicated the caller's gate without adding signal here.
enum BrainMapEmptyStateClassifier {
    static func mode(
        state: BuildState,
        totalMemories: Int,
        processedMemories: Int
    ) -> EmptyStateMode {
        // If a build is actively in progress (or paused mid-build) and we
        // haven't extracted any nodes yet, show the building copy.
        switch state {
        case .building, .pausedThermal, .pausedBattery, .pausedNotIdle, .modelNotReady:
            return .backfillRunningNoNodesYet
        case .idleNoWork:
            // No pending work. Either the backfill is finished, or it never
            // had anything to do. If we processed at least one memory the
            // backfill ran — distinguish from "haven't started" (no memories
            // touched and there are memories that could be).
            if processedMemories > 0 || totalMemories == 0 {
                return .backfillCompleteEmpty
            }
            return .backfillNotStarted
        }
    }
}

/// Singleton publisher fed by the `.extractKG` handler. The Brain Map VM
/// subscribes to `stream` and renders the pill / empty-state copy.
///
/// Throttle: emits at most every 250 ms. ETA: rolling avg of last 5 drain
/// durations × remaining count, nil until we have ≥ 3 samples.
actor KGProgressPublisher {
    static let shared = KGProgressPublisher()

    private var continuations: [UUID: AsyncStream<KGBuildProgress>.Continuation] = [:]
    private var lastEmittedAt: Date?
    private var lastSnapshot: KGBuildProgress?
    private var coalesceTask: Task<Void, Never>?
    /// Cluster I — single-flight flush. When `true` and a flush is already
    /// scheduled or in-flight, emit() returns without spawning a second timer
    /// and `flushTrailing` will re-run on completion.
    private var pendingTrailingFlush: Bool = false
    /// Cluster E2 — low-frequency poller so paused / model-not-ready states
    /// surface even when no `.extractKG` handler tick has fired. Started on
    /// first subscriber, stopped when the subscriber count drops to zero.
    /// Polls every `pollSeconds`; the 250ms emit throttle prevents flooding.
    private var pollTask: Task<Void, Never>?
    private let pollSeconds: TimeInterval = 5.0

    /// Last N drain durations, used to compute ETA.
    private var drainSamples: [TimeInterval] = []
    /// Maximum samples retained.
    private let maxSamples = 5
    /// Minimum samples before we publish a non-nil ETA.
    private let minSamplesForETA = 3
    /// Min throttle window between consecutive emits.
    private let throttleSeconds: TimeInterval = 0.25

    private init() {}

    /// Async stream of progress snapshots. Each call returns a fresh stream;
    /// the caller owns it.
    var stream: AsyncStream<KGBuildProgress> {
        AsyncStream { continuation in
            let id = UUID()
            self.registerContinuation(id: id, continuation: continuation)
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self = self else { return }
                Task { await self.removeContinuation(id: id) }
            }
        }
    }

    private func registerContinuation(
        id: UUID,
        continuation: AsyncStream<KGBuildProgress>.Continuation
    ) {
        continuations[id] = continuation
        // Replay last snapshot so newly subscribed observers see current state
        // immediately rather than waiting for the next tick.
        if let snap = lastSnapshot {
            continuation.yield(snap)
        }
        // Cluster E2: ensure poller is running so paused / model-not-ready
        // states surface without waiting for a handler-driven tick. Also
        // schedule an immediate sample for first paint.
        startPollerIfNeeded()
        Task { [weak self] in await self?.tick() }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
        if continuations.isEmpty {
            stopPoller()
        }
    }

    // MARK: - Polling (Cluster E2)

    private func startPollerIfNeeded() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.pollSeconds * 1_000_000_000))
                if Task.isCancelled { return }
                await self.pollTickIfActive()
            }
        }
    }

    private func stopPoller() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Poll-driven tick. Bails out if no subscribers remain (raced cancel).
    private func pollTickIfActive() async {
        guard !continuations.isEmpty else { return }
        await tick()
    }

    // MARK: - Public

    /// Record a per-memory drain duration sample. Call once per handler
    /// invocation so the ETA estimator has a denominator.
    func recordDrainSample(seconds: TimeInterval) {
        drainSamples.append(seconds)
        if drainSamples.count > maxSamples {
            drainSamples.removeFirst(drainSamples.count - maxSamples)
        }
    }

    /// Sample DB counters + scheduler state, build a `KGBuildProgress`, and
    /// emit on the stream (subject to throttle/coalesce).
    /// On DB read failure the tick is skipped — emitting a 0/0 snapshot
    /// would be indistinguishable from "backfill complete empty" and
    /// would silently corrupt the UI's state machine.
    func tick() async {
        guard let snap = await sample() else { return }
        await emit(snap)
    }

    /// Force an immediate emit ignoring the throttle. Used for state changes
    /// (e.g. "model became ready") where the user is waiting for the pill to
    /// flip.
    func emitNow() async {
        guard let snap = await sample() else { return }
        coalesceTask?.cancel()
        coalesceTask = nil
        deliver(snap)
    }

    // MARK: - Sampling

    /// Returns nil on DB read failure. Caller must skip the emit.
    private func sample() async -> KGBuildProgress? {
        async let totalMemoriesAsync = totalMemoryCount()
        async let processedAsync = processedAndSucceededCounts()
        async let totalNodesAsync = totalNodesCount()

        let totalMemories: Int
        let processed: Int
        let succeeded: Int
        let totalNodes: Int
        do {
            totalMemories = try await totalMemoriesAsync
            (processed, succeeded) = try await processedAsync
            totalNodes = try await totalNodesAsync
        } catch {
            // Don't emit — a 0/0 snapshot here would render as
            // "backfill complete empty" and lie to the user.
            logError("KGProgressPublisher: sample DB read failed; skipping tick", error: error)
            return nil
        }

        let state = await deriveState(processedMemories: processed, totalMemories: totalMemories)
        let eta = computeETA(
            processed: processed, totalMemories: totalMemories
        )

        return KGBuildProgress(
            totalMemories: totalMemories,
            processedMemories: processed,
            succeededMemories: succeeded,
            totalNodes: totalNodes,
            state: state,
            etaSeconds: eta
        )
    }

    @MainActor
    private func mainActorReadiness() -> (
        allowHeavy: Bool, allowAutonomous: Bool,
        thermalSerious: Bool, onBattery: Bool, modelReady: Bool
    ) {
        let s = BatteryAwareScheduler.shared
        let lifecycle = MLXLifecycleManager.shared
        let modelReady = lifecycle.agentInstalled && lifecycle.modelPresent
        return (
            allowHeavy: s.allowHeavyWork,
            allowAutonomous: s.allowAutonomousAIWork,
            thermalSerious: s.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue,
            onBattery: s.source != .ac,
            modelReady: modelReady
        )
    }

    private func deriveState(processedMemories: Int, totalMemories: Int) async -> BuildState {
        let r = await mainActorReadiness()

        // Pending-work depth for `.extractKG` decides whether there's work at
        // all. If the queue is empty, treat as `idleNoWork` regardless of
        // power state — there's nothing pending to be paused.
        let depth: PendingWorkDepth
        do {
            depth = try await PendingWorkStorage.shared.depthSummary()
        } catch {
            logError(
                "KGProgressPublisher: depthSummary threw, falling back to empty PendingWorkDepth",
                error: error
            )
            depth = PendingWorkDepth()
        }
        let key = PendingWork.Kind.extractKG.rawValue
        let pending = (depth.queued[key] ?? 0) + (depth.failed[key] ?? 0) + (depth.claimed[key] ?? 0)

        if pending == 0 {
            return .idleNoWork
        }

        // There's pending work — derive the precedence ladder gate reason.
        if !r.modelReady { return .modelNotReady }
        if r.thermalSerious { return .pausedThermal }
        if r.onBattery && !r.allowHeavy { return .pausedBattery }
        if r.allowHeavy && !r.allowAutonomous {
            // Heavy work is allowed (AC + thermal ok) but the user is active —
            // autonomous-LLM work waits for idle/lock.
            return .pausedNotIdle
        }
        return .building
    }

    private func computeETA(processed: Int, totalMemories: Int) -> Int? {
        guard drainSamples.count >= minSamplesForETA else { return nil }
        let remaining = max(0, totalMemories - processed)
        guard remaining > 0 else { return 0 }
        let avg = drainSamples.reduce(0, +) / Double(drainSamples.count)
        return Int((Double(remaining) * avg).rounded())
    }

    // MARK: - DB counters

    private func totalMemoryCount() async throws -> Int {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return 0 }
        return try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM memories WHERE deleted = 0"
            ) ?? 0
        }
    }

    /// Returns (processedMemories, succeededMemories).
    /// Processed = distinct memoryIds with any node provenance row, excluding
    /// the onboarding sentinel.
    /// Succeeded = same, with `kg_extraction_status = 'succeeded'`.
    private func processedAndSucceededCounts() async throws -> (Int, Int) {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return (0, 0) }
        return try await dbQueue.read { db in
            let processed = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(DISTINCT m.id)
                    FROM memories m
                    WHERE m.deleted = 0
                      AND m.kg_extraction_status IS NOT NULL
                """
            ) ?? 0
            let succeeded = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM memories
                    WHERE deleted = 0
                      AND kg_extraction_status = ?
                """,
                arguments: [KGExtractionStatus.succeeded.rawValue]
            ) ?? 0
            return (processed, succeeded)
        }
    }

    private func totalNodesCount() async throws -> Int {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return 0 }
        return try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM local_kg_nodes") ?? 0
        }
    }

    // MARK: - Throttling

    private func emit(_ snapshot: KGBuildProgress) async {
        // Coalesce: if a tick lands inside the throttle window, schedule a
        // single trailing emit and drop intermediate samples.
        let now = Date()
        if let last = lastEmittedAt, now.timeIntervalSince(last) < throttleSeconds {
            // Stash the latest snapshot for diagnostic replay.
            lastSnapshot = snapshot
            // Single-flight (cluster I): if a flush is already pending, just
            // mark that another should run on completion and return. The
            // previous cancel-then-replace pattern raced with `flushTrailing`
            // re-entrant runs; flipping to a flag avoids that entirely.
            if coalesceTask != nil {
                pendingTrailingFlush = true
                return
            }
            let delay = throttleSeconds - now.timeIntervalSince(last)
            coalesceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.flushTrailing()
            }
            return
        }
        deliver(snapshot)
    }

    private func flushTrailing() async {
        // Re-sample so the trailing emit reflects the freshest DB state, not
        // the snapshot that was queued at throttle-start. If the DB read
        // fails we skip the emit — a 0/0 snapshot would lie.
        let snap = await sample()
        // Single-flight: re-check for queued work BEFORE clearing the slot
        // (cluster I). If another tick landed during the sample, run another
        // pass without spawning a parallel coalesce timer.
        let needsAnother = pendingTrailingFlush
        pendingTrailingFlush = false
        coalesceTask = nil
        if let snap = snap {
            deliver(snap)
        }
        if needsAnother {
            // Re-emit the latest state immediately. Use Task here to avoid
            // unbounded recursion if multiple flushes pile up; the actor
            // reentry will serialize them anyway.
            Task { [weak self] in
                await self?.flushTrailing()
            }
        }
    }

    private func deliver(_ snapshot: KGBuildProgress) {
        lastEmittedAt = Date()
        lastSnapshot = snapshot
        for (_, c) in continuations {
            c.yield(snapshot)
        }
    }
}

