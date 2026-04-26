//! Shared on-disk API token loader.
//!
//! The Swift app, the Rust daemon, and the `recall` CLI all need to read
//! the same bearer token from disk. This module is the single source of
//! truth for *where* that file lives and *how* to read it. The daemon
//! also generates the file on first run via [`ensure_token`].
//!
//! Path resolution:
//! - `INFINITE_RECALL_TOKEN_PATH` env var, if set
//! - else `~/Library/Application Support/InfiniteRecall/api-token.txt`

use std::fs;
use std::io::Write;
use std::path::PathBuf;

use anyhow::{Context, Result};

/// Resolve the on-disk path of the API token file.
pub fn token_path() -> PathBuf {
    if let Ok(v) = std::env::var("INFINITE_RECALL_TOKEN_PATH") {
        return PathBuf::from(v);
    }
    let home = dirs::home_dir().expect("HOME dir resolvable");
    home.join("Library/Application Support/InfiniteRecall/api-token.txt")
}

/// Read the token from disk if it exists. Returns `Ok(None)` when the file
/// is missing or empty so callers can choose to generate vs error.
///
/// This is the read-only entry point used by the CLI — no filesystem
/// mutation, no token generation, no panic on absence.
pub fn load_token() -> Result<Option<String>> {
    let path = token_path();
    if !path.exists() {
        return Ok(None);
    }
    let s = fs::read_to_string(&path)
        .with_context(|| format!("reading token at {path:?}"))?;
    let trimmed = s.trim().to_string();
    if trimmed.is_empty() {
        Ok(None)
    } else {
        Ok(Some(trimmed))
    }
}

/// Read existing token or generate a fresh 32-byte random one. Used by the
/// daemon at startup. The token file is created with mode 0600 on Unix.
pub fn ensure_token() -> Result<String> {
    use rand::RngCore;

    let path = token_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("creating {parent:?}"))?;
    }

    if let Some(existing) = load_token()? {
        return Ok(existing);
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
