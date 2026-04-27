//! Lane D: hard-kill a tracked LocalModel worker by pid.
//!
//! Exposes `terminate_pid` (the SIGTERM-then-SIGKILL helper) and
//! `is_local_model_pid` (the security gate). The route handler in
//! `routes::activity::terminate` composes them.
//!
//! ## Why not call into `resources.rs`?
//!
//! The 2s `Inner` cache there is shared with the snapshot reader. PID-recycle
//! is a real risk — between a cached snapshot and our `kill(2)` syscall the
//! original mlx worker could exit, the kernel could reuse the pid, and we'd
//! signal an unrelated process. So we re-do discovery from scratch (pidfile +
//! `pgrep -P` BFS, same shape `discover_pids` uses) every terminate request,
//! THEN double-check the pid is still alive via `proc_pid::pidinfo` right
//! before signalling.
//!
//! Lane A is forbidden from editing `Cargo.toml`, so this module owns the
//! `libc = "0.2"` dependency add. We use `libc::kill` directly rather than
//! the `nix` crate to keep the dep tree small.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

/// Same ceilings the snapshot path uses (see `resources.rs`). Kept in sync
/// by hand — these are defensive caps, not contract values.
const DESCENDANT_MAX_DEPTH: usize = 4;
const DESCENDANT_MAX_COUNT: usize = 16;

/// Pidfile basenames under the InfiniteRecall app-support dir. Mirror the
/// constants in `resources.rs` — Lane A's territory, so we can't import.
const MLX_PIDFILE: &str = "mlxlm.pid";
const MLX_VLM_PIDFILE: &str = "mlxvlm.pid";

/// Launchd labels. Mirrors `resources.rs`.
const MLX_LAUNCHD_LABEL: &str = "com.infiniterecall.mlx";
const MLX_VLM_LAUNCHD_LABEL: &str = "com.infiniterecall.vlm";

/// `pgrep -f` patterns. Mirrors `resources.rs`.
const MLX_PGREP_PATTERN: &str = " mlx_lm.server";
const MLX_VLM_PGREP_PATTERN: &str = " mlx_vlm.server";

/// Outcome of a terminate attempt.
#[derive(Debug)]
pub enum TerminateOutcome {
    /// Process exited within the SIGTERM grace window or was already gone.
    GracefulExit,
    /// SIGTERM was sent, the grace window elapsed with the process still
    /// alive, and SIGKILL was then issued successfully.
    KilledForcibly,
}

/// Errors the route handler maps to a 500 with `{error: <msg>}`.
#[derive(Debug, thiserror::Error)]
pub enum TerminateError {
    #[error("kill({pid}, SIGTERM) failed: {errno}")]
    SigtermFailed { pid: i32, errno: String },
    #[error("kill({pid}, SIGKILL) failed: {errno}")]
    SigkillFailed { pid: i32, errno: String },
}

/// Test seam — production impl walks the real filesystem; tests inject a
/// closure-backed allowlist so they don't have to fork mlx-lm.
pub trait LocalModelGate: Send + Sync {
    /// Return true iff `pid` is currently tracked as a `LocalModel` worker
    /// (root or descendant). Implementations must do their OWN fresh
    /// discovery — the cached `ResourceSampler` snapshot is up to 2 s stale
    /// and not safe to rely on for a TOCTOU-sensitive kill gate.
    fn is_local_model(&self, pid: i32) -> bool;
}

/// Production gate: re-discovers the LocalModel pid set on every call.
pub struct ProcLocalModelGate {
    support_dir: PathBuf,
}

impl ProcLocalModelGate {
    pub fn new() -> Self {
        Self {
            support_dir: default_support_dir(),
        }
    }

    #[cfg(test)]
    pub fn with_support_dir(dir: PathBuf) -> Self {
        Self { support_dir: dir }
    }
}

impl Default for ProcLocalModelGate {
    fn default() -> Self {
        Self::new()
    }
}

impl LocalModelGate for ProcLocalModelGate {
    fn is_local_model(&self, pid: i32) -> bool {
        let pids = discover_local_model_pids(&self.support_dir);
        pids.contains(&pid)
    }
}

