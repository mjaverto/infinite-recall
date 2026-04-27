//! Activity Tab — Stream I integration tests.
//!
//! These exercise the `/v1/activity/*` HTTP surface against the assembled
//! axum app, with stub implementations of the four backend traits
//! (`PauseStore`, `InflightRegistry`, `ResourceSampler`, `ProcessingGate`).
//!
//! ## Why everything is gated
//!
//! Integration tests in `tests/` need to import the crate as a library
//! (`use infinite_recall_api::...`). The Phase 0 stub crate is binary-only
//! (`Backend-Rust/Cargo.toml` declares no `[lib]`), and Stream A owns
//! `state.rs` / `routes/mod.rs` wiring + `main.rs` constructor. Until Stream A
//! lands a `lib.rs` exposing `routes::router` and the extended `AppState`,
//! these tests CANNOT compile against the trait-extended state — there is no
//! library surface to import.
//!
//! Strategy:
//!   1. Wrap the entire test body in `#[cfg(feature = "activity_test_wiring")]`
//!      so `cargo test` is a no-op today (the file compiles to zero tests).
//!   2. Stream I's post-merge follow-up flips the feature on (or, more likely,
//!      Stream A's `lib.rs` makes the imports valid and we drop the gate).
//!   3. Each test that further depends on a *specific* downstream stream is
//!      tagged with a `#[ignore = "stream-X"]` so the operator can see at a
//!      glance which stream's impl unlocks it.
//!
//! ## Pre-flight before flipping the feature on
//!
//! When this file is enabled, the following Cargo.toml additions are
//! required (Stream I's post-merge follow-up will own this single edit
//! to avoid colliding with Stream C's `libproc` add):
//!
//! ```toml
//! [features]
//! activity_test_wiring = []
//!
//! [dev-dependencies]
//! tempfile = "3"
//! tokio = { version = "1", features = ["full", "macros", "rt-multi-thread"] }
//! ```
//!
//! `tower` and `axum` are already in `[dependencies]`.
//!
//! ## Verification matrix (mirrors §Verification in the plan)
//!
//! | Test                                  | Gated on streams |
//! |---------------------------------------|------------------|
//! | `snapshot_returns_200_with_full_shape` | A                |
//! | `pause_returns_paused_until`           | A + B            |
//! | `paused_kind_visible_in_snapshot`      | A + B            |
//! | `pause_persists_across_restart`        | A + B            |
//! | `resume_clears_pause`                  | A + B            |
//! | `inflight_loopback_round_trip`         | A + D            |
//! | `missing_bearer_returns_401`           | A                |
//! | `pause_request_validation`             | A                |
//! | `enum_round_trip_via_wire`             | (none — type-only) |

#![cfg(feature = "activity_test_wiring")]

// =====================================================================
// The block below assumes Stream A has shipped the following:
//
//   1. `Backend-Rust/Cargo.toml` declares a `[lib]` with `name = "infinite_recall_api"`
//      and `path = "src/lib.rs"`.
//   2. `src/lib.rs` re-exports `routes::router`, `state::AppState`, and the
//      `activity::traits` module.
//   3. `AppState` is extended with the four `Arc<dyn ...>` fields named
//      in `activity/contract.md`: `pause_store`, `inflight`,
//      `resource_sampler`, `processing_gate`.
//   4. `routes::router(state)` mounts `/v1/activity/*` behind `require_bearer`,
//      with `/v1/activity/_internal/inflight` additionally restricted to
//      loopback peers (or at minimum still authed).
//
// Plus the per-test gating noted above for B/C/D.
// =====================================================================

use std::collections::HashMap;
use std::num::NonZeroU32;
use std::sync::{Arc, Mutex, RwLock};

use axum::body::{to_bytes, Body};
use axum::http::{header, Method, Request, StatusCode};
use chrono::{DateTime, Duration, Utc};
use serde_json::{json, Value};
use tower::util::ServiceExt; // brings `oneshot` onto Router

use infinite_recall_api::activity::traits::{
    InflightRegistry, PauseStore, PauseStoreError, ProcessingGate, ResourceSampler,
    WritableProcessingGate,
};
use infinite_recall_api::activity::types::{
    BlockReason, CaptureKind, GateState, InFlight, PauseTargetId, ProcessBreakdown, ResourceSample,
    ThermalState, WaitCondition, WorkKind,
};
use infinite_recall_api::db::SqlitePool;
use infinite_recall_api::routes;
use infinite_recall_api::state::AppState;

fn nz(n: u32) -> NonZeroU32 {
    NonZeroU32::new(n).expect("test minutes must be non-zero")
}

// ---------------------------------------------------------------------
// Stub implementations
// ---------------------------------------------------------------------

/// Minimal in-memory `PauseStore` used when Stream B's SQLite impl is not
/// the unit under test. For persistence test, use Stream B's `SqlPauseStore`
/// directly (see `pause_persists_across_restart`).
///
/// Issue #34: keys are `PauseTargetId` directly — no string `id` column,
/// no risk of `Kind`+`"audio"` slipping through.
struct MemPauseStore {
    inner: Mutex<HashMap<PauseTargetId, DateTime<Utc>>>,
}

impl MemPauseStore {
    fn new() -> Self {
        Self {
            inner: Mutex::new(HashMap::new()),
        }
    }
}

