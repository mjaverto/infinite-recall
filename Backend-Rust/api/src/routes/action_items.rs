//! /v1/action-items — read + write surface backed by the `action_items` table.
//!
//! Reads use `state.pool` (the strictly read-only pool); mutations use
//! `state.write_pool`. The Swift app is the other writer — both rely on
//! WAL journaling for cross-process safety. See `crate::db`.
//!
//! Soft-delete semantics: rows are never removed; `deleted=1` hides them
//! from list/show/lookup. PATCH and complete refuse to touch a soft-deleted
//! row (404).

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    Json,
};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::db::{with_conn, PooledConn};
use crate::error::{ApiError, ApiResult};
use crate::state::AppState;

#[derive(Debug, Deserialize, Default)]
pub struct ListQuery {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
    pub completed: Option<bool>,
}

#[derive(Debug, Serialize)]
pub struct ActionItem {
    pub id: i64,
    pub backend_id: Option<String>,
    pub description: String,
    pub completed: bool,
    pub source: Option<String>,
    pub conversation_id: Option<String>,
    pub priority: Option<String>,
    pub category: Option<String>,
    pub due_at: Option<String>,
    pub source_app: Option<String>,
    pub created_at: Option<String>,
    pub updated_at: Option<String>,
}

const SELECT_COLS: &str = "id, backendId, description, completed, source, conversationId, \
                           priority, category, dueAt, sourceApp, createdAt, updatedAt";

fn map_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<ActionItem> {
    Ok(ActionItem {
        id: r.get(0)?,
        backend_id: r.get(1)?,
        description: r.get(2)?,
        completed: r.get::<_, i64>(3)? != 0,
        source: r.get(4)?,
        conversation_id: r.get(5)?,
        priority: r.get(6)?,
        category: r.get(7)?,
        due_at: r.get(8)?,
        source_app: r.get(9)?,
        created_at: r.get(10)?,
        updated_at: r.get(11)?,
    })
}

/// Fetch one non-deleted action item by id. `Ok(None)` when missing or
/// soft-deleted — callers translate to 404.
fn fetch_one_active(conn: &PooledConn, id: i64) -> rusqlite::Result<Option<ActionItem>> {
    let sql = format!(
        "SELECT {SELECT_COLS} FROM action_items WHERE id = ? AND deleted = 0"
    );
    match conn.query_row(&sql, [id], map_row) {
        Ok(it) => Ok(Some(it)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(e),
    }
}

pub async fn list(
    State(state): State<AppState>,
    Query(q): Query<ListQuery>,
) -> ApiResult<Json<Value>> {
    let limit = q.limit.unwrap_or(50).clamp(1, 500);
    let offset = q.offset.unwrap_or(0).max(0);

    let rows = with_conn(&state.pool, move |c| {
        let mut sql = format!("SELECT {SELECT_COLS} FROM action_items WHERE deleted = 0");
        let mut params: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();
        if let Some(comp) = q.completed {
            sql.push_str(" AND completed = ?");
            params.push(Box::new(if comp { 1i64 } else { 0i64 }));
        }
        sql.push_str(" ORDER BY createdAt DESC LIMIT ? OFFSET ?");
        params.push(Box::new(limit));
        params.push(Box::new(offset));

        let mut stmt = c.prepare(&sql)?;
        let param_refs: Vec<&dyn rusqlite::ToSql> = params
            .iter()
            .map(|p| p.as_ref() as &dyn rusqlite::ToSql)
            .collect();
        let rows = stmt
            .query_map(rusqlite::params_from_iter(param_refs), map_row)?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(rows)
    })
    .await
    .map_err(ApiError::Internal)?;

    Ok(Json(json!({
        "action_items": rows,
        "limit": limit,
        "offset": offset,
    })))
}

// ---------------------------------------------------------------------------
// Mutations
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct CreateBody {
    pub description: String,
    pub due_at: Option<String>,
    pub priority: Option<String>,
    pub conversation_id: Option<String>,
    pub source_app: Option<String>,
}

/// `POST /v1/action-items`
///
/// Inserts a new row. Defaults: `completed=0`, `deleted=0`,
/// `backendSynced=0`, `source="cli"` (so we can tell CLI-originated
/// items apart from screenshot/conversation-derived ones in the DB).
/// Returns the freshly inserted row with HTTP 201.
pub async fn create(
    State(state): State<AppState>,
    Json(body): Json<CreateBody>,
) -> ApiResult<(StatusCode, Json<Value>)> {
    let description = body.description.trim().to_string();
    if description.is_empty() {
        return Err(ApiError::BadRequest(
            "description must be non-empty".into(),
        ));
    }

    let now = Utc::now().to_rfc3339();
    let item = with_conn(&state.write_pool, move |c| {
        c.execute(
            "INSERT INTO action_items (
                description, completed, deleted, backendSynced, source,
                conversationId, priority, dueAt, sourceApp, createdAt, updatedAt
             ) VALUES (?, 0, 0, 0, 'cli', ?, ?, ?, ?, ?, ?)",
            rusqlite::params![
                description,
                body.conversation_id,
                body.priority,
                body.due_at,
                body.source_app,
                now,
                now,
            ],
        )?;
        let id = c.last_insert_rowid();
        let item = fetch_one_active(c, id)?
            .ok_or_else(|| anyhow::anyhow!("inserted row id={id} immediately missing"))?;
        Ok(item)
    })
    .await
    .map_err(ApiError::Internal)?;

    Ok((StatusCode::CREATED, Json(json!({ "action_item": item }))))
}

