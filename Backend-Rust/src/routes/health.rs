use axum::{extract::State, Json};
use serde_json::{json, Value};

use crate::db::with_conn;
use crate::error::ApiResult;
use crate::state::AppState;

pub async fn health(State(state): State<AppState>) -> ApiResult<Json<Value>> {
    // Cheap readability check.
    let ok = with_conn(&state.pool, |c| {
        c.query_row("SELECT 1", [], |_| Ok(()))?;
        Ok(true)
    })
    .await
    .unwrap_or(false);
    Ok(Json(json!({
        "status": if ok { "ok" } else { "degraded" },
        "db_readable": ok,
    })))
}

pub async fn version() -> Json<Value> {
    Json(json!({
        "name": env!("CARGO_PKG_NAME"),
        "version": env!("CARGO_PKG_VERSION"),
        "api_shape": "omi-local-v1",
    }))
}
