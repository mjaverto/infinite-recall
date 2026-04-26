//! Trivial bearer-token auth for the local API.
//!
//! Token storage and on-disk path resolution live in [`crate::token`] —
//! that module is shared with the `recall` CLI. This file owns the
//! HTTP middleware that enforces `Authorization: Bearer <token>`.

use axum::{
    extract::{Request, State},
    http::{header, StatusCode},
    middleware::Next,
    response::Response,
};

use crate::state::AppState;

// Re-exports kept for backwards-compatibility with any in-tree callers.
// The shared token module (`crate::token`) is the canonical home.
pub use crate::token::{ensure_token, load_token, token_path};

/// Axum middleware: require `Authorization: Bearer <token>` matching state.
/// Health and version routes mount this middleware; we exempt them at the
/// router level instead of here, to keep this layer dumb.
pub async fn require_bearer(
    State(state): State<AppState>,
    req: Request,
    next: Next,
) -> Result<Response, StatusCode> {
    let header_val = req
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok());

    let supplied = match header_val {
        Some(s) if s.starts_with("Bearer ") => &s[7..],
        _ => return Err(StatusCode::UNAUTHORIZED),
    };

    if constant_time_eq(supplied.as_bytes(), state.token.as_bytes()) {
        Ok(next.run(req).await)
    } else {
        Err(StatusCode::UNAUTHORIZED)
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff: u8 = 0;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}
