use std::sync::Arc;

use tokio::sync::broadcast;

use crate::activity::{InflightRegistry, PauseStore, ProcessingGate, ResourceSampler};
use crate::db::SqlitePool;

/// Notification payload broadcast when a pause/resume is applied so other
/// subsystems (e.g. the Swift `CapturePauseGate` poller) can refresh
/// without waiting for their next poll tick.
///
/// Issue #34: `target` is now a typed `PauseTargetId` carrying both the
/// kind/capture discriminator and its concrete payload, so subscribers
/// no longer have to redo string→variant parsing on every change.
#[derive(Debug, Clone)]
pub struct PauseChange {
    pub target: crate::activity::PauseTargetId,
    /// `None` = resumed/cleared. `Some(t)` = paused until `t`.
    pub paused_until: Option<chrono::DateTime<chrono::Utc>>,
}

/// Shared application state. Two pools, two purposes:
///
/// * `pool`       — read-only, large; serves every GET handler.
/// * `write_pool` — read-write, small; serves the action-item mutation
///                  endpoints. Kept as a separate field (rather than
///                  swapping `pool`) so reads remain on the strictly
///                  read-only file handle and can never accidentally
///                  scribble.
#[derive(Clone)]
pub struct AppState {
    pub pool: SqlitePool,
    pub write_pool: SqlitePool,
    pub token: String,

    // === activity:A ===
    /// Persistent absolute-time pause storage (Stream B impl).
    pub pause_store: Arc<dyn PauseStore>,
    /// In-memory currently-executing kinds map (Stream D impl).
    pub inflight: Arc<dyn InflightRegistry>,
    /// Process-tree CPU/RSS + system GPU sampler (Stream C impl).
    pub resource_sampler: Arc<dyn ResourceSampler>,
    /// Read-only view of the device-idle / processing gate.
    pub processing_gate: Arc<dyn ProcessingGate>,
    /// Broadcast channel for pause/resume changes. Receivers are best-effort;
    /// Lagged receivers are simply expected to re-poll on their next tick.
    pub pause_tx: broadcast::Sender<PauseChange>,
    // === /activity:A ===
}
