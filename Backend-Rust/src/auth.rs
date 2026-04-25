//! Trivial bearer-token auth for the local API.
//!
//! Token is generated once on first run and written to
//!   ~/Library/Application Support/InfiniteRecall/api-token.txt
//! with mode 0600. The Swift app reads the same file. Loopback only.

use std::fs;
use std::io::Write;
use std::path::PathBuf;

use anyhow::{Context, Result};
use axum::{
    extract::{Request, State},
    http::{header, StatusCode},
    middleware::Next,
    response::Response,
};
use rand::RngCore;

use crate::state::AppState;

pub fn token_path() -> PathBuf {
    if let Ok(v) = std::env::var("INFINITE_RECALL_TOKEN_PATH") {
        return PathBuf::from(v);
    }
    let home = dirs::home_dir().expect("HOME dir resolvable");
    home.join("Library/Application Support/InfiniteRecall/api-token.txt")
}

/// Read existing token or generate a fresh one. The token file is 0600.
pub fn ensure_token() -> Result<String> {
    let path = token_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {parent:?}"))?;
    }

    if path.exists() {
        let s = fs::read_to_string(&path)
            .with_context(|| format!("reading token at {path:?}"))?;
        let trimmed = s.trim().to_string();
        if !trimmed.is_empty() {
            return Ok(trimmed);
        }
    }

    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    let token = hex::encode(bytes);

    write_token_file(&path, &token).with_context(|| format!("writing token at {path:?}"))?;
    Ok(token)
}

#[cfg(unix)]
fn write_token_file(path: &PathBuf, token: &str) -> Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    let mut f = fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?;
    f.write_all(token.as_bytes())?;
    f.write_all(b"\n")?;
    Ok(())
}

#[cfg(not(unix))]
fn write_token_file(path: &PathBuf, token: &str) -> Result<()> {
    let mut f = fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(path)?;
    f.write_all(token.as_bytes())?;
    f.write_all(b"\n")?;
    Ok(())
}

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