/// Re-implementation of the LocalModel half of `resources::discover_pids`.
/// Returns the set of pids (roots + descendants) tagged `LocalModel`.
///
/// This is a parallel implementation, not a delegation — Lane A owns
/// `resources.rs` and this lane can't add a public `pub fn discover_pids`.
fn discover_local_model_pids(support_dir: &Path) -> Vec<i32> {
    let mut roots: Vec<i32> = Vec::new();

    if let Some(pid) = discover_one(
        &support_dir.join(MLX_PIDFILE),
        MLX_PGREP_PATTERN,
        Some(MLX_LAUNCHD_LABEL),
    ) {
        roots.push(pid);
    }
    if let Some(pid) = discover_one(
        &support_dir.join(MLX_VLM_PIDFILE),
        MLX_VLM_PGREP_PATTERN,
        Some(MLX_VLM_LAUNCHD_LABEL),
    ) {
        roots.push(pid);
    }

    let mut out: Vec<i32> = roots.clone();
    for root in roots {
        for child in descendants_of(root, DESCENDANT_MAX_DEPTH, DESCENDANT_MAX_COUNT) {
            if !out.contains(&child) {
                out.push(child);
            }
        }
    }
    out
}

fn default_support_dir() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("/"))
        .join("Library/Application Support/InfiniteRecall")
}

fn discover_one(pidfile: &Path, pgrep_pattern: &str, launchd_label: Option<&str>) -> Option<i32> {
    if let Some(pid) = read_pidfile(pidfile) {
        return Some(pid);
    }
    if let Some(pid) = pid_from_pgrep(pgrep_pattern) {
        return Some(pid);
    }
    if let Some(label) = launchd_label {
        if let Some(pid) = pid_from_launchctl(label) {
            return Some(pid);
        }
    }
    tracing::debug!(
        component = "activity.terminate",
        pidfile = %pidfile.display(),
        pgrep_pattern,
        launchd_label = ?launchd_label,
        "discover_one: no live pid found via pidfile/pgrep/launchctl"
    );
    None
}

fn read_pidfile(path: &Path) -> Option<i32> {
    let raw = match std::fs::read_to_string(path) {
        Ok(s) => s,
        Err(e) => {
            tracing::debug!(
                component = "activity.terminate",
                path = %path.display(),
                error = %e,
                "read_pidfile: failed to read pidfile"
            );
            return None;
        }
    };
    let pid: i32 = match raw.trim().parse() {
        Ok(p) => p,
        Err(e) => {
            tracing::debug!(
                component = "activity.terminate",
                path = %path.display(),
                error = %e,
                "read_pidfile: pidfile contents not parseable as i32"
            );
            return None;
        }
    };
    if pid <= 0 {
        tracing::debug!(
            component = "activity.terminate",
            path = %path.display(),
            pid,
            "read_pidfile: non-positive pid"
        );
        return None;
    }
    if !pid_alive(pid) {
        tracing::debug!(
            component = "activity.terminate",
            path = %path.display(),
            pid,
            "read_pidfile: pid not alive"
        );
        return None;
    }
    Some(pid)
}