#[derive(Debug, Deserialize, Default)]
pub struct UpdateBody {
    pub description: Option<String>,
    pub due_at: Option<String>,
    pub priority: Option<String>,
    pub conversation_id: Option<String>,
    pub source_app: Option<String>,
    pub category: Option<String>,
}

/// `PATCH /v1/action-items/:id`
///
/// Partial update — only fields present in the body are touched. An
/// empty body still bumps `updatedAt` and confirms the row exists. 404
/// when the row is missing or already soft-deleted.
pub async fn update(
    State(state): State<AppState>,
    Path(id): Path<i64>,
    Json(body): Json<UpdateBody>,
) -> ApiResult<Json<Value>> {
    if let Some(d) = &body.description {
        if d.trim().is_empty() {
            return Err(ApiError::BadRequest(
                "description, if provided, must be non-empty".into(),
            ));
        }
    }

    let now = Utc::now().to_rfc3339();
    let item = with_conn(&state.write_pool, move |c| {
        // Build SET list dynamically over the provided fields.
        let mut sets: Vec<&'static str> = Vec::new();
        let mut params: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();
        if let Some(v) = body.description {
            sets.push("description = ?");
            params.push(Box::new(v));
        }
        if let Some(v) = body.due_at {
            sets.push("dueAt = ?");
            params.push(Box::new(v));
        }
        if let Some(v) = body.priority {
            sets.push("priority = ?");
            params.push(Box::new(v));
        }
        if let Some(v) = body.conversation_id {
            sets.push("conversationId = ?");
            params.push(Box::new(v));
        }
        if let Some(v) = body.source_app {
            sets.push("sourceApp = ?");
            params.push(Box::new(v));
        }
        if let Some(v) = body.category {
            sets.push("category = ?");
            params.push(Box::new(v));
        }
        sets.push("updatedAt = ?");
        params.push(Box::new(now));
        params.push(Box::new(id));

        let sql = format!(
            "UPDATE action_items SET {} WHERE id = ? AND deleted = 0",
            sets.join(", ")
        );
        let param_refs: Vec<&dyn rusqlite::ToSql> = params
            .iter()
            .map(|p| p.as_ref() as &dyn rusqlite::ToSql)
            .collect();
        let affected = c.execute(&sql, rusqlite::params_from_iter(param_refs))?;
        if affected == 0 {
            return Ok(None);
        }
        Ok(fetch_one_active(c, id)?)
    })
    .await
    .map_err(ApiError::Internal)?;

    match item {
        Some(it) => Ok(Json(json!({ "action_item": it }))),
        None => Err(ApiError::NotFound),
    }
}

#[derive(Debug, Deserialize)]
pub struct CompleteBody {
    pub completed: bool,
}

/// `POST /v1/action-items/:id/complete`
///
/// Sets `completed` to the value in the body and bumps `updatedAt`.
/// Body is mandatory so callers can't accidentally leave the bit
/// ambiguous. 404 when the row is missing or already soft-deleted.
pub async fn complete(
    State(state): State<AppState>,
    Path(id): Path<i64>,
    Json(body): Json<CompleteBody>,
) -> ApiResult<Json<Value>> {
    let now = Utc::now().to_rfc3339();
    let completed = if body.completed { 1i64 } else { 0i64 };

    let item = with_conn(&state.write_pool, move |c| {
        let affected = c.execute(
            "UPDATE action_items
             SET completed = ?, updatedAt = ?
             WHERE id = ? AND deleted = 0",
            rusqlite::params![completed, now, id],
        )?;
        if affected == 0 {
            return Ok(None);
        }
        Ok(fetch_one_active(c, id)?)
    })
    .await
    .map_err(ApiError::Internal)?;

    match item {
        Some(it) => Ok(Json(json!({ "action_item": it }))),
        None => Err(ApiError::NotFound),
    }
}

/// `DELETE /v1/action-items/:id`
///
/// Soft delete: flips `deleted=1`, bumps `updatedAt`. The Swift schema
/// also has a `deletedBy` column which we leave NULL — only the
/// user-driven Swift path tracks who deleted what. 404 when the row is
/// already deleted or never existed.
///
/// Returns the row as it looked *before* deletion, so callers have
/// something to undo with.
pub async fn delete(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> ApiResult<Json<Value>> {
    let now = Utc::now().to_rfc3339();

    let item = with_conn(&state.write_pool, move |c| {
        // Snapshot before delete so the response includes the prior state.
        let snapshot = fetch_one_active(c, id)?;
        if snapshot.is_none() {
            return Ok(None);
        }
        let affected = c.execute(
            "UPDATE action_items
             SET deleted = 1, updatedAt = ?
             WHERE id = ? AND deleted = 0",
            rusqlite::params![now, id],
        )?;
        if affected == 0 {
            // Lost a race with another deleter — treat as already-gone.
            return Ok(None);
        }
        Ok(snapshot)
    })
    .await
    .map_err(ApiError::Internal)?;

    match item {
        Some(it) => Ok(Json(json!({ "action_item": it }))),
        None => Err(ApiError::NotFound),
    }
}
