use std::sync::Arc;

use tokio::sync::broadcast;

use crate::activity::terminate::LocalModelGate;
use crate::activity::{InflightRegistry, PauseStore, ProcessingGate, ResourceSampler, WritableProcessingGate};
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
    /// Read-only view of the device-idle / processing gate. Used by the
    /// snapshot route handler.
    pub processing_gate: Arc<dyn ProcessingGate>,
    /// Write-side capability for the gate. Used by the
    /// `POST /v1/activity/_internal/gate-state` route handler. Production
    /// wires the same `Arc<BridgedProcessingGate>` here as
    /// `processing_gate` (upcast); the trait split prevents read-only
    /// stub gates from being silently substituted into the write path.
    pub processing_gate_writer: Arc<dyn WritableProcessingGate>,
    /// Broadcast channel for pause/resume changes. Receivers are best-effort;
    /// Lagged receivers are simply expected to re-poll on their next tick.
    pub pause_tx: broadcast::Sender<PauseChange>,
    // === /activity:A ===
    // === activity:lane-d ===
    /// LocalModel allowlist gate for `POST /v1/activity/processes/:pid/terminate`.
    /// Production wires `ProcLocalModelGate` (re-discovers the LocalModel pid
    /// set on every call — does NOT trust the 2 s sampler cache, which would
    /// leave a TOCTOU window for pid-recycle). Tests inject a stub.
    pub local_model_gate: Arc<dyn LocalModelGate>,
    // === /activity:lane-d ===

    /// Resolved on-disk path of the read-only Omi SQLite DB. Cached on
    /// AppState so the `test_introspection` ground-truth endpoints can
    /// report the same path the read pool was opened against without
    /// re-running the env/$HOME resolution.
    pub db_path: Arc<std::path::PathBuf>,
    /// Resolved on-disk path of the activity SQLite DB.
    pub activity_db_path: Arc<std::path::PathBuf>,
    /// Bounded ring buffer of recent worker errors. No-op stub unless the
    /// `test_introspection` Cargo feature is on (see `crate::worker_errors`).
    pub worker_errors: Arc<crate::worker_errors::WorkerErrorSink>,
}
