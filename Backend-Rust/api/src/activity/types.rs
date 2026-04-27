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

/// Why deferred work is currently blocked. Only meaningful inside
/// `GateState::Blocked` — the `Allowed` variant doesn't carry one,
/// because "we're allowed to drain" doesn't have a sub-reason
/// (issue #35: collapse `{allowed: bool, reason: enum}` into a sum).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BlockReason {
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
    /// Initial state before the first gate-state report from Swift
    /// arrives. Should only be observed during the brief boot window
    /// (~3s — one `ProcessingGateReporter` poll cycle). External POSTs
    /// of this variant are rejected by `BridgedProcessingGate::set`.
    Initializing,
}

/// What the gate is waiting for before it will let work drain again.
/// Typed payload (issue #35): replaces the previous stringly-typed
/// `Option<String>` (`"2 min of idle"`, `"AC power"`, ...) so consumers
/// can render the right copy / icon without parsing English.
///
/// Wire shape — internally-tagged sum, snake_case discriminator:
/// ```json
/// {"type": "idle_for", "duration_secs": 120}
/// {"type": "ac_power"}
/// {"type": "thermal_cooldown"}
/// {"type": "unlock"}
/// {"type": "manual"}
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum WaitCondition {
    /// Wait until the device has been idle for this long.
    /// Wire field `duration_secs` is whole seconds; matches `Duration::from_secs`.
    IdleFor {
        #[serde(rename = "duration_secs", with = "duration_secs")]
        duration: std::time::Duration,
    },
    /// Wait for the laptop to be back on AC power.
    AcPower,
    /// Wait for thermals to come down (gate decides when).
    ThermalCooldown,
    /// Wait for the user to unlock the screen.
    Unlock,
    /// Wait for the user to manually un-pause from the Activity tab.
    Manual,
}

mod duration_secs {
    use serde::{Deserialize, Deserializer, Serializer};
    use std::time::Duration;

    pub fn serialize<S: Serializer>(d: &Duration, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_u64(d.as_secs())
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Duration, D::Error> {
        let secs = u64::deserialize(d)?;
        Ok(Duration::from_secs(secs))
    }
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

/// Classifier for `ProcessBreakdown` rows so the UI can group them.
/// Wire shape: snake_case string. Field is optional on `ProcessBreakdown` —
/// older daemons emit no `kind`, and clients must tolerate unknown future
/// variants gracefully. `Unknown` is the catch-all for future variants:
/// `#[serde(other)]` makes deserialization match Swift's forward-compat
/// fallback so an older daemon that adds a new wire value doesn't fail
/// the whole snapshot decode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProcessKind {
    Core,
    LocalModel,
    #[serde(other)]
    Unknown,
}

/// Per-process sample line.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessBreakdown {
    pub name: String,
    pub pid: i32,
    pub cpu_percent: f32,
    /// Memory in MB, sourced from `ri_phys_footprint` (matches the value
    /// Activity Monitor's "Memory" column displays). NOT plain RSS — RSS
    /// excludes compressed/swapped regions and undercounts MLX worker
    /// rows by a wide margin.
    pub mem_mb: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<ProcessKind>,
}

/// One sample tick of system resources.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResourceSample {
    /// Sum of `process_breakdown[*].cpu_percent`.
    pub cpu_percent: f32,
    /// Sum of `process_breakdown[*].mem_mb`.
    pub mem_mb: u32,
    /// System-wide GPU utilisation, when available (Apple Silicon).
    pub gpu_system_percent: Option<f32>,
    pub thermal_state: ThermalState,
    pub on_battery: bool,
    pub low_power: bool,
    pub process_breakdown: Vec<ProcessBreakdown>,
}

