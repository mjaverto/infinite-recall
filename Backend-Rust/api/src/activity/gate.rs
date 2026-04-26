//! `ProcessingGate` placeholder. The real implementation is owned by the
//! idle-gate agent (separate stream not yet shipped). Until then we ship
//! an "always-allowed" stub so `ActivityState` can be constructed and the
//! snapshot endpoint returns a stable shape.
//!
//! Issue #35: with `GateState` collapsed to a sum type, `AlwaysAllowedGate`
//! returns `GateState::Allowed { since }` per the issue spec. The
//! pre-#35 `GateReason::Stub` variant (and its "Gate not yet wired (#32)"
//! UI banner) is gone — the sum doesn't have a "we don't really know"
//! third state, and the issue acceptance criterion is explicit. The
//! `tracing::warn!` boot breadcrumb in `lib.rs` still flags the stub for
//! anyone debugging from the daemon side.

use chrono::Utc;

use super::traits::ProcessingGate;
use super::types::GateState;

/// Always-allowed gate. No idle/thermal throttling enforced; the snapshot
/// reports `Allowed` so the rest of the pipeline can run without being
/// gated. The real `ProcessingGate` lands with issue #32.
pub struct AlwaysAllowedGate;

impl ProcessingGate for AlwaysAllowedGate {
    fn current(&self) -> GateState {
        GateState::Allowed { since: Utc::now() }
    }
}
