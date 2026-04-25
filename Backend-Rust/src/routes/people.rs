//! /v1/people — backed by the local `people` table.

use axum::{
    extract::{Path, State},
    Json,
};
use serde::Serialize;
use serde_json::{json, Value};

use crate::db::with_conn;
use crate::error::{ApiError, ApiResult};
use crate::state::AppState;

#[derive(Debug, Serialize)]
pub struct Person {
    pub id: String,
    pub display_name: String,
    pub default_emoji: Option<String>,
    pub created_at: Option<String>,
    pub updated_at: Option<String>,
}

pub async fn list(State(state): State<AppState>) -> ApiResult<Json<Value>> {
    let people = with_conn(&state.pool, |c| {
        let mut stmt = c.prepare(
            "SELECT id, displayName, defaultEmoji, createdAt, updatedAt
             FROM people ORDER BY displayName ASC",
        )?;
        let mut rows = stmt.query([])?;
        let mut out = Vec::new();
        while let Some(r) = rows.next()? {
            out.push(Person {
                id: r.get(0)?,
                display_name: r.get(1)?,
                default_emoji: r.get(2)?,
                created_at: r.get(3)?,
                updated_at: r.get(4)?,
            });
        }
        Ok(out)
    })
    .await
    .map_err(ApiError::Internal)?;

    Ok(Json(json!({ "people": people })))
}

pub async fn get_one(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Json<Person>> {
    let p = with_conn(&state.pool, move |c| {
        let p = c.query_row(
            "SELECT id, displayName, defaultEmoji, createdAt, updatedAt
             FROM people WHERE id = ?",
            [&id],
            |r| {
                Ok(Person {
                    id: r.get(0)?,
                    display_name: r.get(1)?,
                    default_emoji: r.get(2)?,
                    created_at: r.get(3)?,
                    updated_at: r.get(4)?,
                })
            },
        )?;
        Ok(p)
    })
    .await;
    match p {
        Ok(v) => Ok(Json(v)),
        Err(e) if format!("{e:#}").contains("Query returned no rows") => Err(ApiError::NotFound),
        Err(e) => Err(ApiError::Internal(e)),
    }
}