impl PauseStore for MemPauseStore {
    fn paused_until(&self, target: &PauseTargetId) -> Option<DateTime<Utc>> {
        self.inner.lock().unwrap().get(target).copied()
    }

    fn pause(
        &self,
        target: &PauseTargetId,
        minutes: NonZeroU32,
    ) -> Result<DateTime<Utc>, PauseStoreError> {
        let resume_at = Utc::now() + Duration::minutes(i64::from(minutes.get()));
        self.inner.lock().unwrap().insert(*target, resume_at);
        Ok(resume_at)
    }

    fn resume(&self, target: &PauseTargetId) -> Result<bool, PauseStoreError> {
        let removed = self.inner.lock().unwrap().remove(target).is_some();
        Ok(removed)
    }
}

/// Minimal in-memory `InflightRegistry`.
struct MemInflight {
    inner: RwLock<HashMap<WorkKind, InFlight>>,
}

impl MemInflight {
    fn new() -> Self {
        Self {
            inner: RwLock::new(HashMap::new()),
        }
    }
}

impl InflightRegistry for MemInflight {
    fn snapshot(&self) -> HashMap<WorkKind, InFlight> {
        self.inner.read().unwrap().clone()
    }

    fn update(&self, kind: WorkKind, in_flight: Option<InFlight>) {
        let mut g = self.inner.write().unwrap();
        match in_flight {
            Some(f) => {
                g.insert(kind, f);
            }
            None => {
                g.remove(&kind);
            }
        }
    }
}

/// Returns a fixed `ResourceSample` so assertions are deterministic.
struct FakeSampler;
impl ResourceSampler for FakeSampler {
    fn sample(&self) -> ResourceSample {
        ResourceSample {
            cpu_percent: 12.5,
            rss_mb: 256,
            gpu_system_percent: Some(33.3),
            thermal_state: ThermalState::Nominal,
            on_battery: false,
            low_power: false,
            process_breakdown: vec![ProcessBreakdown {
                name: "infinite-recall-api".into(),
                pid: 4242,
                cpu_percent: 12.5,
                rss_mb: 256,
                kind: None,
            }],
        }
    }
}

/// Always-allow gate for stub purposes; tests that need a "blocked" gate
/// substitute their own.
struct FakeGate {
    state: GateState,
}
impl FakeGate {
    fn allow() -> Self {
        Self {
            state: GateState::Allowed { since: Utc::now() },
        }
    }
}
impl ProcessingGate for FakeGate {
    fn current(&self) -> GateState {
        self.state.clone()
    }
}

/// Test stub for the writable side. Tests that don't exercise the
/// gate-state POST endpoint use this so they don't have to mock out the
/// production `BridgedProcessingGate`. Writes are silently ignored —
/// fine here because the read side returns a fixed `FakeGate` value.
struct NoopWritableGate;
impl ProcessingGate for NoopWritableGate {
    fn current(&self) -> GateState {
        GateState::Allowed { since: Utc::now() }
    }
}
impl WritableProcessingGate for NoopWritableGate {
    fn set(&self, _new_state: GateState) {}
}

// ---------------------------------------------------------------------
// App builder
// ---------------------------------------------------------------------

const TEST_TOKEN: &str = "test-bearer-token-deadbeef";

/// Build an `AppState` with stub trait impls. The two SQLite pools come
/// from an `:memory:` DB so we don't touch disk.
///
/// NOTE: Stream A is responsible for ensuring `AppState` has a constructor
/// (or at least public fields) that lets test code populate the four new
/// `Arc<dyn ...>` slots independently of the real one in `main.rs`.
fn make_state(
    pause_store: Arc<dyn PauseStore>,
    inflight: Arc<dyn InflightRegistry>,
    sampler: Arc<dyn ResourceSampler>,
    gate: Arc<dyn ProcessingGate>,
) -> AppState {
    make_state_with_writer(
        pause_store,
        inflight,
        sampler,
        gate,
        Arc::new(NoopWritableGate),
    )
}

fn make_state_with_writer(
    pause_store: Arc<dyn PauseStore>,
    inflight: Arc<dyn InflightRegistry>,
    sampler: Arc<dyn ResourceSampler>,
    gate: Arc<dyn ProcessingGate>,
    gate_writer: Arc<dyn WritableProcessingGate>,
) -> AppState {
    let pool = infinite_recall_api::db::open_in_memory_pool()
        .expect("in-memory pool — Stream A should expose a test helper");
    let write_pool = infinite_recall_api::db::open_in_memory_pool().expect("in-memory write pool");
    let (pause_tx, _pause_rx) = tokio::sync::broadcast::channel(64);
    AppState {
        pool,
        write_pool,
        token: TEST_TOKEN.to_string(),
        pause_store,
        inflight,
        resource_sampler: sampler,
        processing_gate: gate,
        processing_gate_writer: gate_writer,
        pause_tx,
    }
}

fn make_default_app() -> axum::Router {
    let state = make_state(
        Arc::new(MemPauseStore::new()),
        Arc::new(MemInflight::new()),
        Arc::new(FakeSampler),
        Arc::new(FakeGate::allow()),
    );
    routes::router(state)
}

fn auth_header() -> (axum::http::HeaderName, axum::http::HeaderValue) {
    (
        header::AUTHORIZATION,
        format!("Bearer {TEST_TOKEN}").parse().unwrap(),
    )
}

