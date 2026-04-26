// Activity Tab — Stream H. Singleton observer for pause state of live
// capture services and per-kind work.
//
// Two refresh triggers:
//  1. Periodic poll every 5s of the Rust pause store via APIClient.
//  2. Local NotificationCenter observer on
//     `ActivityNotifications.pauseChanged`, posted by Stream F's UI when
//     the user toggles a pause so live capture services react instantly
//     instead of waiting for the next 5s tick.
//
// Consumers (AudioCaptureService, ScreenCaptureService, the future
// scheduler in Stream G, Stream F's UI) call `isPaused(target:id:)` (or
// `isPausedSync` from non-isolated contexts) to gate work. Keys are stored
// as `"<target>/<id>"` so a single dictionary covers both `"capture"` and
// `"kind"` namespaces.

import Foundation
import Combine
import os

final class CapturePauseGate: ObservableObject {
    static let shared = CapturePauseGate()

    /// Map of `"<target>/<id>"` → absolute resume timestamp. An entry is
    /// only present while the pause is in the future; expired entries are
    /// pruned on read so consumers always see a truthful state.
    ///
    /// MainActor-isolated for SwiftUI publishing. Synchronous, non-isolated
    /// callers (e.g. `ScreenCaptureService.captureActiveWindow()`) must use
    /// `isPausedSync` / `pausedUntilSync`, which read the lock-protected
    /// `mirror` without hopping to the main thread (consensus-fix C6).
    @MainActor @Published private(set) var pauses: [String: Date] = [:]

    /// Lock-protected mirror of `pauses` for read-side use from non-isolated
    /// contexts. Every write to `pauses` MUST also write through to `mirror`
    /// so the two stay in sync. See `isPausedSync` for the intended consumer.
    private let mirror = OSAllocatedUnfairLock<[String: Date]>(initialState: [:])

    @MainActor private var pollTimer: Timer?
    @MainActor private var observer: NSObjectProtocol?
    @MainActor private var isStarted = false

    private init() {}

    // MARK: - Lifecycle

    /// Begin polling the Rust pause store and observing pause-change
    /// notifications. Idempotent.
    @MainActor
    func start() {
        guard !isStarted else { return }
        isStarted = true

        // Local notification: snappy refresh when the UI changes pause state.
        observer = NotificationCenter.default.addObserver(
            forName: ActivityNotifications.pauseChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Hop to the MainActor explicitly — the observer block is
            // not actor-isolated even though `queue: .main` runs it on the
            // main thread.
            Task { @MainActor in
                self?.handlePauseNotification(note)
            }
        }

        // 5s background poll. Use a Timer scheduled on the main runloop so
        // it interleaves cleanly with UI updates.
        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshFromBackend()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        // Kick off an initial refresh so the gate isn't "open" for 5s on
        // cold start when a pause is already live in the Rust store.
        Task { @MainActor in
            await self.refreshFromBackend()
        }
    }

