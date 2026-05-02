//! Lane D: integration test for `POST /v1/activity/processes/:pid/terminate`.
//!
//! Spins up the real `routes::router` against an `AppState` with stub trait
//! impls (mirrors the pattern in `activity_endpoints.rs`, but does NOT gate on
//! `activity_test_wiring` — this lane needs the test to run on default
//! `cargo test -p api terminate`).
//!
//! Coverage:
//! * SIGTERM path: spawn a `sleep 60`, allowlist its pid, POST terminate,
//!   assert 204 and the pid is gone (kill(pid, 0) returns ESRCH).
//! * Allowlist gate: a fresh (un-allowlisted) pid returns 404.

use std::collections::HashMap;
use std::num::NonZeroU32;
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use axum::body::Body;
use axum::http::{header, Method, Request, StatusCode};
use chrono::{DateTime, Utc};
use tower::util::ServiceExt;

use infinite_recall_api::activity::terminate::LocalModelGate;
use infinite_recall_api::activity::traits::{
    InflightRegistry, PauseStore, PauseStoreError, ProcessingGate, ResourceSampler,
    WritableProcessingGate,
};
use infinite_recall_api::activity::types::{
    BlockReason, GateState, InFlight, PauseTargetId, ProcessBreakdown, ResourceSample,
    ThermalState, WaitCondition, WorkKind,
};
use infinite_recall_api::routes;
use infinite_recall_api::state::AppState;

const TEST_TOKEN: &str = "test-bearer-token-lane-d";

// ---------------------------------------------------------------------
// Stubs (minimal; this test only exercises the terminate route)
// ---------------------------------------------------------------------

struct MemPauseStore {
    inner: Mutex<HashMap<PauseTargetId, DateTime<Utc>>>,
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
        let resume_at = Utc::now() + chrono::Duration::minutes(i64::from(minutes.get()));
        self.inner.lock().unwrap().insert(*target, resume_at);
        Ok(resume_at)
    }
    fn resume(&self, target: &PauseTargetId) -> Result<bool, PauseStoreError> {
        Ok(self.inner.lock().unwrap().remove(target).is_some())
    }
}

struct MemInflight {
    inner: RwLock<HashMap<WorkKind, InFlight>>,
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

struct FakeSampler;
impl ResourceSampler for FakeSampler {
    fn sample(&self) -> ResourceSample {
        ResourceSample {
            cpu_percent: 0.0,
            mem_mb: 0,
            gpu_system_percent: None,
            thermal_state: ThermalState::Nominal,
            on_battery: false,
            low_power: false,
            process_breakdown: vec![ProcessBreakdown {
                name: "stub".into(),
                pid: 1,
                cpu_percent: 0.0,
                mem_mb: 0,
                kind: None,
            }],
        }
    }
}

struct FakeGate;
impl ProcessingGate for FakeGate {
    fn current(&self) -> GateState {
        GateState::Allowed { since: Utc::now() }
    }
}

struct NoopWritableGate;
impl ProcessingGate for NoopWritableGate {
    fn current(&self) -> GateState {
        GateState::Allowed { since: Utc::now() }
    }
}
impl WritableProcessingGate for NoopWritableGate {
    fn set(&self, _new_state: GateState) {}
}

/// Stub LocalModel allowlist — caller provides the exact pid set so the test
/// doesn't have to fork a real mlx-lm worker.
struct StubLocalModelGate {
    allowed: Vec<i32>,
}

impl LocalModelGate for StubLocalModelGate {
    fn is_local_model(&self, pid: i32) -> bool {
        self.allowed.contains(&pid)
    }
}

// Suppress unused-import warnings for stubs we don't use in every test.
#[allow(dead_code)]
fn _block_reason_keepalive() -> BlockReason {
    BlockReason::Initializing
}
#[allow(dead_code)]
fn _wait_condition_keepalive() -> WaitCondition {
    WaitCondition::Manual
}

// ---------------------------------------------------------------------
// Builders
// ---------------------------------------------------------------------

/// Build a `SqlitePool` against a temp file. We can't use the
/// `infinite_recall_api::db::open_in_memory_pool` helper because Lane A's
/// crate gates it behind `cfg(any(test, feature = "activity_test_wiring"))`,
/// and integration tests don't pick up the `test` cfg of the parent crate.
/// Going via the public `open_read_write_pool` would require us to seed a
/// non-empty SQLite file with PRAGMA journal_mode=WAL — overkill for a route
/// that doesn't touch SQL at all. So we shell-create an empty file and
/// re-use the public read-only path.
fn make_temp_pools() -> (
    infinite_recall_api::db::SqlitePool,
    infinite_recall_api::db::SqlitePool,
    tempfile::TempDir,
) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("terminate-test.sqlite");
    // Create an empty, valid SQLite file via a one-shot connection.
    {
        let conn = rusqlite::Connection::open(&path).expect("open sqlite");
        conn.execute_batch("CREATE TABLE _seed (x INTEGER); DROP TABLE _seed;")
            .expect("seed sqlite");
    }
    let read_pool =
        infinite_recall_api::db::open_read_only_pool(&path).expect("open read-only pool");
    let write_pool =
        infinite_recall_api::db::open_read_write_pool(&path).expect("open read-write pool");
    (read_pool, write_pool, dir)
}

