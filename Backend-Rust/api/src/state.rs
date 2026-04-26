use crate::db::SqlitePool;

/// Shared application state. Two pools, two purposes:
///
/// * `pool`       — read-only, large; serves every GET handler.
/// * `write_pool` — read-write, small; serves the action-item mutation
///                  endpoints. Kept as a separate field (rather than
///                  swapping `pool`) so reads remain on the strictly
///                  read-only file handle and can never accidentally
///                  scribble.
#[derive(Clone)]
pub struct AppState {
    pub pool: SqlitePool,
    pub write_pool: SqlitePool,
    pub token: String,
}
