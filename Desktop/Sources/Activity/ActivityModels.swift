// Activity Tab — Phase 0 contract freeze.
//
// Codable mirrors of `Backend-Rust/src/activity/types.rs`. Field names use
// snake_case on the wire; we map via CodingKeys.
//
// **Do not change a field without updating both the Rust type and
// `Backend-Rust/src/activity/contract.md`.**
//
// Owner: Stream F. (Phase 0 ships the types; F flesh-out lives here.)

import Foundation

// MARK: - Enums

public enum WorkKind: String, Codable, CaseIterable, Hashable {
    case transcribe
    case ocr
    case summarize
    case extractMemory = "extract_memory"
    case extractActionItems = "extract_action_items"
}

public enum CaptureKind: String, Codable, CaseIterable, Hashable {
    case audio
    case screen
}

public enum PauseTarget: String, Codable, Hashable {
    case kind
    case capture
}

public enum ThermalState: String, Codable, Hashable {
    case nominal
    case fair
    case serious
    case critical
}

public enum GateReason: String, Codable, Hashable {
    case idle
    case deviceActive = "device_active"
    case onBattery = "on_battery"
    case thermal
    case locked
    case manualPause = "manual_pause"
    case none
}

// MARK: - Inner shapes

public struct InFlight: Codable, Hashable {
    public let label: String
    public let startedAt: Date

    enum CodingKeys: String, CodingKey {
        case label
        case startedAt = "started_at"
    }

    public init(label: String, startedAt: Date) {
        self.label = label
        self.startedAt = startedAt
    }
}

public struct KindRow: Codable, Hashable {
    public let kind: WorkKind
    public let inFlight: InFlight?
    public let queued: UInt32
    public let failed: UInt32
    public let lastDoneAt: Date?
    public let pausedUntil: Date?

    enum CodingKeys: String, CodingKey {
        case kind
        case inFlight = "in_flight"
        case queued
        case failed
        case lastDoneAt = "last_done_at"
        case pausedUntil = "paused_until"
    }
}

public struct CaptureRow: Codable, Hashable {
    public let kind: CaptureKind
    public let running: Bool
    public let pausedUntil: Date?

    enum CodingKeys: String, CodingKey {
        case kind
        case running
        case pausedUntil = "paused_until"
    }
}

public struct ProcessBreakdown: Codable, Hashable {
    public let name: String
    public let pid: Int32
    public let cpuPercent: Float
    public let rssMb: UInt32

    enum CodingKeys: String, CodingKey {
        case name
        case pid
        case cpuPercent = "cpu_percent"
        case rssMb = "rss_mb"
    }
}

public struct ResourceSample: Codable, Hashable {
    public let cpuPercent: Float
    public let rssMb: UInt32
    public let gpuSystemPercent: Float?
    public let thermalState: ThermalState
    public let onBattery: Bool
    public let lowPower: Bool
    public let processBreakdown: [ProcessBreakdown]

    enum CodingKeys: String, CodingKey {
        case cpuPercent = "cpu_percent"
        case rssMb = "rss_mb"
        case gpuSystemPercent = "gpu_system_percent"
        case thermalState = "thermal_state"
        case onBattery = "on_battery"
        case lowPower = "low_power"
        case processBreakdown = "process_breakdown"
    }
}

public struct GateState: Codable, Hashable {
    public let allowed: Bool
    public let reason: GateReason
    public let since: Date
    public let waitingFor: String?

    enum CodingKeys: String, CodingKey {
        case allowed
        case reason
        case since
        case waitingFor = "waiting_for"
    }
}

// MARK: - Top-level snapshot

public struct ActivitySnapshot: Codable, Hashable {
    public let kinds: [KindRow]
    public let capture: [CaptureRow]
    public let resources: ResourceSample
    public let processingGate: GateState
    public let generatedAt: Date

    enum CodingKeys: String, CodingKey {
        case kinds
        case capture
        case resources
        case processingGate = "processing_gate"
        case generatedAt = "generated_at"
    }
}

// MARK: - Request bodies

public struct PauseRequest: Codable {
    public let target: PauseTarget
    public let id: String
    public let minutes: UInt32

    public init(target: PauseTarget, id: String, minutes: UInt32) {
        self.target = target
        self.id = id
        self.minutes = minutes
    }
}

public struct ResumeRequest: Codable {
    public let target: PauseTarget
    public let id: String

    public init(target: PauseTarget, id: String) {
        self.target = target
        self.id = id
    }
}

public struct InflightUpdate: Codable {
    public let kind: String
    public let inFlight: InFlight?

    enum CodingKeys: String, CodingKey {
        case kind
        case inFlight = "in_flight"
    }

    public init(kind: String, inFlight: InFlight?) {
        self.kind = kind
        self.inFlight = inFlight
    }
}

// MARK: - Notification names + UserDefaults keys (shared across streams)

public enum ActivityNotifications {
    /// Posted when a pause/resume change is observed locally so live capture
    /// services (Stream H) can react without polling.
    public static let pauseChanged = Notification.Name("activityPauseChanged")
}

public enum ActivityDefaultsKeys {
    /// Local cache of the most recent snapshot's `processing_gate` for snappy
    /// UI on cold start. Owned by Stream F.
    public static let lastGateStateJSON = "activity.lastGateStateJSON"
}