async fn json_body(resp: axum::response::Response) -> Value {
    let bytes = to_bytes(resp.into_body(), 1 << 20).await.unwrap();
    serde_json::from_slice(&bytes).expect("response body is valid JSON")
}

async fn seed_pending_work(pool: &SqlitePool, rows: &[(&str, &str)]) {
    let rows = rows
        .iter()
        .map(|(status, work_type)| ((*status).to_string(), (*work_type).to_string()))
        .collect::<Vec<_>>();
    infinite_recall_api::db::with_conn(pool, move |c| {
        c.execute_batch(
            "CREATE TABLE IF NOT EXISTS pending_work (
                status TEXT NOT NULL,
                workType TEXT NOT NULL
            );
            DELETE FROM pending_work;",
        )?;
        for (status, work_type) in rows {
            c.execute(
                "INSERT INTO pending_work (status, workType) VALUES (?1, ?2)",
                rusqlite::params![status, work_type],
            )?;
        }
        Ok(())
    })
    .await
    .expect("seed pending_work rows");
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

/// §Verification step 6: snapshot returns the full shape with every field
/// present and correctly typed.
#[tokio::test]
async fn snapshot_returns_200_with_full_shape() {
    let app = make_default_app();
    let (k, v) = auth_header();
    let req = Request::builder()
        .method(Method::GET)
        .uri("/v1/activity/snapshot")
        .header(k, v)
        .body(Body::empty())
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = json_body(resp).await;

    // Top-level shape per contract.md.
    for required in [
        "kinds",
        "capture",
        "resources",
        "processing_gate",
        "generated_at",
    ] {
        assert!(
            body.get(required).is_some(),
            "missing required field `{required}` in: {body}"
        );
    }

    // `kinds` is an array of objects with all six keys.
    let kinds = body["kinds"].as_array().expect("kinds is an array");
    for row in kinds {
        for required in [
            "kind",
            "in_flight",
            "queued",
            "failed",
            "last_done_at",
            "paused_until",
        ] {
            assert!(
                row.get(required).is_some(),
                "kind row missing `{required}`: {row}"
            );
        }
    }

    // `capture` is an array of {kind, running, paused_until}.
    let capture = body["capture"].as_array().expect("capture is an array");
    for row in capture {
        for required in ["kind", "running", "paused_until"] {
            assert!(row.get(required).is_some());
        }
    }

    // `resources` populated by FakeSampler.
    let res = &body["resources"];
    assert_eq!(res["cpu_percent"], json!(12.5));
    assert_eq!(res["rss_mb"], json!(256));
    assert_eq!(res["gpu_system_percent"], json!(33.3));
    assert_eq!(res["thermal_state"], json!("nominal"));
    assert_eq!(res["on_battery"], json!(false));
    assert_eq!(res["low_power"], json!(false));
    assert!(res["process_breakdown"].is_array());

    // `processing_gate` populated by FakeGate::allow. Issue #35: wire
    // shape is now an internally-tagged sum on the `state` field; the
    // `Allowed` variant carries `state` + `since` only.
    let g = &body["processing_gate"];
    assert_eq!(g["state"], json!("allowed"));
    assert!(g["since"].is_string());
    assert!(g.get("reason").is_none(), "Allowed must not carry reason");
    assert!(
        g.get("waiting_for").is_none(),
        "Allowed must not carry waiting_for"
    );

    // `generated_at` is ISO-8601 string.
    assert!(body["generated_at"].is_string());
}

/// Issue #35: snapshot wire shape when the gate reports `Blocked` —
/// verifies the typed `waiting_for` payload makes it through the route
/// handler intact.
#[tokio::test]
async fn snapshot_blocked_gate_round_trips_typed_waiting_for() {
    use std::time::Duration;
    struct BlockedGate;
    impl ProcessingGate for BlockedGate {
        fn current(&self) -> GateState {
            GateState::Blocked {
                reason: BlockReason::DeviceActive,
                since: Utc::now(),
                waiting_for: WaitCondition::IdleFor {
                    duration: Duration::from_secs(120),
                },
            }
        }
    }
    let state = make_state(
        Arc::new(MemPauseStore::new()),
        Arc::new(MemInflight::new()),
        Arc::new(FakeSampler),
        Arc::new(BlockedGate),
    );
    let app = routes::router(state);
    let (k, v) = auth_header();
    let req = Request::builder()
        .method(Method::GET)
        .uri("/v1/activity/snapshot")
        .header(k, v)
        .body(Body::empty())
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body = json_body(resp).await;
    let g = &body["processing_gate"];
    assert_eq!(g["state"], json!("blocked"));
    assert_eq!(g["reason"], json!("device_active"));
    assert!(g["since"].is_string());
    assert_eq!(g["waiting_for"]["type"], json!("idle_for"));
    assert_eq!(g["waiting_for"]["duration_secs"], json!(120));
}

/// §Verification step 7: POST pause writes the row and returns
/// `{paused_until: iso8601}`.
#[tokio::test]
async fn pause_returns_paused_until() {
    let app = make_default_app();
    let (k, v) = auth_header();
    let body = json!({ "target": "kind", "id": "ocr", "minutes": 1 });
    let req = Request::builder()
        .method(Method::POST)
        .uri("/v1/activity/pause")
        .header(k, v)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = json_body(resp).await;
    let s = body["paused_until"]
        .as_str()
        .expect("paused_until is a string");
    let parsed: DateTime<Utc> = s.parse().expect("paused_until is iso8601");
    let delta = parsed - Utc::now();
    assert!(
        delta.num_seconds().abs() <= 70,
        "paused_until should be ~now+60s; got delta {}s",
        delta.num_seconds()
    );
}

