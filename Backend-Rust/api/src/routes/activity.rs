//! Stream A: `/v1/activity/*` route handlers.
//!
//! Assembles `ActivitySnapshot` from the four trait objects parked on
//! `AppState` (`PauseStore`, `InflightRegistry`, `ResourceSampler`,
//! `ProcessingGate`) and exposes pause/resume + a Swift→Rust loopback
//! in-flight reporting endpoint.
//!
//! Wire-format types live in `crate::activity::types`. Concrete trait
//! impls are owned by Streams B/C/D and the idle-gate agent — the Phase 0
//! contract (`activity/contract.md`) is the source of truth.

use axum::{extract::State, http::StatusCode, Json};
use chrono::Utc;
use serde_json::json;

use crate::activity::types::{
    ActivitySnapshot, CaptureKind, CaptureRow, InflightUpdate, KindRow, PauseRequest, PauseTarget,
    ResumeRequest, WorkKind,
};
use crate::state::{AppState, PauseChange};

/// All `WorkKind`s, in display order. Used to assemble the `kinds` array
/// in the snapshot — every kind gets a row even if there's no in-flight
/// item or pause, so the UI can render a stable table.
const ALL_KINDS: [WorkKind; 5] = [
    WorkKind::Transcribe,
    WorkKind::Ocr,
    WorkKind::Summarize,
    WorkKind::ExtractMemory,
    WorkKind::ExtractActionItems,
];

const ALL_CAPTURES: [CaptureKind; 2] = [CaptureKind::Audio, CaptureKind::Screen];

fn kind_id(k: WorkKind) -> &'static str {
    match k {
        WorkKind::Transcribe => "transcribe",
        WorkKind::Ocr => "ocr",
        WorkKind::Summarize => "summarize",
        WorkKind::ExtractMemory => "extract_memory",
        WorkKind::ExtractActionItems => "extract_action_items",
    }
}

fn capture_id(c: CaptureKind) -> &'static str {
    match c {
        CaptureKind::Audio => "audio",
        CaptureKind::Screen => "screen",
    }
}

/// `GET /v1/activity/snapshot` — full live snapshot.
pub async fn snapshot(State(state): State<AppState>) -> Json<ActivitySnapshot> {
    // Pull each piece independently. Sampler + gate are expected to cache
    // their own work; pause_store is a cheap SQLite point-lookup; inflight
    // is an in-memory RwLock read.
    let inflight_map = state.inflight.snapshot();
    let resources = state.resource_sampler.sample();
    let processing_gate = state.processing_gate.current();

    let kinds: Vec<KindRow> = ALL_KINDS
        .iter()
        .map(|k| KindRow {
            kind: *k,
            in_flight: inflight_map.get(k).cloned(),
            // Queue depth + failure counters live in the Swift app's domain
            // (PendingWork rows). Until Stream G/F surface those into the
            // Rust daemon, report 0/0 — the UI degrades gracefully.
            queued: 0,
            failed: 0,
            last_done_at: None,
            paused_until: state.pause_store.paused_until(PauseTarget::Kind, kind_id(*k)),
        })
        .collect();

    let capture: Vec<CaptureRow> = ALL_CAPTURES
        .iter()
        .map(|c| {
            let paused = state
                .pause_store
                .paused_until(PauseTarget::Capture, capture_id(*c));
            CaptureRow {
                kind: *c,
                // We don't yet observe live capture state from the Rust daemon
                // (Swift side owns AVCapture / SCStream). The Swift Activity
                // service overlays its local `running` view on top of this row.
                // Default: "would be running unless paused".
                running: paused.is_none(),
                paused_until: paused,
            }
        })
        .collect();

    Json(ActivitySnapshot {
        kinds,
        capture,
        resources,
        processing_gate,
        generated_at: Utc::now(),
    })
}

