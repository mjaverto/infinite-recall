use std::sync::Mutex;
use std::time::{Duration, Instant};

use axum::{extract::State, Json};
use serde_json::{json, Value};

use crate::db::with_conn;
use crate::error::ApiResult;
use crate::state::AppState;

// ---------------------------------------------------------------------------
// Pending-work cache (5-second TTL, per design doc §6.3)
// ---------------------------------------------------------------------------

struct PendingWorkCache {
    value: Value,
    fetched_at: Instant,
}

fn pending_work_cache() -> &'static Mutex<Option<PendingWorkCache>> {
    use std::sync::OnceLock;
    static CACHE: OnceLock<Mutex<Option<PendingWorkCache>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(None))
}

async fn get_pending_work(pool: &crate::db::SqlitePool) -> Value {
    const TTL: Duration = Duration::from_secs(5);

    // Check cache first (non-async lock, held briefly).
    {
        let guard = pending_work_cache().lock().unwrap_or_else(|e| e.into_inner());
        if let Some(ref cached) = *guard {
            if cached.fetched_at.elapsed() < TTL {
                return cached.value.clone();
            }
        }
    }

    // Fetch from DB on a blocking thread.
    let result = with_conn(pool, |c| {
        // The `pending_work` table is created by the Swift app's GRDB
        // migration (commit c0d94a2). The Rust API opens the DB read-only,
        // so until the app has launched once with the new code, the table
        // doesn't exist. Detect that case explicitly and return zeros with
        // `"migrated": false` so the health endpoint stays useful — bubbling
        // up "no such table" as "query failed" hides the real status.
        let table_exists: bool = c
            .query_row(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='pending_work'",
                [],
                |_| Ok(true),
            )
            .unwrap_or(false);
        if !table_exists {
            return Ok(json!({
                "queued":  0,
                "claimed": 0,
                "failed":  0,
                "dead":    0,
                "oldest_queued_seconds": null,
                "migrated": false,
            }));
        }

        // Status counts.
        let mut queued: i64 = 0;
        let mut claimed: i64 = 0;
        let mut failed: i64 = 0;
        let mut dead: i64 = 0;

        let mut stmt = c.prepare(
            "SELECT status, COUNT(*) AS cnt FROM pending_work GROUP BY status",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })?;
        for r in rows.flatten() {
            match r.0.as_str() {
                "queued"  => queued  = r.1,
                "claimed" => claimed = r.1,
                "failed"  => failed  = r.1,
                "dead"    => dead    = r.1,
                _ => {}
            }
        }

        // Oldest queued row — scheduledFor as text; compute age via chrono.
        let oldest_sec: Option<f64> = {
            let ts: Option<String> = c
                .query_row(
                    "SELECT MIN(scheduledFor) FROM pending_work WHERE status = 'queued'",
                    [],
                    |row| row.get(0),
                )
                .ok()
                .flatten();
            ts.and_then(|s| {
                // GRDB stores datetimes as "YYYY-MM-DD HH:MM:SS.SSS" (UTC).
                // Try RFC 3339 first, then the GRDB format.
                let dt = chrono::DateTime::parse_from_rfc3339(&s)
                    .map(|d| d.with_timezone(&chrono::Utc))
                    .or_else(|_| {
                        chrono::NaiveDateTime::parse_from_str(&s, "%Y-%m-%d %H:%M:%S%.f")
                            .map(|n| n.and_utc())
                    })
                    .or_else(|_| {
                        chrono::NaiveDateTime::parse_from_str(&s, "%Y-%m-%d %H:%M:%S")
                            .map(|n| n.and_utc())
                    });
                dt.ok().map(|d| {
                    let age = chrono::Utc::now().signed_duration_since(d);
                    age.num_milliseconds() as f64 / 1000.0
                })
            })
        };

        Ok(json!({
            "queued":  queued,
            "claimed": claimed,
            "failed":  failed,
            "dead":    dead,
            "oldest_queued_seconds": oldest_sec,
            "migrated": true,
        }))
    })
    .await;

    let value = result.unwrap_or_else(|_| json!({
        "queued": null,
        "claimed": null,
        "failed": null,
        "dead": null,
        "oldest_queued_seconds": null,
        "error": "query failed",
    }));

    // Update cache.
    {
        let mut guard = pending_work_cache().lock().unwrap_or_else(|e| e.into_inner());
        *guard = Some(PendingWorkCache {
            value: value.clone(),
            fetched_at: Instant::now(),
        });
    }

    value
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

pub async fn health(State(state): State<AppState>) -> ApiResult<Json<Value>> {
    // Cheap readability check.
    let ok = with_conn(&state.pool, |c| {
        c.query_row("SELECT 1", [], |_| Ok(()))?;
        Ok(true)
    })
    .await
    .unwrap_or(false);

    let pending_work = get_pending_work(&state.pool).await;

    Ok(Json(json!({
        "status": if ok { "ok" } else { "degraded" },
        "db_readable": ok,
        "pending_work": pending_work,
    })))
}

pub async fn version() -> Json<Value> {
    Json(json!({
        "name": env!("CARGO_PKG_NAME"),
        "version": env!("CARGO_PKG_VERSION"),
        "api_shape": "omi-local-v1",
    }))
}
