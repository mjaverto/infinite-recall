//! Stream C: `SystemResourceSampler` — process-tree CPU/memory + system GPU sampler.
//!
//! Implements [`ResourceSampler`] using:
//! - `libproc::proc_pid::pidinfo::<TaskInfo>` for self + Swift PID + mlx-lm PID
//!   CPU deltas.
//! - `libproc::pid_rusage::pidrusage::<RUsageInfoV4>` for `ri_phys_footprint`,
//!   the field Activity Monitor's "Memory" column reads. We do NOT use
//!   `pti_resident_size` (plain RSS) — it under-reports MLX workers by
//!   excluding compressed / swapped pages.
//! - PID discovery order:
//!   1. pidfile under `~/Library/Application Support/InfiniteRecall/{swift,mlxlm}.pid`
//!   2. `pgrep -f` against the well-known executable pattern
//!   3. (mlx only) `launchctl list com.infiniterecall.mlx` for the launchd-managed
//!      `mlx_lm.server` agent
//! - `ioreg -r -c IOAccelerator -d 1` shellout to read `Device Utilization %`.
//! - `pmset -g batt` for battery / low-power state.
//! - `sysctl machdep.xcpm.cpu_thermal_level` (with `pmset -g therm` fallback)
//!   for thermal pressure.
//! - Caches the assembled [`ResourceSample`] for one second so back-to-back
//!   snapshot requests do not re-sample.

use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

use libproc::pid_rusage::{pidrusage, RUsageInfoV4};
use libproc::proc_pid;
use libproc::task_info::TaskInfo;

use super::traits::ResourceSampler;
use super::types::{ProcessBreakdown, ProcessKind, ResourceSample, ThermalState};

/// `pgrep -f` patterns. The Swift app is launched as a regular `.app` (never
/// under launchd) so its PID has to come from the bundle path; the mlx-lm /
/// mlx-vlm helpers are `uv tool run mlx_{lm,vlm}.server` invocations that
/// uniquely match the executable name.
///
/// The mlx patterns are anchored with a leading space so an argv that
/// happens to mention both names (e.g. a wrapper script) doesn't
/// double-match the same PID under both labels.
const SWIFT_PGREP_PATTERN: &str = "Infinite Recall.app/Contents/MacOS";
const MLX_PGREP_PATTERN: &str = " mlx_lm.server";
const MLX_VLM_PGREP_PATTERN: &str = " mlx_vlm.server";

/// Launchd labels for the local-model helpers. The Swift app is NOT under
/// launchd, so no swift-side label is probed.
const MLX_LAUNCHD_LABEL: &str = "com.infiniterecall.mlx";
const MLX_VLM_LAUNCHD_LABEL: &str = "com.infiniterecall.vlm";

/// Pidfile basenames under the InfiniteRecall app-support dir.
const MLX_VLM_PIDFILE: &str = "mlxvlm.pid";

/// How long to hold a sample in cache before re-sampling.
///
/// Singleton-fixer S4: bumped 1s → 2s. The sampler costs ~300ms per
/// miss (250ms CPU-delta sleep + ~5 subprocess forks). With the Swift
/// Activity tab polling at 1Hz, a 1s TTL meant a cache miss every tick;
/// 2s halves that to every other tick without any user-visible staleness
/// (CPU/RSS/GPU are coarse readouts, not real-time meters).
const CACHE_TTL: Duration = Duration::from_secs(2);

/// Maximum BFS depth when walking descendants of a `LocalModel` root via
/// `pgrep -P`. Defensive cap so a runaway tree (e.g. a wrapper that re-execs)
/// can't expand the snapshot indefinitely.
const DESCENDANT_MAX_DEPTH: usize = 4;

/// Maximum number of descendants collected per `LocalModel` root.
/// Paired with `DESCENDANT_MAX_DEPTH` to bound `discover_pids` overhead
/// regardless of process tree shape.
const DESCENDANT_MAX_COUNT: usize = 16;

/// Window over which we measure CPU% deltas.
const CPU_SAMPLE_WINDOW: Duration = Duration::from_millis(250);

/// Process-tree + system GPU sampler.
pub struct SystemResourceSampler {
    inner: Mutex<Inner>,
}

struct Inner {
    /// Last assembled sample + the instant it was produced.
    cache: Option<(Instant, ResourceSample)>,
    /// Override for the InfiniteRecall app-support directory; tests use this.
    support_dir_override: Option<PathBuf>,
    /// If `Some`, take this list of pids verbatim instead of discovering.
    /// Tests use this so they do not have to spin up real processes.
    pid_override: Option<Vec<(String, i32, Option<ProcessKind>)>>,
}

impl SystemResourceSampler {
    /// Construct a sampler that reads PIDs from the real filesystem +
    /// launchctl on each (post-cache) sample.
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(Inner {
                cache: None,
                support_dir_override: None,
                pid_override: None,
            }),
        }
    }

    /// Test constructor: pidfiles are read from `support_dir` instead of
    /// `~/Library/Application Support/InfiniteRecall/`.
    #[cfg(test)]
    fn with_support_dir(dir: PathBuf) -> Self {
        Self {
            inner: Mutex::new(Inner {
                cache: None,
                support_dir_override: Some(dir),
                pid_override: None,
            }),
        }
    }

    /// Test constructor: skip PID discovery entirely and sample these pids.
    #[cfg(test)]
    fn with_pids(pids: Vec<(String, i32, Option<ProcessKind>)>) -> Self {
        Self {
            inner: Mutex::new(Inner {
                cache: None,
                support_dir_override: None,
                pid_override: Some(pids),
            }),
        }
    }
}

impl Default for SystemResourceSampler {
    fn default() -> Self {
        Self::new()
    }
}

impl ResourceSampler for SystemResourceSampler {
    fn sample(&self) -> ResourceSample {
        // 1. cache check
        {
            let guard = self.inner.lock().unwrap();
            if let Some((at, sample)) = &guard.cache {
                if at.elapsed() < CACHE_TTL {
                    return sample.clone();
                }
            }
        }

        // 2. discover pids (without the lock held — discovery may shell out)
        let (support_dir_override, pid_override) = {
            let guard = self.inner.lock().unwrap();
            (
                guard.support_dir_override.clone(),
                guard.pid_override.clone(),
            )
        };

        let pids: Vec<(String, i32, Option<ProcessKind>)> = match pid_override {
            Some(v) => v,
            None => discover_pids(support_dir_override.as_deref()),
        };

        // 3. sample
        let breakdown = sample_processes(&pids);
        let cpu_total: f32 = breakdown.iter().map(|p| p.cpu_percent).sum();
        let mem_total: u32 = breakdown.iter().map(|p| p.mem_mb).sum();
        let gpu = sample_gpu_percent();
        let thermal = sample_thermal();
        let (on_battery, low_power) = sample_power();

        let sample = ResourceSample {
            cpu_percent: cpu_total,
            mem_mb: mem_total,
            gpu_system_percent: gpu,
            thermal_state: thermal,
            on_battery,
            low_power,
            process_breakdown: breakdown,
        };

        // 4. cache + return
        let mut guard = self.inner.lock().unwrap();
        guard.cache = Some((Instant::now(), sample.clone()));
        sample
    }
}

// ---------------------------------------------------------------------------
// PID discovery
// ---------------------------------------------------------------------------

