import Foundation
import HeapSwiftCore
import FirebaseAuth

// Infinite Recall fork: telemetry disabled. All public methods are no-ops.
// SDK imports are kept so the rest of the codebase compiles.

/// Singleton manager for Heap analytics — tracks signup/k-factor events only.
/// Complements MixpanelManager and PostHogManager via AnalyticsManager dispatch.
@MainActor
class HeapManager {
    static let shared = HeapManager()

    private let appId = "2191797670"
    private var isInitialized = false

    private init() {}

    // MARK: - Initialization

    func initialize() {
        log("[telemetry-stripped] HeapManager.initialize: no-op (Infinite Recall is local-first)")
        // Disabled for local-first fork: Heap.shared.startRecording(appId)
        return
    }

    // MARK: - User Identification

    func identify() {
        // Disabled for local-first fork: Heap.shared.identify(uid)
        // Disabled for local-first fork: Heap.shared.addUserProperties(properties)
    }

    // MARK: - Reset

    func reset() {
        // Disabled for local-first fork: Heap.shared.resetIdentity()
    }

    // MARK: - Event Tracking

    func track(_ eventName: String, properties: [String: String]? = nil) {
        // Disabled for local-first fork: Heap.shared.track(eventName, properties: properties)
    }
}