/// Resolve a `PauseRequest`/`ResumeRequest` `id` against its `target`. The
/// id space is tiny and validated server-side so the Swift caller can't
/// pause an unknown kind.
fn validate_target_id(target: PauseTarget, id: &str) -> Result<(), StatusCode> {
    match target {
        PauseTarget::Kind => {
            if ALL_KINDS.iter().any(|k| kind_id(*k) == id) {
                Ok(())
            } else {
                Err(StatusCode::BAD_REQUEST)
            }
        }
        PauseTarget::Capture => {
            if ALL_CAPTURES.iter().any(|c| capture_id(*c) == id) {
                Ok(())
            } else {
                Err(StatusCode::BAD_REQUEST)
            }
        }
    }
}

/// `POST /v1/activity/pause` — pause a kind or live capture for N minutes.
pub async fn pause(
    State(state): State<AppState>,
    Json(body): Json<PauseRequest>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    if body.minutes == 0 {
        return Err(StatusCode::BAD_REQUEST);
    }
    validate_target_id(body.target, &body.id)?;

    let resume_at = state
        .pause_store
        .pause(body.target, &body.id, body.minutes);

    // Best-effort fanout. No subscribers = ok; the Swift poller still
    // refreshes on its 1s tick.
    let _ = state.pause_tx.send(PauseChange {
        target: body.target,
        id: body.id.clone(),
        paused_until: Some(resume_at),
    });

    Ok(Json(
        json!({ "paused_until": resume_at.to_rfc3339_opts(chrono::SecondsFormat::Millis, true) }),
    ))
}

/// `POST /v1/activity/resume` — clear a pause row.
pub async fn resume(
    State(state): State<AppState>,
    Json(body): Json<ResumeRequest>,
) -> Result<StatusCode, StatusCode> {
    validate_target_id(body.target, &body.id)?;

    state.pause_store.resume(body.target, &body.id);

    let _ = state.pause_tx.send(PauseChange {
        target: body.target,
        id: body.id.clone(),
        paused_until: None,
    });

    Ok(StatusCode::NO_CONTENT)
}

/// `POST /v1/activity/_internal/inflight` — Swift → Rust loopback.
///
/// The daemon binds to 127.0.0.1 only (see `main.rs`), so loopback is
/// enforced by the listener. We still require bearer auth via the
/// `authed` middleware.
pub async fn inflight(
    State(state): State<AppState>,
    Json(body): Json<InflightUpdate>,
) -> Result<StatusCode, StatusCode> {
    let kind = parse_work_kind(&body.kind).ok_or(StatusCode::BAD_REQUEST)?;
    state.inflight.update(kind, body.in_flight);
    Ok(StatusCode::NO_CONTENT)
}

fn parse_work_kind(s: &str) -> Option<WorkKind> {
    match s {
        "transcribe" => Some(WorkKind::Transcribe),
        "ocr" => Some(WorkKind::Ocr),
        "summarize" => Some(WorkKind::Summarize),
        "extract_memory" => Some(WorkKind::ExtractMemory),
        "extract_action_items" => Some(WorkKind::ExtractActionItems),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_work_kind_round_trip() {
        for k in ALL_KINDS {
            assert_eq!(parse_work_kind(kind_id(k)), Some(k));
        }
        assert_eq!(parse_work_kind("nope"), None);
    }

    #[test]
    fn validate_target_id_accepts_known() {
        assert!(validate_target_id(PauseTarget::Kind, "ocr").is_ok());
        assert!(validate_target_id(PauseTarget::Capture, "audio").is_ok());
        assert!(validate_target_id(PauseTarget::Capture, "screen").is_ok());
    }

    #[test]
    fn validate_target_id_rejects_unknown() {
        assert!(validate_target_id(PauseTarget::Kind, "audio").is_err());
        assert!(validate_target_id(PauseTarget::Capture, "ocr").is_err());
        assert!(validate_target_id(PauseTarget::Kind, "").is_err());
    }

}
