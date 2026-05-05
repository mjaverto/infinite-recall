// Activity Tab — Stream F.
//
// `ActivityMonitorService` polls the local Rust daemon at 1 Hz while the IR
// window is key, exposing the latest `ActivitySnapshot` to SwiftUI via
// `@Published`. Polling is suspended while the window is hidden / not key
// (per Phase 0 contract: "Hidden window suspends polling. UI MUST NOT poll
// the Rust daemon while NSWindow.didResignKey").
//
// Pause/resume + capture pause/resume are funneled through this service so
// it can:
//   1. Optimistically mutate the local snapshot for instant UI feedback
//      (set/clear `paused_until` on the affected row).
//   2. Post `ActivityNotifications.pauseChanged` so Stream H's
//      `CapturePauseGate` (and live capture services) can react without
//      polling.
//
// Owner: Stream F.

import AppKit
import Combine
import Foundation

@MainActor
public final class ActivityMonitorService: ObservableObject, InternalPostFailureReporter {
    public static let shared = ActivityMonitorService()

    @Published public private(set) var snapshot: ActivitySnapshot?
    @Published public private(set) var lastError: String?

    private var timer: Timer?
    private var isStarted: Bool = false
    private var isFetching: Bool = false
    private var keyObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?

    /// Issue #104 — cold-start grace.
    ///
    /// On launch, the Activity tab's first `getActivitySnapshot` can race the
    /// Rust daemon's bind/init: the request hits a 5s `URLRequest.timeoutInterval`
    /// before the daemon answers, surfacing a user-visible
    /// "snapshot failed: The request timed out." banner even though the next
    /// 1 Hz tick almost always succeeds.
    ///
    /// We swallow *transient daemon-startup* errors (timeout / connection
    /// refused / 5xx) for the first `coldStartGraceAttempts` fetches before
    /// the first successful snapshot. After grace is exhausted, or once we've
    /// ever seen a successful snapshot, errors surface to the banner as before.
    private var hasReceivedFirstSnapshot: Bool = false
    private var coldStartFailureCount: Int = 0
    /// 5 attempts × 1s poll interval ≈ 5s of grace beyond the per-request 5s
    /// timeout, which empirically covers the worst observed cold-start race
    /// in #104 without masking real outages.
    static let coldStartGraceAttempts: Int = 5

