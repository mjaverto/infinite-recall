//! Library entrypoint for the `infinite-recall-api` daemon.
//!
//! The daemon binary in `main.rs` is a thin shim that calls [`run`].
//! The library form exists primarily so sibling crates (notably the
//! `recall` CLI) can depend on shared building blocks like
//! [`token::token_path`] without re-implementing them.

pub mod activity;
pub mod auth;
pub mod db;
pub mod error;
pub mod routes;
pub mod state;
pub mod token;

use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::{Context, Result};
use tracing_subscriber::EnvFilter;

use state::AppState;

/// Boot the HTTP daemon. Blocks until shutdown / error.
pub async fn run() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("info,infinite_recall_api=info")),
        )
        .try_init()
        .ok();

    let db_path = resolve_db_path();
    tracing::info!(db = %db_path.display(), "opening sqlite (read pool + write pool)");

    let pool = open_read_only_pool_with_retry(&db_path)?;
    let write_pool = db::open_read_write_pool(&db_path)
        .with_context(|| format!("opening sqlite write pool at {}", db_path.display()))?;

    let token = token::ensure_token().context("ensuring api token file")?;
    tracing::info!(
        token_path = %token::token_path().display(),
        "bearer token ready (read it from the token file; not logged)"
    );

    // === activity:A ===
    // Real impls from streams B/C/D + an always-allowed gate stub until the
    // idle-gate agent ships its real ProcessingGate.
    let activity_db_path = resolve_activity_db_path();
    if let Some(parent) = activity_db_path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating activity db dir {}", parent.display()))?;
    }
    let pause_store: Arc<dyn activity::PauseStore> = Arc::new(
        activity::pause_store::SqlPauseStore::open(&activity_db_path)
            .with_context(|| format!("opening activity pause store at {}", activity_db_path.display()))?,
    );
    let inflight: Arc<dyn activity::InflightRegistry> =
        Arc::new(activity::inflight::MemoryInflightRegistry::new());
    let resource_sampler: Arc<dyn activity::ResourceSampler> =
        Arc::new(activity::resources::SystemResourceSampler::new());
    // Issue #32: real `ProcessingGate` implementation. Swift owns the OS
    // signal observation and POSTs `GateState` updates to
    // `/v1/activity/_internal/gate-state`. Until that first POST arrives,
    // `current()` returns `Blocked { reason: Initializing, ... }` so the UI is
    // honest about the brief startup window.
    //
    // Single backing Arc upcast into both the read-side (`ProcessingGate`)
    // and the write-side (`WritableProcessingGate`) so the snapshot reader
    // and the gate-state POST handler share the same RwLock<GateState>
    // store. The trait split prevents a future `set()`-less gate from
    // being silently wired into the write path.
    let bridged_gate: Arc<activity::BridgedProcessingGate> =
        Arc::new(activity::BridgedProcessingGate::new());
    let processing_gate: Arc<dyn activity::ProcessingGate> = bridged_gate.clone();
    let processing_gate_writer: Arc<dyn activity::WritableProcessingGate> = bridged_gate;
    let (pause_tx, _pause_rx) = tokio::sync::broadcast::channel(64);
    // === /activity:A ===

    // === activity:lane-d ===
    // Production LocalModel allowlist gate for the terminate route. Re-runs
    // pid discovery on every call (does not trust the sampler's 2 s cache).
    let local_model_gate: Arc<dyn activity::terminate::LocalModelGate> =
        Arc::new(activity::terminate::ProcLocalModelGate::new());
    // === /activity:lane-d ===

    let state = AppState {
        pool,
        write_pool,
        token,
        // === activity:A ===
        pause_store,
        inflight,
        resource_sampler,
        processing_gate,
        processing_gate_writer,
        pause_tx,
        // === /activity:A ===
        // === activity:lane-d ===
        local_model_gate,
        // === /activity:lane-d ===
    };
    let app = routes::router(state);

    let bind: SocketAddr = std::env::var("INFINITE_RECALL_BIND")
        .unwrap_or_else(|_| "127.0.0.1:7331".to_string())
        .parse()
        .context("parsing INFINITE_RECALL_BIND")?;

    if !bind.ip().is_loopback() {
        anyhow::bail!(
            "refusing non-loopback bind {bind} — the activity loopback endpoint must stay local-only"
        );
    }

    let listener = tokio::net::TcpListener::bind(&bind)
        .await
        .with_context(|| format!("binding {bind}"))?;
    tracing::info!(%bind, "infinite-recall-api listening");

    axum::serve(listener, app).await?;
    Ok(())
}

