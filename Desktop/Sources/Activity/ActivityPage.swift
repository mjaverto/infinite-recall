// Activity Tab — Stream E.
//
// User-facing surface for IR's deferred-work + capture system.
//
// Layout (per UX scenarios 1–9 in plan):
//   • Header banner — color-coded `processing_gate` reason
//   • 3 resource cards — CPU%, memory (phys_footprint), system-wide GPU(?)
//     - CPU card expands into per-process breakdown (Swift / Rust / mlx-lm)
//   • In-flight section — one row per kind currently running
//   • Live capture section — Audio + Screen with confirm sheet on pause
//   • Queued section — per-kind queued + failed counts
//   • Empty state — copy depends on gate state
//
// Reads from `ActivityMonitorService.shared` (Stream F). All actions call
// `pauseKind / pauseCapture / resume` on the same service. Until F lands
// these are no-op fallbacks (see `ActivityMonitorServiceFallback` below).

import SwiftUI
import os.log

extension BlockReason {
    /// True when this reason outranks the `.onBattery` substitution in
    /// `activityCorrectedGate` — the activity banner keeps this reason
    /// instead of swapping in a power block, so more-specific gates aren't
    /// masked by battery state.
    var outranksOnBattery: Bool {
        switch self {
        case .thermal, .locked, .deviceActive: return true
        case .onBattery, .initializing: return false
        }
    }

    /// True when the "Run now" button should be disabled for this reason.
    /// `.deviceActive` is excluded — `runOnceIgnoringPower` bypasses idle at
    /// the engine layer (`ProcessingGateReporter.swift:130`).
    /// `.thermal` IS included — engine refuses one-shot under thermal
    /// pressure (`ProcessingGateReporter.swift:120`).
    var disablesRunNowOverride: Bool {
        switch self {
        case .thermal, .locked: return true
        case .deviceActive, .onBattery, .initializing: return false
        }
    }
}

// MARK: - Power gate helpers

/// Local Activity-page power blocker. The wire model currently exposes the
/// power gate as `.onBattery`; this helper keeps the battery-vs-Low-Power-Mode
/// distinction available for UI copy and tests without broadening the API.
enum ActivityPowerBlock: Equatable {
    case battery
    case lowPowerMode
}

func activityPowerBlock(resources: ResourceSample, queued: UInt32) -> ActivityPowerBlock? {
    guard queued > 0 else { return nil }
    if resources.onBattery { return .battery }
    if resources.lowPower { return .lowPowerMode }
    return nil
}

func activityCorrectedGate(
    snapshotGate: GateState,
    resources: ResourceSample,
    queued: UInt32,
    thermalState: ProcessInfo.ThermalState,
    isRunOnceActive: Bool,
    runOnceStartedAt: Date?,
    now: Date = Date()
) -> GateState {
    if thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
        return .blocked(reason: .thermal, since: snapshotGate.since, waitingFor: .thermalCooldown)
    }
    if isRunOnceActive {
        return .allowed(since: runOnceStartedAt ?? now)
    }
    if snapshotGate.blockReason?.outranksOnBattery == true {
        return snapshotGate
    }
    if activityPowerBlock(resources: resources, queued: queued) != nil {
        return .blocked(reason: .onBattery, since: snapshotGate.since, waitingFor: .acPower)
    }
    // Issue #105: discard a stale `Blocked(.onBattery)` from the daemon
    // snapshot when the same snapshot's resource sample says we're actually
    // on AC and not in Low Power Mode. Both `snapshotGate` and `resources`
    // ride the same 1Hz Rust poll, but the gate-state reporter de-dupes
    // posts — so the cached gate can lag the resource sample at the
    // AC/battery transition window. Without this, the user sees
    // "Waiting for AC power" while plugged in until the next gate-state
    // diff is observed.
    if case .blocked(.onBattery, _, _) = snapshotGate,
       !resources.onBattery, !resources.lowPower {
        activityCorrectedGateLog.debug(
            "Downgrading stale .onBattery gate (since=\(snapshotGate.since.timeIntervalSince1970, privacy: .public)) to .allowed — resources report on-AC, not low-power."
        )
        return .allowed(since: snapshotGate.since)
    }
    return snapshotGate
}

/// Subsystem-wide logger for the Activity-page gate-correction predicate.
/// Pulled out so a user reporting "Activity says allowed but nothing runs"
/// (or vice-versa) leaves a breadcrumb when the Issue #105 stale-gate
/// downgrade fires.
private let activityCorrectedGateLog = Logger(
    subsystem: "me.omi.desktop",
    category: "ActivityCorrectedGate"
)

