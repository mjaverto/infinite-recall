//! Library entrypoint for the `infinite-recall-api` daemon.
//!
//! The daemon binary in `main.rs` is a thin shim that calls [`run`].
//! The library form exists primarily so sibling crates (notably the
//! `recall` CLI) can depend on shared building blocks like
//! [`token::token_path`] without re-implementing them.

pub mod auth;
pub mod db;
pub mod error;
pub mod routes;
pub mod state;
pub mod token;

use std::net::SocketAddr;

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

    let state = AppState { pool, write_pool, token };
    let app = routes::router(state);

    let bind: SocketAddr = std::env::var("INFINITE_RECALL_BIND")
        .unwrap_or_else(|_| "127.0.0.1:7331".to_string())
        .parse()
        .context("parsing INFINITE_RECALL_BIND")?;

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