/// After a pause, the kind row in the snapshot reflects `paused_until`.
#[tokio::test]
async fn paused_kind_visible_in_snapshot() {
    // Single AppState shared across the two requests so the pause persists.
    let pause_store: Arc<dyn PauseStore> = Arc::new(MemPauseStore::new());
    let state = make_state(
        pause_store.clone(),
        Arc::new(MemInflight::new()),
        Arc::new(FakeSampler),
        Arc::new(FakeGate::allow()),
    );
    let app = routes::router(state);
    let (k, v) = auth_header();

    // 1. Pause OCR for 1 minute.
    let pause_req = Request::builder()
        .method(Method::POST)
        .uri("/v1/activity/pause")
        .header(&k, v.clone())
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(
            json!({"target":"kind","id":"ocr","minutes":1}).to_string(),
        ))
        .unwrap();
    let resp = app.clone().oneshot(pause_req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    // 2. Snapshot should now show ocr row with paused_until ≈ now+60s.
    let snap_req = Request::builder()
        .method(Method::GET)
        .uri("/v1/activity/snapshot")
        .header(k, v)
        .body(Body::empty())
        .unwrap();
    let snap = json_body(app.oneshot(snap_req).await.unwrap()).await;

    let ocr = snap["kinds"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["kind"] == "ocr")
        .expect("snapshot must contain a row for every WorkKind");
    let pu = ocr["paused_until"]
        .as_str()
        .expect("ocr.paused_until is set");
    let parsed: DateTime<Utc> = pu.parse().expect("iso8601");
    let delta = parsed - Utc::now();
    assert!(
        delta.num_seconds() > 0 && delta.num_seconds() <= 70,
        "paused_until should be ~now+60s; got {}s",
        delta.num_seconds()
    );
}

/// §Verification step 9: pause persists across daemon restart.
/// Uses Stream B's `SqlPauseStore` directly — both lifecycles point at the
/// same SQLite file path.
#[tokio::test]
async fn pause_persists_across_restart() {
    use infinite_recall_api::activity::pause_store::SqlPauseStore;
    let tmp = tempfile::NamedTempFile::new().unwrap();
    let path = tmp.path().to_path_buf();

    // Lifecycle 1: write a pause then drop everything.
    {
        let store = SqlPauseStore::open(&path).expect("open SqlPauseStore");
        let resume_at = store
            .pause(&PauseTargetId::Kind(WorkKind::Ocr), nz(30))
            .expect("pause should persist");
        assert!(resume_at > Utc::now());
        // store dropped here.
    }

    // Lifecycle 2: re-open the same file; the pause must still be there.
    {
        let store = SqlPauseStore::open(&path).expect("re-open SqlPauseStore");
        let pu = store
            .paused_until(&PauseTargetId::Kind(WorkKind::Ocr))
            .expect("pause must survive restart");
        let delta = pu - Utc::now();
        assert!(
            delta.num_minutes() > 25 && delta.num_minutes() <= 30,
            "resume time drifted: {}m",
            delta.num_minutes()
        );
    }
}

/// POST resume clears the pause row.
#[tokio::test]
async fn resume_clears_pause() {
    let pause_store: Arc<dyn PauseStore> = Arc::new(MemPauseStore::new());
    let state = make_state(
        pause_store.clone(),
        Arc::new(MemInflight::new()),
        Arc::new(FakeSampler),
        Arc::new(FakeGate::allow()),
    );
    let app = routes::router(state);
    let (k, v) = auth_header();

    pause_store
        .pause(&PauseTargetId::Kind(WorkKind::Ocr), nz(5))
        .expect("pause ok");
    assert!(pause_store
        .paused_until(&PauseTargetId::Kind(WorkKind::Ocr))
        .is_some());

    let req = Request::builder()
        .method(Method::POST)
        .uri("/v1/activity/resume")
        .header(k, v)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({"target":"kind","id":"ocr"}).to_string()))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
    assert!(
        pause_store
            .paused_until(&PauseTargetId::Kind(WorkKind::Ocr))
            .is_none(),
        "resume must clear the row"
    );
}

