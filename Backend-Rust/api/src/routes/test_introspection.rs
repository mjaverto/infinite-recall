//! `/v1/_test/*` ground-truth introspection endpoints.
//!
//! Off-by-default: the parent module declaration gates the entire file
//! behind `#[cfg(feature = "test_introspection")]`, and even when the
//! feature is on each handler additionally checks `IR_TEST_INTROSPECTION=1`
//! at request time. A stray feature-on build with the env var unset
//! returns 404 (looks identical to the feature being off).

use std::collections::HashMap;
use std::os::unix::fs::MetadataExt;

use axum::{
    extract::State,
    http::StatusCode,
    routing::get,
    Json, Router,
};
use rusqlite::OptionalExtension;
use serde_json::{json, Value};

use crate::db::with_conn;
use crate::state::AppState;

const EXPECTED_TABLES: &[&str] = &["conversations", "memories", "transcript_segments"];

fn enabled() -> bool {
    std::env::var("IR_TEST_INTROSPECTION").as_deref() == Ok("1")
}

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/v1/_test/db", get(db))
        .route("/v1/_test/user_dir", get(user_dir))
        .route("/v1/_test/workers", get(workers))
        .route("/v1/_test/build", get(build))
}

fn file_meta(path: &std::path::Path) -> Value {
    let exists = path.exists();
    let (inode, size) = if exists {
        match std::fs::metadata(path) {
            Ok(m) => (Some(m.ino()), Some(m.len())),
            Err(_) => (None, None),
        }
    } else {
        (None, None)
    };
    json!({
        "path": path.display().to_string(),
        "exists": exists,
        "inode": inode,
        "size_bytes": size,
    })
}

async fn db(State(state): State<AppState>) -> Result<Json<Value>, StatusCode> {
    if !enabled() {
        return Err(StatusCode::NOT_FOUND);
    }
    Ok(Json(json!({
        "main": file_meta(state.db_path.as_path()),
        "activity": file_meta(state.activity_db_path.as_path()),
    })))
}

async fn user_dir(State(state): State<AppState>) -> Result<Json<Value>, StatusCode> {
    if !enabled() {
        return Err(StatusCode::NOT_FOUND);
    }

    let user_id =
        std::env::var("INFINITE_RECALL_USER_ID").unwrap_or_else(|_| "anonymous".to_string());
    let base = state
        .db_path
        .parent()
        .map(|p| p.display().to_string())
        .unwrap_or_default();
    let exists = state
        .db_path
        .parent()
        .map(|p| p.exists())
        .unwrap_or(false);

    let pool = state.pool.clone();
    let table_result = with_conn(&pool, |c| {
        let mut stmt = c.prepare("SELECT name FROM sqlite_master WHERE type='table'")?;
        let names: Vec<String> = stmt
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<_, _>>()?;

        let mut counts: HashMap<String, i64> = HashMap::new();
        let mut missing: Vec<String> = Vec::new();
        for &expected in EXPECTED_TABLES {
            if names.iter().any(|n| n == expected) {
                let count: i64 = c
                    .query_row(&format!("SELECT COUNT(*) FROM {expected}"), [], |r| r.get(0))
                    .optional()?
                    .unwrap_or(0);
                counts.insert(expected.to_string(), count);
            } else {
                missing.push(expected.to_string());
            }
        }
        Ok((counts, missing))
    })
    .await;

    let (tables, missing_tables) = match table_result {
        Ok(t) => t,
        Err(_) => (
            HashMap::new(),
            EXPECTED_TABLES.iter().map(|s| s.to_string()).collect(),
        ),
    };

    Ok(Json(json!({
        "user_id": user_id,
        "base": base,
        "exists": exists,
        "tables": tables,
        "missing_tables": missing_tables,
    })))
}

async fn workers(State(state): State<AppState>) -> Result<Json<Value>, StatusCode> {
    if !enabled() {
        return Err(StatusCode::NOT_FOUND);
    }

    let inflight_map = state.inflight.snapshot();
    let inflight: HashMap<String, Value> = inflight_map
        .into_iter()
        .map(|(k, v)| {
            (
                k.as_str().to_string(),
                json!({
                    "label": v.label,
                    "started_at_ms": v.started_at.timestamp_millis(),
                }),
            )
        })
        .collect();

    let queues = read_queue_depths(&state).await;

    Ok(Json(json!({
        "inflight": inflight,
        "queues": queues,
        "recent_errors": state.worker_errors.snapshot(),
    })))
}

async fn read_queue_depths(state: &AppState) -> HashMap<String, Value> {
    let pool = state.pool.clone();
    let res = with_conn(&pool, |c| {
        let table_exists = c
            .query_row(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='pending_work'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .optional()?
            .is_some();
        if !table_exists {
            return Ok(HashMap::<String, (u32, u32)>::new());
        }
        let mut stmt = c.prepare(
            "SELECT status, workType, COUNT(*) AS cnt
             FROM pending_work
             WHERE status IN ('queued', 'failed')
             GROUP BY status, workType",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
            ))
        })?;
        let mut depths: HashMap<String, (u32, u32)> = HashMap::new();
        for row in rows {
            let (status, work_type, count) = row?;
            let count = u32::try_from(count).unwrap_or(u32::MAX);
            let entry = depths.entry(work_type).or_insert((0, 0));
            match status.as_str() {
                "queued" => entry.0 = count,
                "failed" => entry.1 = count,
                _ => {}
            }
        }
        Ok(depths)
    })
    .await;

    match res {
        Ok(depths) => depths
            .into_iter()
            .map(|(k, (queued, failed))| {
                (k, json!({ "queued": queued, "failed": failed }))
            })
            .collect(),
        Err(_) => HashMap::new(),
    }
}

async fn build() -> Result<Json<Value>, StatusCode> {
    if !enabled() {
        return Err(StatusCode::NOT_FOUND);
    }
    let git_sha = option_env!("VERGEN_GIT_SHA")
        .or(option_env!("GIT_SHA"))
        .unwrap_or("unknown");
    Ok(Json(json!({
        "version": env!("CARGO_PKG_VERSION"),
        "git_sha": git_sha,
        "features": ["test_introspection"],
    })))
}
