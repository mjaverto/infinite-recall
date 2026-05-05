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

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use chrono::Utc;
use rusqlite::{Error as RusqliteError, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::HashMap;

use crate::activity::traits::PauseStoreError;
use crate::activity::types::{
    ActivitySnapshot, CaptureKind, CaptureRow, GateState, InflightUpdate, KindRow, PauseRequest,
    PauseTargetId, ResumeRequest, WorkKind,
};
use crate::db::with_conn;
use crate::state::{AppState, PauseChange};

/// All `WorkKind`s, in display order. Used to assemble the `kinds` array
/// in the snapshot — every kind gets a row even if there's no in-flight
/// item or pause, so the UI can render a stable table.
const ALL_KINDS: [WorkKind; 6] = [
    WorkKind::Transcribe,
    WorkKind::Ocr,
    WorkKind::Summarize,
    WorkKind::ExtractMemory,
    WorkKind::ExtractActionItems,
    // Issue #105: keep the Activity snapshot's queue accounting in sync
    // with `PendingWorkStorage.pendingCount()` (which the menu-bar badge
    // reads). Pre-#105, `extractKG` rows were counted by the badge but
    // absent here, producing the "8 items waiting (battery)" / "0 queued"
    // disagreement reported in the bug.
    WorkKind::ExtractKg,
];

const ALL_CAPTURES: [CaptureKind; 2] = [CaptureKind::Audio, CaptureKind::Screen];

// ---------------------------------------------------------------------
// Per-kind queue-depth rows (DB-authoritative)
// ---------------------------------------------------------------------
//
// The Swift app owns `pending_work`, but the Rust daemon already has a
// read-only SQLite pool. Activity snapshots therefore read queue / failure
// counts from the DB on every GET instead of trusting the old Swift→Rust
// push cache. Missing migration/table degrades to all-zero counts so a fresh
// install still renders a valid snapshot; query errors surface as 500 rather
// than falling back to stale process memory.

/// One row of the queue-depth payload — `queued` and `failed` counts for a
/// single `PendingWork.Kind`. Defaults to all-zeros for kinds Swift hasn't
/// pushed yet.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct QueueDepth {
    pub queued: u32,
    pub failed: u32,
}

// Issue #137: `QueueDepthUpdate` (the body type for the legacy
// `_internal/queue-depth` POST) was pruned. Activity snapshots are
// DB-authoritative; no Swift producer ever pushed to the route.

fn is_missing_pending_work_table_error(error: &RusqliteError) -> bool {
    matches!(
        error,
        RusqliteError::SqliteFailure(_, Some(message))
            if message.contains("no such table: pending_work")
    )
}

/// Query `pending_work` directly for per-kind Activity counts.
async fn pending_work_depths_by_kind(
    pool: &crate::db::SqlitePool,
) -> anyhow::Result<HashMap<String, QueueDepth>> {
    with_conn(pool, |c| {
        let table_exists = c
            .query_row(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='pending_work'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .optional()?
            .is_some();
        if !table_exists {
            return Ok(HashMap::new());
        }

        let mut depths: HashMap<String, QueueDepth> = HashMap::new();
        let mut stmt = match c.prepare(
            "SELECT status, workType, COUNT(*) AS cnt
             FROM pending_work
             WHERE status IN ('queued', 'failed')
             GROUP BY status, workType",
        ) {
            Ok(stmt) => stmt,
            Err(e) if is_missing_pending_work_table_error(&e) => return Ok(HashMap::new()),
            Err(e) => return Err(e.into()),
        };
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
            ))
        })?;

        for row in rows {
            let (status, work_type, count) = row?;
            let count = u32::try_from(count).unwrap_or(u32::MAX);
            let entry = depths.entry(work_type).or_default();
            match status.as_str() {
                "queued" => entry.queued = count,
                "failed" => entry.failed = count,
                _ => {}
            }
        }
        Ok(depths)
    })
    .await
}