/// `_internal/inflight` updates the registry; subsequent snapshot reflects it.
#[tokio::test]
async fn inflight_loopback_round_trip() {
    let inflight: Arc<dyn InflightRegistry> = Arc::new(MemInflight::new());
    let state = make_state(
        Arc::new(MemPauseStore::new()),
        inflight.clone(),
        Arc::new(FakeSampler),
        Arc::new(FakeGate::allow()),
    );
    let app = routes::router(state);
    let (k, v) = auth_header();

    let body = json!({
        "kind": "transcribe",
        "in_flight": {
            "label": "Transcribing 14:22:01→14:25:00 (en)",
            "started_at": "2026-04-26T14:22:03.812Z"
        }
    });
    let req = Request::builder()
        .method(Method::POST)
        .uri("/v1/activity/_internal/inflight")
        .header(&k, v.clone())
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    let resp = app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    // Snapshot now shows transcribe.in_flight populated.
    let snap_req = Request::builder()
        .method(Method::GET)
        .uri("/v1/activity/snapshot")
        .header(k, v)
        .body(Body::empty())
        .unwrap();
    let snap = json_body(app.oneshot(snap_req).await.unwrap()).await;
    let transcribe = snap["kinds"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["kind"] == "transcribe")
        .unwrap();
    let inf = &transcribe["in_flight"];
    assert!(
        !inf.is_null(),
        "in_flight must be populated after loopback POST"
    );
    assert_eq!(inf["label"], json!("Transcribing 14:22:01→14:25:00 (en)"));

    // Clearing form: in_flight: null
    let clear = json!({ "kind": "transcribe", "in_flight": null });
    let (k2, v2) = auth_header();
    let req = Request::builder()
        .method(Method::POST)
        .uri("/v1/activity/_internal/inflight")
        .header(k2, v2)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(clear.to_string()))
        .unwrap();
    let app2 = routes::router(make_state(
        Arc::new(MemPauseStore::new()),
        inflight.clone(),
        Arc::new(FakeSampler),
        Arc::new(FakeGate::allow()),
    ));
    let resp = app2.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
    assert!(inflight.snapshot().get(&WorkKind::Transcribe).is_none());
}

/// Activity queue counts are DB-authoritative: `/snapshot` reads
/// `pending_work` directly and ignores the legacy `_internal/queue-depth`
/// push payload.
#[tokio::test]
async fn queue_depth_snapshot_reads_pending_work_not_loopback_cache() {
    let state = make_state(
        Arc::new(MemPauseStore::new()),
        Arc::new(MemInflight::new()),
        Arc::new(FakeSampler),
        Arc::new(FakeGate::allow()),
    );
    seed_pending_work(
        &state.pool,
        &[
            ("queued", "transcribe"),
            ("queued", "transcribe"),
            ("failed", "ocr"),
            ("queued", "summarize"),
            ("failed", "extractMemory"),
            ("failed", "extractActionItems"),
            ("failed", "extractActionItems"),
            ("claimed", "transcribe"),
            ("dead", "ocr"),
            ("unknown", "summarize"),
            ("queued", "notARealWorkKind"),
        ],
    )
    .await;
    let app = routes::router(state);
    let (k, v) = auth_header();

    // Legacy push is accepted but must not override DB truth.
    let body = json!({
        "depths": {
            "transcribe": { "queued": 99, "failed": 99 },
            "summarize":  { "queued": 99, "failed": 99 }
        }
    });
    let req = Request::builder()
        .method(Method::POST)
        .uri("/v1/activity/_internal/queue-depth")
        .header(&k, v.clone())
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    let resp = app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    let snap_req = Request::builder()
        .method(Method::GET)
        .uri("/v1/activity/snapshot")
        .header(k, v)
        .body(Body::empty())
        .unwrap();
    let snap = json_body(app.oneshot(snap_req).await.unwrap()).await;
    let kinds = snap["kinds"].as_array().expect("kinds is an array");

    let row_for = |wire: &str| -> &Value {
        kinds
            .iter()
            .find(|r| r["kind"] == wire)
            .unwrap_or_else(|| panic!("snapshot missing row for `{wire}`"))
    };

    assert_eq!(row_for("transcribe")["queued"], json!(2));
    assert_eq!(row_for("transcribe")["failed"], json!(0));
    assert_eq!(row_for("ocr")["queued"], json!(0));
    assert_eq!(row_for("ocr")["failed"], json!(1));
    assert_eq!(row_for("summarize")["queued"], json!(1));
    assert_eq!(row_for("summarize")["failed"], json!(0));
    assert_eq!(row_for("extract_memory")["queued"], json!(0));
    assert_eq!(row_for("extract_memory")["failed"], json!(1));
    assert_eq!(row_for("extract_action_items")["queued"], json!(0));
    assert_eq!(row_for("extract_action_items")["failed"], json!(2));
}

/// Fresh installs may not have run the Swift `pending_work` migration yet.
/// Snapshot should still be 200 with every queue/failure count at zero.
#[tokio::test]
async fn queue_depth_snapshot_missing_pending_work_table_is_empty() {
    let app = make_default_app();
    let (k, v) = auth_header();
    let req = Request::builder()
        .method(Method::GET)
        .uri("/v1/activity/snapshot")
        .header(k, v)
        .body(Body::empty())
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let snap = json_body(resp).await;
    for row in snap["kinds"].as_array().expect("kinds is an array") {
        assert_eq!(row["queued"], json!(0), "queued not empty for row {row}");
        assert_eq!(row["failed"], json!(0), "failed not empty for row {row}");
    }
}

/// Auth: missing bearer → 401.
#[tokio::test]
async fn missing_bearer_returns_401() {
    let app = make_default_app();
    let req = Request::builder()
        .method(Method::GET)
        .uri("/v1/activity/snapshot")
        .body(Body::empty())
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

/// Bad pause body → 400 (or 422). Stream A picks the exact code; we accept
/// any 4xx that signals client error.
#[tokio::test]
async fn pause_request_validation() {
    let app = make_default_app();
    let (k, v) = auth_header();
    // Missing `minutes`.
    let req = Request::builder()
        .method(Method::POST)
        .uri("/v1/activity/pause")
        .header(k, v)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(json!({"target":"kind","id":"ocr"}).to_string()))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert!(
        resp.status().is_client_error(),
        "expected 4xx for invalid body; got {}",
        resp.status()
    );
}

