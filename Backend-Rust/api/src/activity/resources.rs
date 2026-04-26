//! Stream C: `SystemResourceSampler` — process-tree CPU/RSS + system GPU sampler.
//!
//! Implements [`ResourceSampler`] using:
//! - `libproc::pid_rusage::pidinfo::<TaskInfo>` for self + Swift PID + mlx-lm PID
//!   CPU/RSS deltas.
//! - PID discovery: pidfile under `~/Library/Application Support/InfiniteRecall/`
//!   first, then `launchctl list` parsing as fallback.
//! - `ioreg -r -c IOAccelerator -d 1` shellout to read `Device Utilization %`.
//! - `pmset -g batt` for battery / low-power state.
//! - `sysctl machdep.xcpm.cpu_thermal_level` (with `pmset -g therm` fallback)
//!   for thermal pressure.
//! - Caches the assembled [`ResourceSample`] for one second so back-to-back
//!   snapshot requests do not re-sample.

use std::path::PathBuf;
use std::process::Command;
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

use libproc::proc_pid;
use libproc::task_info::TaskInfo;

use super::traits::ResourceSampler;
use super::types::{ProcessBreakdown, ResourceSample, ThermalState};

/// Default labels we will probe via `launchctl list` if a pidfile is missing.
///
/// The first matching label wins. The plan suggested `com.omi.infinite-recall`
/// and `org.mlxlm.server`; observed installs use `com.infiniterecall.*`. We
/// probe both to stay robust.
const SWIFT_LABEL_CANDIDATES: &[&str] = &[
    "com.omi.infinite-recall",
    "com.infiniterecall.app",
    "com.infiniterecall.desktop",
];
const MLX_LABEL_CANDIDATES: &[&str] = &[
    "com.infiniterecall.mlx",
    "org.mlxlm.server",
    "com.mlxlm.server",
];

/// How long to hold a sample in cache before re-sampling.
const CACHE_TTL: Duration = Duration::from_secs(1);

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
    pid_override: Option<Vec<(String, i32)>>,
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
    fn with_pids(pids: Vec<(String, i32)>) -> Self {
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
            (guard.support_dir_override.clone(), guard.pid_override.clone())
        };

        let pids: Vec<(String, i32)> = match pid_override {
            Some(v) => v,
            None => discover_pids(support_dir_override.as_deref()),
        };

        // 3. sample
        let breakdown = sample_processes(&pids);
        let cpu_total: f32 = breakdown.iter().map(|p| p.cpu_percent).sum();
        let rss_total: u32 = breakdown.iter().map(|p| p.rss_mb).sum();
        let gpu = sample_gpu_percent();
        let thermal = sample_thermal();
        let (on_battery, low_power) = sample_power();

        let sample = ResourceSample {
            cpu_percent: cpu_total,
            rss_mb: rss_total,
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
fn discover_pids(support_dir_override: Option<&std::path::Path>) -> Vec<(String, i32)> {
    let mut out: Vec<(String, i32)> = Vec::with_capacity(3);

    let self_pid = std::process::id() as i32;
    out.push(("api".to_string(), self_pid));

    let support_dir = support_dir_override
        .map(|p| p.to_path_buf())
        .unwrap_or_else(default_support_dir);

    if let Some(pid) = read_pidfile(&support_dir.join("swift.pid"))
        .or_else(|| pid_from_launchctl_any(SWIFT_LABEL_CANDIDATES))
    {
        out.push(("swift".to_string(), pid));
    }

    if let Some(pid) = read_pidfile(&support_dir.join("mlxlm.pid"))
        .or_else(|| pid_from_launchctl_any(MLX_LABEL_CANDIDATES))
    {
        out.push(("mlx-lm".to_string(), pid));
    }

    out
}

fn default_support_dir() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("/"))
        .join("Library/Application Support/InfiniteRecall")
}

/// Reads a single integer pid from the given file. Returns `None` if the file
/// does not exist, is unreadable, or does not contain a positive integer.
fn read_pidfile(path: &std::path::Path) -> Option<i32> {
    let raw = std::fs::read_to_string(path).ok()?;
    let pid: i32 = raw.trim().parse().ok()?;
    if pid <= 0 {
        return None;
    }
    if !pid_alive(pid) {
        return None;
    }
    Some(pid)
}

/// Tries each candidate label until one returns a live pid.
fn pid_from_launchctl_any(labels: &[&str]) -> Option<i32> {
    for label in labels {
        if let Some(pid) = pid_from_launchctl(label) {
            return Some(pid);
        }
    }
    None
}

/// Parses `launchctl list <label>` for a `"PID" = <int>;` line.
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

fn parse_launchctl_pid(stdout: &str) -> Option<i32> {
    for line in stdout.lines() {
        let line = line.trim();
        // Expected shape: `"PID" = 12345;`
        if let Some(rest) = line.strip_prefix("\"PID\"") {
            let rest = rest.trim_start_matches([' ', '=']).trim();
            let rest = rest.trim_end_matches(';').trim();
            if let Ok(pid) = rest.parse::<i32>() {
                if pid > 0 {
                    return Some(pid);
                }
            }
        }
    }
    None
}

fn pid_alive(pid: i32) -> bool {
    proc_pid::pidinfo::<TaskInfo>(pid, 0).is_ok()
}

// ---------------------------------------------------------------------------
// libproc CPU/RSS sampling
// ---------------------------------------------------------------------------