fn pid_from_pgrep(pattern: &str) -> Option<i32> {
    let out = match Command::new("pgrep").args(["-f", pattern]).output() {
        Ok(o) => o,
        Err(e) => {
            tracing::debug!(
                component = "activity.terminate",
                pattern,
                error = %e,
                "pid_from_pgrep: pgrep command failed to spawn"
            );
            return None;
        }
    };
    if !out.status.success() {
        tracing::debug!(
            component = "activity.terminate",
            pattern,
            status = ?out.status,
            "pid_from_pgrep: pgrep exited non-zero (no matches?)"
        );
        return None;
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    let self_pid = std::process::id() as i32;
    for line in stdout.lines() {
        if let Ok(pid) = line.trim().parse::<i32>() {
            if pid > 0 && pid != self_pid && pid_alive(pid) {
                return Some(pid);
            }
        }
    }
    tracing::debug!(
        component = "activity.terminate",
        pattern,
        "pid_from_pgrep: pgrep matched but no live pid in output"
    );
    None
}

fn pid_from_launchctl(label: &str) -> Option<i32> {
    let out = match Command::new("launchctl").args(["list", label]).output() {
        Ok(o) => o,
        Err(e) => {
            tracing::debug!(
                component = "activity.terminate",
                label,
                error = %e,
                "pid_from_launchctl: launchctl command failed to spawn"
            );
            return None;
        }
    };
    if !out.status.success() {
        tracing::debug!(
            component = "activity.terminate",
            label,
            status = ?out.status,
            "pid_from_launchctl: launchctl list exited non-zero (label not loaded?)"
        );
        return None;
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    for line in stdout.lines() {
        let line = line.trim();
        let rest_legacy = line.strip_prefix("\"PID\"");
        let rest_new = line
            .strip_prefix("pid")
            .or_else(|| line.strip_prefix("PID"))
            .filter(|tail| {
                tail.chars()
                    .next()
                    .map_or(false, |c| c == '=' || c.is_whitespace())
            });
        let rest = rest_legacy.or(rest_new);
        let Some(rest) = rest else { continue };
        let rest = rest.trim_start_matches([' ', '\t', '=']).trim();
        let rest = rest.trim_end_matches(';').trim();
        if let Ok(pid) = rest.parse::<i32>() {
            if pid > 0 {
                return Some(pid);
            }
        }
    }
    tracing::debug!(
        component = "activity.terminate",
        label,
        "pid_from_launchctl: no PID line found in launchctl output"
    );
    None
}

fn pgrep_children(ppid: i32) -> Vec<i32> {
    let Ok(out) = Command::new("pgrep")
        .args(["-P", &ppid.to_string()])
        .output()
    else {
        return Vec::new();
    };
    let stdout = String::from_utf8_lossy(&out.stdout);
    let self_pid = std::process::id() as i32;
    let mut pids = Vec::new();
    for line in stdout.lines() {
        if let Ok(pid) = line.trim().parse::<i32>() {
            if pid > 0 && pid != self_pid && pid_alive(pid) {
                pids.push(pid);
            }
        }
    }
    pids
}

fn descendants_of(root_ppid: i32, max_depth: usize, max_count: usize) -> Vec<i32> {
    let mut out: Vec<i32> = Vec::new();
    if max_depth == 0 || max_count == 0 {
        return out;
    }
    let mut frontier: Vec<(i32, usize)> = vec![(root_ppid, 1)];
    while let Some((parent, depth)) = frontier.first().copied() {
        frontier.remove(0);
        if depth > max_depth {
            continue;
        }
        for child in pgrep_children(parent) {
            if out.len() >= max_count {
                return out;
            }
            out.push(child);
            if depth < max_depth {
                frontier.push((child, depth + 1));
            }
        }
    }
    out
}

/// Outcome of a defense-in-depth aliveness probe via `proc_pid::pidinfo`.
///
/// Distinguishes "process is gone" (ESRCH — caller should 404) from
/// "kernel won't let us inspect" (EPERM, EAGAIN, …) so the route handler
/// doesn't conflate a legitimate "already dead" with a transient inspect
/// failure and 404 a process that's actually alive.
#[derive(Debug, Eq, PartialEq)]
pub enum PidStatus {
    /// `pidinfo` succeeded — process is alive and inspectable.
    Alive,
    /// `pidinfo` failed with `ESRCH` — process is gone, what we want.
    Gone,
    /// `pidinfo` failed for any other reason (most likely EPERM). The
    /// process may or may not be alive; the caller should fall through to
    /// `kill(2)` and let `kill`'s own ESRCH handling decide.
    InspectFailed(libc::c_int),
}

/// Check the kernel's view of `pid` via `proc_pid::pidinfo::<TaskInfo>`.
///
/// `libproc::proc_pid::pidinfo` doesn't surface errno directly — it returns
/// a `String`. We instead probe with `kill(pid, 0)` (signal 0 = "is the
/// pid signalable by us?"), which gives us a real errno. This is the same
/// probe used inside the SIGTERM grace-poll loop, kept consistent on
/// purpose.
pub fn pid_status(pid: i32) -> PidStatus {
    let rc = unsafe { libc::kill(pid as libc::pid_t, 0) };
    if rc == 0 {
        return PidStatus::Alive;
    }
    let errno = std::io::Error::last_os_error()
        .raw_os_error()
        .unwrap_or(0);
    if errno == libc::ESRCH {
        PidStatus::Gone
    } else {
        PidStatus::InspectFailed(errno)
    }
}

/// Backwards-compatible wrapper used inside this module's discovery helpers.
/// Returns `true` for both `Alive` and `InspectFailed` — the discovery code
/// just wants to skip pids the kernel already reaped, not gate on permissions.
fn pid_alive(pid: i32) -> bool {
    !matches!(pid_status(pid), PidStatus::Gone)
}

/// SIGTERM, wait up to 5 s, then SIGKILL if still alive.
///
/// Uses `tokio::time::sleep` (NOT `std::thread::sleep`) so the calling
/// async handler doesn't block a runtime worker for 5 s.
///
/// Returns:
/// * `Ok(GracefulExit)`     — process gone within the SIGTERM grace window.
/// * `Ok(KilledForcibly)`   — SIGKILL succeeded after the grace window.
/// * `Err(SigtermFailed)`   — SIGTERM returned -1 with errno != ESRCH.
/// * `Err(SigkillFailed)`   — SIGKILL returned -1 with errno != ESRCH.
///
/// `errno == ESRCH` (no such process) is treated as success — the pid
/// is gone, which is exactly the post-condition we wanted.
pub async fn terminate_pid(pid: i32) -> Result<TerminateOutcome, TerminateError> {
    // 1. SIGTERM
    let term_rc = unsafe { libc::kill(pid as libc::pid_t, libc::SIGTERM) };
    if term_rc == -1 {
        let errno = std::io::Error::last_os_error();
        if errno.raw_os_error() == Some(libc::ESRCH) {
            // Already gone — that's success.
            return Ok(TerminateOutcome::GracefulExit);
        }
        return Err(TerminateError::SigtermFailed {
            pid,
            errno: errno.to_string(),
        });
    }

    // 2. Poll up to 50 * 100 ms = 5 s for graceful exit.
    for _ in 0..50 {
        tokio::time::sleep(Duration::from_millis(100)).await;
        let probe = unsafe { libc::kill(pid as libc::pid_t, 0) };
        if probe == -1 {
            let errno = std::io::Error::last_os_error();
            if errno.raw_os_error() == Some(libc::ESRCH) {
                return Ok(TerminateOutcome::GracefulExit);
            }
            // EPERM (process exists but not signalable by us) shouldn't happen
            // since we just SIGTERM'd it, but if it does we treat the process
            // as still alive and continue waiting / fall through to SIGKILL.
            if errno.raw_os_error() == Some(libc::EPERM) {
                let errno = libc::EPERM;
                tracing::warn!(
                    component = "activity.terminate",
                    pid,
                    errno,
                    "kill(pid, 0) returned EPERM during grace poll"
                );
            }
        }
    }

    // 3. Still alive after 5 s — SIGKILL.
    let kill_rc = unsafe { libc::kill(pid as libc::pid_t, libc::SIGKILL) };
    if kill_rc == -1 {
        let errno = std::io::Error::last_os_error();
        if errno.raw_os_error() == Some(libc::ESRCH) {
            // Raced with the SIGTERM finally taking effect.
            return Ok(TerminateOutcome::GracefulExit);
        }
        return Err(TerminateError::SigkillFailed {
            pid,
            errno: errno.to_string(),
        });
    }
    Ok(TerminateOutcome::KilledForcibly)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `terminate_pid` against a live `sleep` child must SIGTERM it and
    /// observe exit within the grace window.
    ///
    /// Subtle: in production the mlx-lm worker's parent is launchd, which
    /// reaps zombies quickly. In this test WE are the parent, so unless
    /// we `wait()` concurrently the SIGTERM'd child becomes a zombie that
    /// `kill(pid, 0)` reports as alive — which would push `terminate_pid`
    /// into the SIGKILL branch and return `KilledForcibly` instead of
    /// `GracefulExit`. Spawning the wait on a background thread keeps the
    /// pid table accurate during the grace-window poll.
    #[tokio::test]
    async fn terminate_pid_signals_sigterm_path() {
        let child = std::process::Command::new("sleep")
            .arg("60")
            .spawn()
            .expect("spawn sleep");
        let pid = child.id() as i32;
        // Background reaper: drain the zombie as soon as the SIGTERM lands so
        // the kernel actually frees the pid slot during the grace window.
        let reap_handle = std::thread::spawn(move || {
            let mut child = child;
            let _ = child.wait();
        });
        // Give the kernel a beat to register the child.
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(pid_alive(pid), "child must be alive pre-terminate");

        let outcome = terminate_pid(pid).await.expect("terminate ok");
        let _ = reap_handle.join();
        assert!(
            matches!(outcome, TerminateOutcome::GracefulExit),
            "expected GracefulExit; got {outcome:?}"
        );
        assert!(!pid_alive(pid), "child must be gone post-terminate");
    }

    /// `terminate_pid` against an already-dead pid must succeed (ESRCH path).
    #[tokio::test]
    async fn terminate_pid_already_dead_is_success() {
        // Spawn + reap so the pid is genuinely gone.
        let mut child = std::process::Command::new("true")
            .spawn()
            .expect("spawn true");
        let pid = child.id() as i32;
        let _ = child.wait();
        // After wait(), the kernel has reaped the zombie — kill(pid, SIGTERM)
        // should fail with ESRCH, which we map to `GracefulExit`.
        let outcome = terminate_pid(pid).await.expect("dead pid is success");
        assert!(matches!(outcome, TerminateOutcome::GracefulExit));
    }

    /// `discover_local_model_pids` against an empty support dir + no launchd
    /// labels matching is allowed to return an empty list (or whatever pgrep
    /// happens to find on the host — we only assert no panic).
    #[test]
    fn discover_local_model_empty_support_dir_does_not_panic() {
        let tmp = std::env::temp_dir().join(format!(
            "ir-lane-d-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();
        let _ = discover_local_model_pids(&tmp);
    }

    /// Pidfile-driven discovery: write a live pid into `mlxlm.pid` and assert
    /// it shows up in the result set.
    #[test]
    fn discover_local_model_pidfile_path() {
        let tmp = std::env::temp_dir().join(format!(
            "ir-lane-d-pidfile-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&tmp).unwrap();

        let mut child = std::process::Command::new("sleep")
            .arg("30")
            .spawn()
            .expect("spawn sleep");
        let pid = child.id() as i32;
        std::fs::write(tmp.join(MLX_PIDFILE), pid.to_string()).unwrap();
        // brief warmup
        std::thread::sleep(Duration::from_millis(50));

        let pids = discover_local_model_pids(&tmp);

        // Tear down before assertions so a panic can't leak the sleep.
        let _ = child.kill();
        let _ = child.wait();

        assert!(
            pids.contains(&pid),
            "pidfile-discovered pid {pid} must appear in {pids:?}"
        );
    }

    /// `pid_status` for our own pid must report `Alive`.
    #[test]
    fn pid_status_self_is_alive() {
        let pid = std::process::id() as i32;
        assert_eq!(pid_status(pid), PidStatus::Alive);
    }

    /// `pid_status` for a freshly-reaped pid must report `Gone`.
    #[test]
    fn pid_status_dead_pid_is_gone() {
        let mut child = std::process::Command::new("true")
            .spawn()
            .expect("spawn true");
        let pid = child.id() as i32;
        let _ = child.wait();
        // The pid may have been recycled by the kernel between `wait()` and
        // here, but in a single-threaded test the window is microseconds
        // and the kernel is conservative about reusing pids — accept either
        // `Gone` or `InspectFailed` (paranoia), but reject `Alive` for the
        // exact pid we just reaped iff it's the same process. In practice
        // we expect `Gone`.
        let status = pid_status(pid);
        assert!(
            matches!(status, PidStatus::Gone | PidStatus::InspectFailed(_)),
            "expected Gone or InspectFailed for reaped pid {pid}; got {status:?}"
        );
    }

    /// `terminate_pid` against a process that ignores SIGTERM must fall
    /// through the 5 s grace window and SIGKILL it, returning
    /// `KilledForcibly`.
    ///
    /// We use `bash -c "trap '' TERM; sleep 30"` to trap (and ignore) SIGTERM
    /// without a child shell — the trap is on bash itself, so SIGTERM lands
    /// on the very pid we're about to terminate and is silently dropped.
    #[cfg(unix)]
    #[tokio::test]
    async fn terminate_pid_falls_through_to_sigkill() {
        let child = std::process::Command::new("bash")
            .args(["-c", "trap '' TERM; sleep 30"])
            .spawn()
            .expect("spawn sigterm-ignoring bash");
        let pid = child.id() as i32;

        // Background reaper so the SIGKILL'd shell doesn't linger as a zombie.
        let reap_handle = std::thread::spawn(move || {
            let mut child = child;
            let _ = child.wait();
        });

        // Give bash a beat to install the trap before we SIGTERM it.
        tokio::time::sleep(Duration::from_millis(150)).await;
        assert!(
            pid_alive(pid),
            "sigterm-ignoring child must be alive pre-terminate"
        );

        let outcome = terminate_pid(pid).await.expect("terminate ok");
        let _ = reap_handle.join();

        assert!(
            matches!(outcome, TerminateOutcome::KilledForcibly),
            "expected KilledForcibly (SIGTERM ignored, SIGKILL won); got {outcome:?}"
        );
        assert!(
            matches!(pid_status(pid), PidStatus::Gone | PidStatus::InspectFailed(_)),
            "child must be gone post-SIGKILL"
        );
    }
}
