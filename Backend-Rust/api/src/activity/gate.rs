//! `ProcessingGate` placeholder. The real implementation is owned by the
//! idle-gate agent (separate stream not yet shipped). Until then we ship
//! an "always-allowed" stub so `ActivityState` can be constructed and the
//! snapshot endpoint returns a stable shape.
//!
//! Consensus-fix C4: report the stub status via `GateReason::Stub` and
//! `waiting_for: "real gate not wired"` so the UI can render an honest
//! "Gate not yet wired (#32)" instead of "Idle processing — running".

use chrono::Utc;

use super::traits::ProcessingGate;
use super::types::{GateReason, GateState};

/// Always-allowed gate. No idle/thermal throttling enforced; the snapshot
/// reports `allowed: true` with `reason: Stub` so consumers can detect the
/// placeholder and surface it as such in the UI.
pub struct AlwaysAllowedGate;

impl ProcessingGate for AlwaysAllowedGate {
    fn current(&self) -> GateState {
        GateState {
            allowed: true,
            reason: GateReason::Stub,
            since: Utc::now(),
            waiting_for: Some("real gate not wired".to_string()),
        }
    }
}