fn make_state(allowed_pids: Vec<i32>) -> (AppState, tempfile::TempDir) {
    let (pool, write_pool, dir) = make_temp_pools();
    let (pause_tx, _pause_rx) = tokio::sync::broadcast::channel(64);
    let state = AppState {
        pool,
        write_pool,
        token: TEST_TOKEN.to_string(),
        pause_store: Arc::new(MemPauseStore {
            inner: Mutex::new(HashMap::new()),
        }),
        inflight: Arc::new(MemInflight {
            inner: RwLock::new(HashMap::new()),
        }),
        resource_sampler: Arc::new(FakeSampler),
        processing_gate: Arc::new(FakeGate),
        processing_gate_writer: Arc::new(NoopWritableGate),
        pause_tx,
        local_model_gate: Arc::new(StubLocalModelGate {
            allowed: allowed_pids,
        }),
        db_path: Arc::new(std::path::PathBuf::from(":memory:")),
        activity_db_path: Arc::new(std::path::PathBuf::from(":memory:")),
        worker_errors: Arc::new(infinite_recall_api::worker_errors::WorkerErrorSink::default()),
    };
    (state, dir)
}

fn auth_header() -> (axum::http::HeaderName, axum::http::HeaderValue) {
    (
        header::AUTHORIZATION,
        format!("Bearer {TEST_TOKEN}").parse().unwrap(),
    )
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

/// Happy path: spawn `sleep 60`, allowlist its pid, POST terminate, expect
/// 204 and the pid to be gone.
///
/// Subtle: in production the mlx-lm worker is parented to launchd, which
/// reaps zombies promptly. In this test WE are the parent, so we need a
/// concurrent reaper thread — without it the SIGTERM'd `sleep` becomes a
/// zombie that `kill(pid, 0)` reports as alive, pushing the handler all
/// the way through the 5 s grace window into the SIGKILL branch. The route
/// returns 204 either way, but the test runs ~5 s slower without a reaper.
#[tokio::test]
async fn terminate_kills_allowlisted_process() {
    let child = std::process::Command::new("sleep")
        .arg("60")
        .spawn()
        .expect("spawn sleep");
    let pid = child.id() as i32;

    // Background reaper: drain the zombie as soon as the route's SIGTERM lands.
    let reap_handle = std::thread::spawn(move || {
        let mut child = child;
        let _ = child.wait();
    });

    // brief warmup so the kernel has the pid registered
    tokio::time::sleep(Duration::from_millis(50)).await;

    let (state, _tmp) = make_state(vec![pid]);
    let app = routes::router(state);
    let (k, v) = auth_header();
    let req = Request::builder()
        .method(Method::POST)
        .uri(format!("/v1/activity/processes/{pid}/terminate"))
        .header(k, v)
        .body(Body::empty())
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    let status = resp.status();

    let _ = reap_handle.join();

    assert_eq!(status, StatusCode::NO_CONTENT);

    // kill(pid, 0) returns -1 ESRCH for a gone pid.
    let probe = unsafe { libc::kill(pid as libc::pid_t, 0) };
    assert_eq!(probe, -1, "process must be gone after terminate");
    let errno = std::io::Error::last_os_error().raw_os_error();
    assert_eq!(
        errno,
        Some(libc::ESRCH),
        "expected ESRCH (no such process) after terminate; got {errno:?}"
    );
}

/// Negative path: pid is not in the allowlist → 404.
#[tokio::test]
async fn terminate_unallowlisted_pid_is_404() {
    // Spawn a real live process so the aliveness check (gate 2) passes if the
    // allowlist were ever permissive. The point of this test is that gate 1
    // (the allowlist) does its job — so we deliberately leave the allowlist
    // empty.
    let mut child = std::process::Command::new("sleep")
        .arg("60")
        .spawn()
        .expect("spawn sleep");
    let pid = child.id() as i32;
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Empty allowlist — pid is alive but NOT a tracked LocalModel.
    let (state, _tmp) = make_state(vec![]);
    let app = routes::router(state);
    let (k, v) = auth_header();
    let req = Request::builder()
        .method(Method::POST)
        .uri(format!("/v1/activity/processes/{pid}/terminate"))
        .header(k, v)
        .body(Body::empty())
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    let status = resp.status();

    // Tear down the sleep — the route MUST NOT have killed it.
    let probe_before_cleanup = unsafe { libc::kill(pid as libc::pid_t, 0) };
    let _ = child.kill();
    let _ = child.wait();

    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(
        probe_before_cleanup, 0,
        "404 path must not have killed the process; kill(pid,0) returned {probe_before_cleanup}"
    );
}

/// Auth: missing bearer → 401, even with a valid allowlist entry.
#[tokio::test]
async fn terminate_requires_bearer() {
    let (state, _tmp) = make_state(vec![std::process::id() as i32]);
    let app = routes::router(state);
    let req = Request::builder()
        .method(Method::POST)
        .uri("/v1/activity/processes/12345/terminate")
        .body(Body::empty())
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

/// Gate 2 reject: pid is in the LocalModel allowlist (gate 1 pass) but the
/// process is already dead (gate 2 fail) → 404.
///
/// This guards the "stale pidfile" scenario: discovery saw a pid via pidfile
/// or pgrep, but between cache-fill and the kill request the worker exited
/// on its own. Without gate 2 we'd `kill(2)` a recycled pid; with gate 2 we
/// 404 cleanly.
#[tokio::test]
async fn terminate_allowlisted_but_dead_pid_is_404() {
    // Spawn + reap so the pid is genuinely gone when we POST.
    let mut child = std::process::Command::new("true")
        .spawn()
        .expect("spawn true");
    let pid = child.id() as i32;
    let _ = child.wait();

    // Allowlist the now-dead pid — gate 1 passes, gate 2 must catch it.
    let (state, _tmp) = make_state(vec![pid]);
    let app = routes::router(state);
    let (k, v) = auth_header();
    let req = Request::builder()
        .method(Method::POST)
        .uri(format!("/v1/activity/processes/{pid}/terminate"))
        .header(k, v)
        .body(Body::empty())
        .unwrap();
    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::NOT_FOUND,
        "allowlisted-but-dead pid must 404 (gate 2 reject)"
    );
}
