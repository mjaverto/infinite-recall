//! Infinite Recall — local Omi-shaped REST API.
//!
//! Read-only HTTP server over the GRDB SQLite at
//! ~/Library/Application Support/Omi/users/anonymous/omi.db
//! Listens on 127.0.0.1:7331 by default. Bearer-token auth.
//!
//! All wiring lives in the library crate (see `lib.rs`); this binary is
//! a thin shim so sibling crates (notably the `recall` CLI) can reuse
//! the same modules — especially `token` — without pulling in `main()`.

use anyhow::Result;

#[tokio::main]
async fn main() -> Result<()> {
    infinite_recall_api::run().await
}