/// Issue #134: true when at least one lightweight (non-autonomous) work
/// kind has queued or in-flight rows. The `BatteryAwareScheduler` drains
/// these on AC even when `Blocked(.deviceActive)` (only `.summarize` and
/// `.extractKG` need user-idle), so the banner must not say "Waiting for
/// idle" while transcribe / OCR / extractMemory / extractActionItems are
/// actively running. Pure helper; tests live in
/// `Desktop/Tests/ActivityPagePowerGateTests.swift`.
func activityLightweightWorkActive(kinds: [KindRow]) -> Bool {
    kinds.contains { row in
        row.kind.requiresAutonomousReadiness == false
            && (row.queued > 0 || row.inFlight != nil)
    }
}

func activityShouldShowRunNowButton(
    snapshotGate: GateState?,
    correctedGate: GateState?,
    resources: ResourceSample?,
    queued: UInt32,
    isThermalBlocked: Bool,
    isRunOnceActive: Bool
) -> Bool {
    if isThermalBlocked || snapshotGate?.blockReason?.disablesRunNowOverride == true { return false }
    if isRunOnceActive { return true }
    if snapshotGate?.blockReason == .deviceActive && queued > 0 { return true }
    guard let resources, activityPowerBlock(resources: resources, queued: queued) != nil else { return false }
    return correctedGate?.blockReason == .onBattery
}

// MARK: - Page

struct ActivityPage: View {
    /// Stream F's real ActivityMonitorService singleton. Polls the local
    /// Rust daemon and surfaces snapshot via @Published.
    @StateObject private var service = ActivityMonitorService.shared
    @StateObject private var scheduler = BatteryAwareScheduler.shared

    @State private var captureToConfirm: CaptureKind? = nil
    @State private var captureMinutesToConfirm: UInt32 = 5

    // Unload (LocalModel kill) state. Per-pid sets are required so multiple
    // concurrent unloads each track their own spinner / hidden-row state.
    @State private var unloadingPids: Set<Int32> = []
    @State private var hiddenPids: Set<Int32> = []
    @State private var pendingUnload: PendingUnload? = nil
    @State private var unloadErrorMessage: String? = nil

    @State private var isRestartingDaemon: Bool = false

    /// Drives the per-row "elapsed timer" updates without polling the service.
    @State private var tick = Date()
    private let tickTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Identifiable wrapper around the pid we're about to unload, so we can
    /// drive `.alert(item:)` (which requires Identifiable). The dialog also
    /// needs the process name for copy.
    fileprivate struct PendingUnload: Identifiable {
        let pid: Int32
        let name: String
        var id: Int32 { pid }
    }

    /// Identifiable wrapper for `.alert(item:)` — required because Swift's
    /// `String` is not `Identifiable`.
    ///
    /// `id` derives from `message` so identity is stable across SwiftUI
    /// re-renders of the computed binding. A `UUID()`-per-render here would
    /// make every body recomputation look like a brand-new alert and cause
    /// flicker / re-presentation.
    fileprivate struct UnloadErrorIdentifier: Identifiable {
        let message: String
        var id: String { message }
    }

