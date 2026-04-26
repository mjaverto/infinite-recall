//! Stream C: `SystemResourceSampler` — process-tree + system GPU sampler.
//!
//! TODO(stream-C): implement `ResourceSampler` using:
//! - `libproc` for self + Swift PID + mlx-lm PID CPU/RSS
//! - PID discovery: try `~/Library/Application Support/InfiniteRecall/{swift,mlxlm}.pid`
//!   first, fall back to `launchctl list <label>` parsing
//! - `ioreg -r -c IOAccelerator` shellout for system GPU%
//! - Cache results for 1 second