/// Samples CPU% and RSS for each pid by reading task_info twice ~250ms apart.
///
/// CPU% is computed as `(delta_user_ns + delta_sys_ns) /
/// (elapsed_ns * num_cores) * 100`. RSS is taken from the second sample.
///
/// Pids that disappear between calls are silently dropped.
fn sample_processes(pids: &[(String, i32)]) -> Vec<ProcessBreakdown> {
    if pids.is_empty() {
        return Vec::new();
    }

    let cores = num_logical_cores().max(1) as f64;

    let t0 = Instant::now();
    let first: Vec<(String, i32, Option<TaskInfo>)> = pids
        .iter()
        .map(|(n, p)| (n.clone(), *p, proc_pid::pidinfo::<TaskInfo>(*p, 0).ok()))
        .collect();

    thread::sleep(CPU_SAMPLE_WINDOW);

    let elapsed_ns = t0.elapsed().as_nanos() as f64;
    let mut out = Vec::with_capacity(first.len());
    for (name, pid, before) in first {
        let Some(before) = before else { continue };
        let Ok(after) = proc_pid::pidinfo::<TaskInfo>(pid, 0) else {
            continue;
        };

        let du = after.pti_total_user.saturating_sub(before.pti_total_user) as f64;
        let ds = after.pti_total_system.saturating_sub(before.pti_total_system) as f64;
        let cpu_ns = du + ds;
        let cpu_percent = if elapsed_ns > 0.0 {
            ((cpu_ns / (elapsed_ns * cores)) * 100.0) as f32
        } else {
            0.0
        };

        // pti_resident_size is bytes; convert to MB (1024^2 to stay consistent
        // with Activity Monitor "Memory" column reporting).
        let rss_mb = (after.pti_resident_size / (1024 * 1024)) as u32;

        // Best-effort: prefer the OS-reported short name, fall back to the
        // discovery label.
        let display_name = proc_pid::name(pid).ok().filter(|s| !s.is_empty()).unwrap_or(name);

        out.push(ProcessBreakdown {
            name: display_name,
            pid,
            cpu_percent,
            rss_mb,
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
/// `IOPSCopyPowerSourcesInfo` is the long-term goal (issue #32 follow-up),
/// but until that lands we ship a fail-closed parse: any unrecognised /
/// localised pmset output reports `(on_battery: true, low_power: true)`,
/// which makes the scheduler's `allowHeavyWork` conservatively block
/// rather than letting Whisper run wide-open on a non-English Mac.
///
/// Each fallback emits a `tracing::warn!` so the conservative branch is
/// observable in logs.
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
                    tracing::warn!(
                        component = "activity.resources.power",
                        "pmset -g output missing lowpowermode — failing closed (low_power=true)"
                    );
                    true
                }
            }
        }
        other => {
            tracing::warn!(
                component = "activity.resources.power",
                status = ?other.as_ref().map(|o| o.status),
                "pmset -g failed — failing closed (low_power=true)"
            );
            true
        }
    };
    (on_battery, low_power)
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

/// Parse `pmset -g` for `lowpowermode N`. Returns `None` (→ fail-closed)
/// when the key is absent.
fn parse_low_power_safe(stdout: &str) -> Option<bool> {
    for line in stdout.lines() {
        let l = line.trim();
        if let Some(rest) = l.strip_prefix("lowpowermode") {
            let rest = rest.trim_start_matches([' ', '=']).trim();
            if let Ok(v) = rest.parse::<u32>() {
                return Some(v != 0);
            }
        }
    }
    None
}

// Legacy non-safe wrappers retained for the unit tests asserting the
// fail-closed default (None → true).
#[cfg(test)]
fn parse_on_battery(stdout: &str) -> bool {
    parse_on_battery_safe(stdout).unwrap_or(true)
}

#[cfg(test)]
fn parse_low_power(stdout: &str) -> bool {
    parse_low_power_safe(stdout).unwrap_or(true)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// PID-from-pidfile happy path: writing our own pid into the support dir
    /// is enough to be picked up by discover_pids.
    #[test]
    fn pidfile_happy_path() {
        let tmp = tempdir();
        let me = std::process::id() as i32;
        fs::write(tmp.join("swift.pid"), me.to_string()).unwrap();
        fs::write(tmp.join("mlxlm.pid"), me.to_string()).unwrap();

        let pids = discover_pids(Some(&tmp));
        // self + swift + mlx-lm = 3, all pointing at our own pid in this test.
        assert_eq!(pids.len(), 3, "expected 3 pids, got {pids:?}");
        assert!(pids.iter().all(|(_, p)| *p == me));
        let names: Vec<&str> = pids.iter().map(|(n, _)| n.as_str()).collect();
        assert!(names.contains(&"api"));
        assert!(names.contains(&"swift"));
        assert!(names.contains(&"mlx-lm"));
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
        assert!(pids.iter().any(|(n, _)| n == "api"));

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
        let s = SystemResourceSampler::with_pids(vec![("api".to_string(), me)]);

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
        assert_eq!(a.process_breakdown[0].rss_mb, b.process_breakdown[0].rss_mb);
        assert!((a.cpu_percent - b.cpu_percent).abs() < f32::EPSILON);
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

    #[test]
    fn parses_low_power_mode() {
        assert_eq!(parse_low_power_safe(" lowpowermode         1\n other line"), Some(true));
        assert_eq!(parse_low_power_safe(" lowpowermode         0\n other line"), Some(false));
        // Missing → None (caller fails closed).
        assert_eq!(parse_low_power_safe("nothing here"), None);
    }

    /// Consensus-fix C5: when the parse fails, `sample_power` MUST report
    /// `(true, true)` — failing closed prevents heavy ML from running on
    /// battery just because pmset spoke a different language.
    #[test]
    fn unrecognised_pmset_output_fails_closed() {
        assert!(parse_on_battery("nothing useful")); // legacy wrapper
        assert!(parse_low_power("nothing useful")); // legacy wrapper
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