/// Returns `[(name, pid)]` for self + Swift app + mlx-lm if found.
///
/// Order is meaningful so tests / logs are stable: `api`, `swift`, `mlx`.
///
/// Singleton-fixer S7: each discovery path emits a structured tracing
/// breadcrumb so the next contributor can tell whether a missing pid is
/// "no pidfile yet" vs "launchctl label renamed" vs "stale pidfile".
fn discover_pids(
    support_dir_override: Option<&std::path::Path>,
) -> Vec<(String, i32, Option<ProcessKind>)> {
    let mut out: Vec<(String, i32, Option<ProcessKind>)> = Vec::with_capacity(4);

    let self_pid = std::process::id() as i32;
    out.push(("api".to_string(), self_pid, Some(ProcessKind::Core)));

    let support_dir = support_dir_override
        .map(|p| p.to_path_buf())
        .unwrap_or_else(default_support_dir);

    if let Some(pid) = discover_one(
        "swift",
        &support_dir.join("swift.pid"),
        SWIFT_PGREP_PATTERN,
        None,
    ) {
        out.push(("swift".to_string(), pid, Some(ProcessKind::Core)));
    }

    if let Some(pid) = discover_one(
        "mlx",
        &support_dir.join("mlxlm.pid"),
        MLX_PGREP_PATTERN,
        Some(MLX_LAUNCHD_LABEL),
    ) {
        out.push(("mlx-lm".to_string(), pid, Some(ProcessKind::LocalModel)));
    }

    if let Some(pid) = discover_one(
        "mlx-vlm",
        &support_dir.join(MLX_VLM_PIDFILE),
        MLX_VLM_PGREP_PATTERN,
        Some(MLX_VLM_LAUNCHD_LABEL),
    ) {
        out.push(("mlx-vlm".to_string(), pid, Some(ProcessKind::LocalModel)));
    }

    // Walk descendants of every `LocalModel` root and append them as their own
    // rows. The launchd-managed parent (e.g. `uv tool run mlx_lm.server`) holds
    // ~5 MB; the forked Python child it execs holds the multi-GB model weights.
    // Without this walk the Activity tab silently undercounts by ~10+ GB. We
    // only walk LocalModel roots — Core (api/swift) descendants are short-lived
    // shells (Bash/pgrep/launchctl) that aren't memory-relevant.
    //
    // Snapshot the roots first so we're not iterating `out` while pushing to
    // it. Existing dedupe (below) handles any collisions with the parent.
    let local_model_roots: Vec<(String, i32)> = out
        .iter()
        .filter_map(|(name, pid, kind)| {
            if matches!(kind, Some(ProcessKind::LocalModel)) {
                Some((name.clone(), *pid))
            } else {
                None
            }
        })
        .collect();
    for (name, ppid) in local_model_roots {
        for (child_pid, depth) in
            descendants_of(ppid, DESCENDANT_MAX_DEPTH, DESCENDANT_MAX_COUNT)
        {
            tracing::debug!(
                component = "activity.discover.descendants",
                root = %name,
                ppid,
                child_pid,
                depth,
                "discovered model worker descendant"
            );
            out.push((
                format!("{name} child"),
                child_pid,
                Some(ProcessKind::LocalModel),
            ));
        }
    }

    // Dedupe by pid: anchored pgrep patterns + distinct launchd labels make
    // collisions unlikely, but a wrapper script whose argv contains both
    // names would otherwise yield two identical rows. Drop later duplicates
    // so the first-discovered label wins.
    let mut seen: std::collections::HashMap<i32, String> = std::collections::HashMap::new();
    out.retain(|(name, pid, _)| match seen.get(pid) {
        None => {
            seen.insert(*pid, name.clone());
            true
        }
        Some(kept) => {
            tracing::warn!(
                component = "activity.discover",
                kept_label = %kept,
                duplicate_label = %name,
                pid,
                "dropping duplicate pid from discovery (already discovered under another label)"
            );
            false
        }
    });

    out
}

/// Try pidfile, then `pgrep -f`, then (optionally) `launchctl list`. Emits a
/// single `tracing::debug!` when every path falls through; never warns
/// because a missing target is normal before the user starts the helper.
fn discover_one(
    target: &str,
    pidfile: &std::path::Path,
    pgrep_pattern: &str,
    launchd_label: Option<&str>,
) -> Option<i32> {
    if let Some(pid) = read_pidfile(pidfile) {
        tracing::debug!(
            component = "activity.discover",
            target,
            via = "pidfile",
            path = %pidfile.display(),
            pid,
            "discovered pid via pidfile"
        );
        return Some(pid);
    }
    if let Some(pid) = pid_from_pgrep(pgrep_pattern, target) {
        tracing::debug!(
            component = "activity.discover",
            target,
            via = "pgrep",
            pattern = pgrep_pattern,
            pid,
            "discovered pid via pgrep"
        );
        return Some(pid);
    }
    if let Some(label) = launchd_label {
        if let Some(pid) = pid_from_launchctl(label) {
            tracing::debug!(
                component = "activity.discover",
                target,
                via = "launchctl",
                label,
                pid,
                "discovered pid via launchctl"
            );
            return Some(pid);
        }
    }
    tracing::debug!(
        component = "activity.discover",
        target,
        pgrep_pattern,
        launchd_label,
        "no pid found via pidfile / pgrep / launchctl"
    );
    None
}

fn default_support_dir() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("/"))
        .join("Library/Application Support/InfiniteRecall")
}

/// Reads a single integer pid from the given file. Returns `None` if the
/// file is missing, unreadable, contains garbage, or names a dead pid.
///
/// Singleton-fixer S7: each failure mode emits a `tracing::debug!` so the
/// "why didn't we discover this pid?" question is answerable from logs.
/// `debug` (not `warn`) because pidfile-missing is normal at first launch
/// before the Swift app + mlx-lm have been started by the user.
fn read_pidfile(path: &std::path::Path) -> Option<i32> {
    let raw = match std::fs::read_to_string(path) {
        Ok(s) => s,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            tracing::debug!(
                component = "activity.discover.pidfile",
                path = %path.display(),
                reason = "missing",
                "pidfile not present"
            );
            return None;
        }
        Err(e) => {
            tracing::debug!(
                component = "activity.discover.pidfile",
                path = %path.display(),
                reason = "unreadable",
                error = %e,
                "pidfile read failed"
            );
            return None;
        }
    };
    let pid: i32 = match raw.trim().parse() {
        Ok(v) => v,
        Err(e) => {
            tracing::debug!(
                component = "activity.discover.pidfile",
                path = %path.display(),
                reason = "unparseable",
                contents = %raw.trim(),
                error = %e,
                "pidfile contents not an integer"
            );
            return None;
        }
    };
    if pid <= 0 {
        tracing::debug!(
            component = "activity.discover.pidfile",
            path = %path.display(),
            reason = "unparseable",
            pid,
            "pidfile contains non-positive pid"
        );
        return None;
    }
    if !pid_alive(pid) {
        tracing::debug!(
            component = "activity.discover.pidfile",
            path = %path.display(),
            reason = "stale",
            pid,
            "pidfile points at a dead pid"
        );
        return None;
    }
    Some(pid)
}

/// Runs `pgrep -f <pattern>` and returns the first live, non-self pid.
fn pid_from_pgrep(pattern: &str, target: &str) -> Option<i32> {
    let out = Command::new("pgrep").args(["-f", pattern]).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    parse_pgrep_pid(&stdout, std::process::id() as i32, target)
}

