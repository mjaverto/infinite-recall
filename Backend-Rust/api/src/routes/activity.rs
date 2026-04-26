//! Stream A: `/v1/activity/*` route handlers.
//!
//! TODO(stream-A): wire concrete impls from B/C/D into `AppState` and
//! flesh out these handlers. Stubs here exist solely so `cargo build`
//! passes during Phase 0.

use axum::{extract::State, http::StatusCode, Json};

use crate::activity::types::{
    ActivitySnapshot, InflightUpdate, PauseRequest, ResumeRequest,
};
use crate::state::AppState;

/// `GET /v1/activity/snapshot` — full live snapshot.
pub async fn snapshot(State(_state): State<AppState>) -> Json<ActivitySnapshot> {
    unimplemented!("stream A: assemble snapshot from PauseStore + InflightRegistry + ResourceSampler + ProcessingGate")
}

/// `POST /v1/activity/pause` — pause a kind or live capture for N minutes.
pub async fn pause(
    State(_state): State<AppState>,
    Json(_body): Json<PauseRequest>,
) -> (StatusCode, Json<serde_json::Value>) {
    unimplemented!("stream A: call PauseStore::pause and return {{paused_until: iso8601}}")
}

/// `POST /v1/activity/resume` — clear a pause row.
pub async fn resume(
    State(_state): State<AppState>,
    Json(_body): Json<ResumeRequest>,
) -> StatusCode {
    unimplemented!("stream A: call PauseStore::resume and return 204")
}

/// `POST /v1/activity/_internal/inflight` — Swift → Rust loopback.
///
/// **Loopback only.** Auth still required (bearer); reject non-loopback
/// peer addresses at the middleware layer if/when Stream A adds that.
pub async fn inflight(
    State(_state): State<AppState>,
    Json(_body): Json<InflightUpdate>,
) -> StatusCode {
    unimplemented!("stream A: call InflightRegistry::update and return 204")
}