/// Open the read-only pool with a small startup retry. On a fresh launch
/// (or right after a state-dir wipe) the Swift app may still be creating
/// the SQLite file when the daemon boots; we want to wait a few seconds
/// rather than crashing the daemon and bouncing on launchd's KeepAlive.
///
/// Only transient failures retry — file missing or SQLITE_BUSY/locked.
/// Permission errors, corruption, etc. fail fast (no point retrying).
pub(crate) fn open_read_only_pool_with_retry(db_path: &std::path::Path) -> Result<db::SqlitePool> {
    const MAX_ATTEMPTS: usize = 5;
    const BACKOFF: std::time::Duration = std::time::Duration::from_secs(1);

    let mut last_err: Option<anyhow::Error> = None;
    for attempt in 1..=MAX_ATTEMPTS {
        match db::open_read_only_pool(db_path) {
            Ok(pool) => {
                if attempt > 1 {
                    tracing::info!(
                        attempt,
                        "sqlite read pool opened after retry"
                    );
                }
                return Ok(pool);
            }
            Err(err) => {
                if !db::is_transient_open_error(&err) {
                    return Err(err.context(format!(
                        "opening sqlite read pool at {} (terminal failure, no retry)",
                        db_path.display()
                    )));
                }
                tracing::info!(
                    attempt,
                    max_attempts = MAX_ATTEMPTS,
                    error = %err,
                    "transient sqlite open failure; will retry"
                );
                last_err = Some(err);
                if attempt < MAX_ATTEMPTS {
                    std::thread::sleep(BACKOFF);
                }
            }
        }
    }
    let err = last_err.unwrap_or_else(|| anyhow::anyhow!("unknown sqlite open failure"));
    Err(err.context(format!(
        "opening sqlite read pool at {} failed after {} attempts",
        db_path.display(),
        MAX_ATTEMPTS
    )))
}

/// Pick the SQLite path. Honors `INFINITE_RECALL_DB`, otherwise falls back
/// to the Swift app's location under Application Support.
fn resolve_db_path() -> std::path::PathBuf {
    if let Ok(v) = std::env::var("INFINITE_RECALL_DB") {
        return std::path::PathBuf::from(v);
    }
    let home = dirs::home_dir().expect("HOME dir resolvable");
    home.join("Library/Application Support/Omi/users/anonymous/omi.db")
}

/// Pick the Activity Tab SQLite path (separate file from the read-only
/// transcription DB). Honors `INFINITE_RECALL_ACTIVITY_DB`, otherwise
/// falls back to the InfiniteRecall Application Support directory.
fn resolve_activity_db_path() -> std::path::PathBuf {
    if let Ok(v) = std::env::var("INFINITE_RECALL_ACTIVITY_DB") {
        return std::path::PathBuf::from(v);
    }
    let home = dirs::home_dir().expect("HOME dir resolvable");
    home.join("Library/Application Support/InfiniteRecall/activity.db")
}

#[cfg(test)]
mod retry_tests {
    use super::open_read_only_pool_with_retry;
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    /// Build a minimal but valid SQLite file at `path` so the read-only pool
    /// can actually open it. We write nothing — opening the file with a
    /// `rusqlite::Connection` (read-write) creates the header + first page.
    fn create_empty_sqlite_db(path: &std::path::Path) {
        let conn = rusqlite::Connection::open(path).expect("create sqlite");
        conn.execute_batch("PRAGMA journal_mode=WAL;").ok();
        drop(conn);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn retries_until_file_appears() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path: PathBuf = dir.path().join("late.db");

        // The retry function blocks (uses std::thread::sleep), so we run it
        // on a blocking task while a parallel task creates the file at 1.5s.
        let path_for_creator = path.clone();
        let created = Arc::new(AtomicBool::new(false));
        let created_flag = created.clone();
        let creator = tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
            create_empty_sqlite_db(&path_for_creator);
            created_flag.store(true, Ordering::SeqCst);
        });

        let path_for_open = path.clone();
        let open_result = tokio::task::spawn_blocking(move || {
            open_read_only_pool_with_retry(&path_for_open)
        })
        .await
        .expect("join blocking");

        creator.await.expect("creator");
        assert!(
            created.load(Ordering::SeqCst),
            "creator must have run before assertion"
        );
        assert!(
            open_result.is_ok(),
            "expected pool open to succeed within retry budget, got: {:?}",
            open_result.err()
        );
    }

    // Terminal-error fast-fail behavior is covered by the `db::tests` unit
    // suite (`sqlite_notadb_is_terminal`, `io_permission_denied_is_terminal`)
    // — those pin `is_transient_open_error` directly without needing to
    // drive a real SQLite handle through the full retry loop, which is
    // non-deterministic to set up across macOS/Linux test environments.
}
