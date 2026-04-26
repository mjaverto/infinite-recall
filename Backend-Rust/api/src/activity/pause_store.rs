//! Stream B: `SqlPauseStore` — persistent absolute-time pause storage.
//!
//! Implements the [`PauseStore`] trait against a writable SQLite database
//! containing the `paused_work` table (see
//! `Backend-Rust/api/migrations/0001_paused_work.sql`).
//!
//! Schema:
//! ```sql
//! CREATE TABLE paused_work (
//!     target    TEXT NOT NULL,    -- 'kind' | 'capture'
//!     id        TEXT NOT NULL,    -- WorkKind snake_case or 'audio'/'screen'
//!     resume_at INTEGER NOT NULL, -- unix seconds, absolute, UTC
//!     PRIMARY KEY (target, id)
//! );
//! ```
//!
//! This module owns its own writable connection pool because the main
//! `crate::db` pool is opened **read-only** against the GRDB-managed
//! `omi.db`. Activity-tab pause state is daemon-owned and lives in a
//! separate file (`activity.db`) so it never collides with the Swift
//! app's writes.

use std::num::NonZeroU32;
use std::path::Path;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use chrono::{DateTime, TimeZone, Utc};
use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;
use rusqlite::params;

use super::traits::{PauseStore, PauseStoreError};
use super::types::PauseTargetId;

/// Inline migration source. Kept in lockstep with
/// `Backend-Rust/api/migrations/0001_paused_work.sql` so the binary can
/// bootstrap an empty `activity.db` without a separate runner.
const MIGRATION_0001: &str = include_str!("../../migrations/0001_paused_work.sql");

type WritablePool = Pool<SqliteConnectionManager>;

/// SQLite-backed `PauseStore`.
///
/// Cloning is cheap — the inner connection pool is `Arc`-shared.
#[derive(Clone)]
pub struct SqlPauseStore {
    pool: Arc<WritablePool>,
}

impl SqlPauseStore {
    /// Open (or create) the activity SQLite database at `path` and run
    /// the embedded migration. Suitable for production use; the daemon
    /// should pass `~/Library/Application Support/InfiniteRecall/activity.db`.
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("creating parent dir {}", parent.display()))?;
        }
        let manager = SqliteConnectionManager::file(path);
        Self::from_manager(manager)
    }

    /// Open an in-memory database. Intended for tests.
    pub fn open_in_memory() -> Result<Self> {
        // `memory()` gives each connection its own private DB, which is
        // useless for a pool. Use a shared-cache URI so all pooled
        // connections see the same in-memory schema.
        let manager = SqliteConnectionManager::file("file::memory:?cache=shared")
            .with_flags(rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE
                | rusqlite::OpenFlags::SQLITE_OPEN_CREATE
                | rusqlite::OpenFlags::SQLITE_OPEN_URI
                | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX);
        Self::from_manager(manager)
    }

    fn from_manager(manager: SqliteConnectionManager) -> Result<Self> {
        let pool = Pool::builder()
            .max_size(4)
            .build(manager)
            .context("building writable r2d2 pool")?;
        {
            let conn = pool.get().context("checking out initial connection")?;
            // WAL keeps readers + the single writer playing nicely.
            // Errors here are non-fatal: in-memory DBs reject WAL.
            let _ = conn.pragma_update(None, "journal_mode", "WAL");
            conn.execute_batch(MIGRATION_0001)
                .context("running 0001_paused_work migration")?;
        }
        Ok(Self {
            pool: Arc::new(pool),
        })
    }
}

fn now_unix_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn from_unix_secs(secs: i64) -> DateTime<Utc> {
    Utc.timestamp_opt(secs, 0)
        .single()
        .unwrap_or_else(Utc::now)
}

impl PauseStore for SqlPauseStore {
    fn paused_until(&self, target: &PauseTargetId) -> Option<DateTime<Utc>> {
        let conn = self.pool.get().ok()?;
        let (t, id) = target.as_storage_pair();
        let now = now_unix_secs();

        let row: rusqlite::Result<i64> = conn.query_row(
            "SELECT resume_at FROM paused_work WHERE target = ?1 AND id = ?2",
            params![t, id],
            |r| r.get(0),
        );
        match row {
            Ok(resume_at) if resume_at > now => Some(from_unix_secs(resume_at)),
            Ok(_expired) => {
                // Opportunistic GC of expired rows. Failure is non-fatal —
                // the row is already semantically clear.
                let _ = conn.execute(
                    "DELETE FROM paused_work WHERE target = ?1 AND id = ?2 AND resume_at <= ?3",
                    params![t, id, now],
                );
                None
            }
            Err(rusqlite::Error::QueryReturnedNoRows) => None,
            Err(e) => {
                tracing::warn!(error = %e, target = t, id = id, "paused_until query failed");
                None
            }
        }
    }

