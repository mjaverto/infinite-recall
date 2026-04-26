// Activity Tab — Stream E.
//
// User-facing surface for IR's deferred-work + capture system.
//
// Layout (per UX scenarios 1–9 in plan):
//   • Header banner — color-coded `processing_gate` reason
//   • 3 resource cards — CPU%, RSS, system-wide GPU(?)
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

// MARK: - Page

struct ActivityPage: View {
    /// Stream F's real ActivityMonitorService singleton. Polls the local
    /// Rust daemon and surfaces snapshot via @Published.
    @StateObject private var service = ActivityMonitorService.shared

    @State private var captureToConfirm: CaptureKind? = nil
    @State private var captureMinutesToConfirm: UInt32 = 5

    /// Drives the per-row "elapsed timer" updates without polling the service.
    @State private var tick = Date()
    private let tickTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                gateBanner
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
    // === /activity:C3 ===

    // MARK: Snapshot accessors

    private var snapshot: ActivitySnapshot? { service.snapshot }
    private var gate: GateState? { snapshot?.processingGate }
    private var kinds: [KindRow] { snapshot?.kinds ?? [] }
    private var captures: [CaptureRow] { snapshot?.capture ?? [] }
    private var resources: ResourceSample? { snapshot?.resources }

    private var totalQueued: UInt32 { kinds.reduce(0) { $0 + $1.queued } }
    private var totalInFlight: Int { kinds.filter { $0.inFlight != nil }.count }
    private var isEmptyState: Bool { totalInFlight == 0 && totalQueued == 0 }

    // MARK: - Banner

    private var gateBanner: some View {
        let info = bannerInfo(for: gate, queued: totalQueued)
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

    private struct BannerInfo {
        let icon: String
        let title: String
        let detail: String?
        let color: Color
    }

    private func bannerInfo(for gate: GateState?, queued: UInt32) -> BannerInfo {
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
            return blockedBannerInfo(reason: reason, waitingFor: waitingFor, queued: queued)
        }
    }

    private func blockedBannerInfo(
        reason: BlockReason,
        waitingFor: WaitCondition,
        queued: UInt32
    ) -> BannerInfo {
        let detail = waitingForDescription(waitingFor)
        switch reason {
        case .deviceActive:
            return BannerInfo(
                icon: "keyboard.fill",
                title: "Waiting for idle — \(queued) item\(queued == 1 ? "" : "s") queued",
                detail: "Resumes after \(detail).",
                color: OmiColors.warning
            )
        case .onBattery:
            return BannerInfo(
                icon: "battery.25",
                title: "Waiting for AC power — \(queued) item\(queued == 1 ? "" : "s") queued",
                detail: detail,
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
        case .manualPause:
            return BannerInfo(
                icon: "pause.circle.fill",
                title: "Manually paused",
                detail: detail,
                color: OmiColors.error
            )
        case .unwired:
            // PR #40 review: the Rust `AlwaysAllowedGate` placeholder
            // reports `.unwired` until the real `ProcessingGate` (#32)
            // ships. Render an honest, non-alarming banner instead of
            // pretending we're processing.
            return BannerInfo(
                icon: "wrench.and.screwdriver",
                title: "Activity gate not yet wired",
                detail: "Processing decisions are placeholder. Tracking issue: #32.",
                color: OmiColors.warning
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
                rssCard
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

    private var rssCard: some View {
        StatCard(
            title: "Memory (RSS)",
            value: resources.map { rssString($0.rssMb) } ?? "—",
            subtitle: "resident"
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

    private func rssString(_ mb: UInt32) -> String {
        if mb >= 1024 {
            return String(format: "%.2f GB", Double(mb) / 1024.0)
        }
        return "\(mb) MB"
    }

    private func processBreakdownView(_ procs: [ProcessBreakdown]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Process breakdown")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundColor(OmiColors.textTertiary)
            VStack(spacing: 4) {
                ForEach(procs, id: \.pid) { p in
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
                        Text(rssString(p.rssMb))
                            .scaledFont(size: 12)
                            .foregroundColor(OmiColors.textTertiary)
                            .frame(width: 70, alignment: .trailing)
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
        }
    }

    private func kindLabel(_ kind: WorkKind) -> String {
        switch kind {
        case .transcribe: return "Transcribe"
        case .ocr: return "OCR"
        case .summarize: return "Summarize"
        case .extractMemory: return "Extract memories"
        case .extractActionItems: return "Find action items"
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
                // PR #40 review: don't say "Up to date" when the gate is
                // just unwired — that's misleading. Honest title for the
                // placeholder; existing semantics for real block reasons.
                let detail = emptyStateBlockedDetail(reason: reason, waitingFor: waitingFor)
                let title = (reason == .unwired)
                    ? "Activity gate not yet wired"
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
        case .onBattery:    return "Waiting for AC power."
        case .thermal:      return "Waiting for thermal cooldown."
        case .locked:       return "Resumes when you unlock."
        case .manualPause:  return "Manually paused."
        case .unwired:      return "Processing decisions are placeholder until issue #32 ships."
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
