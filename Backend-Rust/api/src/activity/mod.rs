//! Activity surface — live process/task explorer with per-kind pause.
//!
//! Phase 0 contract freeze. See `contract.md` in this directory for the
//! REST + JSON shapes consumed by every Phase 1 stream.
//!
//! Module map (one file per Phase 1 stream owner):
//! - `types`        — serde-serialisable shapes (this PR)
//! - `traits`       — `PauseStore`, `InflightRegistry`, `ResourceSampler`,
//!                    `ProcessingGate` (this PR)
//! - `pause_store`  — Stream B: `SqlPauseStore` impl
//! - `resources`    — Stream C: `SystemResourceSampler` impl
//! - `inflight`     — Stream D: `MemoryInflightRegistry` impl

pub mod gate;
pub mod inflight;
pub mod pause_store;
pub mod resources;
pub mod traits;
pub mod types;

pub use traits::{InflightRegistry, PauseStore, ProcessingGate, ResourceSampler};
pub use types::{
    ActivitySnapshot, CaptureRow, GateState, GateReason, InFlight, InflightUpdate, KindRow,
    PauseRequest, PauseTarget, ProcessBreakdown, ResourceSample, ResumeRequest, ThermalState,
    WorkKind,
};