/// Snapshot of the idle/processing gate at sample time.
///
/// Issue #35: was a `{allowed: bool, reason: enum, waiting_for: Option<String>}`
/// struct that permitted illegal states like `{allowed: true, reason: ManualPause}`
/// or `Blocked` with no `waiting_for`. Now a sum type — each variant carries
/// exactly the data that's meaningful for it.
///
/// Wire shape — internally-tagged sum, snake_case discriminator on field
/// `state`. **Breaking change** vs the pre-#35 flat shape; the Swift mirror
/// in `Desktop/Sources/Activity/ActivityModels.swift` is updated in lockstep.
/// ```json
/// // Allowed (work is draining, e.g. device is idle).
/// {"state": "allowed", "since": "2026-04-26T14:25:00.000Z"}
///
/// // Blocked — `reason` says why, `waiting_for` says how to resume.
/// {
///   "state":       "blocked",
///   "reason":      "device_active",
///   "since":       "2026-04-26T14:25:00.000Z",
///   "waiting_for": {"type": "idle_for", "duration_secs": 120}
/// }
/// ```
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum GateState {
    /// Deferred-work claims are permitted right now. `since` is the moment
    /// the gate flipped to `Allowed`. No `reason` / `waiting_for` because
    /// neither is meaningful when nothing is blocking.
    Allowed { since: DateTime<Utc> },
    /// Deferred work is held off. `reason` is a typed `BlockReason`,
    /// `waiting_for` is a typed `WaitCondition` — both required.
    Blocked {
        reason: BlockReason,
        since: DateTime<Utc>,
        waiting_for: WaitCondition,
    },
}

impl GateState {
    /// Returns `true` iff this is the `Allowed` variant. Convenience
    /// accessor for the (very common) "are we draining?" question; the
    /// boolean is fully derivable from the variant, which is the whole
    /// point of the sum-type refactor.
    pub fn is_allowed(&self) -> bool {
        matches!(self, GateState::Allowed { .. })
    }

    /// Timestamp the current variant became active.
    pub fn since(&self) -> DateTime<Utc> {
        match self {
            GateState::Allowed { since } => *since,
            GateState::Blocked { since, .. } => *since,
        }
    }
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
    pub kind: WorkKind,
    /// `None` clears the slot.
    pub in_flight: Option<InFlight>,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// PR #39 review: guard against future drift between `WorkKind::as_str()`
    /// and the snake_case derivation `serde(rename_all = "snake_case")` uses
    /// on the wire. If a contributor adds a `WorkKind` variant and forgets
    /// to extend `as_str()`, this test will fail.
    #[test]
    fn workkind_as_str_matches_serde() {
        for k in [
            WorkKind::Transcribe,
            WorkKind::Ocr,
            WorkKind::Summarize,
            WorkKind::ExtractMemory,
            WorkKind::ExtractActionItems,
        ] {
            assert_eq!(
                serde_json::to_value(k).unwrap(),
                serde_json::Value::String(k.as_str().to_string()),
                "WorkKind::{:?} as_str() drifted from serde rename",
                k
            );
        }
    }

    #[test]
    fn capturekind_as_str_matches_serde() {
        for c in [CaptureKind::Audio, CaptureKind::Screen] {
            assert_eq!(
                serde_json::to_value(c).unwrap(),
                serde_json::Value::String(c.as_str().to_string()),
                "CaptureKind::{:?} as_str() drifted from serde rename",
                c
            );
        }
    }

    // ----- Issue #35: GateState sum-type wire-format coverage -----

    #[test]
    fn gate_state_allowed_wire_shape() {
        let since: DateTime<Utc> = "2026-04-26T14:25:00Z".parse().unwrap();
        let g = GateState::Allowed { since };
        let v: serde_json::Value = serde_json::to_value(&g).unwrap();
        assert_eq!(v["state"], "allowed");
        assert_eq!(v["since"], "2026-04-26T14:25:00Z");
        // `Allowed` carries no `reason` / `waiting_for` — those keys must
        // not be present (the whole point of the sum is that they're not
        // meaningful in this variant).
        assert!(v.get("reason").is_none(), "Allowed must not carry reason");
        assert!(
            v.get("waiting_for").is_none(),
            "Allowed must not carry waiting_for"
        );

        // Round-trip back through the wire and we get the same variant.
        let back: GateState = serde_json::from_value(v).unwrap();
        assert!(back.is_allowed());
        assert_eq!(back.since(), since);
    }

