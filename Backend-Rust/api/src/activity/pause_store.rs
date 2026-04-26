//! Stream B: `SqlPauseStore` — persistent absolute-time pause storage.
//!
//! TODO(stream-B): implement `PauseStore` against a new `paused_work` table
//! (see `Backend-Rust/migrations/NNNN_paused_work.sql`).
//!
//! Schema:
//! ```sql
//! CREATE TABLE paused_work (
//!     target    TEXT NOT NULL,    -- 'kind' | 'capture'
//!     id        TEXT NOT NULL,    -- WorkKind snake_case or 'audio'/'screen'
//!     resume_at INTEGER NOT NULL, -- unix seconds, absolute
//!     PRIMARY KEY (target, id)
//! );
//! ```
