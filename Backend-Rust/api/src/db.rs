//! SQLite connection pools.
//!
//! Two pools share the same on-disk database:
//!
//! * `read_pool`  — opened with `SQLITE_OPEN_READ_ONLY | SQLITE_OPEN_NO_MUTEX`.
//!   Used by every GET handler. Cannot mutate, cannot block the Swift writer.
//! * `write_pool` — opened with `SQLITE_OPEN_READ_WRITE`. Smaller (max 2)
//!   because writes serialize at the SQLite layer regardless. Used only by
//!   the action-item mutation endpoints.
//!
//! Cross-process safety relies on the Swift app keeping the database in
//! WAL mode (`PRAGMA journal_mode = WAL`), confirmed in
//! `Desktop/Sources/Rewind/Core/RewindDatabase.swift:246`. WAL lets the Rust
//! reader work without ever taking a lock that conflicts with the GRDB writer,
//! and lets concurrent writers from Rust + Swift cooperate via the
//! per-database write-ahead log.

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
        .context("building r2d2 read pool")?;
    // Sanity check: open once.
    let conn = pool.get().context("checking out initial read connection")?;
    conn.query_row("SELECT 1", [], |_| Ok(()))
        .context("smoke-testing read-only connection")?;
    Ok(pool)
}

/// Open a *small* read-write pool. Writers serialize at the SQLite layer
/// regardless of pool size, so we keep this tight (max 2) — one connection
/// in flight, one warm spare. Each connection sets `busy_timeout` so a
/// transient lock from the Swift writer becomes a wait, not an error.
pub fn open_read_write_pool(path: &Path) -> Result<SqlitePool> {
    if !path.exists() {
        anyhow::bail!(
            "database not found at {} — start the Swift app at least once to create it",
            path.display()
        );
    }
    let manager = SqliteConnectionManager::file(path)
        .with_flags(OpenFlags::SQLITE_OPEN_READ_WRITE)
        .with_init(|c| {
            // 5s should comfortably exceed any GRDB write transaction.
            c.busy_timeout(std::time::Duration::from_secs(5))?;
            // Don't try to flip journal_mode here — Swift owns the database
            // and the pragma sticks at the file level. Verify only.
            let mode: String = c.query_row("PRAGMA journal_mode", [], |r| r.get(0))?;
            if !mode.eq_ignore_ascii_case("wal") {
                tracing::warn!(
                    journal_mode = %mode,
                    "expected WAL journaling for safe cross-process writes; \
                     mutations may serialize against Swift readers"
                );
            }
            Ok(())
        });
    let pool = Pool::builder()
        .max_size(2)
        .build(manager)
        .context("building r2d2 write pool")?;
    let conn = pool.get().context("checking out initial write connection")?;
    conn.query_row("SELECT 1", [], |_| Ok(()))
        .context("smoke-testing read-write connection")?;
    Ok(pool)
}

/// Test-only in-memory pool. Used by `tests/activity_endpoints.rs` (Stream I)
/// to construct an `AppState` without touching the on-disk Omi DB. Gated
/// behind `activity_test_wiring` so it never compiles into release builds.
#[cfg(any(test, feature = "activity_test_wiring"))]
pub fn open_in_memory_pool() -> Result<SqlitePool> {
    let manager = SqliteConnectionManager::memory();
    let pool = Pool::builder()
        .max_size(1)
        .build(manager)
        .context("building r2d2 in-memory pool")?;
    let conn = pool.get().context("checking out initial in-memory connection")?;
    conn.query_row("SELECT 1", [], |_| Ok(()))
        .context("smoke-testing in-memory connection")?;
    Ok(pool)
}

/// Helper: run a closure on a blocking thread with a pooled connection.
/// Most rusqlite calls are blocking; we offload to the tokio blocking pool
/// so the async runtime stays responsive. Works for both read and write
/// pools — pick the right pool at the call site.
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
