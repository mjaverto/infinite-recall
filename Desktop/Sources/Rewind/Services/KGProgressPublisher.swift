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
/// the SceneKit view because there's nothing to render yet).
enum BrainMapEmptyStateClassifier {
    static func mode(
        state: BuildState,
        totalNodes: Int,
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
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
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
    func tick() async {
        let snap = await sample()
        await emit(snap)
    }

    /// Force an immediate emit ignoring the throttle. Used for state changes
    /// (e.g. "model became ready") where the user is waiting for the pill to
    /// flip.
    func emitNow() async {
        let snap = await sample()
        coalesceTask?.cancel()
        coalesceTask = nil
        deliver(snap)
    }

    // MARK: - Sampling

    private func sample() async -> KGBuildProgress {
        async let totalMemoriesAsync = totalMemoryCount()
        async let processedAsync = processedAndSucceededCounts()
        async let totalNodesAsync = totalNodesCount()

        let totalMemories = (try? await totalMemoriesAsync) ?? 0
        let (processed, succeeded) = (try? await processedAsync) ?? (0, 0)
        let totalNodes = (try? await totalNodesAsync) ?? 0

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
        let depth = (try? await PendingWorkStorage.shared.depthSummary()) ?? PendingWorkDepth()
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
                      AND kg_extraction_status = 'succeeded'
                """
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
            // Queue (or replace) a trailing emit.
            coalesceTask?.cancel()
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
        coalesceTask = nil
        // Re-sample so the trailing emit reflects the freshest DB state, not
        // the snapshot that was queued at throttle-start.
        let snap = await sample()
        deliver(snap)
    }

    private func deliver(_ snapshot: KGBuildProgress) {
        lastEmittedAt = Date()
        lastSnapshot = snapshot
        for (_, c) in continuations {
            c.yield(snapshot)
        }
    }
}