    /// Subsystem-wide logger for the Activity page. Matches the pattern used
    /// elsewhere in the app (`Logger(subsystem: "me.omi.desktop", category: ...)`).
    private static let log = Logger(subsystem: "me.omi.desktop", category: "ActivityPage")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // When we have a service error AND no snapshot yet, the
                // gateBanner would otherwise display a spurious
                // "Loading activity…" header right next to the error
                // banner. Hide the gate banner in that case so the error
                // is the only thing the user has to act on.
                if !(service.lastError != nil && snapshot == nil) {
                    gateBanner
                }
                if let err = service.lastError {
                    errorBanner(err)
                }
                resourceCards
                inFlightSection
                liveCaptureSection
                queuedSection
                if isEmptyState {
                    emptyStateView
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(OmiColors.backgroundPrimary)
        .navigationTitle("Activity")
        .onReceive(tickTimer) { now in tick = now }
        // === activity:C1 ===
        // Polling lifecycle: start when the tab is visible, stop on
        // disappear so we don't hammer the daemon while hidden (per UX
        // scenario 9 in the plan). CapturePauseGate is owned by OmiApp.
        .task {
            service.start()
        }
        .onDisappear {
            service.stop()
        }
        // === /activity:C1 ===
        .sheet(item: $captureToConfirm) { kind in
            captureConfirmSheet(kind: kind)
        }
        .alert(item: $pendingUnload) { pending in
            Alert(
                title: Text("Unload \(pending.name)?"),
                message: Text(
                    "Free memory used by \(pending.name) (pid \(pending.pid)) now? launchd will restart the model automatically within seconds."
                ),
                primaryButton: .destructive(Text("Unload")) {
                    Task { await performUnload(pid: pending.pid) }
                },
                secondaryButton: .cancel()
            )
        }
        .alert(item: Binding(
            get: { unloadErrorMessage.map { UnloadErrorIdentifier(message: $0) } },
            set: { if $0 == nil { unloadErrorMessage = nil } }
        )) { err in
            Alert(
                title: Text("Couldn't unload"),
                message: Text(err.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .accessibilityIdentifier("activity_page")
    }

    // === activity:C3 ===
    /// Small dismissible banner under the header for the most recent
    /// pause/resume/snapshot failure surfaced by `ActivityMonitorService`.
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(size: 14)
                .foregroundColor(OmiColors.error)
            Text(message)
                .scaledFont(size: 12)
                .foregroundColor(OmiColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                Task { await restartDaemon() }
            } label: {
                HStack(spacing: 4) {
                    if isRestartingDaemon {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                        Text("Restarting…")
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .scaledFont(size: 11)
                        Text("Restart daemon")
                    }
                }
                .scaledFont(size: 11, weight: .medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderless)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(OmiColors.backgroundPrimary.opacity(0.7))
            )
            .disabled(isRestartingDaemon)
            .accessibilityLabel("Restart daemon")
            .accessibilityIdentifier("activity_error_restart_button")

            Button {
                service.clearLastError()
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 11)
                    .foregroundColor(OmiColors.textTertiary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss error")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(OmiColors.error.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(OmiColors.error.opacity(0.35), lineWidth: 1)
                )
        )
        .accessibilityIdentifier("activity_error_banner")
    }

    /// Kickstart the launchd-managed Rust daemon, hold the "Restarting…"
    /// state for ~2 s so the button isn't pummelled in tight clicks, then
    /// re-fetch the snapshot. The token-file poll inside `activityHeaders`
    /// (LocalDaemonToken.read(waitFor:)) covers the brief window between
    /// the daemon restarting and api-token.txt being rewritten.
    private func restartDaemon() async {
        guard !isRestartingDaemon else { return }
        isRestartingDaemon = true
        defer { isRestartingDaemon = false }

        let uid = String(getuid())

        // Run launchctl off the MainActor so the spinner doesn't freeze
        // while we wait on the subprocess.
        let result: (exitCode: Int32, stderr: String) = await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = [
                "kickstart", "-k", "gui/\(uid)/com.infiniterecall.api",
            ]
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                return (process.terminationStatus, text)
            } catch {
                return (-1, error.localizedDescription)
            }
        }.value