/// Type-only round trip — no Stream A wiring needed. Sanity check that
/// the contract.md snake_case wire format matches what serde emits.
#[tokio::test]
async fn enum_round_trip_via_wire() {
    use infinite_recall_api::activity::types as t;

    // Every WorkKind value.
    for (kind, wire) in [
        (t::WorkKind::Transcribe, "transcribe"),
        (t::WorkKind::Ocr, "ocr"),
        (t::WorkKind::Summarize, "summarize"),
        (t::WorkKind::ExtractMemory, "extract_memory"),
        (t::WorkKind::ExtractActionItems, "extract_action_items"),
    ] {
        let s = serde_json::to_string(&kind).unwrap();
        assert_eq!(s, format!("\"{wire}\""));
        let back: t::WorkKind = serde_json::from_str(&s).unwrap();
        assert_eq!(kind, back);
    }

    // Issue #35: `GateReason` is gone, replaced by `BlockReason` (only
    // the Blocked variant carries one — Allowed has no sub-reason).
    for (reason, wire) in [
        (t::BlockReason::DeviceActive, "device_active"),
        (t::BlockReason::OnBattery, "on_battery"),
        (t::BlockReason::Thermal, "thermal"),
        (t::BlockReason::Locked, "locked"),
        (t::BlockReason::ManualPause, "manual_pause"),
        (t::BlockReason::Initializing, "initializing"),
    ] {
        let s = serde_json::to_string(&reason).unwrap();
        assert_eq!(s, format!("\"{wire}\""));
    }

    // Every ThermalState.
    for (ts, wire) in [
        (t::ThermalState::Nominal, "nominal"),
        (t::ThermalState::Fair, "fair"),
        (t::ThermalState::Serious, "serious"),
        (t::ThermalState::Critical, "critical"),
    ] {
        let s = serde_json::to_string(&ts).unwrap();
        assert_eq!(s, format!("\"{wire}\""));
    }

    // Issue #34: `PauseTargetId` is a sum type that serializes via
    // serde(tag/content) — exercise every variant's wire form.
    for kind in [
        t::WorkKind::Transcribe,
        t::WorkKind::Ocr,
        t::WorkKind::Summarize,
        t::WorkKind::ExtractMemory,
        t::WorkKind::ExtractActionItems,
    ] {
        let pt = t::PauseTargetId::Kind(kind);
        let s = serde_json::to_string(&pt).unwrap();
        let expected = format!(r#"{{"target":"kind","id":"{}"}}"#, kind.as_str());
        assert_eq!(s, expected, "PauseTargetId::Kind({kind:?}) wire shape");
        let back: t::PauseTargetId = serde_json::from_str(&s).unwrap();
        assert_eq!(back, pt);
    }
    for cap in [t::CaptureKind::Audio, t::CaptureKind::Screen] {
        let pt = t::PauseTargetId::Capture(cap);
        let s = serde_json::to_string(&pt).unwrap();
        let expected = format!(r#"{{"target":"capture","id":"{}"}}"#, cap.as_str());
        assert_eq!(s, expected, "PauseTargetId::Capture({cap:?}) wire shape");
    }
}

// ---------------------------------------------------------------------
// Issue #34 — `PauseRequest` / `ResumeRequest` wire-format coverage
// ---------------------------------------------------------------------

/// Pause body decodes for every `WorkKind` variant via the typed sum.
#[tokio::test]
async fn pause_kind_round_trip_for_every_variant() {
    let app = make_default_app();
    let (k, v) = auth_header();
    for kind_str in [
        "transcribe",
        "ocr",
        "summarize",
        "extract_memory",
        "extract_action_items",
    ] {
        let body = json!({"target":"kind","id":kind_str,"minutes":1});
        let req = Request::builder()
            .method(Method::POST)
            .uri("/v1/activity/pause")
            .header(&k, v.clone())
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(body.to_string()))
            .unwrap();
        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(
            resp.status(),
            StatusCode::OK,
            "pause kind {kind_str} should be accepted"
        );
    }
}

/// Pause body decodes for every `CaptureKind` variant via the typed sum.
#[tokio::test]
async fn pause_capture_round_trip_for_every_variant() {
    let app = make_default_app();
    let (k, v) = auth_header();
    for cap_str in ["audio", "screen"] {
        let body = json!({"target":"capture","id":cap_str,"minutes":2});
        let req = Request::builder()
            .method(Method::POST)
            .uri("/v1/activity/pause")
            .header(&k, v.clone())
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(body.to_string()))
            .unwrap();
        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(
            resp.status(),
            StatusCode::OK,
            "pause capture {cap_str} should be accepted"
        );
    }
}

/// `minutes: 0` is unrepresentable post-#34 — `NonZeroU32` rejects at the
/// serde layer, which axum surfaces as a 4xx with no manual guard required.
#[tokio::test]
async fn pause_with_zero_minutes_is_4xx_from_serde() {
    let app = make_default_app();
    let (k, v) = auth_header();
    let body = json!({"target":"kind","id":"ocr","minutes":0});
    let req = Request::builder()
        .method(Method::POST)
        .uri("/v1/activity/pause")
        .header(k, v)
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert!(
        resp.status().is_client_error(),
        "minutes=0 must be rejected by serde; got {}",
        resp.status()
    );
}

