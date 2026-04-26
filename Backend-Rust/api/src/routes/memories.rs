//! /v3/memories — backed by `memories` table.

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
    pub category: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Memory {
    pub id: i64,
    pub backend_id: Option<String>,
    pub content: String,
    pub category: String,
    pub tags: Option<String>,
    pub source: Option<String>,
    pub source_app: Option<String>,
    pub conversation_id: Option<String>,
    pub confidence: Option<f64>,
    pub reviewed: bool,
    pub manually_added: bool,
    pub created_at: Option<String>,
    pub updated_at: Option<String>,
}

const SELECT: &str = "SELECT id, backendId, content, category, tagsJson,
        source, sourceApp, conversationId, confidence, reviewed, manuallyAdded,
        createdAt, updatedAt
     FROM memories WHERE deleted = 0";

fn map_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Memory> {
    Ok(Memory {
        id: r.get(0)?,
        backend_id: r.get(1)?,
        content: r.get(2)?,
        category: r.get(3)?,
        tags: r.get(4)?,
        source: r.get(5)?,
        source_app: r.get(6)?,
        conversation_id: r.get(7)?,
        confidence: r.get(8)?,
        reviewed: r.get::<_, i64>(9)? != 0,
        manually_added: r.get::<_, i64>(10)? != 0,
        created_at: r.get(11)?,
        updated_at: r.get(12)?,
    })
}

pub async fn list(
    State(state): State<AppState>,
    Query(q): Query<ListQuery>,
) -> ApiResult<Json<Value>> {
    let limit = q.limit.unwrap_or(50).clamp(1, 500);
    let offset = q.offset.unwrap_or(0).max(0);

    let rows = with_conn(&state.pool, move |c| {
        let mut sql = SELECT.to_string();
        let mut params: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();
        if let Some(cat) = q.category.clone() {
            sql.push_str(" AND category = ?");
            params.push(Box::new(cat));
        }
        sql.push_str(" ORDER BY createdAt DESC LIMIT ? OFFSET ?");
        params.push(Box::new(limit));
        params.push(Box::new(offset));

        let mut stmt = c.prepare(&sql)?;
        let param_refs: Vec<&dyn rusqlite::ToSql> =
            params.iter().map(|p| p.as_ref() as &dyn rusqlite::ToSql).collect();
        let mut rows = stmt.query(rusqlite::params_from_iter(param_refs))?;
        let mut out = Vec::new();
        while let Some(r) = rows.next()? {
            out.push(map_row(r)?);
        }
        Ok(out)
    })
    .await
    .map_err(ApiError::Internal)?;

    Ok(Json(json!({
        "memories": rows,
        "limit": limit,
        "offset": offset,
    })))
}

pub async fn get_one(
    State(state): State<AppState>,
    Path(id): Path<i64>,
) -> ApiResult<Json<Memory>> {
    let mem = with_conn(&state.pool, move |c| {
        let sql = format!("{SELECT} AND id = ?");
        let mem = c.query_row(&sql, [id], map_row)?;
        Ok(mem)
    })
    .await;

    match mem {
        Ok(m) => Ok(Json(m)),
        Err(e) if format!("{e:#}").contains("Query returned no rows") => Err(ApiError::NotFound),
        Err(e) => Err(ApiError::Internal(e)),
    }
}
