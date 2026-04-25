//! /v1/action-items — backed by `action_items` table.

use axum::{
    extract::{Query, State},
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

pub async fn list(
    State(state): State<AppState>,
    Query(q): Query<ListQuery>,
) -> ApiResult<Json<Value>> {
    let limit = q.limit.unwrap_or(50).clamp(1, 500);
    let offset = q.offset.unwrap_or(0).max(0);

    let rows = with_conn(&state.pool, move |c| {
        let mut sql = String::from(
            "SELECT id, backendId, description, completed, source, conversationId,
                    priority, category, dueAt, sourceApp, createdAt, updatedAt
             FROM action_items WHERE deleted = 0",
        );
        let mut params: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();
        if let Some(comp) = q.completed {
            sql.push_str(" AND completed = ?");
            params.push(Box::new(if comp { 1i64 } else { 0i64 }));
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
            out.push(ActionItem {
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
            });
        }
        Ok(out)
    })
    .await
    .map_err(ApiError::Internal)?;

    Ok(Json(json!({
        "action_items": rows,
        "limit": limit,
        "offset": offset,
    })))
}
