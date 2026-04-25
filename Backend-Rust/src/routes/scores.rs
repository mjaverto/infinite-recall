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
        let count = |sql: &str| -> rusqlite::Result<i64> {
            c.query_row(sql, rusqlite::params![day_start, day_end], |r| r.get(0))
        };

        let screenshots: i64 = count(
            "SELECT COUNT(*) FROM screenshots WHERE timestamp >= ? AND timestamp <= ?",
        )?;
        let conversations: i64 = count(
            "SELECT COUNT(*) FROM transcription_sessions
             WHERE startedAt >= ? AND startedAt <= ?",
        )?;
        let memories: i64 = count(
            "SELECT COUNT(*) FROM memories
             WHERE deleted = 0 AND createdAt >= ? AND createdAt <= ?",
        )?;
        let action_items: i64 = count(
            "SELECT COUNT(*) FROM action_items
             WHERE deleted = 0 AND createdAt >= ? AND createdAt <= ?",
        )?;
        let action_items_completed: i64 = c.query_row(
            "SELECT COUNT(*) FROM action_items
             WHERE deleted = 0 AND completed = 1 AND updatedAt >= ? AND updatedAt <= ?",
            rusqlite::params![day_start, day_end],
            |r| r.get(0),
        )?;

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
