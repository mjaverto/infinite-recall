//! Stream D: `MemoryInflightRegistry` — `Arc<RwLock<HashMap<WorkKind, InFlight>>>`.
//!
//! Trivial in-memory implementation of the [`InflightRegistry`] trait. The
//! registry is process-local: it tracks which `WorkKind` slots are currently
//! mid-handler so the snapshot route can render the in-flight column.
//!
//! Concurrency model: a `std::sync::RwLock` over a `HashMap`. Updates take a
//! brief write lock; snapshots take a read lock and clone. Contention is
//! bounded by the number of concurrent kind transitions per second (low —
//! single-digits in practice), so a parking-lot lock is unnecessary.

use std::collections::HashMap;
use std::sync::{Arc, RwLock};

use super::traits::InflightRegistry;
use super::types::{InFlight, WorkKind};

/// In-memory implementation of [`InflightRegistry`].
///
/// Cloning is cheap: the inner map is shared via `Arc`.
#[derive(Debug, Clone, Default)]
pub struct MemoryInflightRegistry {
    map: Arc<RwLock<HashMap<WorkKind, InFlight>>>,
}

impl MemoryInflightRegistry {
    /// Construct an empty registry.
    pub fn new() -> Self {
        Self::default()
    }
}

impl InflightRegistry for MemoryInflightRegistry {
    fn snapshot(&self) -> HashMap<WorkKind, InFlight> {
        // Clone under the read lock so callers never see partial state.
        // PoisonError → fall back to an empty snapshot rather than panicking
        // the route handler; a poisoned lock here means an earlier writer
        // panicked, but the data itself is still readable.
        match self.map.read() {
            Ok(guard) => guard.clone(),
            Err(poisoned) => poisoned.into_inner().clone(),
        }
    }

    fn update(&self, kind: WorkKind, in_flight: Option<InFlight>) {
        let mut guard = match self.map.write() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        };
        match in_flight {
            Some(value) => {
                guard.insert(kind, value);
            }
            None => {
                guard.remove(&kind);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::thread;

    use chrono::Utc;

    use super::*;

    fn sample(label: &str) -> InFlight {
        InFlight {
            label: label.to_string(),
            started_at: Utc::now(),
        }
    }

    #[test]
    fn insert_then_snapshot_returns_value() {
        let reg = MemoryInflightRegistry::new();
        reg.update(WorkKind::Transcribe, Some(sample("t1")));

        let snap = reg.snapshot();
        assert_eq!(snap.len(), 1);
        assert_eq!(snap.get(&WorkKind::Transcribe).unwrap().label, "t1");
    }

    #[test]
    fn update_overwrites_existing_slot() {
        let reg = MemoryInflightRegistry::new();
        reg.update(WorkKind::Ocr, Some(sample("first")));
        reg.update(WorkKind::Ocr, Some(sample("second")));

        let snap = reg.snapshot();
        assert_eq!(snap.len(), 1);
        assert_eq!(snap.get(&WorkKind::Ocr).unwrap().label, "second");
    }

    #[test]
    fn none_removes_slot() {
        let reg = MemoryInflightRegistry::new();
        reg.update(WorkKind::Summarize, Some(sample("s")));
        assert!(reg.snapshot().contains_key(&WorkKind::Summarize));

        reg.update(WorkKind::Summarize, None);
        assert!(!reg.snapshot().contains_key(&WorkKind::Summarize));
        assert_eq!(reg.snapshot().len(), 0);
    }

    #[test]
    fn snapshot_is_independent_clone() {
        let reg = MemoryInflightRegistry::new();
        reg.update(WorkKind::Ocr, Some(sample("a")));

        let snap = reg.snapshot();
        // Mutating the registry after taking a snapshot does not change it.
        reg.update(WorkKind::Ocr, None);
        reg.update(WorkKind::Transcribe, Some(sample("t")));

        assert!(snap.contains_key(&WorkKind::Ocr));
        assert!(!snap.contains_key(&WorkKind::Transcribe));
    }

    #[test]
    fn multiple_kinds_coexist() {
        let reg = MemoryInflightRegistry::new();
        reg.update(WorkKind::Transcribe, Some(sample("t")));
        reg.update(WorkKind::Ocr, Some(sample("o")));
        reg.update(WorkKind::ExtractMemory, Some(sample("m")));

        let snap = reg.snapshot();
        assert_eq!(snap.len(), 3);
        assert!(snap.contains_key(&WorkKind::Transcribe));
        assert!(snap.contains_key(&WorkKind::Ocr));
        assert!(snap.contains_key(&WorkKind::ExtractMemory));
    }

    #[test]
    fn concurrent_inserts_from_many_threads_no_deadlock() {
        // Each of N threads writes into a distinct kind; final snapshot
        // must contain all N entries with the right label.
        let reg = Arc::new(MemoryInflightRegistry::new());
        let kinds = [
            WorkKind::Transcribe,
            WorkKind::Ocr,
            WorkKind::Summarize,
            WorkKind::ExtractMemory,
            WorkKind::ExtractActionItems,
        ];

        let mut handles = Vec::new();
        for (i, kind) in kinds.iter().copied().enumerate() {
            let reg = Arc::clone(&reg);
            handles.push(thread::spawn(move || {
                // Hammer it a bit so the read/write locks actually interleave.
                for j in 0..50 {
                    reg.update(kind, Some(sample(&format!("k{i}-iter{j}"))));
                    let _ = reg.snapshot();
                }
                // Final write per thread is deterministic.
                reg.update(kind, Some(sample(&format!("final-{i}"))));
            }));
        }
        for h in handles {
            h.join().expect("worker panicked");
        }

        let snap = reg.snapshot();
        assert_eq!(snap.len(), kinds.len());
        for (i, kind) in kinds.iter().copied().enumerate() {
            assert_eq!(snap.get(&kind).unwrap().label, format!("final-{i}"));
        }
    }

    #[test]
    fn concurrent_writers_on_same_kind_no_deadlock() {
        // All threads contend on a single key; we only assert that the run
        // completes (no deadlock) and that the registry is in a consistent
        // state (either present or absent — last writer wins, but we don't
        // know which one).
        let reg = Arc::new(MemoryInflightRegistry::new());
        let mut handles = Vec::new();
        for i in 0..16 {
            let reg = Arc::clone(&reg);
            handles.push(thread::spawn(move || {
                for j in 0..100 {
                    if (i + j) % 2 == 0 {
                        reg.update(WorkKind::Ocr, Some(sample("x")));
                    } else {
                        reg.update(WorkKind::Ocr, None);
                    }
                }
            }));
        }
        for h in handles {
            h.join().expect("worker panicked");
        }

        // The map is in *some* consistent state — it must hold either 0 or 1
        // entries, never more.
        assert!(reg.snapshot().len() <= 1);
    }
}
