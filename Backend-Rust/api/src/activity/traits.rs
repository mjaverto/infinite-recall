//! Internal Rust traits implemented by Phase 1 streams B/C/D and the
//! external idle-gate agent. Stream A wires concrete impls into `AppState`.
//!
//! These traits are **the** coupling boundary — implementations live in
//! sibling modules, but the route handlers and `AppState` only know about
//! these trait objects.

use std::collections::HashMap;

use chrono::{DateTime, Utc};

use super::types::{GateState, InFlight, PauseTarget, ResourceSample, WorkKind};

/// Persistent absolute-time pause storage. Backed by SQLite (Stream B).
pub trait PauseStore: Send + Sync {
    /// Returns the wall-time at which the given target/id resumes,
    /// or `None` when not paused.
    fn paused_until(&self, target: PauseTarget, id: &str) -> Option<DateTime<Utc>>;

    /// Pause for `minutes` from now; returns the resolved resume time.
    fn pause(&self, target: PauseTarget, id: &str, minutes: u32) -> DateTime<Utc>;

    /// Clear any pause row for the given target/id.
    fn resume(&self, target: PauseTarget, id: &str);
}

/// Tracks which `WorkKind` is currently mid-handler. Backed by an
/// in-memory `Arc<RwLock<HashMap>>` (Stream D).
pub trait InflightRegistry: Send + Sync {
    /// Snapshot of all currently-executing kinds.
    fn snapshot(&self) -> HashMap<WorkKind, InFlight>;

    /// Set or clear the in-flight slot for one kind.
    fn update(&self, kind: WorkKind, in_flight: Option<InFlight>);
}

/// Polls process-tree CPU/RSS + system GPU. Backed by libproc + ioreg
/// shellout (Stream C). Implementations are expected to cache for ~1s.
pub trait ResourceSampler: Send + Sync {
    fn sample(&self) -> ResourceSample;
}

/// Read-only view of the device-idle / processing gate. Owned by the
/// separate idle-gate agent; this trait is the contract for consuming
/// their state from the snapshot route without coupling to internals.
pub trait ProcessingGate: Send + Sync {
    fn current(&self) -> GateState;
}