    fn pause(
        &self,
        target: &PauseTargetId,
        minutes: NonZeroU32,
    ) -> Result<DateTime<Utc>, PauseStoreError> {
        let resume_at_secs = now_unix_secs().saturating_add(i64::from(minutes.get()) * 60);
        let resume_at = from_unix_secs(resume_at_secs);
        let (t, id) = target.as_storage_pair();
        let conn = self.pool.get().map_err(|e| {
            tracing::error!(error = %e, "pause: pool checkout failed");
            PauseStoreError::from(e)
        })?;
        conn.execute(
            "INSERT INTO paused_work (target, id, resume_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(target, id) DO UPDATE SET resume_at = excluded.resume_at",
            params![t, id, resume_at_secs],
        )
        .map_err(|e| {
            tracing::error!(error = %e, target = t, id = id, "pause upsert failed");
            PauseStoreError::from(e)
        })?;
        Ok(resume_at)
    }

    fn resume(&self, target: &PauseTargetId) -> Result<bool, PauseStoreError> {
        let (t, id) = target.as_storage_pair();
        let conn = self.pool.get().map_err(|e| {
            tracing::error!(error = %e, "resume: pool checkout failed");
            PauseStoreError::from(e)
        })?;
        let affected = conn
            .execute(
                "DELETE FROM paused_work WHERE target = ?1 AND id = ?2",
                params![t, id],
            )
            .map_err(|e| {
                tracing::error!(error = %e, target = t, id = id, "resume delete failed");
                PauseStoreError::from(e)
            })?;
        Ok(affected > 0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::activity::types::{CaptureKind, WorkKind};
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::thread;

    fn nz(n: u32) -> NonZeroU32 {
        NonZeroU32::new(n).expect("test minutes must be non-zero")
    }
    const KIND_OCR: PauseTargetId = PauseTargetId::Kind(WorkKind::Ocr);
    const KIND_TRANSCRIBE: PauseTargetId = PauseTargetId::Kind(WorkKind::Transcribe);
    const KIND_SUMMARIZE: PauseTargetId = PauseTargetId::Kind(WorkKind::Summarize);
    const KIND_EXTRACT_MEMORY: PauseTargetId = PauseTargetId::Kind(WorkKind::ExtractMemory);
    const CAPTURE_AUDIO: PauseTargetId = PauseTargetId::Capture(CaptureKind::Audio);
    const CAPTURE_SCREEN: PauseTargetId = PauseTargetId::Capture(CaptureKind::Screen);

    /// Each test gets its own shared-cache in-memory DB by salting the
    /// URI with a unique counter — otherwise tests would alias rows.
    static URI_COUNTER: AtomicU32 = AtomicU32::new(0);

    fn fresh_store() -> SqlPauseStore {
        let n = URI_COUNTER.fetch_add(1, Ordering::SeqCst);
        let uri = format!("file:pause_store_test_{n}?mode=memory&cache=shared");
        let manager = SqliteConnectionManager::file(&uri).with_flags(
            rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE
                | rusqlite::OpenFlags::SQLITE_OPEN_CREATE
                | rusqlite::OpenFlags::SQLITE_OPEN_URI
                | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
        );
        SqlPauseStore::from_manager(manager).expect("open in-memory store")
    }

    #[test]
    fn pause_then_read_back_returns_resume_time() {
        let store = fresh_store();
        let returned = store.pause(&KIND_OCR, nz(15)).expect("pause ok");
        let observed = store
            .paused_until(&KIND_OCR)
            .expect("paused row should be returned");
        // Compare to the second — `pause` and `paused_until` both round to seconds.
        assert_eq!(observed.timestamp(), returned.timestamp());
        // Sanity: ~15 minutes from now (+/- a couple of seconds for clock drift).
        let now = now_unix_secs();
        assert!(observed.timestamp() >= now + 15 * 60 - 2);
        assert!(observed.timestamp() <= now + 15 * 60 + 2);
    }

    #[test]
    fn unpaused_target_returns_none() {
        let store = fresh_store();
        assert!(store.paused_until(&CAPTURE_AUDIO).is_none());
    }

    #[test]
    fn expired_pause_returns_none_and_is_gced() {
        let store = fresh_store();
        // Insert a row with a past resume_at directly, simulating a
        // pause that elapsed while the daemon was down.
        let conn = store.pool.get().unwrap();
        conn.execute(
            "INSERT INTO paused_work (target, id, resume_at) VALUES ('kind', 'transcribe', ?1)",
            params![now_unix_secs() - 10],
        )
        .unwrap();
        drop(conn);

        assert!(store.paused_until(&KIND_TRANSCRIBE).is_none());

        // Opportunistic GC should have removed the row.
        let conn = store.pool.get().unwrap();
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM paused_work WHERE target='kind' AND id='transcribe'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 0, "expired row should have been opportunistically deleted");
    }

    #[test]
    fn pause_then_resume_clears_row() {
        let store = fresh_store();
        store.pause(&KIND_SUMMARIZE, nz(30)).expect("pause ok");
        assert!(store.paused_until(&KIND_SUMMARIZE).is_some());

        let was_paused = store.resume(&KIND_SUMMARIZE).expect("resume ok");
        assert!(was_paused, "resume should report row was deleted");
        assert!(store.paused_until(&KIND_SUMMARIZE).is_none());
    }

    #[test]
    fn pause_overwrite_extends_resume_time() {
        let store = fresh_store();
        let short = store.pause(&CAPTURE_SCREEN, nz(1)).expect("pause ok");
        let longer = store.pause(&CAPTURE_SCREEN, nz(60)).expect("pause ok");
        assert!(longer.timestamp() > short.timestamp());

        let observed = store
            .paused_until(&CAPTURE_SCREEN)
            .expect("row should still exist after overwrite");
        assert_eq!(observed.timestamp(), longer.timestamp());

        // Exactly one row per (target,id) — primary key prevents dupes.
        let conn = store.pool.get().unwrap();
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM paused_work", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn resume_on_unpaused_target_is_noop() {
        let store = fresh_store();
        // Should not panic or error; should report no row was deleted.
        let was_paused = store.resume(&KIND_EXTRACT_MEMORY).expect("resume ok");
        assert!(!was_paused, "resume of un-paused target should report false");
        assert!(store.paused_until(&KIND_EXTRACT_MEMORY).is_none());
    }

    #[test]
    fn kind_and_capture_targets_are_independent() {
        // Issue #34: previously this test paused a `Kind`/`"audio"` combo
        // (which was illegal-but-representable). Post-#34 the type system
        // forbids that, so we exercise independence with two legal
        // targets that share NOTHING in common (Capture::Audio vs the
        // analogous Kind::Ocr — same row count check, different keys).
        store_independence_check(&fresh_store());

        fn store_independence_check(store: &SqlPauseStore) {
            store.pause(&KIND_OCR, nz(10)).expect("pause ok");
            // Same row count check, different target — must be a separate row.
            assert!(store.paused_until(&CAPTURE_AUDIO).is_none());
            assert!(store.paused_until(&KIND_OCR).is_some());
        }
    }

    #[test]
    fn concurrent_reads_are_safe() {
        let store = fresh_store();
        store.pause(&KIND_OCR, nz(5)).expect("pause ok");
        let store_arc = Arc::new(store);

        let handles: Vec<_> = (0..8)
            .map(|_| {
                let s = Arc::clone(&store_arc);
                thread::spawn(move || {
                    for _ in 0..50 {
                        let r = s.paused_until(&KIND_OCR);
                        assert!(r.is_some(), "concurrent reader saw missing row");
                    }
                })
            })
            .collect();
        for h in handles {
            h.join().unwrap();
        }
    }

    #[test]
    fn concurrent_writers_keep_single_row_per_key() {
        let store = Arc::new(fresh_store());
        let handles: Vec<_> = (0..8)
            .map(|i| {
                let s = Arc::clone(&store);
                thread::spawn(move || {
                    for _ in 0..20 {
                        s.pause(&KIND_OCR, nz(i + 1)).expect("pause ok");
                    }
                })
            })
            .collect();
        for h in handles {
            h.join().unwrap();
        }
        let conn = store.pool.get().unwrap();
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM paused_work WHERE target='kind' AND id='ocr'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 1, "primary key should keep exactly one row");
    }
}