/// Parse newline-separated `pgrep` output. Skips our own pid (which can match
/// when the daemon was launched with the matching pattern in argv).
///
/// F4: emits a `warn!` when more than one non-self live PID matches (e.g.
/// dev + prod IR builds against the same bundle pattern). Pick semantics
/// unchanged — first match still wins.
fn parse_pgrep_pid(stdout: &str, self_pid: i32, target: &str) -> Option<i32> {
    let mut picked: Option<i32> = None;
    let mut extras: u32 = 0;
    for line in stdout.lines() {
        let Ok(pid) = line.trim().parse::<i32>() else {
            continue;
        };
        if pid > 0 && pid != self_pid && pid_alive(pid) {
            if picked.is_none() {
                picked = Some(pid);
            } else {
                extras += 1;
            }
        }
    }
    if extras > 0 {
        if let Some(pid) = picked {
            tracing::warn!(
                component = "activity.discover",
                target,
                picked_pid = pid,
                extra_matches = extras,
                "pgrep returned multiple live candidates; picking first"
            );
        }
    }
    picked
}

/// Parse newline-separated `pgrep` output, returning ALL live, non-self pids.
///
/// Sibling of `parse_pgrep_pid` — kept separate (rather than generalising the
/// existing one with a `multi: bool` flag) so each parser stays single-purpose
/// and easy to reason about. Used by the descendant tree walk.
fn parse_pgrep_pids_all(stdout: &str, self_pid: i32) -> Vec<i32> {
    let mut out = Vec::new();
    for line in stdout.lines() {
        let Ok(pid) = line.trim().parse::<i32>() else {
            continue;
        };
        if pid > 0 && pid != self_pid && pid_alive(pid) {
            out.push(pid);
        }
    }
    out
}

/// Run `pgrep -P <ppid>` and return the live, non-self direct children of
/// `ppid`. Mirrors `pid_from_pgrep` but returns every match.
fn pgrep_children(ppid: i32) -> Vec<i32> {
    let out = match Command::new("pgrep")
        .args(["-P", &ppid.to_string()])
        .output()
    {
        Ok(o) => o,
        Err(e) => {
            // Mirrors the `pid_from_pgrep` convention: emit a debug breadcrumb
            // when the `pgrep` binary itself is unspawnable so ops can tell
            // the difference between "no children" and "the feature is
            // structurally broken on this host". Not noisy: only fires when
            // the spawn itself fails, not on the (normal) no-match exit code.
            tracing::debug!(
                component = "activity.discover.descendants",
                ppid,
                error = %e,
                "pgrep -P spawn failed"
            );
            return Vec::new();
        }
    };
    let stdout = String::from_utf8_lossy(&out.stdout);
    // pgrep exits non-zero (1) when there are no matches; that's not an error.
    // Anything OTHER than 0 (success) or 1 (no matches) with empty stdout is
    // surprising — log at debug so a future regression isn't silent.
    if !out.status.success() && out.stdout.is_empty() && out.status.code() != Some(1) {
        tracing::debug!(
            component = "activity.discover.descendants",
            ppid,
            status = ?out.status,
            "pgrep -P returned unexpected non-(0|1) exit with empty stdout"
        );
    }
    parse_pgrep_pids_all(&stdout, std::process::id() as i32)
}

/// BFS the process tree rooted at `root_ppid`, returning `(pid, depth)` pairs
/// for every descendant up to `max_depth` levels deep, capped at `max_count`.
///
/// Depth 1 == direct children of `root_ppid`. The root itself is not
/// included. The `depth` is propagated to the tracing breadcrumb so log
/// readers can answer "which generation of the tree is this?" without
/// re-walking by hand.
fn descendants_of(root_ppid: i32, max_depth: usize, max_count: usize) -> Vec<(i32, usize)> {
    let mut out: Vec<(i32, usize)> = Vec::new();
    if max_depth == 0 || max_count == 0 {
        return out;
    }
    // (pid_to_walk, depth_of_its_children)
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
            out.push((child, depth));
            if depth < max_depth {
                frontier.push((child, depth + 1));
            }
        }
    }
    out
}

/// Parses `launchctl list <label>` for a `"PID" = <int>;` (legacy) or
/// `pid = N` (newer macOS) line.
fn pid_from_launchctl(label: &str) -> Option<i32> {
    let out = Command::new("launchctl")
        .args(["list", label])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    parse_launchctl_pid(&stdout)
}

