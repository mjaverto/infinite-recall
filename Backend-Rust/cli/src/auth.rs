//! Token loading for the CLI.
//!
//! Default path lookup goes through [`infinite_recall_api::token`] so the
//! CLI and the daemon stay in lockstep on file location and parsing rules.
//! `--token-path` overrides skip the shared loader entirely — they're a
//! direct file read so the user can hand the CLI an arbitrary token without
//! futzing with `INFINITE_RECALL_TOKEN_PATH`.

use std::fs;
use std::path::Path;

use crate::error::CliError;
use crate::GlobalOpts;

/// Best-effort token load. Returns `Ok(None)` if no token is configured *and*
/// the user did not pass `--token-path`. Health doesn't need a token; every
/// other command should call [`require_token`] instead.
pub fn load_token(opts: &GlobalOpts) -> Result<Option<String>, CliError> {
    if let Some(path) = &opts.token_path {
        return Ok(Some(read_explicit_path(path)?));
    }
    infinite_recall_api::token::load_token()
        .map_err(|e| CliError::AuthFailed(format!("reading token file: {e:#}")))
}

/// Strict token load. Returns `AuthFailed` (exit 4) when no token is found.
pub fn require_token(opts: &GlobalOpts) -> Result<String, CliError> {
    match load_token(opts)? {
        Some(t) => Ok(t),
        None => {
            let p = infinite_recall_api::token::token_path();
            Err(CliError::AuthFailed(format!(
                "no token at {}; is the daemon running? \
                 set INFINITE_RECALL_TOKEN_PATH or pass --token-path",
                p.display()
            )))
        }
    }
}

fn read_explicit_path(path: &Path) -> Result<String, CliError> {
    if !path.exists() {
        return Err(CliError::AuthFailed(format!(
            "token file not found: {}",
            path.display()
        )));
    }
    let s = fs::read_to_string(path)
        .map_err(|e| CliError::AuthFailed(format!("reading {}: {e}", path.display())))?;
    let trimmed = s.trim().to_string();
    if trimmed.is_empty() {
        return Err(CliError::AuthFailed(format!(
            "token file is empty: {}",
            path.display()
        )));
    }
    Ok(trimmed)
}