    private init() {}

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        timer?.invalidate()
    }

    // MARK: - Lifecycle

    /// Begin polling. Idempotent. Wires up window-key observers so polling
    /// suspends when the IR window is hidden/inactive.
    public func start() {
        // Reset cold-start grace on first start (or after a real `stop()`),
        // but NOT on a re-entrant `start()` while we're already polling — the
        // Activity tab can be hidden/shown rapidly and we don't want grace to
        // re-arm every flip. The `!isStarted` guard below ensures the reset
        // runs at most once per start/stop cycle.
        guard !isStarted else { return }
        hasReceivedFirstSnapshot = false
        coldStartFailureCount = 0
        isStarted = true

        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleBecameKey()
            }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleResignedKey()
            }
        }

        // If a window is already key at start time, begin polling immediately
        // (no 1s delay before the first sample).
        if NSApp?.keyWindow != nil {
            startTimerIfNeeded(immediateFetch: true)
        }
    }

    /// Stop polling and tear down observers.
    public func stop() {
        isStarted = false
        timer?.invalidate()
        timer = nil
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
            self.keyObserver = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        // Note: cold-start grace is reset in `start()` (guarded by
        // `!isStarted`), not here. Keeping reset out of `stop()` makes
        // rapid hide/show flapping safe — grace re-arms only on a genuine
        // restart of the polling loop.
    }

    // MARK: - Public actions

    /// Pause a `WorkKind` row for `minutes` minutes. Optimistically updates
    /// the local snapshot and posts `pauseChanged`.
    public func pauseKind(_ kind: WorkKind, minutes: Int) async {
        await pause(target: .kind(kind), minutes: minutes)
    }

    /// Pause a capture row (audio/screen) for `minutes` minutes. UI is
    /// expected to have already shown the confirm sheet for `audio`.
    public func pauseCapture(_ capture: CaptureKind, minutes: Int) async {
        await pause(target: .capture(capture), minutes: minutes)
    }

    /// Resume a previously paused row.
    /// Consensus-fix C3: only mutate local state after the backend write
    /// succeeds. Previously we wrote optimistically and the next snapshot
    /// poll silently reverted on backend failure.
    public func resume(target: PauseTargetId) async {
        do {
            try await APIClient.shared.resumeActivity(target: target)
            applyOptimisticPause(target: target, until: nil)
            postPauseChanged()
            self.lastError = nil
            await fetchOnce()
        } catch {
            self.lastError = userFacingErrorMessage(action: "Resume", error: error)
        }
    }

    /// Clear the user-visible error banner. Bound to the dismiss button in
    /// `ActivityPage.errorBanner`.
    public func clearLastError() {
        self.lastError = nil
    }

    /// Surface a user-visible error from outside the service (e.g. UI-side
    /// recovery actions like the Restart Daemon button). Routed through the
    /// same `lastError` channel so the existing banner picks it up.
    public func setLastError(_ message: String) {
        self.lastError = message
    }

    /// POST /v1/activity/processes/:pid/terminate — ask the Rust daemon to
    /// SIGTERM the LocalModel worker child for `pid` so its memory is
    /// reclaimed. launchd `KeepAlive=true` will respawn it on the next
    /// request, which is fine — this is a memory-reclaim button ("Unload"),
    /// not a permanent stop.
    public func terminateProcess(pid: Int32) async throws {
        try await APIClient.shared.terminateActivityProcess(pid: pid)
    }

    /// Production-safe immediate refresh for one-shot scheduling state flips.
    /// Uses the same guarded fetch path as the 1 Hz poller, so overlapping
    /// refreshes coalesce instead of piling up network calls.
    public func refreshNow() async {
        await fetchOnce()
    }

    /// Surface a banner when `_internal/*` POSTs (inflight, gate-state) have
    /// failed `consecutive` times in a row. Routed through
    /// `InternalPostFailureTracker` so duplicate counters don't drift.
    /// (Issue #137: queue-depth was pruned — Activity snapshots are now
    /// DB-authoritative via `snapshotWithAuthoritativeQueueDepth`.)
    func reportInternalPostFailure(category: String, consecutive: Int) {
        lastError = "Internal reporting failing: \(category) (\(consecutive) consecutive failures)"
    }

    // MARK: - Private

    /// Consensus-fix C3: write to local state ONLY after the round-trip
    /// returns success. On failure we set `lastError` and leave the
    /// snapshot untouched so the UI never silently rolls back.
    private func pause(target: PauseTargetId, minutes: Int) async {
        // Issue #34 (PR #39 review): a `minutes <= 0` value is a caller
        // bug — surface it as a user-visible error instead of silently
        // coercing to a 1-minute pause. Mirrors the throwing
        // `PauseRequest.init` invariant (Rust's `NonZeroU32`).
        guard minutes > 0 else {
            self.lastError = "Pause failed: minutes must be greater than zero."
            return
        }
        let mins = UInt32(minutes)
        do {
            let until = try await APIClient.shared.pauseActivity(
                target: target,
                minutes: mins
            )
            applyOptimisticPause(target: target, until: until)
            postPauseChanged()
            self.lastError = nil
            await fetchOnce()
        } catch {
            self.lastError = userFacingErrorMessage(action: "Pause", error: error)
        }
    }

    /// Convert an `APIError` (or any `Error`) into a one-line user-readable
    /// banner string. Surfaces the route's `pause_store_failure` detail
    /// when present so users see "Couldn't pause: pause store storage error
    /// — disk full" rather than just "HTTP 500".
    private func userFacingErrorMessage(action: String, error: Error) -> String {
        let detail: String
        if let apiErr = error as? APIError {
            switch apiErr {
            case .unauthorized:
                detail = "the local API rejected the request"
            case .httpError(let code):
                detail = "the local API returned HTTP \(code)"
            case .invalidResponse:
                detail = "the local API returned an invalid response"
            default:
                detail = error.localizedDescription
            }
        } else {
            detail = error.localizedDescription
        }
        return "\(action) failed: \(detail)"
    }

    private func handleBecameKey() {
        guard isStarted else { return }
        startTimerIfNeeded(immediateFetch: true)
    }

    private func handleResignedKey() {
        guard isStarted else { return }
        // If another IR window is still key, keep polling.
        if NSApp?.keyWindow != nil { return }
        timer?.invalidate()
        timer = nil
    }

    private func startTimerIfNeeded(immediateFetch: Bool) {
        if timer != nil {
            if immediateFetch { Task { await self.fetchOnce() } }
            return
        }
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.fetchOnce()
            }
        }
        // Ensure the timer fires while menus / drags hold the run loop.
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if immediateFetch {
            Task { await self.fetchOnce() }
        }
    }

    private func fetchOnce() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        do {
            let snap = try await APIClient.shared.getActivitySnapshot()
            self.snapshot = await snapshotWithAuthoritativeQueueDepth(snap)
            self.lastError = nil
            self.hasReceivedFirstSnapshot = true
            self.coldStartFailureCount = 0
        } catch APIError.daemonNotConfigured {
            // Distinct UI message: tells the user the daemon URL is unset
            // (almost always means `scripts/run.sh` wasn't re-run after a
            // checkout), instead of letting it fall through to a misleading
            // generic "HTTP error: 404" string.
            //
            // This is a *configuration* error (not a daemon-startup race), so
            // it is never silenced by the cold-start grace.
            self.lastError = APIError.daemonNotConfigured.localizedDescription
        } catch {
            // Issue #104 — cold-start grace. If we haven't yet seen a
            // successful snapshot AND the error is a transient daemon-startup
            // indicator (timeout, connection refused, 5xx, 401 token rotation),
            // don't surface a banner yet — the 1 Hz timer will retry and
            // almost always succeeds within the next few ticks. Only surface
            // the error after `coldStartGraceAttempts` consecutive transient
            // failures. The first `coldStartGraceAttempts` are suppressed
            // (tick 5 still suppressed, tick 6 surfaces) — see
            // `testGraceWindowSuppressesFirst5TransientFailures`.
            if !hasReceivedFirstSnapshot,
               Self.isTransientStartupError(error) {
                coldStartFailureCount += 1
                if coldStartFailureCount <= Self.coldStartGraceAttempts {
                    // Stay quiet during grace; preserve any prior error
                    // message so a stale banner doesn't get overwritten by
                    // a transient one. Log to /private/tmp/omi-dev.log so
                    // the suppression is observable when triaging "why is
                    // the banner not showing" reports.
                    NSLog(
                        "[activity-monitor] suppressed cold-start \(error) (\(coldStartFailureCount)/\(Self.coldStartGraceAttempts))"
                    )
                    return
                }
            }
            self.lastError = "snapshot failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Testability seam (Issue #104)
    //
    // `fetchOnce` calls `APIClient.shared` directly and there is no DI seam
    // for the network client at this layer (introducing one is out of scope
    // for this PR). The grace-window state machine is otherwise entirely
    // local to this service, so we expose narrow internal hooks that drive
    // the same state transitions from a test, without going through
    // URLSession. These mirror the exact branches in `fetchOnce` above.

    /// Drive the cold-start state machine as if a network error of `error`
    /// just occurred. Returns `true` if the error was suppressed (no banner),
    /// `false` if it was surfaced via `lastError`. Test-only.
    @discardableResult
    func _testHandleFetchError(_ error: Error) -> Bool {
        if case APIError.daemonNotConfigured = error {
            self.lastError = APIError.daemonNotConfigured.localizedDescription
            return false
        }
        if !hasReceivedFirstSnapshot, Self.isTransientStartupError(error) {
            coldStartFailureCount += 1
            if coldStartFailureCount <= Self.coldStartGraceAttempts {
                return true
            }
        }
        self.lastError = "snapshot failed: \(error.localizedDescription)"
        return false
    }

    /// Mark a successful snapshot as if `fetchOnce` succeeded. Test-only.
    func _testHandleFetchSuccess() {
        self.lastError = nil
        self.hasReceivedFirstSnapshot = true
        self.coldStartFailureCount = 0
    }

    /// Reset state as if `start()` ran from a not-started position. Test-only.
    func _testResetStartGrace() {
        hasReceivedFirstSnapshot = false
        coldStartFailureCount = 0
        self.lastError = nil
    }

    /// Transient errors that almost always clear themselves within a few
    /// 1 Hz polls during daemon launch / restart. Delegates to the shared
    /// `DaemonErrorClassifier` so this service, `InternalPostFailureTracker`,
    /// and `ProcessingGateReporter` can never drift apart again. Kept as a
    /// `static` here so existing tests can call
    /// `ActivityMonitorService.isTransientStartupError(...)` unchanged.
    nonisolated static func isTransientStartupError(_ error: Error) -> Bool {
        DaemonErrorClassifier.isTransient(error)
    }

    private func snapshotWithAuthoritativeQueueDepth(_ snap: ActivitySnapshot) async -> ActivitySnapshot {
        do {
            let depth = try await PendingWorkStorage.shared.depthSummary()
            return Self.snapshot(snap, applying: depth)
        } catch {
            // If the DB is not initialized yet, keep the daemon snapshot. The
            // Rust endpoint also reads `pending_work`; this overlay mainly
            // protects against stale legacy queue-depth pushes while Swift and
            // Rust are upgraded together.
            return snap
        }
    }

    nonisolated static func snapshot(_ snap: ActivitySnapshot, applying depth: PendingWorkDepth) -> ActivitySnapshot {
        let updatedKinds = snap.kinds.map { row -> KindRow in
            let key = pendingWorkKey(for: row.kind)
            return KindRow(
                kind: row.kind,
                inFlight: row.inFlight,
                queued: UInt32(clamping: depth.queued[key] ?? 0),
                failed: UInt32(clamping: depth.failed[key] ?? 0),
                lastDoneAt: row.lastDoneAt,
                pausedUntil: row.pausedUntil
            )
        }
        return ActivitySnapshot(
            kinds: updatedKinds,
            capture: snap.capture,
            resources: snap.resources,
            processingGate: snap.processingGate,
            generatedAt: snap.generatedAt
        )
    }

    nonisolated private static func pendingWorkKey(for kind: WorkKind) -> String {
        switch kind {
        case .transcribe: return PendingWork.Kind.transcribe.rawValue
        case .ocr: return PendingWork.Kind.ocr.rawValue
        case .summarize: return PendingWork.Kind.summarize.rawValue
        case .extractMemory: return PendingWork.Kind.extractMemory.rawValue
        case .extractActionItems: return PendingWork.Kind.extractActionItems.rawValue
        case .extractKG: return PendingWork.Kind.extractKG.rawValue
        }
    }

    /// Mutate `snapshot` in place to set/clear `paused_until` on the affected
    /// row. Caller passes `until = nil` to clear (resume).
    ///
    /// Issue #34: takes a typed `PauseTargetId` directly — no string→enum
    /// reverse lookup, and the type system prevents callers from passing an
    /// id that doesn't belong to its variant.
    private func applyOptimisticPause(target: PauseTargetId, until: Date?) {
        guard let current = snapshot else { return }

        switch target {
        case .kind(let kind):
            let updatedKinds = current.kinds.map { row -> KindRow in
                guard row.kind == kind else { return row }
                return KindRow(
                    kind: row.kind,
                    inFlight: row.inFlight,
                    queued: row.queued,
                    failed: row.failed,
                    lastDoneAt: row.lastDoneAt,
                    pausedUntil: until
                )
            }
            self.snapshot = ActivitySnapshot(
                kinds: updatedKinds,
                capture: current.capture,
                resources: current.resources,
                processingGate: current.processingGate,
                generatedAt: current.generatedAt
            )

        case .capture(let cap):
            let updatedCapture = current.capture.map { row -> CaptureRow in
                guard row.kind == cap else { return row }
                return CaptureRow(
                    kind: row.kind,
                    running: row.running,
                    pausedUntil: until
                )
            }
            self.snapshot = ActivitySnapshot(
                kinds: current.kinds,
                capture: updatedCapture,
                resources: current.resources,
                processingGate: current.processingGate,
                generatedAt: current.generatedAt
            )
        }
    }

    private func postPauseChanged() {
        NotificationCenter.default.post(
            name: ActivityNotifications.pauseChanged,
            object: nil
        )
    }
}
