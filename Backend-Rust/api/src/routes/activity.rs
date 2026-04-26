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

use axum::{extract::State, http::StatusCode, response::IntoResponse, Json};
use chrono::Utc;
use serde_json::json;

use crate::activity::traits::PauseStoreError;
use crate::activity::types::{
    ActivitySnapshot, CaptureKind, CaptureRow, GateState, InflightUpdate, KindRow, PauseRequest,
    PauseTargetId, ResumeRequest, WorkKind,
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

/// `GET /v1/activity/snapshot` — full live snapshot.
pub async fn snapshot(
    State(state): State<AppState>,
) -> Result<Json<ActivitySnapshot>, (StatusCode, String)> {
    // Pull each piece independently. Sampler + gate are expected to cache
    // their own work; pause_store is a cheap SQLite point-lookup; inflight
    // is an in-memory RwLock read.
    let inflight_map = state.inflight.snapshot();

    // Singleton-fixer S4: `SystemResourceSampler::sample()` blocks the
    // calling thread for ~300ms on a cache miss (it `thread::sleep(250ms)`
    // for the CPU-delta window plus ~5 sync subprocess forks for ioreg /
    // sysctl / pmset). With the sampler's 2s cache TTL and the Swift
    // poller hitting `/snapshot` at 1Hz, on the old `.sample()`-on-the-
    // tokio-worker path every other tick stalled an entire runtime
    // worker. Move the sample to a blocking pool so the async runtime
    // stays free to serve the rest of the daemon.
    let sampler = state.resource_sampler.clone();
    let resources = tokio::task::spawn_blocking(move || sampler.sample())
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("resource sampler join error: {e}"),
            )
        })?;
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
            paused_until: state
                .pause_store
                .paused_until(&PauseTargetId::Kind(*k)),
        })
        .collect();

    let capture: Vec<CaptureRow> = ALL_CAPTURES
        .iter()
        .map(|c| {
            let paused = state
                .pause_store
                .paused_until(&PauseTargetId::Capture(*c));
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

    Ok(Json(ActivitySnapshot {
        kinds,
        capture,
        resources,
        processing_gate,
        generated_at: Utc::now(),
    }))
}

// Issue #34: `validate_target_id` was deleted. The combination of
// `PauseTargetId` (a sum type whose variants carry typed `WorkKind` /
// `CaptureKind` payloads) and serde's `tag/content` deserialization
// rejects any unknown `target` or `id` at the parse layer, returning
// 400/422 to the caller automatically. The route handlers no longer
// need a runtime guard — the type system enforces what this used to
// check.

/// Map `PauseStoreError` to a 5xx response with structured JSON detail
/// (consensus-fix C3) so the Swift caller can show the real failure
/// instead of silently rolling back optimistic UI state.
fn pause_store_error_response(e: PauseStoreError) -> (StatusCode, Json<serde_json::Value>) {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(json!({
            "error": "pause_store_failure",
            "detail": e.to_string(),
        })),
    )
}

