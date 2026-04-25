// Infinite Recall fork: in-app installer sheet for the local MLX server.
//
// Replaces the prior Terminal-launch flow. Owned by Settings → AI / Models.

import AppKit
import SwiftUI

struct LocalAIInstallSheet: View {

  /// Which sidecar this sheet is installing. Drives both the install kick-off
  /// and the header copy. Defaults to `.mlx` to preserve the historical call
  /// sites that pre-date the vision tier.
  enum Kind {
    /// Text tier — mlx-lm.server on 127.0.0.1:8080.
    case mlx
    /// Vision tier — mlx-vlm.server on 127.0.0.1:8081.
    case vlm
    /// Local Rust REST API daemon — `infinite-recall-api`.
    case api
  }

  @Environment(\.dismiss) private var dismiss
  @StateObject private var installer = LocalAIInstaller.shared
  @State private var showLogs: Bool = false

  /// Which sidecar to install. See `Kind`.
  var kind: Kind = .mlx

  /// Optional override of the model id (only honored for `.mlx` and `.vlm`).
  var modelId: String? = nil

  /// Legacy back-compat shim: callers that pass `installAPIInstead: true` still
  /// work and are mapped to `kind = .api`.
  var installAPIInstead: Bool = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)

      Divider().overlay(OmiColors.backgroundQuaternary)

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          stepList
          if showLogs {
            logsView
              .transition(.opacity)
          }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
      }

      Divider().overlay(OmiColors.backgroundQuaternary)

      footer
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
    .frame(width: 520, height: 460)
    .background(OmiColors.backgroundPrimary)
    .interactiveDismissDisabled(installer.isRunning)
    .task {
      // Kick off the install once the sheet appears, but only if we're not
      // already running (e.g. the sheet got re-presented after being closed).
      if !installer.isRunning && installer.currentStep != .done {
        // Honor legacy installAPIInstead first, then fall through to `kind`.
        if installAPIInstead {
          await installer.startAPIInstall()
          return
        }
        switch kind {
        case .mlx:
          if let id = modelId {
            await installer.startMLXInstall(modelId: id)
          } else {
            await installer.startMLXInstall()
          }
        case .vlm:
          await installer.startVLMInstall(modelId: modelId)
        case .api:
          await installer.startAPIInstall()
        }
      }
    }
  }

  // MARK: - Copy helpers

  /// Human-readable tier label that matches the card title in Settings.
  private var tierLabel: String {
    let resolvedKind = installAPIInstead ? Kind.api : kind
    switch resolvedKind {
    case .vlm: return "Vision Model"
    case .api: return "API Server"
    case .mlx: return "Local Model"
    }
  }

  /// Disk size string sourced from the catalog entry being installed, e.g.
  /// "5.5 GB". Falls back gracefully when no catalog entry is available.
  private var catalogDiskSizeLabel: String {
    let resolvedKind = installAPIInstead ? Kind.api : kind
    switch resolvedKind {
    case .mlx:
      let entry = modelId.flatMap { LocalModelCatalog.option(forId: $0) }
        ?? LocalModelCatalog.recommended
      return String(format: "%.4g GB", entry.approxDiskGB)
    case .vlm:
      let entry = modelId.flatMap { VisionModelCatalog.option(forId: $0) }
        ?? VisionModelCatalog.recommended
      return String(format: "%.4g GB", entry.approxDiskGB)
    case .api:
      return ""
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      ZStack {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(OmiColors.purplePrimary.opacity(0.18))
          .frame(width: 44, height: 44)
        Image(systemName: installer.currentStep == .done
              ? "checkmark.circle.fill"
              : "cpu")
          .scaledFont(size: 20, weight: .semibold)
          .foregroundColor(installer.currentStep == .done
                           ? OmiColors.success
                           : OmiColors.purplePrimary)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(installer.currentStep == .done
             ? "\(tierLabel) is ready"
             : (installer.currentStep == .failed
                ? "Install failed"
                : "Setting up \(tierLabel)"))
          .scaledFont(size: 17, weight: .semibold)
          .foregroundColor(OmiColors.textPrimary)

        Text(headerSubtitle)
          .scaledFont(size: 12)
          .foregroundColor(OmiColors.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
  }

  private var headerSubtitle: String {
    switch installer.currentStep {
    case .done:
      return "Memory extraction and chat will start working in the next minute."
    case .failed:
      return installer.error ?? "Something went wrong. See details below."
    default:
      let sizeClause = catalogDiskSizeLabel.isEmpty ? "" : " About \(catalogDiskSizeLabel) of disk."
      return "This installs everything needed to run AI on this Mac.\(sizeClause)"
    }
  }

  // MARK: - Step list

  private var stepList: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(LocalAIInstaller.Step.displayed) { step in
        stepRow(step: step)
      }
    }
  }

  @ViewBuilder
  private func stepRow(step: LocalAIInstaller.Step) -> some View {
    let isCompleted = installer.completedSteps.contains(step) || installer.currentStep == .done
    let isCurrent = installer.currentStep == step && !isCompleted
    let isFailed = installer.currentStep == .failed && installer.completedSteps.contains(step) == false &&
      LocalAIInstaller.Step.displayed.firstIndex(of: step) ==
        LocalAIInstaller.Step.displayed.firstIndex(where: { !installer.completedSteps.contains($0) })

    HStack(alignment: .top, spacing: 12) {
      stepIcon(isCompleted: isCompleted, isCurrent: isCurrent, isFailed: isFailed)
        .frame(width: 22, height: 22)

      VStack(alignment: .leading, spacing: 6) {
        Text(stepLabel(for: step))
          .scaledFont(size: 14, weight: isCurrent ? .medium : .regular)
          .foregroundColor(
            isCompleted || isCurrent
              ? OmiColors.textPrimary
              : OmiColors.textSecondary)

        if step == .downloadingModel && (isCurrent || installer.modelDownloadProgress != nil) {
          downloadProgressView
        }
      }
      Spacer(minLength: 0)
    }
  }

  /// Returns the display label for a step row. The download step includes the
  /// catalog-sourced size so it always agrees with the header subtitle.
  private func stepLabel(for step: LocalAIInstaller.Step) -> String {
    if step == .downloadingModel, !catalogDiskSizeLabel.isEmpty {
      return "Downloading model (~\(catalogDiskSizeLabel))"
    }
    return step.rawValue
  }

  @ViewBuilder
  private func stepIcon(isCompleted: Bool, isCurrent: Bool, isFailed: Bool) -> some View {
    if isFailed {
      Image(systemName: "xmark.circle.fill")
        .scaledFont(size: 16)
        .foregroundColor(OmiColors.error)
    } else if isCompleted {
      Image(systemName: "checkmark.circle.fill")
        .scaledFont(size: 16)
        .foregroundColor(OmiColors.success)
    } else if isCurrent {
      ProgressView()
        .progressViewStyle(.circular)
        .controlSize(.small)
        .tint(OmiColors.purplePrimary)
    } else {
      Image(systemName: "circle")
        .scaledFont(size: 16)
        .foregroundColor(OmiColors.textTertiary.opacity(0.6))
    }
  }

  private var downloadProgressView: some View {
    VStack(alignment: .leading, spacing: 4) {
      ProgressView(value: installer.modelDownloadProgress ?? 0)
        .progressViewStyle(LinearProgressViewStyle(tint: OmiColors.purplePrimary))

      let pct = Int((installer.modelDownloadProgress ?? 0) * 100)
      let downloaded = LocalAIInstaller.formattedBytes(installer.modelDownloadedBytes)
      let total = LocalAIInstaller.formattedBytes(installer.modelTotalBytes)
      Text("\(pct)% — \(downloaded) of \(total)")
        .scaledFont(size: 11)
        .foregroundColor(OmiColors.textTertiary)
    }
  }

  // MARK: - Logs

  private var logsView: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Output")
          .scaledFont(size: 11, weight: .medium)
          .foregroundColor(OmiColors.textTertiary)
        Spacer()
        Button("Copy log") { copyLog() }
          .buttonStyle(.plain)
          .scaledFont(size: 11)
          .foregroundColor(OmiColors.purplePrimary)
      }

      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(installer.logLines.enumerated()), id: \.offset) { (idx, line) in
              Text(line)
                .scaledFont(size: 11)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(OmiColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(idx)
            }
          }
          .padding(8)
        }
        .frame(height: 140)
        .background(OmiColors.backgroundSecondary)
        .cornerRadius(6)
        .onChange(of: installer.logLines.count) { _, newCount in
          if newCount > 0 {
            withAnimation { proxy.scrollTo(newCount - 1, anchor: .bottom) }
          }
        }
      }
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack {
      DisclosureGroup(isExpanded: $showLogs) {
        EmptyView()
      } label: {
        Text("Show technical details")
          .scaledFont(size: 12)
          .foregroundColor(OmiColors.textSecondary)
      }
      .toggleStyle(.button)
      .buttonStyle(.plain)

      Spacer()

      if installer.isRunning {
        Button("Cancel") {
          installer.cancel()
          dismiss()
        }
        .buttonStyle(.plain)
        .scaledFont(size: 13, weight: .medium)
        .foregroundColor(OmiColors.error)
      }

      if installer.currentStep == .done || installer.currentStep == .failed {
        Button(installer.currentStep == .done ? "Done" : "Close") {
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .tint(OmiColors.purplePrimary)
      }
    }
  }

  // MARK: - Actions

  private func copyLog() {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(installer.logLines.joined(separator: "\n"), forType: .string)
  }
}
