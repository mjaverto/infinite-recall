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
    /// Issue #105: brain-map / knowledge-graph extraction. Mirrored on the
    /// wire so the Activity snapshot's per-kind table accounts for the same
    /// `pending_work` rows that `BatteryAwareScheduler.pendingWorkCount`
    /// (which feeds the menu-bar badge) already counts. Pre-#105 this
    /// kind was scheduler-internal only, producing the count mismatch
    /// reported in the bug.
    case extractKG = "extract_kg"
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

public enum ProcessKind: String, Codable, Hashable {
    case core
    case localModel = "local_model"
    case unknown

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        // Fallback to .unknown for forward-compat with newer daemons.
        self = ProcessKind(rawValue: raw) ?? .unknown
    }
}

/// Issue #35: the pre-#35 `GateReason` (`idle/device_active/on_battery/
/// thermal/locked/manual_pause/none/stub`) was a stringly-typed enum that
/// existed alongside an `allowed: Bool` permitting illegal combos like
/// `{allowed: true, reason: .manualPause}`. Replaced by `GateState`
/// (sum type) + `BlockReason` (only meaningful when blocked).
public enum BlockReason: String, Codable, Hashable, CaseIterable {
    case deviceActive = "device_active"
    case onBattery = "on_battery"
    case thermal
    case locked
    case manualPause = "manual_pause"
    /// Initial state before the first gate-state report from Swift
    /// arrives. Should only be observed during the brief boot window
    /// (~3s — one `ProcessingGateReporter` poll cycle). External POSTs
    /// of this variant are rejected by the Rust `BridgedProcessingGate`.
    case initializing
}

/// Issue #35: typed mirror of Rust's `WaitCondition`. Replaces the
/// pre-#35 stringly-typed `Option<String>` on the wire (e.g.
/// `"2 min of idle"`) so the UI can render the right copy/icon
/// without parsing English.
///
/// Wire shape — internally-tagged sum on `type`:
/// ```json
/// {"type": "idle_for", "duration_secs": 120}
/// {"type": "ac_power"}
/// {"type": "thermal_cooldown"}
/// {"type": "unlock"}
/// {"type": "manual"}
/// ```
public enum WaitCondition: Codable, Hashable {
    case idleFor(seconds: UInt64)
    case acPower
    case thermalCooldown
    case unlock
    case manual

    private enum CodingKeys: String, CodingKey {
        case type
        case durationSecs = "duration_secs"
    }

    private enum TypeTag: String, Codable {
        case idleFor = "idle_for"
        case acPower = "ac_power"
        case thermalCooldown = "thermal_cooldown"
        case unlock = "unlock"
        case manual = "manual"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(TypeTag.self, forKey: .type)
        switch tag {
        case .idleFor:
            let secs = try c.decode(UInt64.self, forKey: .durationSecs)
            self = .idleFor(seconds: secs)
        case .acPower: self = .acPower
        case .thermalCooldown: self = .thermalCooldown
        case .unlock: self = .unlock
        case .manual: self = .manual
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idleFor(let secs):
            try c.encode(TypeTag.idleFor, forKey: .type)
            try c.encode(secs, forKey: .durationSecs)
        case .acPower: try c.encode(TypeTag.acPower, forKey: .type)
        case .thermalCooldown: try c.encode(TypeTag.thermalCooldown, forKey: .type)
        case .unlock: try c.encode(TypeTag.unlock, forKey: .type)
        case .manual: try c.encode(TypeTag.manual, forKey: .type)
        }
    }
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
    public let memMb: UInt32
    public let kind: ProcessKind?

    enum CodingKeys: String, CodingKey {
        case name
        case pid
        case cpuPercent = "cpu_percent"
        case memMb = "mem_mb"
        case kind
    }

    public init(name: String, pid: Int32, cpuPercent: Float, memMb: UInt32, kind: ProcessKind? = nil) {
        self.name = name
        self.pid = pid
        self.cpuPercent = cpuPercent
        self.memMb = memMb
        self.kind = kind
    }
}

public struct ResourceSample: Codable, Hashable {
    public let cpuPercent: Float
    public let memMb: UInt32
    public let gpuSystemPercent: Float?
    public let thermalState: ThermalState
    public let onBattery: Bool
    public let lowPower: Bool
    public let processBreakdown: [ProcessBreakdown]

    enum CodingKeys: String, CodingKey {
        case cpuPercent = "cpu_percent"
        case memMb = "mem_mb"
        case gpuSystemPercent = "gpu_system_percent"
        case thermalState = "thermal_state"
        case onBattery = "on_battery"
        case lowPower = "low_power"
        case processBreakdown = "process_breakdown"
    }

    public init(
        cpuPercent: Float,
        memMb: UInt32,
        gpuSystemPercent: Float?,
        thermalState: ThermalState,
        onBattery: Bool,
        lowPower: Bool,
        processBreakdown: [ProcessBreakdown]
    ) {
        self.cpuPercent = cpuPercent
        self.memMb = memMb
        self.gpuSystemPercent = gpuSystemPercent
        self.thermalState = thermalState
        self.onBattery = onBattery
        self.lowPower = lowPower
        self.processBreakdown = processBreakdown
    }
}

/// Issue #35: `GateState` is a sum type. The pre-#35 struct
/// `{allowed: Bool, reason: GateReason, since: Date, waitingFor: String?}`
/// permitted illegal combinations and a stringly-typed `waitingFor`. Now
/// each variant carries exactly the data that's meaningful for it.
///
/// Wire shape — internally-tagged on `state`:
/// ```json
/// {"state": "allowed", "since": "..."}
/// {"state": "blocked", "reason": "device_active", "since": "...",
///  "waiting_for": {"type": "idle_for", "duration_secs": 120}}
/// ```
public enum GateState: Codable, Hashable {
    case allowed(since: Date)
    case blocked(reason: BlockReason, since: Date, waitingFor: WaitCondition)

    private enum CodingKeys: String, CodingKey {
        case state
        case reason
        case since
        case waitingFor = "waiting_for"
    }

    private enum StateTag: String, Codable {
        case allowed
        case blocked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(StateTag.self, forKey: .state)
        let since = try c.decode(Date.self, forKey: .since)
        switch tag {
        case .allowed:
            self = .allowed(since: since)
        case .blocked:
            let reason = try c.decode(BlockReason.self, forKey: .reason)
            let waiting = try c.decode(WaitCondition.self, forKey: .waitingFor)
            self = .blocked(reason: reason, since: since, waitingFor: waiting)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allowed(let since):
            try c.encode(StateTag.allowed, forKey: .state)
            try c.encode(since, forKey: .since)
        case .blocked(let reason, let since, let waitingFor):
            try c.encode(StateTag.blocked, forKey: .state)
            try c.encode(reason, forKey: .reason)
            try c.encode(since, forKey: .since)
            try c.encode(waitingFor, forKey: .waitingFor)
        }
    }

    // MARK: Convenience accessors

    /// `true` iff this is the `.allowed` variant. The boolean is fully
    /// derivable from the variant — that's the whole point of the sum.
    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    /// Timestamp the current variant became active.
    public var since: Date {
        switch self {
        case .allowed(let s): return s
        case .blocked(_, let s, _): return s
        }
    }

    /// `BlockReason` if blocked, else `nil`.
    public var blockReason: BlockReason? {
        if case .blocked(let r, _, _) = self { return r }
        return nil
    }

    /// `WaitCondition` if blocked, else `nil`.
    public var waitingFor: WaitCondition? {
        if case .blocked(_, _, let w) = self { return w }
        return nil
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
