//! `ProcessingGate` placeholder. The real implementation is owned by the
//! idle-gate agent (separate stream not yet shipped). Until then we ship
//! an "always-allowed" stub so `ActivityState` can be constructed and the
//! snapshot endpoint returns a stable shape.

use chrono::Utc;

use super::traits::ProcessingGate;
use super::types::{GateReason, GateState};

/// Always-allowed gate. No idle/thermal throttling enforced; the snapshot
/// will report `allowed: true` and `reason: None`.
pub struct AlwaysAllowedGate;

impl ProcessingGate for AlwaysAllowedGate {
    fn current(&self) -> GateState {
        GateState {
            allowed: true,
            reason: GateReason::None,
            since: Utc::now(),
            waiting_for: None,
        }
    }
}