/// Map a Rust `WorkKind` to the Swift `PendingWork.Kind.rawValue` string
/// used as a key in the queue-depth payload. Frozen interface I1 — these
/// strings are camelCase (Swift's default `RawRepresentable` derivation),
/// NOT the snake_case `WorkKind::as_str()` wire form.
fn workkind_swift_raw_value(k: WorkKind) -> &'static str {
    match k {
        WorkKind::Transcribe => "transcribe",
        WorkKind::Ocr => "ocr",
        WorkKind::Summarize => "summarize",
        WorkKind::ExtractMemory => "extractMemory",
        WorkKind::ExtractActionItems => "extractActionItems",
        // Swift's `PendingWork.Kind.extractKG` rawValue is camelCase
        // ("extractKG"), matching the other camelCase entries above.
        WorkKind::ExtractKg => "extractKG",
    }
}

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

    // Per-kind queue depth + failure counters come from `pending_work` on
    // every snapshot read. This keeps Activity in sync with the same durable
    // queue Conversations / backfill use, with no process-global push cache.
    let depths_snap = pending_work_depths_by_kind(&state.pool)
        .await
        .map_err(|e| {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("pending_work depth query error: {e}"),
            )
        })?;

    let kinds: Vec<KindRow> = ALL_KINDS
        .iter()
        .map(|k| {
            let qd = depths_snap
                .get(workkind_swift_raw_value(*k))
                .copied()
                .unwrap_or_default();
            KindRow {
                kind: *k,
                in_flight: inflight_map.get(k).cloned(),
                queued: qd.queued,
                failed: qd.failed,
                last_done_at: None,
                paused_until: state.pause_store.paused_until(&PauseTargetId::Kind(*k)),
            }
        })
        .collect();

    let capture: Vec<CaptureRow> = ALL_CAPTURES
        .iter()
        .map(|c| {
            let paused = state.pause_store.paused_until(&PauseTargetId::Capture(*c));
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

// Issue #137: `internal_queue_depth` handler pruned. Activity snapshots are
// DB-authoritative (see `pending_work_depths_by_kind` above) and no Swift
// build ever produces this POST in the IR app — Swift's
// `InternalPostFailureTracker` no longer carries a `queue-depth` category.

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
pub async fn gate_state(State(state): State<AppState>, Json(body): Json<GateState>) -> StatusCode {
    // Uses the write-side `WritableProcessingGate` trait — read-only stub
    // gates (e.g. `#[cfg(test)] AlwaysAllowedGate`) cannot be wired here
    // by mistake, since they don't implement the writable trait at all.
    state.processing_gate_writer.set(body);
    StatusCode::NO_CONTENT
}

/// `POST /v1/activity/processes/:pid/terminate` — hard-kill a tracked
/// LocalModel worker.
///
/// Returns:
/// * `204` — process is gone (graceful exit within the SIGTERM grace window
///   OR forcibly killed via SIGKILL after the 5 s grace).
/// * `404` — pid is not currently tracked as a `LocalModel` worker. The gate
///   re-runs PID discovery on every call (does NOT trust the sampler's 2 s
///   cache) AND does a fresh `proc_pid::pidinfo` aliveness check, both as
///   defense-in-depth against PID-recycle between the snapshot the UI saw
///   and our `kill(2)` syscall.
/// * `500 {error: <msg>}` — `kill(2)` failed for any reason other than
///   `ESRCH` (which is treated as success — the pid being already gone is
///   exactly the post-condition we wanted).
///
/// Uses `tokio::time::sleep` for the grace-window poll so the async runtime
/// worker isn't blocked for 5 s. `libc::kill` chosen over `nix` to keep the
/// dep tree small.
pub async fn terminate_process(
    State(state): State<AppState>,
    Path(pid): Path<i32>,
) -> Result<StatusCode, (StatusCode, Json<serde_json::Value>)> {
    use crate::activity::terminate as t;

    // Gate 1: pid must be in the LocalModel allowlist (fresh discovery, not
    // the cached snapshot — the cache can be 2 s stale, leaving a TOCTOU
    // window for pid-recycle).
    if !state.local_model_gate.is_local_model(pid) {
        tracing::info!(
            component = "activity.terminate",
            pid,
            "rejecting terminate: pid not in LocalModel allowlist"
        );
        return Err((StatusCode::NOT_FOUND, Json(json!({
            "error": "pid_not_local_model",
        }))));
    }

    // Gate 2: defense-in-depth — process must still be alive RIGHT NOW
    // (between the gate check above and the kill(2) syscall below). If
    // discovery cached a stale pid + the kernel recycled it in the
    // intervening microseconds, this catches it before we signal.
    //
    // We MUST distinguish ESRCH ("gone, what we want") from EPERM / other
    // inspect failures. Conflating them and 404-ing would silently hide a
    // real failure mode — the Swift client treats 404 as "already dead, no
    // toast", so a real error would never surface to the user.
    match t::pid_status(pid) {
        t::PidStatus::Gone => {
            tracing::info!(
                component = "activity.terminate",
                pid,
                "rejecting terminate: pid no longer alive between gate and kill"
            );
            return Err((
                StatusCode::NOT_FOUND,
                Json(json!({ "error": "pid_not_alive" })),
            ));
        }
        t::PidStatus::Alive => {
            // Fall through to kill.
        }
        t::PidStatus::InspectFailed(errno) => {
            // Don't 404 — `kill(2)` has its own ESRCH handling and may
            // succeed where `kill(pid, 0)` failed (rare, but possible if
            // the EPERM came from a transient ptrace race or sandbox
            // weirdness). Log so support can diagnose.
            tracing::warn!(
                component = "activity.terminate",
                pid,
                errno,
                "pid_status inspect failed; falling through to kill anyway"
            );
        }
    }

    match t::terminate_pid(pid).await {
        Ok(t::TerminateOutcome::GracefulExit) => {
            tracing::info!(
                component = "activity.terminate",
                pid,
                outcome = "graceful",
                "terminated LocalModel worker via SIGTERM"
            );
            Ok(StatusCode::NO_CONTENT)
        }
        Ok(t::TerminateOutcome::KilledForcibly) => {
            tracing::warn!(
                component = "activity.terminate",
                pid,
                outcome = "sigkill",
                "LocalModel worker did not exit within 5 s grace; SIGKILL'd"
            );
            Ok(StatusCode::NO_CONTENT)
        }
        Err(e) => {
            tracing::error!(
                component = "activity.terminate",
                pid,
                error = %e,
                "kill(2) failed"
            );
            Err((
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": e.to_string() })),
            ))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::num::NonZeroU32;

    #[test]
    fn pending_work_missing_table_detection_is_specific() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        let missing_pending_work = conn
            .prepare("SELECT status FROM pending_work")
            .expect_err("pending_work table should be absent");
        assert!(is_missing_pending_work_table_error(&missing_pending_work));

        let missing_other_table = conn
            .prepare("SELECT status FROM some_other_table")
            .expect_err("other table should be absent");
        assert!(!is_missing_pending_work_table_error(&missing_other_table));

        let syntax_error = conn
            .prepare("SELECT FROM")
            .expect_err("invalid SQL should fail");
        assert!(!is_missing_pending_work_table_error(&syntax_error));
    }

    // --- Issue #34: wire-format round-trip for `PauseTargetId` ---
    //
    // The `validate_target_id` helper used to live here; it's gone now.
    // These tests instead cover what replaced it — the typed sum +
    // `serde(tag/content/flatten)` pattern that makes invalid combos
    // unrepresentable at the deserialization layer.

    #[test]
    fn pause_request_decodes_every_workkind() {
        for k in ALL_KINDS {
            let json = format!(r#"{{"target":"kind","id":"{}","minutes":5}}"#, k.as_str());
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
        let err =
            serde_json::from_str::<PauseRequest>(r#"{"target":"kind","id":"ocr","minutes":0}"#);
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
        let err =
            serde_json::from_str::<PauseRequest>(r#"{"target":"capture","id":"ocr","minutes":5}"#);
        assert!(err.is_err(), "capture+ocr must fail at the serde layer");
    }

    #[test]
    fn pause_request_rejects_unknown_target() {
        let err =
            serde_json::from_str::<PauseRequest>(r#"{"target":"nope","id":"ocr","minutes":5}"#);
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