/// `POST /v1/activity/pause` — pause a kind or live capture for N minutes.
///
/// Issue #34: serde rejects `minutes: 0` (`NonZeroU32`) and unknown
/// `target`/`id` combinations (typed `PauseTargetId` sum). No manual
/// validation lives here anymore.
pub async fn pause(
    State(state): State<AppState>,
    Json(body): Json<PauseRequest>,
) -> Result<Json<serde_json::Value>, axum::response::Response> {
    let resume_at = state
        .pause_store
        .pause(&body.target, body.minutes)
        .map_err(|e| pause_store_error_response(e).into_response())?;

    // Best-effort fanout. No subscribers = ok; the Swift poller still
    // refreshes on its 1s tick.
    let _ = state.pause_tx.send(PauseChange {
        target: body.target,
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
) -> Result<StatusCode, axum::response::Response> {
    let was_paused = state
        .pause_store
        .resume(&body.target)
        .map_err(|e| pause_store_error_response(e).into_response())?;

    // Only fan out a notification if a row was actually deleted — otherwise
    // we'd wake every Swift poller for every UI Cmd-R no-op.
    if was_paused {
        let _ = state.pause_tx.send(PauseChange {
            target: body.target,
            paused_until: None,
        });
    }

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
    // PR #39 review: `body.kind` is a typed `WorkKind` — serde's
    // `rename_all = "snake_case"` rejects any unknown variant at
    // the parse layer (returns 400/422), so no manual guard needed.
    state.inflight.update(body.kind, body.in_flight);
    Ok(StatusCode::NO_CONTENT)
}

/// `POST /v1/activity/_internal/gate-state` — Swift → Rust loopback.
///
/// Issue #32: Swift owns the OS signal observation (CGEvent idle seconds,
/// screen lock notifications, power source / low-power-mode, thermal
/// pressure) — `IdleAIController` and `BatteryAwareScheduler` already
/// subscribe for their own scheduling, so a Rust-native re-implementation
/// would be redundant FFI. The Swift `ProcessingGateReporter` polls those
/// signals every ~3s and POSTs the resulting `GateState` here when (and
/// only when) the value changes.
///
/// The handler updates the `BridgedProcessingGate` (or any concrete
/// `ProcessingGate` impl that overrides the trait's default no-op `set`)
/// and returns 204. The existing snapshot poller picks the change up on
/// its next tick — no separate fanout channel is needed.
///
/// Body: a fully-formed `GateState` (typed sum, snake_case discriminator).
/// Bearer-authed via the `authed` middleware. Loopback is enforced by the
/// listener bind (`127.0.0.1` only — see `lib.rs`).
pub async fn gate_state(
    State(state): State<AppState>,
    Json(body): Json<GateState>,
) -> StatusCode {
    // Uses the write-side `WritableProcessingGate` trait — read-only stub
    // gates (e.g. `#[cfg(test)] AlwaysAllowedGate`) cannot be wired here
    // by mistake, since they don't implement the writable trait at all.
    state.processing_gate_writer.set(body);
    StatusCode::NO_CONTENT
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::num::NonZeroU32;

    // --- Issue #34: wire-format round-trip for `PauseTargetId` ---
    //
    // The `validate_target_id` helper used to live here; it's gone now.
    // These tests instead cover what replaced it — the typed sum +
    // `serde(tag/content/flatten)` pattern that makes invalid combos
    // unrepresentable at the deserialization layer.

    #[test]
    fn pause_request_decodes_every_workkind() {
        for k in ALL_KINDS {
            let json = format!(
                r#"{{"target":"kind","id":"{}","minutes":5}}"#,
                k.as_str()
            );
            let req: PauseRequest =
                serde_json::from_str(&json).expect("valid kind body must decode");
            assert_eq!(req.target, PauseTargetId::Kind(k));
            assert_eq!(req.minutes, NonZeroU32::new(5).unwrap());
        }
    }

    #[test]
    fn pause_request_decodes_every_capturekind() {
        for c in ALL_CAPTURES {
            let json = format!(
                r#"{{"target":"capture","id":"{}","minutes":5}}"#,
                c.as_str()
            );
            let req: PauseRequest =
                serde_json::from_str(&json).expect("valid capture body must decode");
            assert_eq!(req.target, PauseTargetId::Capture(c));
        }
    }

    #[test]
    fn pause_request_rejects_zero_minutes_via_serde() {
        // NonZeroU32 makes `minutes: 0` unrepresentable — serde rejects.
        let err = serde_json::from_str::<PauseRequest>(
            r#"{"target":"kind","id":"ocr","minutes":0}"#,
        );
        assert!(err.is_err(), "minutes=0 must fail at the serde layer");
    }

    #[test]
    fn pause_request_rejects_kind_with_capture_id() {
        // `target=kind` + `id="audio"` is unrepresentable — `WorkKind`
        // does not have an `audio` variant.
        let err =
            serde_json::from_str::<PauseRequest>(r#"{"target":"kind","id":"audio","minutes":5}"#);
        assert!(err.is_err(), "kind+audio must fail at the serde layer");
    }

    #[test]
    fn pause_request_rejects_capture_with_kind_id() {
        let err = serde_json::from_str::<PauseRequest>(
            r#"{"target":"capture","id":"ocr","minutes":5}"#,
        );
        assert!(err.is_err(), "capture+ocr must fail at the serde layer");
    }

    #[test]
    fn pause_request_rejects_unknown_target() {
        let err = serde_json::from_str::<PauseRequest>(
            r#"{"target":"nope","id":"ocr","minutes":5}"#,
        );
        assert!(err.is_err(), "unknown target must fail at the serde layer");
    }

    #[test]
    fn pause_request_serializes_to_flat_wire_shape() {
        // Re-serializing must produce the legacy `{target, id, minutes}`
        // shape so the wire format is unchanged.
        let req = PauseRequest {
            target: PauseTargetId::Kind(WorkKind::Ocr),
            minutes: NonZeroU32::new(15).unwrap(),
        };
        let s = serde_json::to_string(&req).unwrap();
        // Order is not guaranteed, but the keys + values must be present.
        assert!(s.contains(r#""target":"kind""#), "got: {s}");
        assert!(s.contains(r#""id":"ocr""#), "got: {s}");
        assert!(s.contains(r#""minutes":15"#), "got: {s}");
    }

    #[test]
    fn resume_request_round_trips_for_capture() {
        let req: ResumeRequest =
            serde_json::from_str(r#"{"target":"capture","id":"audio"}"#).unwrap();
        assert_eq!(req.target, PauseTargetId::Capture(CaptureKind::Audio));
        let s = serde_json::to_string(&req).unwrap();
        assert!(s.contains(r#""target":"capture""#), "got: {s}");
        assert!(s.contains(r#""id":"audio""#), "got: {s}");
    }
}
