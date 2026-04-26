//! Internal Rust traits implemented by Phase 1 streams B/C/D and the
//! external idle-gate agent. Stream A wires concrete impls into `AppState`.
//!
//! These traits are **the** coupling boundary — implementations live in
//! sibling modules, but the route handlers and `AppState` only know about
//! these trait objects.

use std::collections::HashMap;
use std::fmt;

use chrono::{DateTime, Utc};

use super::types::{GateState, InFlight, PauseTarget, ResourceSample, WorkKind};

/// Errors surfaced by `PauseStore` writes (consensus-fix C3).
///
/// Pre-fix, `pause()` and `resume()` swallowed every SQLite / pool error
/// and returned a value as if the write had succeeded — so the UI rendered
/// optimistic state that quietly reverted on the next snapshot poll.
/// Routes now translate this into 5xx so the Swift side can show the
/// failure to the user instead of silently rolling back.
#[derive(Debug)]
pub enum PauseStoreError {
    Storage(rusqlite::Error),
    Pool(r2d2::Error),
    Unknown(String),
}

impl fmt::Display for PauseStoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PauseStoreError::Storage(e) => write!(f, "pause store storage error: {e}"),
            PauseStoreError::Pool(e) => write!(f, "pause store pool error: {e}"),
            PauseStoreError::Unknown(s) => write!(f, "pause store error: {s}"),
        }
    }
}

impl std::error::Error for PauseStoreError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            PauseStoreError::Storage(e) => Some(e),
            PauseStoreError::Pool(e) => Some(e),
            PauseStoreError::Unknown(_) => None,
        }
    }
}

impl From<rusqlite::Error> for PauseStoreError {
    fn from(e: rusqlite::Error) -> Self {
        PauseStoreError::Storage(e)
    }
}

impl From<r2d2::Error> for PauseStoreError {
    fn from(e: r2d2::Error) -> Self {
        PauseStoreError::Pool(e)
    }
}

/// Persistent absolute-time pause storage. Backed by SQLite (Stream B).
pub trait PauseStore: Send + Sync {
    /// Returns the wall-time at which the given target/id resumes,
    /// or `None` when not paused.
    fn paused_until(&self, target: PauseTarget, id: &str) -> Option<DateTime<Utc>>;

    /// Pause for `minutes` from now; returns the resolved resume time.
    /// Errors propagate so the route can surface a 5xx instead of silently
    /// returning a "successful" resume time on a failed write.
    fn pause(
        &self,
        target: PauseTarget,
        id: &str,
        minutes: u32,
    ) -> Result<DateTime<Utc>, PauseStoreError>;

    /// Clear any pause row for the given target/id. Returns `true` iff a
    /// row was actually deleted, so the route can decide whether to fan
    /// out a `pauseChanged` notification.
    fn resume(&self, target: PauseTarget, id: &str) -> Result<bool, PauseStoreError>;
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
