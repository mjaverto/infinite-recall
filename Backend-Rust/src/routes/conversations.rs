//! /v1/conversations — backed by `transcription_sessions` + `transcription_segments`.
//!
//! Omi's "conversation" object roughly maps to one transcription session.
//! Segments (with speaker, start_time, end_time, text) become `transcript_segments`.

use axum::{
    extract::{Path, Query, State},
    Json,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::db::with_conn;
use crate::error::{ApiError, ApiResult};
use crate::state::AppState;

#[derive(Debug, Deserialize, Default)]
pub struct ListQuery {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
    /// ISO8601 inclusive lower bound on `startedAt`.
    pub start_date: Option<String>,
    /// ISO8601 exclusive upper bound on `startedAt`.
    pub end_date: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Conversation {
    pub id: i64,
    pub started_at: Option<String>,
    pub finished_at: Option<String>,
    pub source: String,
    pub language: String,
    pub timezone: String,
    pub status: String,
    pub created_at: Option<String>,
    pub updated_at: Option<String>,
}

pub async fn list(
    State(state): State<AppState>,
    Query(q): Query<ListQuery>,
) -> ApiResult<Json<Value>> {
    let limit = q.limit.unwrap_or(50).clamp(1, 500);
    let offset = q.offset.unwrap_or(0).max(0);

    let rows = with_conn(&state.pool, move |c| {
        let mut sql = String::from(
            "SELECT id, startedAt, finishedAt, source, language, timezone, status,
                    createdAt, updatedAt
             FROM transcription_sessions",
        );
        let mut clauses = Vec::<&'static str>::new();
        let mut params: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();
        if q.start_date.is_some() {
            clauses.push("startedAt >= ?");
            params.push(Box::new(q.start_date.clone().unwrap()));
        }
        if q.end_date.is_some() {
            clauses.push("startedAt < ?");
            params.push(Box::new(q.end_date.clone().unwrap()));
        }
        if !clauses.is_empty() {
            sql.push_str(" WHERE ");
            sql.push_str(&clauses.join(" AND "));
        }
        sql.push_str(" ORDER BY startedAt DESC LIMIT ? OFFSET ?");
        params.push(Box::new(limit));
        params.push(Box::new(offset));

        let mut stmt = c.prepare(&sql)?;
        let param_refs: Vec<&dyn rusqlite::ToSql> =
            params.iter().map(|p| p.as_ref() as &dyn rusqlite::ToSql).collect();
        let mut rows = stmt.query(rusqlite::params_from_iter(param_refs))?;
        let mut out = Vec::new();
        while let Some(r) = rows.next()? {
            out.push(Conversation {
                id: r.get(0)?,
                started_at: r.get(1)?,
                finished_at: r.get(2)?,
                source: r.get(3)?,
                language: r.get(4)?,
                timezone: r.get(5)?,
                status: r.get(6)?,
                created_at: r.get(7)?,
                updated_at: r.get(8)?,
            });
        }
        Ok(out)
    })
    .await
    .map_err(ApiError::Internal)?;

    Ok(Json(json!({
        "conversations": rows,
        "limit": limit,
        "offset": offset,
    })))
}

pub async fn get_one(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> ApiResult<Json<Value>> {
    let conv = with_conn(&state.pool, move |c| {
        let conv = c.query_row(
            "SELECT id, startedAt, finishedAt, source, language, timezone, status,
                    createdAt, updatedAt
             FROM transcription_sessions WHERE id = ?",
            [id],
            |r| {
                Ok(Conversation {
                    id: r.get(0)?,
                    started_at: r.get(1)?,
                    finished_at: r.get(2)?,
                    source: r.get(3)?,
                    language: r.get(4)?,
                    timezone: r.get(5)?,
                    status: r.get(6)?,
                    created_at: r.get(7)?,
                    updated_at: r.get(8)?,
                })
            },
        )?;

        let mut stmt = c.prepare(
            "SELECT speaker, text, startTime, endTime, segmentOrder
             FROM transcription_segments
             WHERE sessionId = ?
             ORDER BY segmentOrder ASC",
        )?;
        let mut rows = stmt.query([id])?;
        let mut segments = Vec::new();
        while let Some(r) = rows.next()? {
            let speaker: i64 = r.get(0)?;
            let text: String = r.get(1)?;
            let start: f64 = r.get(2)?;
            let end: f64 = r.get(3)?;
            let order: i64 = r.get(4)?;
            segments.push(json!({
                "speaker_id": speaker,
                "text": text,
                "start": start,
                "end": end,
                "order": order,
            }));
        }
        Ok::<_, anyhow::Error>(json!({
            "conversation": conv,
            "transcript_segments": segments,
        }))
    })
    .await;

    match conv {
        Ok(v) => Ok(Json(v)),
        Err(e) => {
            // distinguish not found from internal
            let s = format!("{e:#}");
            if s.contains("Query returned no rows") {
                Err(ApiError::NotFound)
            } else {
                Err(ApiError::Internal(e))
            }
        }
    }
}
