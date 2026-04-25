//! Infinite Recall — local Omi-shaped REST API.
//!
//! Read-only HTTP server over the GRDB SQLite at
//! ~/Library/Application Support/Omi/users/anonymous/omi.db
//! Listens on 127.0.0.1:7331 by default. Bearer-token auth.

use std::net::SocketAddr;

use anyhow::{Context, Result};
use tracing_subscriber::EnvFilter;

mod auth;
mod db;
mod error;
mod routes;
mod state;

use state::AppState;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| EnvFilter::new("info,infinite_recall_api=info")),
        )
        .init();

    let db_path = resolve_db_path();
    tracing::info!(db = %db_path.display(), "opening sqlite read-only");

    let pool = db::open_read_only_pool(&db_path)
        .with_context(|| format!("opening sqlite at {}", db_path.display()))?;

    let token = auth::ensure_token().context("ensuring api token file")?;
    tracing::info!(
        token_path = %auth::token_path().display(),
        "bearer token ready (read it from the token file; not logged)"
    );

    let state = AppState { pool, token };

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
