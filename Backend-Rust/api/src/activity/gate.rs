//! `ProcessingGate` placeholder. The real implementation is owned by the
//! idle-gate agent (issue #32, separate stream not yet shipped).
//!
//! PR #40 review: an earlier revision of this file returned
//! `GateState::Allowed { since: now }` from the stub, which was bit-for-bit
//! indistinguishable from a real wired gate that has decided we're clear to
//! drain. Three reviewers independently flagged that as actively misleading
//! — the UI would render "Idle processing — running" and "Up to date" while
//! no real gating existed. The boot-time `tracing::warn!` in `lib.rs` is
//! invisible to users.
//!
//! Fix: ship the stub as `GateState::Blocked` with a dedicated
//! `BlockReason::Unwired` variant. The Swift side renders an honest
//! "Activity gate not yet wired" banner pointing at issue #32, instead of
//! falsely claiming we're processing. When the real gate lands, this whole
//! file goes away and `BlockReason::Unwired` with it.

use chrono::Utc;

use super::traits::ProcessingGate;
use super::types::{BlockReason, GateState, WaitCondition};

/// Placeholder gate that always reports `Blocked { reason: Unwired }`. The
/// snapshot still renders, the UI tells the user what's actually happening
/// (no real gate yet), and we don't pretend to be doing work we aren't.
/// The real `ProcessingGate` lands with issue #32; this struct deletes
/// then.
pub struct AlwaysAllowedGate;

impl ProcessingGate for AlwaysAllowedGate {
    fn current(&self) -> GateState {
        GateState::Blocked {
            reason: BlockReason::Unwired,
            since: Utc::now(),
            waiting_for: WaitCondition::Manual,
        }
    }
}