/// Parse a `launchctl list <label>` stdout buffer for the service pid.
///
/// Tolerates two known formats:
///   - Legacy plist-ish:  `"PID" = 12345;`
///   - Newer key/value:   `pid = 12345`  (or `pid = 12345;`)
///
/// Singleton-fixer S7 / Broad reviewer MED-14.
fn parse_launchctl_pid(stdout: &str) -> Option<i32> {
    for line in stdout.lines() {
        let line = line.trim();

        // Legacy `"PID" = N;`
        let rest_legacy = line.strip_prefix("\"PID\"");

        // Newer `pid = N` (case-insensitive — newer launchctl prints lowercase).
        let rest_new = line
            .strip_prefix("pid")
            .or_else(|| line.strip_prefix("PID"));
        // Guard: only accept the bare-key form when the next char is `=` or
        // whitespace, so we don't grab e.g. `pidsignal = 9`.
        let rest_new = rest_new.filter(|tail| {
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
    None
}

fn pid_alive(pid: i32) -> bool {
    proc_pid::pidinfo::<TaskInfo>(pid, 0).is_ok()
}

// ---------------------------------------------------------------------------
// libproc CPU/memory sampling
// ---------------------------------------------------------------------------

/// Returns `ri_phys_footprint` (in bytes) for `pid` via `pidrusage::<RUsageInfoV4>`.
///
/// **CRITICAL: do NOT replace this body with `pidrusage::<RUsageInfoV4>(pid).map(|r| r.memory_used())`.**
/// `PIDRUsage::memory_used()` is hardcoded to return `ri_resident_size` (plain RSS),
/// which is exactly the value that motivated this fix — it excludes compressed
/// and swapped pages and under-reports MLX workers vs. Activity Monitor's
/// "Memory" column. We deliberately read `ri_phys_footprint` directly.
fn pid_phys_footprint(pid: i32) -> Option<u64> {
    match pidrusage::<RUsageInfoV4>(pid) {
        Ok(r) => Some(r.ri_phys_footprint),
        Err(e) => {
            tracing::debug!(
                component = "activity.resources",
                pid,
                error = %e,
                "pidrusage failed"
            );
            None
        }
    }
}

/// Samples CPU% and memory for each pid by reading task_info twice ~250ms apart,
/// plus one `pidrusage` call for `ri_phys_footprint`.
///
/// CPU% is computed as `(delta_user_ns + delta_sys_ns) /
/// (elapsed_ns * num_cores) * 100`. Memory is `ri_phys_footprint` from the
/// second sample window — the same metric Activity Monitor's "Memory" column
/// surfaces, so MLX worker rows align with what users see in Activity Monitor.
///
/// Pids that disappear between calls are silently dropped.
fn sample_processes(pids: &[(String, i32, Option<ProcessKind>)]) -> Vec<ProcessBreakdown> {
    if pids.is_empty() {
        return Vec::new();
    }

    let cores = num_logical_cores().max(1) as f64;

    let t0 = Instant::now();
    let first: Vec<(String, i32, Option<ProcessKind>, Option<TaskInfo>)> = pids
        .iter()
        .map(|(n, p, k)| (n.clone(), *p, *k, proc_pid::pidinfo::<TaskInfo>(*p, 0).ok()))
        .collect();

    thread::sleep(CPU_SAMPLE_WINDOW);

    let elapsed_ns = t0.elapsed().as_nanos() as f64;
    let mut out = Vec::with_capacity(first.len());
    for (name, pid, kind, before) in first {
        let Some(before) = before else { continue };
        let Ok(after) = proc_pid::pidinfo::<TaskInfo>(pid, 0) else {
            continue;
        };

        let du = after.pti_total_user.saturating_sub(before.pti_total_user) as f64;
        let ds = after
            .pti_total_system
            .saturating_sub(before.pti_total_system) as f64;
        let cpu_ns = du + ds;
        let cpu_percent = if elapsed_ns > 0.0 {
            ((cpu_ns / (elapsed_ns * cores)) * 100.0) as f32
        } else {
            0.0
        };

        // ri_phys_footprint is bytes; convert to MB (1024^2 to stay consistent
        // with Activity Monitor "Memory" column reporting). If pidrusage
        // fails between the two TaskInfo calls (PID exited), drop this row
        // for symmetry with the existing CPU-delta drop.
        let Some(phys_footprint) = pid_phys_footprint(pid) else {
            continue;
        };
        let mem_mb = (phys_footprint / (1024 * 1024)) as u32;

        // For known kinds the discovery label wins: `proc_pid::name` would
        // collapse mlx-lm and mlx-vlm to `python3.11`/`uv`, making the rows
        // indistinguishable in the UI. For untyped pids (None), keep the
        // existing OS-name-preferred behaviour.
        let display_name = if kind.is_some() {
            name
        } else {
            proc_pid::name(pid)
                .ok()
                .filter(|s| !s.is_empty())
                .unwrap_or(name)
        };

        out.push(ProcessBreakdown {
            name: display_name,
            pid,
            cpu_percent,
            mem_mb,
            kind,
        });
    }
    out
}

fn num_logical_cores() -> usize {
    // sysctl hw.ncpu — cheap, no external deps.
    let out = Command::new("sysctl").args(["-n", "hw.ncpu"]).output().ok();
    if let Some(o) = out {
        if let Ok(s) = String::from_utf8(o.stdout) {
            if let Ok(n) = s.trim().parse::<usize>() {
                return n;
            }
        }
    }
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(8)
}

// ---------------------------------------------------------------------------
// GPU
// ---------------------------------------------------------------------------

/// System-wide GPU utilisation in 0..=100 by parsing `ioreg`.
///
/// Returns `None` if ioreg fails or no `Device Utilization %` is found, so the
/// caller can honestly report "GPU: n/a" rather than 0%.
fn sample_gpu_percent() -> Option<f32> {
    let out = Command::new("ioreg")
        .args(["-r", "-c", "IOAccelerator", "-d", "1"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout);
    parse_gpu_percent(&s)
}

fn parse_gpu_percent(ioreg_stdout: &str) -> Option<f32> {
    // The PerformanceStatistics dict line embeds entries like:
    //   "Device Utilization %"=N
    // We grep for that key and pull the number after the `=`.
    for line in ioreg_stdout.lines() {
        if let Some(idx) = line.find("\"Device Utilization %\"") {
            let tail = &line[idx + "\"Device Utilization %\"".len()..];
            // tail starts with `=`, then a number, then `,` or `}`.
            let tail = tail.trim_start_matches('=').trim_start();
            let end = tail
                .find(|c: char| !(c.is_ascii_digit() || c == '.'))
                .unwrap_or(tail.len());
            if let Ok(v) = tail[..end].parse::<f32>() {
                return Some(v);
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Thermal
// ---------------------------------------------------------------------------

fn sample_thermal() -> ThermalState {
    // Try sysctl machdep.xcpm.cpu_thermal_level first; not all macs expose it.
    if let Ok(out) = Command::new("sysctl")
        .args(["-n", "machdep.xcpm.cpu_thermal_level"])
        .output()
    {
        if out.status.success() {
            if let Ok(s) = String::from_utf8(out.stdout) {
                if let Ok(level) = s.trim().parse::<u32>() {
                    return map_thermal_level(level);
                }
            }
        }
    }
    // Fall back to pmset -g therm, which prints something like
    //   "CPU_Scheduler_Limit = 100"
    //   "CPU_Available_CPUs  = N"
    if let Ok(out) = Command::new("pmset").args(["-g", "therm"]).output() {
        if out.status.success() {
            let s = String::from_utf8_lossy(&out.stdout);
            return map_pmset_therm(&s);
        }
    }
    ThermalState::Nominal
}

fn map_thermal_level(level: u32) -> ThermalState {
    // xcpm.cpu_thermal_level is roughly 0..=100 where 0 = no pressure.
    match level {
        0..=10 => ThermalState::Nominal,
        11..=40 => ThermalState::Fair,
        41..=80 => ThermalState::Serious,
        _ => ThermalState::Critical,
    }
}

fn map_pmset_therm(stdout: &str) -> ThermalState {
    // CPU_Scheduler_Limit < 100 means the OS is throttling.
    for line in stdout.lines() {
        let l = line.trim();
        if let Some(rest) = l.strip_prefix("CPU_Scheduler_Limit") {
            let rest = rest.trim_start_matches([' ', '=']).trim();
            if let Ok(limit) = rest.parse::<u32>() {
                return match limit {
                    100 => ThermalState::Nominal,
                    71..=99 => ThermalState::Fair,
                    41..=70 => ThermalState::Serious,
                    _ => ThermalState::Critical,
                };
            }
        }
    }
    ThermalState::Nominal
}

// ---------------------------------------------------------------------------
// Power (battery / low-power)
// ---------------------------------------------------------------------------

/// Consensus-fix C5 (interim): replacing `pmset` shellout with
/// `IOPSCopyPowerSourcesInfo` is the long-term goal (issue #32 follow-up).
///
/// Mixed fail-closed/fail-open policy:
/// - `on_battery` fails closed (default `true`) when parsing fails — the
///   scheduler treats unknown power state as battery to avoid running heavy
///   ML wide-open on a non-English Mac. `pmset -g batt` still works on
///   macOS 26.3, so this branch is unchanged.
/// - `low_power` fails OPEN (default `false`) when parsing fails. This field
///   is observational only — used for the Activity tab Resources card.
///   Swift's `ProcessingGateReporter` reads
///   `ProcessInfo.isLowPowerModeEnabled` for the actual gate decision.
///   Issue #49: macOS 15+ renamed `lowpowermode` → `powermode`, so the
///   legacy parse failed every ~3s. The WARN is now rate-limited to
///   once-per-process via `warn_low_power_parse_once`.
fn sample_power() -> (bool, bool) {
    let on_battery = match Command::new("pmset").args(["-g", "batt"]).output() {
        Ok(o) if o.status.success() => {
            let s = String::from_utf8_lossy(&o.stdout);
            match parse_on_battery_safe(&s) {
                Some(v) => v,
                None => {
                    tracing::warn!(
                        component = "activity.resources.power",
                        "pmset -g batt output not recognised — failing closed (on_battery=true)"
                    );
                    true
                }
            }
        }
        other => {
            tracing::warn!(
                component = "activity.resources.power",
                status = ?other.as_ref().map(|o| o.status),
                "pmset -g batt failed — failing closed (on_battery=true)"
            );
            true
        }
    };
    let low_power = match Command::new("pmset").args(["-g"]).output() {
        Ok(o) if o.status.success() => {
            let s = String::from_utf8_lossy(&o.stdout);
            match parse_low_power_safe(&s) {
                Some(v) => v,
                None => {
                    warn_low_power_parse_once(
                        "pmset -g output missing powermode/lowpowermode — failing open (low_power=false). Real gate uses Swift ProcessInfo.isLowPowerModeEnabled.",
                    );
                    // Fail open: this field is observational for the Activity tab
                    // Resources card. Swift's ProcessingGateReporter reads
                    // ProcessInfo.isLowPowerModeEnabled for the actual gate decision.
                    false
                }
            }
        }
        other => {
            warn_low_power_parse_once(
                &format!(
                    "pmset -g failed (status={:?}) — failing open (low_power=false). Real gate uses Swift ProcessInfo.isLowPowerModeEnabled.",
                    other.as_ref().map(|o| o.status)
                ),
            );
            // Fail open: see comment above.
            false
        }
    };
    (on_battery, low_power)
}

/// Emit the low-power parse-failure warning at most once per process.
/// Without this guard the WARN fires every ~3s on macOS 15+ where the
/// pmset key was renamed from `lowpowermode` to `powermode` (issue #49).
fn warn_low_power_parse_once(msg: &str) {
    static WARNED: AtomicBool = AtomicBool::new(false);
    if WARNED
        .compare_exchange(false, true, Ordering::Relaxed, Ordering::Relaxed)
        .is_ok()
    {
        tracing::warn!(component = "activity.resources.power", "{}", msg);
    }
}

/// Parse the first line of `pmset -g batt`. Returns `None` (→ fail-closed)
/// when the English literals "Battery Power" / "AC Power" are absent
/// (locale shifted, format change, etc.).
fn parse_on_battery_safe(stdout: &str) -> Option<bool> {
    for line in stdout.lines() {
        if line.contains("Battery Power") {
            return Some(true);
        }
        if line.contains("AC Power") {
            return Some(false);
        }
    }
    None
}

/// Parse `pmset -g` for the power-mode field. Returns `None` when neither
/// key is present (caller decides fail-open vs fail-closed).
///
/// macOS 15 (Sequoia) and 26 (Tahoe) renamed `lowpowermode` → `powermode`
/// and widened it to a tri-state:
///
/// * `powermode 0` = Automatic / normal
/// * `powermode 1` = Low Power Mode
/// * `powermode 2` = High Power Mode (MBP 16" M-series only)
///
/// Older macOS still emits `lowpowermode 0` / `lowpowermode 1`.
///
/// We prefer the new key when both appear so a transitional pmset (or a
/// bug Apple hasn't shipped yet) doesn't fool us with stale legacy data.
/// Only `powermode 1` counts as low power — `powermode 2` is high power
/// and must not light up the "Low Power" indicator.
fn parse_low_power_safe(stdout: &str) -> Option<bool> {
    let mut legacy: Option<bool> = None;
    for line in stdout.lines() {
        let l = line.trim();
        // Try the new key first; if both appear we trust `powermode`.
        if let Some(rest) = l.strip_prefix("powermode") {
            let rest = rest.trim_start_matches([' ', '=']).trim();
            if let Ok(v) = rest.parse::<u32>() {
                return Some(v == 1);
            }
        } else if let Some(rest) = l.strip_prefix("lowpowermode") {
            let rest = rest.trim_start_matches([' ', '=']).trim();
            if let Ok(v) = rest.parse::<u32>() {
                legacy = Some(v != 0);
            }
        }
    }
    legacy
}

// Legacy non-safe wrappers retained for the unit tests asserting default
// behaviour. on_battery still fails closed (None → true); low_power now
// fails open (None → false) per issue #49.
#[cfg(test)]
fn parse_on_battery(stdout: &str) -> bool {
    parse_on_battery_safe(stdout).unwrap_or(true)
}

// Issue #49: low-power now fails open (the field is observational; Swift's
// ProcessInfo.isLowPowerModeEnabled is the real gate). Legacy on-battery
// still fails closed since `pmset -g batt` works on macOS 26.3.
#[cfg(test)]
fn parse_low_power(stdout: &str) -> bool {
    parse_low_power_safe(stdout).unwrap_or(false)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// Exercises pidfile precedence in isolation from host pgrep/launchctl
    /// state by probing `discover_one` once per known label.
    #[test]
    fn pidfile_happy_path() {
        let tmp = tempdir();
        let me = std::process::id() as i32;
        let cases: &[(&str, &str, &str, Option<&str>)] = &[
            ("swift", "swift.pid", SWIFT_PGREP_PATTERN, None),
            ("mlx", "mlxlm.pid", MLX_PGREP_PATTERN, Some(MLX_LAUNCHD_LABEL)),
            (
                "mlx-vlm",
                MLX_VLM_PIDFILE,
                MLX_VLM_PGREP_PATTERN,
                Some(MLX_VLM_LAUNCHD_LABEL),
            ),
        ];
        for (target, pidfile_name, pgrep, launchd) in cases {
            let pidfile = tmp.join(pidfile_name);
            fs::write(&pidfile, me.to_string()).unwrap();
            let pid = discover_one(target, &pidfile, pgrep, *launchd);
            assert_eq!(pid, Some(me), "discover_one({target}) should pick pidfile");
            fs::remove_file(&pidfile).unwrap();
        }
    }

    /// Dedupe path: when mlx-lm and mlx-vlm both resolve to the same pid
    /// (e.g. an argv that mentions both names so an unanchored pgrep
    /// double-matches), only one row is emitted.
    ///
    /// Note: descendant expansion (added for the model-worker undercount fix)
    /// may legitimately add additional rows for children of `me`. We only
    /// assert that pids never duplicate, and that the api-self row collapses
    /// to a single entry (no row for `me` appears more than once even though
    /// 4 labels initially pointed at it).
    #[test]
    fn discover_dedupes_colliding_pids() {
        let tmp = tempdir();
        let me = std::process::id() as i32;
        // All four labels (api, swift, mlx-lm, mlx-vlm) resolve to `me`
        // via pidfile or the implicit api self-pid. Dedupe must collapse
        // them to a single row for `me`, and every row's pid must be unique.
        fs::write(tmp.join("swift.pid"), me.to_string()).unwrap();
        fs::write(tmp.join("mlxlm.pid"), me.to_string()).unwrap();
        fs::write(tmp.join(MLX_VLM_PIDFILE), me.to_string()).unwrap();

        let pids = discover_pids(Some(&tmp));
        let unique: std::collections::HashSet<i32> = pids.iter().map(|(_, p, _)| *p).collect();
        assert_eq!(unique.len(), pids.len(), "no duplicate pids allowed");
        let me_count = pids.iter().filter(|(_, p, _)| *p == me).count();
        assert_eq!(me_count, 1, "the colliding self-pid row must dedupe to 1");
    }

    /// PID-not-found: empty support dir + no launchctl labels matching means
    /// only `self` shows up. discover_pids must not panic, and the resulting
    /// `sample()` must be valid (cpu_percent = self only, no missing-process
    /// errors).
    #[test]
    fn pid_not_found_returns_self_only() {
        let tmp = tempdir();
        // No pidfiles. Discovery falls back to launchctl with deliberately
        // unlikely candidate labels — almost certainly nothing matches.
        let pids = discover_pids(Some(&tmp));
        // `self` is always there.
        assert!(pids.iter().any(|(n, _, _)| n == "api"));

        // sample() with the same support dir override must succeed even when
        // only the self pid is present.
        let s = SystemResourceSampler::with_support_dir(tmp);
        let sample = s.sample();
        assert!(!sample.process_breakdown.is_empty());
    }

    /// Cache TTL: two back-to-back samples must return the exact same struct
    /// (same generated-at + same per-pid numbers) because the second call
    /// short-circuits on the cache.
    #[test]
    fn cache_prevents_back_to_back_resample() {
        let me = std::process::id() as i32;
        let s = SystemResourceSampler::with_pids(vec![(
            "api".to_string(),
            me,
            Some(ProcessKind::Core),
        )]);

        let a = s.sample();
        let t = Instant::now();
        let b = s.sample();
        assert!(
            t.elapsed() < Duration::from_millis(50),
            "cached sample should be near-instant; took {:?}",
            t.elapsed()
        );
        // process_breakdown is identical because we returned the cached clone.
        assert_eq!(a.process_breakdown.len(), b.process_breakdown.len());
        assert_eq!(a.process_breakdown[0].pid, b.process_breakdown[0].pid);
        assert_eq!(a.process_breakdown[0].mem_mb, b.process_breakdown[0].mem_mb);
        assert!((a.cpu_percent - b.cpu_percent).abs() < f32::EPSILON);
    }

    /// `pgrep` returned a single pid for our own process — discovery must
    /// reject it so we never double-count the daemon as the Swift app.
    #[test]
    fn pgrep_skips_self_pid() {
        let me = std::process::id() as i32;
        assert_eq!(parse_pgrep_pid(&format!("{me}\n"), me, "swift"), None);
    }

    /// First live non-self pid in the buffer wins. Garbage lines are skipped.
    #[test]
    fn pgrep_returns_first_live_non_self() {
        let me = std::process::id() as i32;
        assert_eq!(parse_pgrep_pid("", me, "swift"), None);
        // Self filter skips every match.
        assert_eq!(parse_pgrep_pid(&format!("{me}\n{me}\n"), me, "swift"), None);
        // A garbage line is skipped, then our (live) pid is returned when we
        // pretend to be discovering "from" a different self pid.
        let other_self = me + 1;
        let buf = format!("not-a-pid\n{me}\n");
        assert_eq!(parse_pgrep_pid(&buf, other_self, "swift"), Some(me));
    }

    /// F4: when `pgrep` returns multiple live non-self pids (dev + prod IR
    /// builds matching the same bundle pattern), pick the first and warn.
    #[test]
    fn pgrep_multi_match_picks_first() {
        let me = std::process::id() as i32;
        let other_self = me + 1;
        let buf = format!("{me}\n{me}\n");
        assert_eq!(
            parse_pgrep_pid(&buf, other_self, "swift"),
            Some(me),
            "first live non-self pid wins"
        );
        // TODO: assert warn when log capture available
    }

    #[test]
    fn parses_launchctl_pid_line() {
        let stdout = r#"{
	"LimitLoadToSessionType" = "Aqua";
	"Label" = "com.infiniterecall.mlx";
	"OnDemand" = false;
	"LastExitStatus" = 0;
	"PID" = 12345;
	"Program" = "/opt/homebrew/bin/uv";
};"#;
        assert_eq!(parse_launchctl_pid(stdout), Some(12345));
    }

    #[test]
    fn parses_launchctl_pid_missing() {
        let stdout = r#"{ "Label" = "x"; }"#;
        assert_eq!(parse_launchctl_pid(stdout), None);
    }

    /// Singleton-fixer S7 / Broad reviewer MED-14: tolerate the newer
    /// `launchctl print` / `launchctl list` lowercase-key format. Without
    /// this, after Apple flips the format the next contributor sees pid
    /// discovery silently regressing to "self-only" with zero log signal.
    #[test]
    fn parses_launchctl_pid_new_format() {
        let stdout = "  pid = 12345\n  state = running\n";
        assert_eq!(parse_launchctl_pid(stdout), Some(12345));
        // Trailing semicolon variant.
        let stdout2 = "pid = 6789;";
        assert_eq!(parse_launchctl_pid(stdout2), Some(6789));
        // Must not match e.g. `pidsignal = 9` — that's a different field.
        let stdout3 = "pidsignal = 9";
        assert_eq!(parse_launchctl_pid(stdout3), None);
    }

    #[test]
    fn parses_gpu_percent_from_ioreg() {
        let stdout = r#"      "PerformanceStatistics" = {"In use system memory (driver)"=0,"Tiler Utilization %"=0,"Renderer Utilization %"=4,"Device Utilization %"=37,"In use system memory"=12345}"#;
        assert_eq!(parse_gpu_percent(stdout), Some(37.0));
    }

    #[test]
    fn parses_gpu_percent_missing_returns_none() {
        let stdout = "no such field anywhere";
        assert_eq!(parse_gpu_percent(stdout), None);
    }

    #[test]
    fn parses_pmset_battery() {
        // Recognised English literals → exact value.
        assert_eq!(
            parse_on_battery_safe("Now drawing from 'Battery Power'\n -InternalBattery-0	75%"),
            Some(true)
        );
        assert_eq!(
            parse_on_battery_safe("Now drawing from 'AC Power'\n -InternalBattery-0	100%"),
            Some(false)
        );
        // Unrecognised → None (caller fails closed).
        assert_eq!(parse_on_battery_safe("Source: 'Réseau'"), None);
    }

    /// Legacy macOS (≤14) emits `lowpowermode N`. Keep parsing it.
    #[test]
    fn parses_low_power_mode() {
        assert_eq!(
            parse_low_power_safe(" lowpowermode         1\n other line"),
            Some(true)
        );
        assert_eq!(
            parse_low_power_safe(" lowpowermode         0\n other line"),
            Some(false)
        );
        // Missing → None (caller decides default).
        assert_eq!(parse_low_power_safe("nothing here"), None);
    }

    /// Issue #49: macOS 15 (Sequoia) and 26 (Tahoe) renamed the field to
    /// `powermode` and widened it to a tri-state. Only `1` is Low Power;
    /// `2` is High Power and must NOT light the LPM indicator.
    #[test]
    fn parses_powermode_mac15() {
        assert_eq!(
            parse_low_power_safe(" powermode            1\n other"),
            Some(true)
        );
        assert_eq!(
            parse_low_power_safe(" powermode            0\n other"),
            Some(false)
        );
        assert_eq!(
            parse_low_power_safe(" powermode            2\n other"),
            Some(false)
        );
    }

    /// During the OS upgrade transition Apple could ship a build that emits
    /// both keys. Trust the new one.
    #[test]
    fn prefers_powermode_when_both_present() {
        let stdout = " lowpowermode         1\n powermode            0\n";
        assert_eq!(parse_low_power_safe(stdout), Some(false));
        let stdout2 = " powermode            1\n lowpowermode         0\n";
        assert_eq!(parse_low_power_safe(stdout2), Some(true));
    }

    /// Issue #49: low-power now fails OPEN — the field is observational
    /// (Activity tab Resources card only). Swift's
    /// ProcessInfo.isLowPowerModeEnabled is the actual gate. on_battery
    /// still fails closed because `pmset -g batt` works on macOS 26.3.
    #[test]
    fn unrecognised_pmset_output_fails_open() {
        assert!(parse_on_battery("nothing useful")); // legacy wrapper, still fail-closed
        assert!(!parse_low_power("nothing useful")); // legacy wrapper, now fail-open
    }

    #[test]
    fn malformed_powermode_value_returns_none() {
        // Issue #49 hardening: future-proofing — if Apple ever ships
        // `powermode High` (string instead of u32), we must not lie.
        assert_eq!(parse_low_power_safe(" powermode  High\n"), None);
        assert_eq!(parse_low_power_safe("powermode\n"), None);
        assert_eq!(parse_low_power_safe("powermode -1\n"), None);
    }

    #[test]
    fn malformed_powermode_falls_through_to_legacy() {
        // If Apple ships a transitional pmset where `powermode` is garbage but
        // legacy `lowpowermode` still emits, we must honour the legacy value.
        assert_eq!(
            parse_low_power_safe("powermode garbage\nlowpowermode 1\n"),
            Some(true),
        );
        assert_eq!(
            parse_low_power_safe("lowpowermode 1\npowermode garbage\n"),
            Some(true),
        );
    }

    /// Issue #49: real `pmset -g` output captured on macOS 26.3 (build 25D125),
    /// M-series, AC power, LPM off. `powermode 0` must parse as Some(false).
    #[test]
    fn parses_real_mac26_pmset_g_fixture() {
        const FIXTURE: &str = r#"System-wide power settings:
Currently in use:
 standby              1
 Sleep On Power Button 1
 SleepServices        0
 hibernatefile        /var/vm/sleepimage
 powernap             0
 networkoversleep     0
 disksleep            0
 sleep                0
 hibernatemode        3
 ttyskeepawake        1
 displaysleep         30
 tcpkeepalive         1
 powermode            0
 womp                 1
"#;
        assert_eq!(parse_low_power_safe(FIXTURE), Some(false));
    }

    #[test]
    fn maps_thermal_levels() {
        assert!(matches!(map_thermal_level(0), ThermalState::Nominal));
        assert!(matches!(map_thermal_level(20), ThermalState::Fair));
        assert!(matches!(map_thermal_level(60), ThermalState::Serious));
        assert!(matches!(map_thermal_level(95), ThermalState::Critical));
    }

    /// Manual smoke: prints a real on-machine sample as JSON so PR reviewers
    /// can paste verification output. Skipped by default so CI on non-mac
    /// runners stays green. Run with:
    ///   cargo test smoke_print -- --ignored --nocapture
    #[test]
    #[ignore]
    fn smoke_print() {
        let s = SystemResourceSampler::new();
        let sample = s.sample();
        println!("{}", serde_json::to_string_pretty(&sample).unwrap());
    }

    /// `parse_pgrep_pids_all` must drop self, non-positive pids, and garbage
    /// while keeping live foreign pids. We can't use `1` (launchd) as the
    /// always-alive fixture because `proc_pid::pidinfo` requires permission
    /// the test runner doesn't have for it; spawn our own short-lived child
    /// instead. Killed before assertions so a panic can't leak it.
    #[test]
    fn parse_pgrep_pids_all_filters_self_and_dead() {
        let me = std::process::id() as i32;
        let mut child = std::process::Command::new("sleep")
            .arg("30")
            .spawn()
            .expect("spawn sleep");
        let live_other = child.id() as i32;
        // Give the child a moment to register so pid_alive sees it.
        std::thread::sleep(Duration::from_millis(50));

        let buf = format!("{me}\n0\nnot-a-pid\n{live_other}\n");
        let pids = parse_pgrep_pids_all(&buf, me);

        // Tear down BEFORE assertions so panic-on-fail can't leak the child.
        let _ = child.kill();
        let _ = child.wait();

        assert!(!pids.contains(&me), "must filter self pid");
        assert!(!pids.contains(&0), "must filter non-positive pid");
        assert!(
            pids.contains(&live_other),
            "must keep live non-self pid {live_other}"
        );
    }

    /// Spawn a 2-deep `sh` tree of `sleep` processes and assert
    /// `descendants_of` returns at least one descendant with depth in 1..=4.
    /// Children are killed BEFORE the assertions so a failed assert doesn't
    /// leak sleeping processes onto the host.
    #[test]
    fn descendants_of_walks_real_tree() {
        // sh -c 'sleep 30 & sleep 30 & wait' — parent sh forks two sleeps,
        // giving us a 2-level tree (sh -> sleep, sh -> sleep).
        let mut child = std::process::Command::new("sh")
            .args(["-c", "sleep 30 & sleep 30 & wait"])
            .spawn()
            .expect("spawn sh tree");
        let parent_pid = child.id() as i32;

        // Poll up to ~2s for pgrep -P to see the children. On a loaded CI
        // machine the old fixed 200ms warmup was occasionally too short.
        let descendants = poll_descendants(parent_pid, 4, 16, Duration::from_secs(2));

        // Tear down BEFORE asserting so a panic can't leave 30s sleeps around.
        // child.kill() only SIGKILLs the `sh`; the `sleep 30` grandchildren
        // would reparent to launchd and linger. `pkill -P <sh-pid>` first so
        // the whole tree dies together (portable across macOS/Linux test
        // hosts; no `nix` dep needed).
        let _ = std::process::Command::new("pkill")
            .args(["-P", &parent_pid.to_string()])
            .status();
        let _ = child.kill();
        let _ = child.wait();

        assert!(
            !descendants.is_empty(),
            "expected at least one descendant of the spawned sh tree within 2s"
        );
        for (pid, depth) in &descendants {
            assert!(*pid > 0, "descendant pid must be positive: {pid}");
            assert!(
                (1..=4).contains(depth),
                "descendant depth out of bounds: {depth}"
            );
        }
    }

    /// Poll `descendants_of` up to `timeout`, sleeping 50ms between calls,
    /// returning the first non-empty result (or the final empty result on
    /// timeout). Used by tests that race against `pgrep -P` propagation
    /// after spawning a fresh tree.
    fn poll_descendants(
        root_ppid: i32,
        max_depth: usize,
        max_count: usize,
        timeout: Duration,
    ) -> Vec<(i32, usize)> {
        let start = Instant::now();
        loop {
            let d = descendants_of(root_ppid, max_depth, max_count);
            if !d.is_empty() {
                return d;
            }
            if start.elapsed() >= timeout {
                return d;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// `descendants_of` must respect `max_count`. Calling against the test
    /// process itself (which may have arbitrary children) with a tight cap
    /// must not exceed it.
    #[test]
    fn descendants_caps_respected() {
        let me = std::process::id() as i32;
        let descendants = descendants_of(me, 4, 3);
        assert!(
            descendants.len() <= 3,
            "max_count=3 violated: got {} entries",
            descendants.len()
        );
    }

    /// `max_depth` cap must actually clip the BFS frontier. Spawn a 5-level
    /// nested `sh` tree and assert `descendants_of(.., max_depth=3, ..)`
    /// returns no entry with depth > 3.
    ///
    /// The 2-level test above (`descendants_of_walks_real_tree`) is too
    /// shallow to prove this — caps of 4, 40, or unbounded would all pass it.
    #[test]
    fn descendants_of_respects_max_depth() {
        // 5 nested shells, each running `sleep 30 & wait` so the parent at
        // every level has a child the next level can fork from. The deepest
        // grandchild sleeps; `wait` propagates up so killing the outermost
        // sh tears the whole tree down (and we pkill -P as belt-and-braces).
        //
        // sh -c 'sh -c "sh -c \"sh -c \\\"sh -c \\\\\\\"sleep 30 & wait\\\\\\\" & wait\\\" & wait\" & wait' & wait'
        // — that's painful to escape; we use a simpler pattern with explicit
        // backgrounding at each level via repeated nested invocations.
        let script = "sh -c 'sh -c \"sh -c \\\"sh -c \\\\\\\"sleep 30\\\\\\\" & wait\\\" & wait\" & wait' & wait";
        let mut child = std::process::Command::new("sh")
            .args(["-c", script])
            .spawn()
            .expect("spawn deeply nested sh tree");
        let parent_pid = child.id() as i32;

        // Poll up to 3s for the deeper levels to come up — each nested `sh`
        // has to fork before the next layer is visible.
        let start = Instant::now();
        let timeout = Duration::from_secs(3);
        let max_depth = 3;
        // Loop until we observe at least one depth==max_depth entry, OR time
        // out. Either way, the assertion below ("no depth > max_depth") is
        // what proves the cap; the wait just makes the test more meaningful
        // (we want to see the cap actually clip, not vacuously pass).
        let descendants = loop {
            let d = descendants_of(parent_pid, max_depth, 64);
            if d.iter().any(|(_, depth)| *depth == max_depth) {
                break d;
            }
            if start.elapsed() >= timeout {
                break d;
            }
            std::thread::sleep(Duration::from_millis(50));
        };

        // Tear down the WHOLE tree before asserting. pkill -P only catches
        // direct children, but child.kill() + the chained `wait`s (and
        // SIGTERM-on-pgrp the OS does for orphans of a killed shell) handle
        // the deeper layers. Repeat pkill once more after killing the root
        // to mop up reparented sleeps.
        let _ = std::process::Command::new("pkill")
            .args(["-P", &parent_pid.to_string()])
            .status();
        let _ = child.kill();
        let _ = child.wait();
        // Best-effort sweep: any `sleep 30` orphaned to launchd from this
        // test will self-exit in 30s, but pkill against the literal command
        // is too aggressive (would kill unrelated host sleeps), so we accept
        // the eventual self-cleanup.

        for (pid, depth) in &descendants {
            assert!(
                *depth <= max_depth,
                "depth cap violated: pid={pid} depth={depth} max={max_depth}"
            );
        }
        // Sanity: we should at least see SOMETHING from this tree in 3s,
        // otherwise the test is degenerate (proves nothing). If this is
        // flaky on CI, the test is providing zero value — fail loudly.
        assert!(
            !descendants.is_empty(),
            "expected at least one descendant from a 5-level sh tree within 3s"
        );
    }

    /// End-to-end: a real `LocalModel` root pidfile + descendants_of splice
    /// in `discover_pids` must produce a row for the root AND at least one
    /// "<root> child" row whose pid is the spawned descendant. Without this
    /// the helpers can each be correct in isolation but the splice could
    /// regress (wrong filter, wrong label, etc.) silently.
    #[test]
    fn discover_pids_walks_local_model_descendants() {
        let tmp = tempdir();

        // Spawn `sh -c 'sleep 30 & wait'` — a 2-level tree where the sh is
        // the LocalModel "root" and the sleep is its descendant.
        let mut child = std::process::Command::new("sh")
            .args(["-c", "sleep 30 & wait"])
            .spawn()
            .expect("spawn sh root");
        let root_pid = child.id() as i32;

        // Stamp the spawned root pid into the mlxlm.pid file so discover_one
        // resolves "mlx-lm" via the pidfile path (skipping pgrep/launchctl).
        fs::write(tmp.join("mlxlm.pid"), root_pid.to_string()).unwrap();

        // Poll up to ~2s for pgrep -P to register the child sleep. We call
        // discover_pids each iteration because that's the actual behaviour
        // we're verifying, not just descendants_of.
        let start = Instant::now();
        let timeout = Duration::from_secs(2);
        let pids = loop {
            let pids = discover_pids(Some(&tmp));
            let saw_child = pids
                .iter()
                .any(|(name, _, _)| name == "mlx-lm child");
            if saw_child || start.elapsed() >= timeout {
                break pids;
            }
            std::thread::sleep(Duration::from_millis(50));
        };

        // Tear down BEFORE assertions. pkill -P first so the sleep doesn't
        // reparent to launchd; then SIGKILL the sh.
        let _ = std::process::Command::new("pkill")
            .args(["-P", &root_pid.to_string()])
            .status();
        let _ = child.kill();
        let _ = child.wait();

        // (a) the root row, labelled "mlx-lm", kind LocalModel.
        let root_row = pids
            .iter()
            .find(|(name, p, _)| name == "mlx-lm" && *p == root_pid);
        assert!(
            root_row.is_some(),
            "expected a 'mlx-lm' row at pid {root_pid}; got {pids:?}"
        );
        assert_eq!(
            root_row.unwrap().2,
            Some(ProcessKind::LocalModel),
            "root row must be tagged LocalModel"
        );

        // (b) at least one descendant row, labelled "mlx-lm child", kind
        // LocalModel, whose pid is NOT the root.
        let child_rows: Vec<_> = pids
            .iter()
            .filter(|(name, p, kind)| {
                name == "mlx-lm child"
                    && *p != root_pid
                    && *kind == Some(ProcessKind::LocalModel)
            })
            .collect();
        assert!(
            !child_rows.is_empty(),
            "expected at least one 'mlx-lm child' row in {pids:?}"
        );
    }

    /// Regression: `mem_mb` must come from `ri_phys_footprint` (matches
    /// Activity Monitor "Memory" column), not `ri_resident_size`. Sampling
    /// our own pid must yield a strictly positive footprint and a sane
    /// upper bound — a test process should never report >64 GiB. We do
    /// NOT cross-check against `getrusage(RUSAGE_SELF).ru_maxrss`: on
    /// macOS that's bytes-not-KB and reports peak-not-current, so it's
    /// the wrong oracle.
    #[test]
    fn mem_mb_uses_phys_footprint_for_self_pid() {
        let me = std::process::id() as i32;
        let breakdown = sample_processes(&[("self".to_string(), me, Some(ProcessKind::Core))]);
        assert_eq!(breakdown.len(), 1, "expected exactly one row for self");
        let row = &breakdown[0];
        assert!(
            row.mem_mb > 0,
            "phys_footprint sampled to 0 MB — likely the wrong field is being read"
        );
        assert!(
            row.mem_mb < 65_536,
            "phys_footprint of {} MB exceeds the 64 GiB sanity ceiling for the test process",
            row.mem_mb
        );

        // And independently confirm the underlying helper agrees with libproc.
        let footprint = pid_phys_footprint(me).expect("pidrusage must succeed for self");
        assert!(footprint > 0, "ri_phys_footprint must be > 0 for live self");
    }

    /// Helper: unique tempdir under env::temp_dir.
    fn tempdir() -> PathBuf {
        let p = std::env::temp_dir().join(format!(
            "ir-stream-c-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&p).unwrap();
        p
    }
}
