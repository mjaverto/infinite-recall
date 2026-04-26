//! Serde shapes shared by the REST surface and Phase 1 stream impls.
//!
//! These are the wire types the Swift `ActivityModels.swift` mirror is
//! generated from. **Do not change a field name without updating both
//! `contract.md` and `Desktop/Sources/Activity/ActivityModels.swift`.**

use std::num::NonZeroU32;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// One of the deferred-work kinds the scheduler drains.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WorkKind {
    Transcribe,
    Ocr,
    Summarize,
    ExtractMemory,
    ExtractActionItems,
}

/// Live capture surfaces (separate from deferred work).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CaptureKind {
    Audio,
    Screen,
}

/// What `Pause`/`Resume` requests target. The variant payload carries the
/// concrete typed id, so illegal `(target, id)` combinations are
/// unrepresentable (issue #34): you cannot construct
/// `PauseTargetId::Kind("audio")` because `"audio"` is not a `WorkKind`.
///
/// Wire shape (preserved for backwards compatibility with the pre-#34
/// `(target, id)` body):
/// ```json
/// { "target": "kind",    "id": "transcribe" }
/// { "target": "capture", "id": "audio" }
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "target", content = "id", rename_all = "snake_case")]
pub enum PauseTargetId {
    Kind(WorkKind),
    Capture(CaptureKind),
}

impl PauseTargetId {
    /// Storage-layer projection: `("kind"|"capture", snake_case_id)`.
    /// Used by `SqlPauseStore` to keep the on-disk schema unchanged
    /// across the #34 refactor.
    pub fn as_storage_pair(&self) -> (&'static str, &'static str) {
        match self {
            PauseTargetId::Kind(k) => ("kind", k.as_str()),
            PauseTargetId::Capture(c) => ("capture", c.as_str()),
        }
    }
}

impl WorkKind {
    /// snake_case wire/storage id (matches `#[serde(rename_all)]`).
    pub fn as_str(&self) -> &'static str {
        match self {
            WorkKind::Transcribe => "transcribe",
            WorkKind::Ocr => "ocr",
            WorkKind::Summarize => "summarize",
            WorkKind::ExtractMemory => "extract_memory",
            WorkKind::ExtractActionItems => "extract_action_items",
        }
    }
}

impl CaptureKind {
    /// snake_case wire/storage id (matches `#[serde(rename_all)]`).
    pub fn as_str(&self) -> &'static str {
        match self {
            CaptureKind::Audio => "audio",
            CaptureKind::Screen => "screen",
        }
    }
}

/// macOS thermal pressure (mirrors `NSProcessInfo.ThermalState`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ThermalState {
    Nominal,
    Fair,
    Serious,
    Critical,
}

/// Why deferred work is or is not draining.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GateReason {
    /// Device is idle and we are draining.
    Idle,
    /// User is actively using the device.
    DeviceActive,
    /// On battery and policy says wait for AC.
    OnBattery,
    /// Thermal pressure is too high.
    Thermal,
    /// Screen locked / session inactive.
    Locked,
    /// User manually paused via the Activity tab.
    ManualPause,
    /// No gating reason; trivial baseline.
    None,
    /// `AlwaysAllowedGate` placeholder is in use — the real `ProcessingGate`
    /// owned by the idle-gate agent has not been wired yet (issue #32).
    /// Consensus-fix C4: surface this so the UI doesn't gaslight users with
    /// "Idle processing — running" when in reality no work drains.
    Stub,
}

/// Single in-flight task currently executing for a given `WorkKind`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InFlight {
    /// Human label e.g. `"Transcribing 14:22:01→14:25:00 (en)"`.
    pub label: String,
    pub started_at: DateTime<Utc>,
}

/// One row in the per-kind table.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KindRow {
    pub kind: WorkKind,
    pub in_flight: Option<InFlight>,
    pub queued: u32,
    pub failed: u32,
    pub last_done_at: Option<DateTime<Utc>>,
    pub paused_until: Option<DateTime<Utc>>,
}

/// One row in the live-capture section.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CaptureRow {
    pub kind: CaptureKind,
    pub running: bool,
    pub paused_until: Option<DateTime<Utc>>,
}

/// Per-process sample line.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessBreakdown {
    pub name: String,
    pub pid: i32,
    pub cpu_percent: f32,
    pub rss_mb: u32,
}

/// One sample tick of system resources.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResourceSample {
    /// Sum of `process_breakdown[*].cpu_percent`.
    pub cpu_percent: f32,
    /// Sum of `process_breakdown[*].rss_mb`.
    pub rss_mb: u32,
    /// System-wide GPU utilisation, when available (Apple Silicon).
    pub gpu_system_percent: Option<f32>,
    pub thermal_state: ThermalState,
    pub on_battery: bool,
    pub low_power: bool,
    pub process_breakdown: Vec<ProcessBreakdown>,
}

/// Snapshot of the idle/processing gate at sample time.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GateState {
    /// Whether deferred-work claims are allowed right now.
    pub allowed: bool,
    pub reason: GateReason,
    /// When the current `reason` started.
    pub since: DateTime<Utc>,
    /// Optional human-readable resume condition, e.g.
    /// `"2 min of idle"`, `"AC power"`, `"thermal cooldown"`.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub waiting_for: Option<String>,
}

/// Top-level GET /v1/activity/snapshot response.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActivitySnapshot {
    pub kinds: Vec<KindRow>,
    pub capture: Vec<CaptureRow>,
    pub resources: ResourceSample,
    pub processing_gate: GateState,
    pub generated_at: DateTime<Utc>,
}

/// POST /v1/activity/pause body.
///
/// Issue #34: the `(target, id)` pair is now a typed `PauseTargetId` sum
/// type — `serde(flatten)` keeps the wire shape `{target, id, minutes}`
/// identical, but illegal combinations like `target=kind, id="audio"`
/// no longer deserialize. `NonZeroU32` likewise rejects `minutes: 0` at
/// the serde layer, so the route handler no longer needs a manual check.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PauseRequest {
    #[serde(flatten)]
    pub target: PauseTargetId,
    pub minutes: NonZeroU32,
}

/// POST /v1/activity/resume body.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResumeRequest {
    #[serde(flatten)]
    pub target: PauseTargetId,
}

/// POST /v1/activity/_internal/inflight body (Swift → Rust loopback).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InflightUpdate {
    /// `WorkKind` snake_case string.
    pub kind: String,
    /// `None` clears the slot.
    pub in_flight: Option<InFlight>,
}
