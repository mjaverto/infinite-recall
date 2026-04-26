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

    let pool = db::open_read_only_pool(&db_path)
        .with_context(|| format!("opening sqlite read pool at {}", db_path.display()))?;
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
    let processing_gate: Arc<dyn activity::ProcessingGate> =
        Arc::new(activity::gate::AlwaysAllowedGate);
    // Consensus-fix C4: leave a single, grep-able boot breadcrumb so anyone
    // staring at the Activity tab can confirm we are still on the stub.
    tracing::warn!(
        component = "activity.gate",
        "AlwaysAllowedGate active — real ProcessingGate not yet wired (issue #32)"
    );
    let (pause_tx, _pause_rx) = tokio::sync::broadcast::channel(64);
    // === /activity:A ===

    let state = AppState {
        pool,
        write_pool,
        token,
        // === activity:A ===
        pause_store,
        inflight,
        resource_sampler,
        processing_gate,
        pause_tx,
        // === /activity:A ===
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
