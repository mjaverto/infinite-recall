//! `ProcessingGate` impls.
//!
//! # Architecture (issue #32)
//!
//! The OS signals that drive the gate (CGEvent idle seconds, screen
//! lock/unlock notifications, power source / low-power-mode, thermal
//! pressure) are observed by the Swift side — `IdleAIController` and
//! `BatteryAwareScheduler` already subscribe to them for their own
//! scheduling decisions, so a Rust-native re-implementation would be
//! redundant FFI work.
//!
//! Instead, Swift computes a [`GateState`] every few seconds and POSTs it
//! to `POST /v1/activity/_internal/gate-state` (loopback, bearer-authed).
//! The handler updates a [`BridgedProcessingGate`] which holds the latest
//! state behind an `Arc<RwLock>`. `ProcessingGate::current()` returns it.
//!
//! Until the first POST arrives (typically within ~3s of daemon start),
//! `current()` returns the same honest "not wired yet" signal that
//! `AlwaysAllowedGate` used to emit, but with a `since` timestamp that
//! advances forward (so it can never be confused with a real, latched
//! `Allowed` decision).
//!
//! `AlwaysAllowedGate` survives behind `#[cfg(test)]` so the integration
//! tests in `tests/activity_endpoints.rs` can keep using a deterministic
//! "always Allowed" gate without spinning up a Swift bridge.

use std::sync::{Arc, RwLock};

use chrono::Utc;

use super::traits::{ProcessingGate, WritableProcessingGate};
use super::types::{BlockReason, GateState, WaitCondition};

/// Production gate impl, fed by the Swift side over the
/// `_internal/gate-state` loopback endpoint.
///
/// State is kept behind an `Arc<RwLock>` so cloning the `BridgedProcessingGate`
/// (or sharing it through `Arc<dyn ProcessingGate>`) shares the same backing
/// store — the route handler that receives a POST and the snapshot reader
/// see a single source of truth.
pub struct BridgedProcessingGate {
    state: Arc<RwLock<GateState>>,
}

impl BridgedProcessingGate {
    /// Construct a gate seeded with `Blocked { reason: Unwired, ... }`.
    /// The variant is the same honest "not wired yet" signal the previous
    /// stub emitted; once Swift POSTs its first real reading, this is
    /// overwritten and never reverts.
    pub fn new() -> Self {
        tracing::info!(
            target: "activity.gate",
            initial = "Unwired",
            "BridgedProcessingGate constructed"
        );
        Self {
            state: Arc::new(RwLock::new(initial_state())),
        }
    }

    /// Replace the stored state. Called by the
    /// `POST /v1/activity/_internal/gate-state` handler.
    ///
    /// Poisoned-lock recovery: if a previous writer panicked, fall back to
    /// `into_inner()` rather than panicking the route handler. The data
    /// itself is still writable.
    ///
    /// `Blocked { reason: Unwired, .. }` is rejected (defense-in-depth):
    /// the `Unwired` variant exists ONLY to represent "haven't received
    /// the first POST yet" — Swift should never post it. We swallow the
    /// write and emit a `tracing::warn!` so an external POST can't latch
    /// the gate back into the boot-window state. The route handler still
    /// returns 204; this validation is internal and never leaks to the
    /// caller.
    pub fn set(&self, new_state: GateState) {
        if let GateState::Blocked {
            reason: BlockReason::Unwired,
            ..
        } = &new_state
        {
            tracing::warn!(
                target: "activity.gate",
                ?new_state,
                "rejected external Unwired gate-state post (Unwired is reserved for the boot window)"
            );
            return;
        }
        let mut guard = match self.state.write() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        };
        *guard = new_state.clone();
        tracing::debug!(
            target: "activity.gate",
            ?new_state,
            "gate state updated"
        );
    }
}

impl Default for BridgedProcessingGate {
    fn default() -> Self {
        Self::new()
    }
}

impl ProcessingGate for BridgedProcessingGate {
    fn current(&self) -> GateState {
        match self.state.read() {
            Ok(g) => g.clone(),
            Err(poisoned) => poisoned.into_inner().clone(),
        }
    }
}

impl WritableProcessingGate for BridgedProcessingGate {
    fn set(&self, new_state: GateState) {
        Self::set(self, new_state);
    }
}

fn initial_state() -> GateState {
    GateState::Blocked {
        reason: BlockReason::Unwired,
        since: Utc::now(),
        waiting_for: WaitCondition::Manual,
    }
}

/// Test-only "always Allowed" gate. Production wiring uses
/// [`BridgedProcessingGate`]; this one stays so integration tests don't
/// have to mock out the Swift bridge.
#[cfg(test)]
pub struct AlwaysAllowedGate;

#[cfg(test)]
impl ProcessingGate for AlwaysAllowedGate {
    fn current(&self) -> GateState {
        GateState::Allowed { since: Utc::now() }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[test]
    fn initial_state_is_blocked_unwired() {
        let gate = BridgedProcessingGate::new();
        match gate.current() {
            GateState::Blocked { reason, waiting_for, .. } => {
                assert_eq!(reason, BlockReason::Unwired);
                assert_eq!(waiting_for, WaitCondition::Manual);
            }
            GateState::Allowed { .. } => panic!("initial must be Blocked Unwired"),
        }
    }

    #[test]
    fn set_replaces_state() {
        let gate = BridgedProcessingGate::new();
        let when = Utc::now();
        gate.set(GateState::Allowed { since: when });
        assert!(matches!(gate.current(), GateState::Allowed { .. }));
        assert_eq!(gate.current().since(), when);
    }

    #[test]
    fn set_to_blocked_round_trip() {
        let gate = BridgedProcessingGate::new();
        let now = Utc::now();
        gate.set(GateState::Blocked {
            reason: BlockReason::DeviceActive,
            since: now,
            waiting_for: WaitCondition::IdleFor {
                duration: Duration::from_secs(45),
            },
        });
        match gate.current() {
            GateState::Blocked { reason, waiting_for, since } => {
                assert_eq!(reason, BlockReason::DeviceActive);
                assert_eq!(waiting_for, WaitCondition::IdleFor { duration: Duration::from_secs(45) });
                assert_eq!(since, now);
            }
            _ => panic!("expected Blocked"),
        }
    }

    #[test]
    fn always_allowed_gate_returns_allowed() {
        let gate = AlwaysAllowedGate;
        assert!(gate.current().is_allowed());
    }
}
