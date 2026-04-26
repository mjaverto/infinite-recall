//! /v1/scores — daily activity rollup.
//!
//! There is no dedicated `daily_scores` table in the local DB. Omi's hosted
//! backend computes a productivity / focus score; here we synthesize a basic
//! activity rollup from primary tables. Useful enough for an MCP "what did I
//! do today" answer; more sophisticated scoring is left to the LLM client.

use axum::{
    extract::{Query, State},
    Json,
};
use chrono::{NaiveDate, Utc};
use serde::Deserialize;
use serde_json::{json, Value};

use crate::db::with_conn;
use crate::error::{ApiError, ApiResult};
use crate::state::AppState;

#[derive(Debug, Deserialize)]
pub struct ScoresQuery {
    /// `YYYY-MM-DD`. Defaults to today (UTC).
    pub date: Option<String>,
}

pub async fn scores(
    State(state): State<AppState>,
    Query(q): Query<ScoresQuery>,
) -> ApiResult<Json<Value>> {
    let date_str = q.date.unwrap_or_else(|| Utc::now().format("%Y-%m-%d").to_string());
    let _parsed = NaiveDate::parse_from_str(&date_str, "%Y-%m-%d")
        .map_err(|_| ApiError::BadRequest("date must be YYYY-MM-DD".into()))?;

    let day_start = format!("{date_str}T00:00:00");
    let day_end = format!("{date_str}T23:59:59.999");

    let body = with_conn(&state.pool, move |c| {
        // Each table may not exist yet on a fresh install (migrations run in
        // the Swift app, not here). Wrap each count in a missing-table guard
        // so /v1/scores degrades gracefully — same posture as /v1/health.
        let table_exists = |c: &rusqlite::Connection, name: &str| -> rusqlite::Result<bool> {
            let n: i64 = c.query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name = ?",
                rusqlite::params![name],
                |r| r.get(0),
            )?;
            Ok(n > 0)
        };
        let count_in_window = |c: &rusqlite::Connection, sql: &str| -> rusqlite::Result<i64> {
            c.query_row(sql, rusqlite::params![day_start, day_end], |r| r.get(0))
        };

        let screenshots: i64 = if table_exists(c, "screenshots")? {
            count_in_window(c, "SELECT COUNT(*) FROM screenshots WHERE timestamp >= ? AND timestamp <= ?")?
        } else { 0 };
        let conversations: i64 = if table_exists(c, "transcription_sessions")? {
            count_in_window(
                c,
                "SELECT COUNT(*) FROM transcription_sessions WHERE startedAt >= ? AND startedAt <= ?",
            )?
        } else { 0 };
        let memories: i64 = if table_exists(c, "memories")? {
            count_in_window(
                c,
                "SELECT COUNT(*) FROM memories WHERE deleted = 0 AND createdAt >= ? AND createdAt <= ?",
            )?
        } else { 0 };
        let (action_items, action_items_completed): (i64, i64) = if table_exists(c, "action_items")? {
            let total = count_in_window(
                c,
                "SELECT COUNT(*) FROM action_items WHERE deleted = 0 AND createdAt >= ? AND createdAt <= ?",
            )?;
            let done: i64 = c.query_row(
                "SELECT COUNT(*) FROM action_items
                 WHERE deleted = 0 AND completed = 1 AND updatedAt >= ? AND updatedAt <= ?",
                rusqlite::params![day_start, day_end],
                |r| r.get(0),
            )?;
            (total, done)
        } else { (0, 0) };

        Ok::<_, anyhow::Error>(json!({
            "date": date_str,
            "counts": {
                "screenshots": screenshots,
                "conversations": conversations,
                "memories": memories,
                "action_items": action_items,
                "action_items_completed": action_items_completed,
            },
        }))
    })
    .await
    .map_err(ApiError::Internal)?;

    Ok(Json(body))
}