/// `target=kind` + an unknown id (or one that belongs to the other variant)
/// is unrepresentable — serde rejects at decode.
#[tokio::test]
async fn pause_with_unknown_target_id_is_4xx_from_serde() {
    let app = make_default_app();
    let (k, v) = auth_header();

    // `Kind` variant cannot carry a `CaptureKind` id.
    let cases = [
        json!({"target":"kind","id":"audio","minutes":5}),
        json!({"target":"kind","id":"nope","minutes":5}),
        json!({"target":"capture","id":"ocr","minutes":5}),
        json!({"target":"capture","id":"nope","minutes":5}),
        json!({"target":"nope","id":"ocr","minutes":5}),
    ];
    for body in cases {
        let req = Request::builder()
            .method(Method::POST)
            .uri("/v1/activity/pause")
            .header(&k, v.clone())
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(body.to_string()))
            .unwrap();
        let resp = app.clone().oneshot(req).await.unwrap();
        assert!(
            resp.status().is_client_error(),
            "expected 4xx for body {body:?}; got {}",
            resp.status()
        );
    }
}

/// Resume body decodes for both kind and capture targets via the typed sum.
#[tokio::test]
async fn resume_round_trip_for_kind_and_capture() {
    let pause_store: Arc<dyn PauseStore> = Arc::new(MemPauseStore::new());
    let state = make_state(
        pause_store.clone(),
        Arc::new(MemInflight::new()),
        Arc::new(FakeSampler),
        Arc::new(FakeGate::allow()),
    );
    let app = routes::router(state);
    let (k, v) = auth_header();

    // Seed both a kind and capture pause.
    pause_store
        .pause(&PauseTargetId::Kind(WorkKind::Ocr), nz(5))
        .unwrap();
    pause_store
        .pause(&PauseTargetId::Capture(CaptureKind::Audio), nz(5))
        .unwrap();

    for body in [
        json!({"target":"kind","id":"ocr"}),
        json!({"target":"capture","id":"audio"}),
    ] {
        let req = Request::builder()
            .method(Method::POST)
            .uri("/v1/activity/resume")
            .header(&k, v.clone())
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(body.to_string()))
            .unwrap();
        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::NO_CONTENT, "body: {body}");
    }

    assert!(pause_store
        .paused_until(&PauseTargetId::Kind(WorkKind::Ocr))
        .is_none());
    assert!(pause_store
        .paused_until(&PauseTargetId::Capture(CaptureKind::Audio))
        .is_none());
}

// ---------------------------------------------------------------------
// Issue #32 — `BridgedProcessingGate` + `_internal/gate-state` endpoint
// ---------------------------------------------------------------------

/// Posting a `GateState` to the gate-state loopback updates what
/// `/snapshot` returns for `processing_gate`. End-to-end round trip.
#[tokio::test]
async fn gate_state_post_updates_snapshot() {
    use infinite_recall_api::activity::BridgedProcessingGate;

    // Use the production `BridgedProcessingGate` so the route handler's
    // `set()` actually mutates state (the test `FakeGate` defaults to a
    // no-op `set`).
    let gate: Arc<BridgedProcessingGate> = Arc::new(BridgedProcessingGate::new());
    let state = make_state_with_writer(
        Arc::new(MemPauseStore::new()),
        Arc::new(MemInflight::new()),
        Arc::new(FakeSampler),
        gate.clone(),
        gate.clone(),
    );
    let app = routes::router(state);
    let (k, v) = auth_header();

    // Pre-condition: snapshot reports `Blocked { reason: Initializing }` until
    // the first POST arrives.
    let snap_req = Request::builder()
        .method(Method::GET)
        .uri("/v1/activity/snapshot")
        .header(&k, v.clone())
        .body(Body::empty())
        .unwrap();
    let snap = json_body(app.clone().oneshot(snap_req).await.unwrap()).await;
    assert_eq!(snap["processing_gate"]["state"], json!("blocked"));
    assert_eq!(snap["processing_gate"]["reason"], json!("initializing"));

    // POST a real `Allowed` state.
    let body = json!({
        "state": "allowed",
        "since": "2026-04-26T14:25:00.000Z"
    });
    let req = Request::builder()
        .method(Method::POST)
        .uri("/v1/activity/_internal/gate-state")
        .header(&k, v.clone())
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    let resp = app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    // Snapshot now reflects the new state.
    let snap_req = Request::builder()
        .method(Method::GET)
        .uri("/v1/activity/snapshot")
        .header(&k, v.clone())
        .body(Body::empty())
        .unwrap();
    let snap = json_body(app.clone().oneshot(snap_req).await.unwrap()).await;
    assert_eq!(snap["processing_gate"]["state"], json!("allowed"));
    assert!(snap["processing_gate"].get("reason").is_none());

    // POST a `Blocked { DeviceActive, IdleFor 120s }` state.
    let body = json!({
        "state": "blocked",
        "reason": "device_active",
        "since": "2026-04-26T14:30:00.000Z",
        "waiting_for": { "type": "idle_for", "duration_secs": 120 }
    });
    let req = Request::builder()
        .method(Method::POST)
        .uri("/v1/activity/_internal/gate-state")
        .header(&k, v.clone())
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    let resp = app.clone().oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    // Direct `current()` read on the gate matches what we POSTed.
    match gate.current() {
        GateState::Blocked {
            reason,
            waiting_for,
            ..
        } => {
            assert_eq!(reason, BlockReason::DeviceActive);
            assert_eq!(
                waiting_for,
                WaitCondition::IdleFor {
                    duration: std::time::Duration::from_secs(120)
                }
            );
        }
        _ => panic!("expected Blocked after POST"),
    }
}

