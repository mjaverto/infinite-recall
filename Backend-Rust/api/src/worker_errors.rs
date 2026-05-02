//! Bounded ring buffer of recent worker errors, exposed by the
//! `test_introspection` Cargo feature.
//!
//! Off-by-default: when the feature is disabled, `WorkerErrorSink` compiles
//! to a zero-state stub whose `push` is a no-op and whose `snapshot` returns
//! an empty `Vec`. Producers can call `push` from any code path without
//! caring whether introspection is on — release builds carry no buffer.

#[derive(serde::Serialize, Clone, Debug)]
pub struct WorkerError {
    pub worker: String,
    pub kind: String,
    pub message: String,
    pub ts_unix_ms: i64,
}

#[cfg(not(feature = "test_introspection"))]
mod imp {
    use super::WorkerError;

    #[derive(Default)]
    pub struct WorkerErrorSink;

    impl WorkerErrorSink {
        pub fn push(&self, _e: WorkerError) {}
        pub fn snapshot(&self) -> Vec<WorkerError> {
            Vec::new()
        }
    }
}

#[cfg(feature = "test_introspection")]
mod imp {
    use super::WorkerError;
    use std::collections::VecDeque;
    use std::sync::Mutex;

    const CAP: usize = 64;

    #[derive(Default)]
    pub struct WorkerErrorSink {
        buf: Mutex<VecDeque<WorkerError>>,
    }

    impl WorkerErrorSink {
        pub fn push(&self, e: WorkerError) {
            if let Ok(mut b) = self.buf.lock() {
                if b.len() == CAP {
                    b.pop_front();
                }
                b.push_back(e);
            }
        }

        pub fn snapshot(&self) -> Vec<WorkerError> {
            self.buf
                .lock()
                .map(|b| b.iter().cloned().collect())
                .unwrap_or_default()
        }
    }
}

pub use imp::WorkerErrorSink;