    /// Stop polling and detach the notification observer. Safe to call
    /// from any state.
    @MainActor
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        isStarted = false
    }

    // MARK: - Reads (MainActor — for SwiftUI)

    /// Returns true iff the given (target, id) pair is paused at this
    /// instant. Expired entries are pruned as a side effect.
    @MainActor
    func isPaused(target: String, id: String) -> Bool {
        return pausedUntil(target: target, id: id) != nil
    }

    /// Returns the absolute resume timestamp for the (target, id) pair if
    /// it is currently paused, else nil. Prunes expired entries.
    @MainActor
    func pausedUntil(target: String, id: String) -> Date? {
        let key = Self.cacheKey(target: target, id: id)
        guard let until = pauses[key] else { return nil }
        if until > Date() {
            return until
        }
        // Expired — drop it so future reads don't keep returning a stale
        // truthy value.
        pauses.removeValue(forKey: key)
        mirror.withLock { $0.removeValue(forKey: key) }
        return nil
    }

    // MARK: - Reads (nonisolated — for sync capture entry points)

    /// Nonisolated read for callers that cannot hop to the MainActor (e.g.
    /// `ScreenCaptureService.captureActiveWindow()`, NotificationCenter
    /// observer closures). Reads the lock-protected `mirror`. Expired
    /// entries are pruned in-place so future reads stay truthful.
    nonisolated func isPausedSync(target: String, id: String) -> Bool {
        return pausedUntilSync(target: target, id: id) != nil
    }

    /// Nonisolated counterpart to `pausedUntil`. See `isPausedSync`.
    nonisolated func pausedUntilSync(target: String, id: String) -> Date? {
        let key = Self.cacheKey(target: target, id: id)
        let now = Date()
        return mirror.withLock { dict -> Date? in
            guard let until = dict[key] else { return nil }
            if until > now { return until }
            dict.removeValue(forKey: key)
            return nil
        }
    }

    // MARK: - Writes (used by UI for optimistic local updates)

    /// Optimistically record a pause locally. Stream F's UI can call this
    /// the instant the user taps "Pause" so consumers see the gate flip
    /// before the backend round-trip completes. The next backend refresh
    /// will overwrite this with the authoritative value.
    @MainActor
    func recordLocalPause(target: String, id: String, until: Date) {
        let key = Self.cacheKey(target: target, id: id)
        pauses[key] = until
        mirror.withLock { $0[key] = until }
        NotificationCenter.default.post(
            name: ActivityNotifications.pauseChanged,
            object: nil,
            userInfo: ["target": target, "id": id, "until": until]
        )
    }

    /// Optimistically clear a pause locally (mirror of recordLocalPause).
    @MainActor
    func clearLocalPause(target: String, id: String) {
        let key = Self.cacheKey(target: target, id: id)
        pauses.removeValue(forKey: key)
        mirror.withLock { $0.removeValue(forKey: key) }
        NotificationCenter.default.post(
            name: ActivityNotifications.pauseChanged,
            object: nil,
            userInfo: ["target": target, "id": id]
        )
    }

    // MARK: - Internals

    private static func cacheKey(target: String, id: String) -> String {
        return "\(target)/\(id)"
    }

    @MainActor
    private func handlePauseNotification(_ note: Notification) {
        // Apply any inline hint from the notification payload first so the
        // gate flips synchronously from the publisher's perspective …
        if let target = note.userInfo?["target"] as? String,
           let id = note.userInfo?["id"] as? String {
            let key = Self.cacheKey(target: target, id: id)
            if let until = note.userInfo?["until"] as? Date {
                pauses[key] = until
                mirror.withLock { $0[key] = until }
            } else {
                // No `until` → treat as resume.
                pauses.removeValue(forKey: key)
                mirror.withLock { $0.removeValue(forKey: key) }
            }
        }
        // …then refresh from the backend so we re-converge on the
        // authoritative state.
        Task { @MainActor in
            await self.refreshFromBackend()
        }
    }

    /// Pull the latest `ActivitySnapshot` and refresh the local map.
    /// Stream F has shipped `getActivitySnapshot()` so we always call it.
    /// Errors are logged so the failure is observable; we fall back to the
    /// last-known map (consensus-fix C2 — no more silent #else return nil).
    @MainActor
    private func refreshFromBackend() async {
        let snapshot: ActivitySnapshot
        do {
            snapshot = try await Self.fetchSnapshot()
        } catch {
            logError("CapturePauseGate snapshot fetch failed", error: error)
            return
        }
        var next: [String: Date] = [:]
        let now = Date()

        for row in snapshot.capture {
            if let until = row.pausedUntil, until > now {
                next[Self.cacheKey(target: "capture", id: row.kind.rawValue)] = until
            }
        }
        for row in snapshot.kinds {
            if let until = row.pausedUntil, until > now {
                next[Self.cacheKey(target: "kind", id: row.kind.rawValue)] = until
            }
        }

        if next != pauses {
            pauses = next
            // Write-through so non-isolated readers see the authoritative
            // state without waiting for individual notification fanouts.
            mirror.withLock { $0 = next }
        }
    }

    /// Throwing fetch — Stream F shipped `getActivitySnapshot()` so the call
    /// always exists; no compile-time feature flag is needed.
    private static func fetchSnapshot() async throws -> ActivitySnapshot {
        return try await APIClient.shared.getActivitySnapshot()
    }
}