        if result.exitCode != 0 {
            Self.log.error(
                "launchctl kickstart failed: code=\(result.exitCode, privacy: .public) stderr=\(result.stderr, privacy: .public)"
            )
            service.setLastError(
                "Restart failed: launchctl exited \(result.exitCode). Try ./setup-api-server.sh from a Terminal."
            )
            return
        }

        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // Only clear `lastError` if the surfaced banner is one of the failure
        // modes a daemon kickstart actually fixes:
        //   - `daemon token unavailable …` from `LocalDaemonToken.TokenError.fileMissing`
        //   - `snapshot failed: …` from a transient daemon-snapshot RPC failure
        //
        // Without this gate, an unrelated banner (e.g. a process-terminate
        // failure surfaced via `setLastError`) is silently wiped the moment
        // the user clicks "Restart daemon", masking errors that have nothing
        // to do with the daemon. `service.refreshNow()` below will overwrite
        // a daemon-related error organically on its next snapshot anyway.
        if let current = service.lastError,
           current.contains("daemon token unavailable")
            || current.hasPrefix("snapshot failed:") {
            service.clearLastError()
        }
        await service.refreshNow()
    }
    // === /activity:C3 ===

    // MARK: Snapshot accessors

    private var snapshot: ActivitySnapshot? { service.snapshot }
    private var gate: GateState? {
        guard let snap = snapshot else { return nil }
        return activityCorrectedGate(
            snapshotGate: snap.processingGate,
            resources: snap.resources,
            queued: totalQueued,
            thermalState: scheduler.thermalState,
            isRunOnceActive: scheduler.isRunOnceActive,
            runOnceStartedAt: scheduler.runOnceStartedAt
        )
    }
    private var kinds: [KindRow] { snapshot?.kinds ?? [] }
    private var captures: [CaptureRow] { snapshot?.capture ?? [] }
    private var resources: ResourceSample? { snapshot?.resources }

    private var totalQueued: UInt32 { kinds.reduce(0) { $0 + $1.queued } }
    private var totalInFlight: Int { kinds.filter { $0.inFlight != nil }.count }
    private var isEmptyState: Bool { totalInFlight == 0 && totalQueued == 0 }
    private var isThermalBlocked: Bool {
        scheduler.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }
    private var shouldShowRunNowButton: Bool {
        activityShouldShowRunNowButton(
            snapshotGate: snapshot?.processingGate,
            correctedGate: gate,
            resources: resources,
            queued: totalQueued,
            isThermalBlocked: isThermalBlocked,
            isRunOnceActive: scheduler.isRunOnceActive
        )
    }

    // MARK: - Banner

    private var gateBanner: some View {
        let info = bannerInfo(for: gate, queued: totalQueued, kinds: kinds)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: info.icon)
                .scaledFont(size: 20)
                .foregroundColor(info.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundColor(OmiColors.textPrimary)
                if let detail = info.detail {
                    Text(detail)
                        .scaledFont(size: 12)
                        .foregroundColor(OmiColors.textTertiary)
                }
            }
            Spacer()
            if shouldShowRunNowButton {
                runNowButton
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(info.color.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(info.color.opacity(0.4), lineWidth: 1)
                )
        )
        .accessibilityIdentifier("activity_gate_banner")
    }

    private var runNowButton: some View {
        let running = scheduler.isRunOnceActive
        return Button {
            Task { await scheduler.runOnceIgnoringPower() }
        } label: {
            HStack(spacing: 6) {
                if running {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                    Text("Running…")
                } else {
                    Image(systemName: "bolt.fill")
                    Text("Run now")
                }
            }
            .scaledFont(size: 12, weight: .semibold)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderless)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(OmiColors.backgroundPrimary.opacity(0.8))
        )
        .disabled(running || totalQueued == 0)
        .accessibilityLabel(running
            ? "Processing queued items"
            : "Run now — process \(totalQueued) queued item\(totalQueued == 1 ? "" : "s")")
        .accessibilityIdentifier("activity_run_now_button")
    }

    private struct BannerInfo {
        let icon: String
        let title: String
        let detail: String?
        let color: Color
    }

    private func bannerInfo(
        for gate: GateState?,
        queued: UInt32,
        kinds: [KindRow]
    ) -> BannerInfo {
        guard let gate = gate else {
            return BannerInfo(
                icon: "ellipsis.circle",
                title: "Loading activity…",
                detail: nil,
                color: OmiColors.textTertiary
            )
        }
        // Issue #35: `GateState` is a sum type. The pre-#35 `.idle/.none/.stub`
        // reasons are gone — `Allowed` covers "we're draining" and the
        // (now-deleted) "stub" reason is no longer tracked at the type level.
        switch gate {
        case .allowed:
            if queued > 0 {
                return BannerInfo(
                    icon: "checkmark.circle.fill",
                    title: "Idle processing — running",
                    detail: "\(queued) item\(queued == 1 ? "" : "s") in queue",
                    color: OmiColors.success
                )
            }
            return BannerInfo(
                icon: "moon.zzz.fill",
                title: "Up to date — 0 queued",
                detail: "Idle processing standing by.",
                color: OmiColors.textSecondary
            )
        case .blocked(let reason, _, let waitingFor):
            return blockedBannerInfo(
                reason: reason,
                waitingFor: waitingFor,
                queued: queued,
                kinds: kinds
            )
        }
    }

    private func blockedBannerInfo(
        reason: BlockReason,
        waitingFor: WaitCondition,
        queued: UInt32,
        kinds: [KindRow]
    ) -> BannerInfo {
        let detail = waitingForDescription(waitingFor)
        switch reason {
        case .deviceActive:
            // Issue #134: only `.summarize` / `.extractKG` actually wait for
            // idle; lightweight kinds (transcribe / OCR / extractMemory /
            // extractActionItems) drain on AC even while typing. If any
            // lightweight row has queued or in-flight work, the banner must
            // reflect that the queue is actively draining instead of
            // contradicting the In-flight section with "Waiting for idle".
            if activityLightweightWorkActive(kinds: kinds) {
                return BannerInfo(
                    icon: "checkmark.circle.fill",
                    title: "Idle processing — running",
                    detail: "\(queued) item\(queued == 1 ? "" : "s") in queue. Heavy work waits for \(detail).",
                    color: OmiColors.success
                )
            }
            return BannerInfo(
                icon: "keyboard.fill",
                title: "Waiting for idle — \(queued) item\(queued == 1 ? "" : "s") queued",
                detail: "Resumes after \(detail) — or run now.",
                color: OmiColors.warning
            )
        case .onBattery:
            if let res = resources, activityPowerBlock(resources: res, queued: queued) == .lowPowerMode {
                return BannerInfo(
                    icon: "bolt.slash.fill",
                    title: "Low Power Mode — \(queued) item\(queued == 1 ? "" : "s") queued",
                    detail: "Turn off Low Power Mode or run now.",
                    color: OmiColors.warning
                )
            }
            // Issue #105: read as "Resumes when on AC power" rather than the
            // bare "AC power" the user reasonably mistook for a current-state
            // assertion. Hardcoded — for `.onBattery`, `waitingFor` is always
            // `.acPower` (see `BatteryAwareScheduler`), but `WaitCondition`
            // also includes `.manual` which would read "Resumes when on manual
            // resume — or run now." Hardcoding avoids the awkward case.
            return BannerInfo(
                icon: "battery.25",
                title: "Waiting for AC power — \(queued) item\(queued == 1 ? "" : "s") queued",
                detail: "Resumes when on AC power — or run now.",
                color: OmiColors.warning
            )
        case .thermal:
            return BannerInfo(
                icon: "thermometer.high",
                title: "Cooling down — \(queued) item\(queued == 1 ? "" : "s") queued",
                detail: "Resumes after \(detail).",
                color: OmiColors.warning
            )
        case .locked:
            return BannerInfo(
                icon: "lock.fill",
                title: "Screen locked — \(queued) item\(queued == 1 ? "" : "s") queued",
                detail: detail,
                color: OmiColors.warning
            )
        case .initializing:
            // Issue #32: with the Swift→Rust gate-state bridge live, the
            // Rust gate only emits `.initializing` during the brief startup
            // window before the first `ProcessingGateReporter` POST
            // arrives (typically <3s). Soften the copy accordingly.
            return BannerInfo(
                icon: "hourglass",
                title: "Initializing…",
                detail: "Reading idle / power / thermal state.",
                color: OmiColors.textTertiary
            )
        }
    }

    /// Issue #35: render `WaitCondition` as user-facing copy. Replaces
    /// the pre-#35 stringly-typed `waitingFor: String?`.
    private func waitingForDescription(_ w: WaitCondition) -> String {
        switch w {
        case .idleFor(let secs):
            if secs >= 60 {
                let mins = secs / 60
                return "\(mins) min of idle"
            }
            return "\(secs)s of idle"
        case .acPower: return "AC power"
        case .thermalCooldown: return "thermal cooldown"
        case .unlock: return "unlock"
        case .manual: return "manual resume"
        }
    }

    // MARK: - Resource cards

    private var resourceCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                cpuCard
                memoryCard
                gpuCard
            }
            if let res = resources, !res.processBreakdown.isEmpty {
                processBreakdownView(res.processBreakdown)
            }
        }
    }

    private var cpuCard: some View {
        StatCard(
            title: "CPU",
            value: resources.map { String(format: "%.0f%%", $0.cpuPercent) } ?? "—",
            subtitle: "across IR processes"
        )
    }

    private var memoryCard: some View {
        StatCard(
            title: "Memory",
            value: resources.map { memString($0.memMb) } ?? "—",
            subtitle: "resident",
            help: "Physical memory footprint, including compressed pages and unified-memory allocations. Approximates Activity Monitor's Memory column."
        )
    }

    private var gpuCard: some View {
        StatCard(
            title: "GPU (system)",
            value: resources?.gpuSystemPercent.map { String(format: "%.0f%%", $0) } ?? "—",
            subtitle: "system-wide",
            help: "Per-process GPU unavailable on Apple Silicon. This is the system-wide GPU utilization."
        )
    }

    private func memString(_ mb: UInt32) -> String {
        if mb >= 1024 {
            return String(format: "%.2f GB", Double(mb) / 1024.0)
        }
        return "\(mb) MB"
    }

    private func processBreakdownView(_ procs: [ProcessBreakdown]) -> some View {
        // Filter out optimistically-hidden rows so a killed LocalModel
        // disappears immediately rather than lingering for up to a snapshot
        // tick (CACHE_TTL ~2s) until the daemon's process list re-syncs.
        let visible = procs.filter { !hiddenPids.contains($0.pid) }
        let sortedProcs = visible.sorted { $0.cpuPercent > $1.cpuPercent }
        let localModels = sortedProcs.filter { $0.kind == .localModel }
        let others = sortedProcs.filter { $0.kind != .localModel }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Process breakdown")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundColor(OmiColors.textTertiary)
            VStack(alignment: .leading, spacing: 8) {
                if localModels.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(others, id: \.pid) { p in
                            processRow(p)
                        }
                    }
                } else {
                    Text("Local Models")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundColor(OmiColors.textTertiary)
                    VStack(spacing: 4) {
                        ForEach(localModels, id: \.pid) { p in
                            processRow(p)
                        }
                    }
                    if !others.isEmpty {
                        Text("Processes")
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundColor(OmiColors.textTertiary)
                        VStack(spacing: 4) {
                            ForEach(others, id: \.pid) { p in
                                processRow(p)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(OmiColors.backgroundSecondary)
            )
        }
    }

    private func processRow(_ p: ProcessBreakdown) -> some View {
        HStack {
            Text(p.name)
                .scaledFont(size: 12)
                .foregroundColor(OmiColors.textSecondary)
            Text("(pid \(p.pid))")
                .scaledFont(size: 11)
                .foregroundColor(OmiColors.textQuaternary)
            Spacer()
            Text(String(format: "%.0f%%", p.cpuPercent))
                .scaledFont(size: 12, weight: .medium)
                .foregroundColor(OmiColors.textPrimary)
                .frame(width: 50, alignment: .trailing)
            Text(memString(p.memMb))
                .scaledFont(size: 12)
                .foregroundColor(OmiColors.textTertiary)
                .frame(width: 70, alignment: .trailing)
            // Issue: launchd's `KeepAlive=true` on the MLX/VLM lifecycle
            // plists means killing the worker child is a one-shot memory
            // reclaim, not a permanent stop — launchd respawns within
            // seconds. Surface as "Unload", not "Stop".
            if p.kind == .localModel {
                Button {
                    pendingUnload = PendingUnload(pid: p.pid, name: p.name)
                } label: {
                    if unloadingPids.contains(p.pid) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "eject.circle")
                            .scaledFont(size: 14)
                            .foregroundColor(OmiColors.textTertiary)
                    }
                }
                .buttonStyle(.borderless)
                .disabled(unloadingPids.contains(p.pid))
                .accessibilityLabel("Unload \(p.name) process \(p.pid)")
                .accessibilityIdentifier("activity_unload_button_\(p.pid)")
                .help("Unload \(p.name) — free its memory. launchd will restart it automatically within seconds.")
            }
        }
    }

    /// Trigger the kill on the daemon. Optimistically hides the row so the
    /// user sees instant feedback (the daemon's process-list cache TTL is
    /// up to 2 s). 404 = the process already died on its own; treat as a
    /// silent no-op so we don't surface "404" to a user who clicked a
    /// stale row. Real failures (5xx, network) re-show the row and surface
    /// via `.alert`.
    private func performUnload(pid: Int32) async {
        unloadingPids.insert(pid)
        hiddenPids.insert(pid)
        defer { unloadingPids.remove(pid) }

        do {
            try await service.terminateProcess(pid: pid)
        } catch APIError.httpError(statusCode: 404) {
            // Process already gone — leave hidden, no error toast.
            Self.log.info("terminate returned 404 for pid \(pid, privacy: .public), already gone")
            return
        } catch {
            // Real failure: un-hide so the user sees the row come back, and
            // surface an explanatory alert.
            hiddenPids.remove(pid)
            let detail: String
            if let apiErr = error as? APIError {
                switch apiErr {
                case .httpError(statusCode: let code):
                    detail = "the local API returned HTTP \(code)"
                case .unauthorized:
                    detail = "the local API rejected the request"
                case .invalidResponse:
                    detail = "the local API returned an invalid response"
                case .decodingError(let err):
                    detail = "the local API returned an unexpected response (\(err.localizedDescription))"
                default:
                    detail = error.localizedDescription
                }
            } else {
                detail = error.localizedDescription
            }
            unloadErrorMessage = "Could not unload pid \(pid): \(detail)"
        }
    }

    // MARK: - In Flight

    private var inFlightSection: some View {
        let rows = kinds.filter { $0.inFlight != nil }
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("In flight", count: rows.count)
            if rows.isEmpty {
                Text("Nothing running.")
                    .scaledFont(size: 12)
                    .foregroundColor(OmiColors.textQuaternary)
                    .padding(.horizontal, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(rows, id: \.kind) { row in
                        inFlightRow(row)
                    }
                }
            }
        }
    }

    private func inFlightRow(_ row: KindRow) -> some View {
        let inFlight = row.inFlight!
        let elapsed = max(0, tick.timeIntervalSince(inFlight.startedAt))
        let isPaused = (row.pausedUntil ?? .distantPast) > tick
        return HStack(spacing: 10) {
            // Status dot
            Circle()
                .fill(isPaused ? OmiColors.textTertiary : OmiColors.success)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(inFlight.label)
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundColor(OmiColors.textPrimary)
                    .lineLimit(1)
                if let pausedUntil = row.pausedUntil, isPaused {
                    Text("Paused — resumes \(timeOnly(pausedUntil))")
                        .scaledFont(size: 11)
                        .foregroundColor(OmiColors.warning)
                } else {
                    Text("Elapsed \(elapsedString(elapsed))")
                        .scaledFont(size: 11)
                        .foregroundColor(OmiColors.textTertiary)
                }
            }
            Spacer()
            pauseMenu(for: row)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(OmiColors.backgroundSecondary)
        )
        .opacity(isPaused ? 0.55 : 1.0)
    }

    @ViewBuilder
    private func pauseMenu(for row: KindRow) -> some View {
        let isPaused = (row.pausedUntil ?? .distantPast) > tick
        if isPaused {
            Button("Resume") {
                Task { await service.resume(target: .kind(row.kind)) }
            }
            .buttonStyle(.borderless)
            .scaledFont(size: 12, weight: .medium)
        } else {
            Menu {
                ForEach([UInt32(5), 15, 30, 60], id: \.self) { mins in
                    Button("Pause \(mins) min") {
                        Task { await service.pauseKind(row.kind, minutes: Int(mins)) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "pause.fill").scaledFont(size: 10)
                    Text("Pause").scaledFont(size: 12, weight: .medium)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(OmiColors.backgroundTertiary)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: - Live Capture

    private var liveCaptureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Live capture", count: captures.count)
            if captures.isEmpty {
                Text("Capture state unavailable.")
                    .scaledFont(size: 12)
                    .foregroundColor(OmiColors.textQuaternary)
                    .padding(.horizontal, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(captures, id: \.kind) { row in
                        captureRow(row)
                    }
                }
            }
        }
    }

    private func captureRow(_ row: CaptureRow) -> some View {
        let isPaused = (row.pausedUntil ?? .distantPast) > tick
        return HStack(spacing: 10) {
            Image(systemName: row.kind == .audio ? "mic.fill" : "rectangle.on.rectangle")
                .scaledFont(size: 14)
                .foregroundColor(row.running && !isPaused ? OmiColors.success : OmiColors.textTertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.kind == .audio ? "Audio capture" : "Screen capture")
                    .scaledFont(size: 13, weight: .medium)
                    .foregroundColor(OmiColors.textPrimary)
                if isPaused, let until = row.pausedUntil {
                    Text("Paused — resumes \(timeOnly(until))")
                        .scaledFont(size: 11)
                        .foregroundColor(OmiColors.warning)
                } else if row.running {
                    Text("Recording")
                        .scaledFont(size: 11)
                        .foregroundColor(OmiColors.success)
                } else {
                    Text("Idle")
                        .scaledFont(size: 11)
                        .foregroundColor(OmiColors.textTertiary)
                }
            }
            Spacer()
            if isPaused {
                Button("Resume") {
                    Task { await service.resume(target: .capture(row.kind)) }
                }
                .buttonStyle(.borderless)
                .scaledFont(size: 12, weight: .medium)
            } else {
                Menu {
                    ForEach([UInt32(5), 15, 30, 60], id: \.self) { mins in
                        Button("Pause \(mins) min") {
                            captureMinutesToConfirm = mins
                            captureToConfirm = row.kind
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pause.fill").scaledFont(size: 10)
                        Text("Pause").scaledFont(size: 12, weight: .medium)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(OmiColors.backgroundTertiary)
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(OmiColors.backgroundSecondary)
        )
        .opacity(isPaused ? 0.55 : 1.0)
    }

    private func captureConfirmSheet(kind: CaptureKind) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: kind == .audio ? "mic.slash.fill" : "rectangle.slash.fill")
                    .scaledFont(size: 20)
                    .foregroundColor(OmiColors.warning)
                Text("Pause \(kind == .audio ? "audio" : "screen") capture?")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(OmiColors.textPrimary)
            }
            Text(kind == .audio
                 ? "Recording will stop. Resume in \(captureMinutesToConfirm) minutes?"
                 : "Screen capture will stop. Resume in \(captureMinutesToConfirm) minutes?")
                .scaledFont(size: 13)
                .foregroundColor(OmiColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") {
                    captureToConfirm = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Pause \(captureMinutesToConfirm) min") {
                    let toPause = kind
                    let mins = captureMinutesToConfirm
                    captureToConfirm = nil
                    Task { await service.pauseCapture(toPause, minutes: Int(mins)) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    // MARK: - Queued

    private var queuedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Queued", count: kinds.count)
            if kinds.isEmpty {
                Text("No work in queue.")
                    .scaledFont(size: 12)
                    .foregroundColor(OmiColors.textQuaternary)
                    .padding(.horizontal, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(kinds, id: \.kind) { row in
                        queuedRow(row)
                    }
                }
            }
        }
    }

    private func queuedRow(_ row: KindRow) -> some View {
        HStack {
            Image(systemName: kindIcon(row.kind))
                .scaledFont(size: 13)
                .foregroundColor(OmiColors.textTertiary)
                .frame(width: 18)
            Text(kindLabel(row.kind))
                .scaledFont(size: 13)
                .foregroundColor(OmiColors.textSecondary)
            Spacer()
            statBadge("queued", value: Int(row.queued), color: OmiColors.info)
            statBadge("failed", value: Int(row.failed), color: OmiColors.error)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(OmiColors.backgroundSecondary.opacity(0.6))
        )
    }

    private func statBadge(_ label: String, value: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundColor(value > 0 ? color : OmiColors.textQuaternary)
            Text(label)
                .scaledFont(size: 11)
                .foregroundColor(OmiColors.textQuaternary)
        }
        .frame(width: 70, alignment: .trailing)
    }

    private func kindIcon(_ kind: WorkKind) -> String {
        switch kind {
        case .transcribe: return "waveform"
        case .ocr: return "doc.text.viewfinder"
        case .summarize: return "text.append"
        case .extractMemory: return "brain"
        case .extractActionItems: return "checklist"
        case .extractKG: return "point.3.connected.trianglepath.dotted"
        }
    }

    private func kindLabel(_ kind: WorkKind) -> String {
        switch kind {
        case .transcribe: return "Transcribe"
        case .ocr: return "OCR"
        case .summarize: return "Summarize"
        case .extractMemory: return "Extract memories"
        case .extractActionItems: return "Find action items"
        case .extractKG: return "Build brain map"
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        let copy: (String, String) = {
            guard let gate = gate else {
                return ("Up to date", "Loading…")
            }
            // Issue #35: switch on the sum-type variant.
            switch gate {
            case .allowed:
                return ("Up to date — 0 queued", "Idle processing standing by.")
            case .blocked(let reason, _, let waitingFor):
                // Issue #32: with the Swift→Rust bridge live, `.initializing`
                // is now just the brief boot window before the first
                // `ProcessingGateReporter` POST. Render as "Initializing…"
                // instead of the alarming pre-#32 copy.
                let detail = emptyStateBlockedDetail(reason: reason, waitingFor: waitingFor)
                let title = (reason == .initializing)
                    ? "Initializing…"
                    : "Up to date — 0 queued"
                return (title, detail)
            }
        }()
        return VStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .scaledFont(size: 28)
                .foregroundColor(OmiColors.success.opacity(0.7))
            Text(copy.0)
                .scaledFont(size: 14, weight: .semibold)
                .foregroundColor(OmiColors.textPrimary)
            Text(copy.1)
                .scaledFont(size: 12)
                .foregroundColor(OmiColors.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(OmiColors.backgroundSecondary.opacity(0.5))
        )
    }

    /// Empty-state copy for `Blocked` gate. Decoupled so the switch above
    /// stays a one-line dispatch per variant.
    private func emptyStateBlockedDetail(
        reason: BlockReason,
        waitingFor: WaitCondition
    ) -> String {
        let wait = waitingForDescription(waitingFor)
        switch reason {
        case .deviceActive: return "Waiting for idle. Resumes after \(wait)."
        case .onBattery:
            if let res = resources, activityPowerBlock(resources: res, queued: totalQueued) == .lowPowerMode {
                return "Waiting for Low Power Mode to turn off."
            }
            return "Waiting for AC power."
        case .thermal:      return "Waiting for thermal cooldown."
        case .locked:       return "Resumes when you unlock."
        case .initializing: return "Reading idle / power / thermal state."
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .scaledFont(size: 13, weight: .semibold)
                .foregroundColor(OmiColors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text("\(count)")
                .scaledFont(size: 11, weight: .medium)
                .foregroundColor(OmiColors.textQuaternary)
            Spacer()
        }
    }

    private func elapsedString(_ s: TimeInterval) -> String {
        let secs = Int(s)
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let sec = secs % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }

    private func timeOnly(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

// MARK: - Stat card

private struct StatCard: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundColor(OmiColors.textTertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                if let help = help {
                    Image(systemName: "questionmark.circle")
                        .scaledFont(size: 11)
                        .foregroundColor(OmiColors.textQuaternary)
                        .help(help)
                }
                Spacer()
            }
            Text(value)
                .scaledFont(size: 22, weight: .bold)
                .foregroundColor(OmiColors.textPrimary)
            if let subtitle = subtitle {
                Text(subtitle)
                    .scaledFont(size: 11)
                    .foregroundColor(OmiColors.textQuaternary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(OmiColors.backgroundSecondary)
        )
    }
}

// MARK: - CaptureKind: Identifiable for .sheet(item:)

extension CaptureKind: Identifiable {
    public var id: String { rawValue }
}

// Stream F's `ActivityMonitorService` is the live service used above.
