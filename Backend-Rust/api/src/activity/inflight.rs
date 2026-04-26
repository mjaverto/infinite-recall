//! Stream D: `MemoryInflightRegistry` — `Arc<RwLock<HashMap<WorkKind, InFlight>>>`.
//!
//! TODO(stream-D): implement `InflightRegistry` with a tokio `RwLock` (or
//! `parking_lot::RwLock`) wrapping `HashMap<WorkKind, InFlight>`.
//! Trivial; bounded by lock contention.
