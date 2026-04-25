//! SQLite connection pool, opened read-only.
//!
//! GRDB writers from the Swift app must remain unaffected. We rely on
//! `OpenFlags::SQLITE_OPEN_READ_ONLY` and the standard SQLite WAL behavior:
//! readers do not block writers.

use std::path::Path;

use anyhow::{Context, Result};
use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;
use rusqlite::OpenFlags;

pub type SqlitePool = Pool<SqliteConnectionManager>;
pub type PooledConn = r2d2::PooledConnection<SqliteConnectionManager>;

pub fn open_read_only_pool(path: &Path) -> Result<SqlitePool> {
    if !path.exists() {
        anyhow::bail!(
            "database not found at {} — start the Swift app at least once to create it",
            path.display()
        );
    }
    let manager = SqliteConnectionManager::file(path).with_flags(
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    );
    let pool = Pool::builder()
        .max_size(8)
        .build(manager)
        .context("building r2d2 pool")?;
    // Sanity check: open once.
    let conn = pool.get().context("checking out initial connection")?;
    conn.query_row("SELECT 1", [], |_| Ok(()))
        .context("smoke-testing read-only connection")?;
    Ok(pool)
}

/// Helper: run a closure on a blocking thread with a pooled connection.
/// Most rusqlite calls are blocking; we offload to the tokio blocking pool
/// so the async runtime stays responsive.
pub async fn with_conn<F, T>(pool: &SqlitePool, f: F) -> Result<T>
where
    F: FnOnce(&PooledConn) -> Result<T> + Send + 'static,
    T: Send + 'static,
{
    let pool = pool.clone();
    tokio::task::spawn_blocking(move || {
        let conn = pool.get().context("checking out connection")?;
        f(&conn)
    })
    .await
    .context("join blocking task")?
}
