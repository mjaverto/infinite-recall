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

/// Classify whether a startup DB-open failure is worth retrying.
///
/// Transient: file-missing (Swift app may still be creating it), SQLITE_BUSY
/// / SQLITE_LOCKED (active writer), SQLITE_IOERR family (filesystem hiccup,
/// often clears on a brief retry), SQLITE_CANTOPEN (shared-state file race
/// during boot), SQLITE_PROTOCOL (transient WAL handshake).
///
/// Terminal: permission denied, SQLITE_NOTADB (real corruption), schema
/// mismatch — retrying will not change the outcome and the caller should
/// bail immediately.
pub fn is_transient_open_error(err: &anyhow::Error) -> bool {
    // Walk the full error chain. Anyhow contexts wrap io::Error / rusqlite
    // errors, and r2d2::Error wraps rusqlite::Error inside its own type —
    // both should be reachable via `source()` (which `anyhow::Chain` walks
    // for us) so a single chain walk handles every wrapping layer.
    for cause in err.chain() {
        if let Some(io_err) = cause.downcast_ref::<std::io::Error>() {
            if matches!(io_err.kind(), std::io::ErrorKind::NotFound) {
                return true;
            }
            // Other io kinds (PermissionDenied, etc.) are terminal.
            return false;
        }
        if let Some(rs_err) = cause.downcast_ref::<rusqlite::Error>() {
            if let rusqlite::Error::SqliteFailure(ffi, _) = rs_err {
                use rusqlite::ErrorCode::*;
                // rusqlite collapses extended codes to a primary-code enum:
                // SQLITE_IOERR family -> SystemIoFailure, SQLITE_CANTOPEN ->
                // CannotOpen, SQLITE_PROTOCOL -> FileLockingProtocolFailed.
                match ffi.code {
                    DatabaseBusy
                    | DatabaseLocked
                    | SystemIoFailure
                    | CannotOpen
                    | FileLockingProtocolFailed => return true,
                    NotADatabase => return false,  // real corruption
                    _ => {}
                }
            }
        }
        // r2d2::Error wraps the inner rusqlite::Error and exposes it via
        // `source()`, which the anyhow chain walks automatically. Nothing
        // extra needed here — covered by the next iteration of the loop.
    }
    // Unknown — treat as terminal so we surface the error fast rather
    // than spin in a retry loop.
    false
}

pub fn open_read_only_pool(path: &Path) -> Result<SqlitePool> {
    // Three distinct error paths so callers (and humans reading logs) can
    // tell why the open failed:
    //   1. file missing  — Swift app hasn't started yet
    //   2. file unreadable — wrong permissions / sandbox / FS error
    //   3. file present but SQLite refuses to open it — corruption,
    //      schema, or a transient lock
    match std::fs::metadata(path) {
        Err(io_err) if io_err.kind() == std::io::ErrorKind::NotFound => {
            // Preserve the io::Error in the anyhow chain so
            // `is_transient_open_error` can classify NotFound -> retry.
            return Err(anyhow::Error::from(io_err).context(format!(
                "database not found at {} — start the Swift app at least once to create it",
                path.display()
            )));
        }
        Err(io_err) => {
            return Err(anyhow::Error::from(io_err).context(format!(
                "database at {} is not readable",
                path.display()
            )));
        }
        Ok(_) => {}
    }
    let manager = SqliteConnectionManager::file(path).with_flags(
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    );
    let pool = Pool::builder()
        .max_size(8)
        .build(manager)
        .with_context(|| format!("database at {} could not be opened", path.display()))?;
    // Sanity check: open once.
    let conn = pool
        .get()
        .with_context(|| format!("database at {} could not be opened", path.display()))?;
    conn.query_row("SELECT 1", [], |_| Ok(()))
        .with_context(|| format!("database at {} could not be opened", path.display()))?;
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

#[cfg(test)]
mod tests {
    use super::is_transient_open_error;
    #[allow(unused_imports)]
    use anyhow::Context as _;

    fn rusqlite_err_with_code(code: rusqlite::ErrorCode) -> rusqlite::Error {
        // Synthesize a `SqliteFailure` with the given primary code. The
        // extended_code value is irrelevant for `is_transient_open_error`
        // since rusqlite collapses to the primary `ErrorCode` enum.
        let ffi = rusqlite::ffi::Error {
            code,
            extended_code: 0,
        };
        rusqlite::Error::SqliteFailure(ffi, None)
    }

    #[test]
    fn io_not_found_is_transient() {
        let io = std::io::Error::from(std::io::ErrorKind::NotFound);
        let err: anyhow::Error = anyhow::Error::from(io);
        assert!(is_transient_open_error(&err));
    }

    #[test]
    fn io_permission_denied_is_terminal() {
        let io = std::io::Error::from(std::io::ErrorKind::PermissionDenied);
        let err: anyhow::Error = anyhow::Error::from(io);
        assert!(!is_transient_open_error(&err));
    }

    #[test]
    fn sqlite_busy_is_transient() {
        let rs = rusqlite_err_with_code(rusqlite::ErrorCode::DatabaseBusy);
        let err: anyhow::Error = anyhow::Error::from(rs);
        assert!(is_transient_open_error(&err));
    }

    #[test]
    fn sqlite_locked_is_transient() {
        let rs = rusqlite_err_with_code(rusqlite::ErrorCode::DatabaseLocked);
        let err: anyhow::Error = anyhow::Error::from(rs);
        assert!(is_transient_open_error(&err));
    }

    #[test]
    fn sqlite_ioerr_is_transient() {
        let rs = rusqlite_err_with_code(rusqlite::ErrorCode::SystemIoFailure);
        let err: anyhow::Error = anyhow::Error::from(rs);
        assert!(is_transient_open_error(&err));
    }

    #[test]
    fn sqlite_cantopen_is_transient() {
        let rs = rusqlite_err_with_code(rusqlite::ErrorCode::CannotOpen);
        let err: anyhow::Error = anyhow::Error::from(rs);
        assert!(is_transient_open_error(&err));
    }

    #[test]
    fn sqlite_protocol_is_transient() {
        let rs = rusqlite_err_with_code(rusqlite::ErrorCode::FileLockingProtocolFailed);
        let err: anyhow::Error = anyhow::Error::from(rs);
        assert!(is_transient_open_error(&err));
    }

    #[test]
    fn sqlite_notadb_is_terminal() {
        let rs = rusqlite_err_with_code(rusqlite::ErrorCode::NotADatabase);
        let err: anyhow::Error = anyhow::Error::from(rs);
        assert!(!is_transient_open_error(&err));
    }

    #[test]
    fn nested_under_anyhow_context_still_classifies() {
        let io = std::io::Error::from(std::io::ErrorKind::NotFound);
        let err: anyhow::Error = anyhow::Error::from(io)
            .context("opening sqlite read pool")
            .context("starting daemon");
        assert!(is_transient_open_error(&err));

        let rs = rusqlite_err_with_code(rusqlite::ErrorCode::DatabaseBusy);
        let err: anyhow::Error = anyhow::Error::from(rs)
            .context("opening connection")
            .context("startup");
        assert!(is_transient_open_error(&err));
    }
}
