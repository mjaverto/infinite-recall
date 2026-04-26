// Activity Tab — Stream H. Singleton observer for pause state of live
// capture services and per-kind work.
//
// Two refresh triggers:
//  1. Periodic poll every 5s of the Rust pause store via APIClient (best
//     effort — falls back to last-known map if the snapshot fetch is not
//     available yet, e.g. before Stream F lands `getActivitySnapshot`).
//  2. Local NotificationCenter observer on
//     `ActivityNotifications.pauseChanged`, posted by Stream F's UI when
//     the user toggles a pause so live capture services react instantly
//     instead of waiting for the next 5s tick.
//
// Consumers (AudioCaptureService, ScreenCaptureService, the future
// scheduler in Stream G, Stream F's UI) call `isPaused(target:id:)` to
// gate work. Keys are stored as `"<target>/<id>"` so a single dictionary
// covers both `"capture"` and `"kind"` namespaces.

import Foundation
import Combine

@MainActor
final class CapturePauseGate: ObservableObject {
    static let shared = CapturePauseGate()

    /// Map of `"<target>/<id>"` → absolute resume timestamp. An entry is
    /// only present while the pause is in the future; expired entries are
    /// pruned on read so consumers always see a truthful state.
    @Published private(set) var pauses: [String: Date] = [:]

    private var pollTimer: Timer?
    private var observer: NSObjectProtocol?
    private var isStarted = false

    private init() {}

    // MARK: - Lifecycle

    /// Begin polling the Rust pause store and observing pause-change
    /// notifications. Idempotent.
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
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        isStarted = false
    }

    // MARK: - Reads

    /// Returns true iff the given (target, id) pair is paused at this
    /// instant. Expired entries are pruned as a side effect.
    func isPaused(target: String, id: String) -> Bool {
        return pausedUntil(target: target, id: id) != nil
    }

    /// Returns the absolute resume timestamp for the (target, id) pair if
    /// it is currently paused, else nil. Prunes expired entries.
    func pausedUntil(target: String, id: String) -> Date? {
        let key = Self.cacheKey(target: target, id: id)
        guard let until = pauses[key] else { return nil }
        if until > Date() {
            return until
        }
        // Expired — drop it so future reads don't keep returning a stale
        // truthy value.
        pauses.removeValue(forKey: key)
        return nil
    }

    // MARK: - Writes (used by UI for optimistic local updates)

    /// Optimistically record a pause locally. Stream F's UI can call this
    /// the instant the user taps "Pause" so consumers see the gate flip
    /// before the backend round-trip completes. The next backend refresh
    /// will overwrite this with the authoritative value.
    func recordLocalPause(target: String, id: String, until: Date) {
        let key = Self.cacheKey(target: target, id: id)
        pauses[key] = until
        NotificationCenter.default.post(
            name: ActivityNotifications.pauseChanged,
            object: nil,
            userInfo: ["target": target, "id": id, "until": until]
        )
    }

    /// Optimistically clear a pause locally (mirror of recordLocalPause).
    func clearLocalPause(target: String, id: String) {
        let key = Self.cacheKey(target: target, id: id)
        pauses.removeValue(forKey: key)
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

    private func handlePauseNotification(_ note: Notification) {
        // Apply any inline hint from the notification payload first so the
        // gate flips synchronously from the publisher's perspective …
        if let target = note.userInfo?["target"] as? String,
           let id = note.userInfo?["id"] as? String {
            let key = Self.cacheKey(target: target, id: id)
            if let until = note.userInfo?["until"] as? Date {
                pauses[key] = until
            } else {
                // No `until` → treat as resume.
                pauses.removeValue(forKey: key)
            }
        }
        // …then refresh from the backend so we re-converge on the
        // authoritative state.
        Task { @MainActor in
            await self.refreshFromBackend()
        }
    }

    /// Pull the latest `ActivitySnapshot` and refresh the local map.
    /// Resilient to the API method being absent (Stream F still in
    /// flight) — uses dynamic dispatch via `APIClient.shared` and
    /// silently no-ops if the call throws or the symbol is unavailable.
    private func refreshFromBackend() async {
        guard let snapshot = await Self.fetchSnapshotIfAvailable() else {
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
        }
    }

    /// Bridge to APIClient that tolerates the absence of
    /// `getActivitySnapshot()` (Stream F may not have landed yet on this
    /// branch). Returns nil on any failure.
    private static func fetchSnapshotIfAvailable() async -> ActivitySnapshot? {
        // Stream F is expected to add `func getActivitySnapshot() async
        // throws -> ActivitySnapshot` to APIClient. Until then this gate
        // just runs notification-only; the optimistic local write path
        // (recordLocalPause / clearLocalPause) keeps the UX correct.
        #if ACTIVITY_API_AVAILABLE
        do {
            return try await APIClient.shared.getActivitySnapshot()
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}
