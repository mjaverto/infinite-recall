import Foundation

// Infinite Recall fork: this service no longer talks to a remote backend.
// Public API kept for compile compat; bodies are no-ops.

/// Background service for retrying failed transcription uploads
/// Runs a periodic timer to check for pending/failed sessions and attempt upload
class TranscriptionRetryService {
    static let shared = TranscriptionRetryService()

    private var retryTimer: Timer?
    private var isProcessing = false
    private let retryInterval: TimeInterval = 60  // Check every 60 seconds
    private let maxRetries = 5
    private var consecutiveDBFailures = 0
    private let maxConsecutiveDBFailures = 3

    private init() {}

    // MARK: - Service Lifecycle

    /// Start the retry service (call on app launch)
    func start() {
        log("[backend-stripped] TranscriptionRetryService.start: no-op (local-first)")
        // Disabled for local-first fork: no periodic timer, no remote reconciliation.
        return
    }

    /// Stop the retry service (call on app termination)
    func stop() {
        // Disabled for local-first fork: no timer to invalidate, but keep API for callers.
        retryTimer?.invalidate()
        retryTimer = nil
    }

    // MARK: - Recovery

    /// Recover pending transcriptions on app launch
    /// Call this after database initialization
    func recoverPendingTranscriptions() async {
        log("[backend-stripped] TranscriptionRetryService.recoverPendingTranscriptions: no-op (local-first)")
        // Disabled for local-first fork: nothing to reconcile against a remote backend.
        return
    }

    // MARK: - Retry Queue Processing

    /// Process the retry queue (called periodically by timer)
    private func processRetryQueue() async {
        // Disabled for local-first fork: no remote backend to reconcile with.
        return
    }

    // MARK: - Stuck Session Recovery

    /// Recover a session stuck in 'uploading' — check if backend already has it before re-uploading
    private func recoverStuckSession(_ session: TranscriptionSessionRecord) async {
        // Disabled for local-first fork: no backend to check against.
        return
    }

    // MARK: - Reconciliation

    /// Reconcile a pending session with the backend.
    /// Since /v4/listen stores segments in Firestore as they stream, the backend already has the
    /// conversation data. We just need to find the matching backend conversation and mark local
    /// session as completed. No segment re-upload needed.
    private func reconcileSession(_ session: TranscriptionSessionRecord) async {
        // Disabled for local-first fork: no backend to reconcile with.
        return
    }

}
