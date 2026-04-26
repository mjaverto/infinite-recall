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

/// Issue #34: typed sum mirror of Rust's `PauseTargetId`. The variant
/// payload carries the typed id (`WorkKind` or `CaptureKind`) so an
/// illegal combination — e.g. `kind` + `"audio"` — is unrepresentable
/// in Swift the same way it is in Rust.
///
/// Wire shape preserved (the pre-#34 `(target, id)` body):
/// ```
/// { "target": "kind",    "id": "transcribe" }
/// { "target": "capture", "id": "audio" }
/// ```
public enum PauseTargetId: Codable, Hashable {
    case kind(WorkKind)
    case capture(CaptureKind)

    enum CodingKeys: String, CodingKey {
        case target
        case id
    }

    /// Wire-format discriminator matching Rust's `serde(rename_all="snake_case")`.
    private enum TargetTag: String, Codable {
        case kind
        case capture
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(TargetTag.self, forKey: .target)
        switch tag {
        case .kind:
            let work = try c.decode(WorkKind.self, forKey: .id)
            self = .kind(work)
        case .capture:
            let cap = try c.decode(CaptureKind.self, forKey: .id)
            self = .capture(cap)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .kind(let k):
            try c.encode(TargetTag.kind, forKey: .target)
            try c.encode(k, forKey: .id)
        case .capture(let cap):
            try c.encode(TargetTag.capture, forKey: .target)
            try c.encode(cap, forKey: .id)
        }
    }
}

/// Validation error surfaced by `PauseRequest.init`. `minutes == 0` is
/// the only condition; mirror's the Rust `NonZeroU32` deserialize check.
public enum PauseRequestError: Error, Equatable {
    case zeroMinutes
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
    /// `AlwaysAllowedGate` placeholder is in use — real `ProcessingGate`
    /// not yet wired (issue #32). Consensus-fix C4: surface honestly in
    /// the UI instead of pretending idle processing is running.
    case stub
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

    public init(
        kind: WorkKind,
        inFlight: InFlight?,
        queued: UInt32,
        failed: UInt32,
        lastDoneAt: Date?,
        pausedUntil: Date?
    ) {
        self.kind = kind
        self.inFlight = inFlight
        self.queued = queued
        self.failed = failed
        self.lastDoneAt = lastDoneAt
        self.pausedUntil = pausedUntil
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

    public init(kind: CaptureKind, running: Bool, pausedUntil: Date?) {
        self.kind = kind
        self.running = running
        self.pausedUntil = pausedUntil
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

    public init(name: String, pid: Int32, cpuPercent: Float, rssMb: UInt32) {
        self.name = name
        self.pid = pid
        self.cpuPercent = cpuPercent
        self.rssMb = rssMb
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

    public init(
        cpuPercent: Float,
        rssMb: UInt32,
        gpuSystemPercent: Float?,
        thermalState: ThermalState,
        onBattery: Bool,
        lowPower: Bool,
        processBreakdown: [ProcessBreakdown]
    ) {
        self.cpuPercent = cpuPercent
        self.rssMb = rssMb
        self.gpuSystemPercent = gpuSystemPercent
        self.thermalState = thermalState
        self.onBattery = onBattery
        self.lowPower = lowPower
        self.processBreakdown = processBreakdown
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

    public init(allowed: Bool, reason: GateReason, since: Date, waitingFor: String?) {
        self.allowed = allowed
        self.reason = reason
        self.since = since
        self.waitingFor = waitingFor
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

    public init(
        kinds: [KindRow],
        capture: [CaptureRow],
        resources: ResourceSample,
        processingGate: GateState,
        generatedAt: Date
    ) {
        self.kinds = kinds
        self.capture = capture
        self.resources = resources
        self.processingGate = processingGate
        self.generatedAt = generatedAt
    }
}

// MARK: - Request bodies

/// POST /v1/activity/pause body. Issue #34: `target` is a typed sum so
/// `kind`+`"audio"` is unrepresentable; `minutes > 0` is checked in `init`
/// to mirror Rust's `NonZeroU32`. The wire shape stays
/// `{target, id, minutes}` because `PauseTargetId.encode(to:)` flattens
/// its two keys directly into the request body.
public struct PauseRequest: Codable {
    public let target: PauseTargetId
    public let minutes: UInt32

    /// Throwing init enforces the `minutes > 0` invariant up front so
    /// the Rust daemon never sees a zero-minute pause.
    public init(target: PauseTargetId, minutes: UInt32) throws {
        guard minutes > 0 else { throw PauseRequestError.zeroMinutes }
        self.target = target
        self.minutes = minutes
    }

    enum CodingKeys: String, CodingKey {
        case minutes
    }

    public init(from decoder: Decoder) throws {
        // Decode the flattened target/id pair from the same container, then
        // pull `minutes` from the keyed view.
        self.target = try PauseTargetId(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let mins = try c.decode(UInt32.self, forKey: .minutes)
        guard mins > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .minutes,
                in: c,
                debugDescription: "minutes must be > 0 (mirrors Rust NonZeroU32)"
            )
        }
        self.minutes = mins
    }

    public func encode(to encoder: Encoder) throws {
        // Flatten target/id into the same encoder container as `minutes`.
        try target.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(minutes, forKey: .minutes)
    }
}

/// POST /v1/activity/resume body. Wire shape `{target, id}` — `target` is
/// a typed sum after #34.
public struct ResumeRequest: Codable {
    public let target: PauseTargetId

    public init(target: PauseTargetId) {
        self.target = target
    }

    public init(from decoder: Decoder) throws {
        self.target = try PauseTargetId(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try target.encode(to: encoder)
    }
}

public struct InflightUpdate: Codable {
    public let kind: WorkKind
    public let inFlight: InFlight?

    enum CodingKeys: String, CodingKey {
        case kind
        case inFlight = "in_flight"
    }

    public init(kind: WorkKind, inFlight: InFlight?) {
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