/// Missing bearer → 401, even on the loopback gate-state endpoint.
#[tokio::test]
async fn gate_state_post_requires_bearer() {
    let app = make_default_app();
    let body = json!({
        "state": "allowed",
        "since": "2026-04-26T14:25:00.000Z"
    });
    let req = Request::builder()
        .method(Method::POST)
        .uri("/v1/activity/_internal/gate-state")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

/// Bodies that don't decode as a `GateState` (missing `waiting_for` on a
/// `Blocked`, unknown variant tag, ...) are rejected at the serde layer
/// with a 4xx — no manual guard needed in the handler.
#[tokio::test]
async fn gate_state_post_rejects_invalid_bodies() {
    let app = make_default_app();
    let (k, v) = auth_header();

    let cases = [
        // Unknown state tag.
        json!({"state":"throttled","since":"2026-04-26T14:25:00Z"}),
        // Blocked missing `waiting_for`.
        json!({"state":"blocked","reason":"device_active","since":"2026-04-26T14:25:00Z"}),
        // Blocked with unknown reason.
        json!({
            "state":"blocked","reason":"galactic_radiation",
            "since":"2026-04-26T14:25:00Z",
            "waiting_for":{"type":"idle_for","duration_secs":120}
        }),
        // Blocked with unknown waiting_for type.
        json!({
            "state":"blocked","reason":"device_active",
            "since":"2026-04-26T14:25:00Z",
            "waiting_for":{"type":"warp_drive"}
        }),
    ];

    for body in cases {
        let req = Request::builder()
            .method(Method::POST)
            .uri("/v1/activity/_internal/gate-state")
            .header(&k, v.clone())
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(body.to_string()))
            .unwrap();
        let resp = app.clone().oneshot(req).await.unwrap();
        assert!(
            resp.status().is_client_error(),
            "expected 4xx for body {body:?}; got {}",
            resp.status()
        );
    }
}

/// `BridgedProcessingGate::set` rejects external `Blocked { Initializing, .. }`
/// posts (defense-in-depth). The `Initializing` variant exists ONLY to
/// represent "haven't received the first POST yet" — Swift should never
/// post it, but if it ever does, we must not let it latch the gate back
/// into the boot-window state. The route handler still returns 204 (this
/// is internal validation that doesn't leak to the caller); the post-
/// condition is that the stored gate state is unchanged.
#[tokio::test]
async fn gate_state_post_rejects_external_initializing_silently() {
    use infinite_recall_api::activity::BridgedProcessingGate;

    let gate: Arc<BridgedProcessingGate> = Arc::new(BridgedProcessingGate::new());
    let state = make_state_with_writer(
        Arc::new(MemPauseStore::new()),
        Arc::new(MemInflight::new()),
        Arc::new(FakeSampler),
        gate.clone(),
        gate.clone(),
    );
    let app = routes::router(state);
    let (k, v) = auth_header();

    // Pre: snapshot reports Initializing (initial state, no real POST yet).
    let snap_req = Request::builder()
        .method(Method::GET)
        .uri("/v1/activity/snapshot")
        .header(&k, v.clone())
        .body(Body::empty())
        .unwrap();
    let snap = json_body(app.clone().oneshot(snap_req).await.unwrap()).await;
    assert_eq!(snap["processing_gate"]["state"], json!("blocked"));
    assert_eq!(snap["processing_gate"]["reason"], json!("initializing"));
    let initial_since = snap["processing_gate"]["since"]
        .as_str()
        .expect("since must be a string")
        .to_string();

    // POST a `Blocked { Initializing, .. }` body — the handler must accept it
    // at the wire level (return 204) but the gate's internal state must
    // be unchanged (rejected by `BridgedProcessingGate::set`).
    let body = json!({
        "state": "blocked",
        "reason": "initializing",
        "since": "2030-01-01T00:00:00.000Z",
        "waiting_for": { "type": "manual" }
    });
    let req = Request::builder()
        .method(Method::POST)
        .uri("/v1/activity/_internal/gate-state")
        .header(&k, v.clone())
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(body.to_string()))
        .unwrap();
    let resp = app.clone().oneshot(req).await.unwrap();
    // 204 — defense-in-depth, no validation leak.
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    // Post: snapshot still reports the original Initializing state (the same
    // `since` from before — the rejected POST didn't overwrite anything).
    let snap_req = Request::builder()
        .method(Method::GET)
        .uri("/v1/activity/snapshot")
        .header(&k, v.clone())
        .body(Body::empty())
        .unwrap();
    let snap = json_body(app.clone().oneshot(snap_req).await.unwrap()).await;
    assert_eq!(snap["processing_gate"]["state"], json!("blocked"));
    assert_eq!(snap["processing_gate"]["reason"], json!("initializing"));
    assert_eq!(
        snap["processing_gate"]["since"].as_str().unwrap(),
        initial_since,
        "`since` must NOT advance — the Initializing POST should be a no-op"
    );
}