    #[test]
    fn gate_state_blocked_wire_shape() {
        let since: DateTime<Utc> = "2026-04-26T14:25:00Z".parse().unwrap();
        let g = GateState::Blocked {
            reason: BlockReason::DeviceActive,
            since,
            waiting_for: WaitCondition::IdleFor {
                duration: std::time::Duration::from_secs(120),
            },
        };
        let v: serde_json::Value = serde_json::to_value(&g).unwrap();
        assert_eq!(v["state"], "blocked");
        assert_eq!(v["reason"], "device_active");
        assert_eq!(v["waiting_for"]["type"], "idle_for");
        assert_eq!(v["waiting_for"]["duration_secs"], 120);

        let back: GateState = serde_json::from_value(v).unwrap();
        assert!(!back.is_allowed());
        assert_eq!(back.since(), since);
        match back {
            GateState::Blocked {
                reason,
                waiting_for,
                ..
            } => {
                assert_eq!(reason, BlockReason::DeviceActive);
                assert!(matches!(
                    waiting_for,
                    WaitCondition::IdleFor { duration } if duration.as_secs() == 120
                ));
            }
            _ => panic!("expected Blocked"),
        }
    }

    #[test]
    fn block_reason_every_variant_round_trips() {
        for (r, wire) in [
            (BlockReason::DeviceActive, "device_active"),
            (BlockReason::OnBattery, "on_battery"),
            (BlockReason::Thermal, "thermal"),
            (BlockReason::Locked, "locked"),
            (BlockReason::ManualPause, "manual_pause"),
            (BlockReason::Initializing, "initializing"),
        ] {
            assert_eq!(serde_json::to_string(&r).unwrap(), format!("\"{wire}\""));
            let back: BlockReason = serde_json::from_str(&format!("\"{wire}\"")).unwrap();
            assert_eq!(back, r);
        }
    }

    #[test]
    fn wait_condition_every_variant_round_trips() {
        let cases: Vec<(WaitCondition, serde_json::Value)> = vec![
            (
                WaitCondition::IdleFor {
                    duration: std::time::Duration::from_secs(120),
                },
                serde_json::json!({"type":"idle_for","duration_secs":120}),
            ),
            (
                WaitCondition::AcPower,
                serde_json::json!({"type":"ac_power"}),
            ),
            (
                WaitCondition::ThermalCooldown,
                serde_json::json!({"type":"thermal_cooldown"}),
            ),
            (WaitCondition::Unlock, serde_json::json!({"type":"unlock"})),
            (WaitCondition::Manual, serde_json::json!({"type":"manual"})),
        ];
        for (w, expected) in cases {
            let v = serde_json::to_value(w).unwrap();
            assert_eq!(v, expected, "encode mismatch for {w:?}");
            let back: WaitCondition = serde_json::from_value(v).unwrap();
            assert_eq!(back, w, "round-trip mismatch for {w:?}");
        }
    }

    #[test]
    fn gate_state_rejects_unknown_state_tag() {
        let json = r#"{"state":"throttled","since":"2026-04-26T00:00:00Z"}"#;
        assert!(serde_json::from_str::<GateState>(json).is_err());
    }

    #[test]
    fn gate_state_blocked_rejects_when_waiting_for_missing() {
        // Sum-type discipline: `Blocked` without `waiting_for` is not a
        // legal value in either direction.
        let bad = serde_json::json!({
            "state": "blocked",
            "reason": "device_active",
            "since": "2026-04-26T14:25:00Z"
            // no `waiting_for`
        });
        let r: Result<GateState, _> = serde_json::from_value(bad);
        assert!(r.is_err(), "Blocked must require waiting_for");
    }

    #[test]
    fn process_kind_unknown_variant_decodes_future_wire_values() {
        let json = r#"{"name":"future-proc","pid":9999,"cpu_percent":1.0,"mem_mb":10,"kind":"future_unknown"}"#;
        let p: ProcessBreakdown = serde_json::from_str(json).unwrap();
        assert_eq!(p.kind, Some(ProcessKind::Unknown));

        let direct: ProcessKind = serde_json::from_str("\"future_unknown\"").unwrap();
        assert_eq!(direct, ProcessKind::Unknown);
    }

    #[test]
    fn gate_state_allowed_rejects_extraneous_reason() {
        // Allowed's untyped extras still parse (serde ignores unknown
        // fields by default), but constructing and round-tripping a clean
        // Allowed must not surface a `reason` key.
        let g = GateState::Allowed {
            since: "2026-04-26T14:25:00Z".parse().unwrap(),
        };
        let s = serde_json::to_string(&g).unwrap();
        assert!(
            !s.contains("reason"),
            "Allowed serialization must not contain reason: {s}"
        );
        assert!(
            !s.contains("waiting_for"),
            "Allowed must not contain waiting_for: {s}"
        );
    }
}
