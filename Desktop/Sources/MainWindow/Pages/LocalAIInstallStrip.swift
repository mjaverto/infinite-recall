// Inline progress strip rendered under the active-model summary on the
// Local Model and Vision Model settings cards. Replaces the prior modal
// install sheet for the two model tiers — the user can switch tabs,
// scroll, or close the window mid-install without losing progress, since
// `LocalAIInstaller.shared` is a singleton whose `@Published` state
// survives view re-mounts.
//
// Scope: text tier (.mlx) and vision tier (.vlm) only. The API server
// install still uses `LocalAIInstallSheet` because it's rarer and shorter.

import SwiftUI

struct LocalAIInstallStrip: View {

  /// Which tier this strip belongs to. The strip self-hides whenever
  /// `installer.pendingKind` doesn't match — only the card whose install
  /// is actually running shows progress.
  let kind: LocalAIInstaller.Kind

  @ObservedObject private var installer = LocalAIInstaller.shared
  @State private var expanded: Bool = false

  var body: some View {
    Group {
      if shouldShow {
        VStack(alignment: .leading, spacing: 10) {
          headerRow
          progressRow
          if expanded {
            detailsView
              .transition(.opacity.combined(with: .move(edge: .top)))
          }
        }
        .padding(12)
        .background(OmiColors.backgroundSecondary)
        .cornerRadius(8)
        .transition(.opacity)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: shouldShow)
    .animation(.easeInOut(duration: 0.2), value: expanded)
  }

  // MARK: - Visibility

  /// Show whenever this tier has an in-flight install, a sticky failure, or a
  /// completed install the user hasn't acknowledged yet. Without `.done` here
  /// the strip would vanish the same frame the install completes — after a
  /// multi-GB download the user gets no confirmation that anything succeeded.
  private var shouldShow: Bool {
    guard installer.pendingKind == kind else { return false }
    return installer.isRunning
      || installer.currentStep == .failed
      || installer.currentStep == .done
  }

  // MARK: - Header row

  private var headerRow: some View {
    HStack(alignment: .center, spacing: 10) {
      icon
      VStack(alignment: .leading, spacing: 2) {
        Text(titleText)
          .scaledFont(size: 13, weight: .semibold)
          .foregroundColor(OmiColors.textPrimary)
        if let subtitle = subtitleText {
          Text(subtitle)
            .scaledFont(size: 11)
            .foregroundColor(OmiColors.textSecondary)
            .lineLimit(2)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 8)
      controlButtons
    }
  }

  @ViewBuilder
  private var icon: some View {
    if installer.currentStep == .failed {
      Image(systemName: installer.wasCancelled ? "xmark.circle" : "exclamationmark.triangle.fill")
        .foregroundColor(installer.wasCancelled ? OmiColors.textSecondary : OmiColors.error)
        .scaledFont(size: 14)
    } else if installer.currentStep == .done {
      Image(systemName: "checkmark.circle.fill")
        .foregroundColor(OmiColors.success)
        .scaledFont(size: 14)
    } else {
      ProgressView()
        .progressViewStyle(.circular)
        .controlSize(.small)
        .tint(OmiColors.purplePrimary)
    }
  }

  private var titleText: String {
    let tier = tierLabel
    switch installer.currentStep {
    case .failed:
      return installer.wasCancelled ? "\(tier) install cancelled" : "\(tier) install failed"
    case .done: return "\(tier) ready"
    default: return "Setting up \(tier)"
    }
  }

  private var subtitleText: String? {
    if installer.currentStep == .failed {
      if installer.wasCancelled { return "Installation was cancelled." }
      return installer.error ?? "Something went wrong. Open details for the log."
    }
    if installer.currentStep == .done {
      return activeModelId
    }
    if let id = activeModelId { return id }
    return installer.currentStep.rawValue
  }

  // MARK: - Controls

  @ViewBuilder
  private var controlButtons: some View {
    HStack(spacing: 6) {
      Button(expanded ? "Hide details" : "Details") {
        expanded.toggle()
      }
      .buttonStyle(.plain)
      .scaledFont(size: 11, weight: .medium)
      .foregroundColor(OmiColors.purplePrimary)

      if installer.isRunning {
        if installer.wasCancelled {
          Text("Cancelling…")
            .scaledFont(size: 11, weight: .medium)
            .foregroundColor(OmiColors.textSecondary)
        } else {
          Button("Cancel") {
            installer.cancel()
          }
          .buttonStyle(.plain)
          .scaledFont(size: 11, weight: .medium)
          .foregroundColor(OmiColors.error)
        }
      } else if installer.currentStep == .failed || installer.currentStep == .done {
        Button(installer.currentStep == .done ? "Done" : "Dismiss") {
          installer.dismissResult()
          expanded = false
        }
        .buttonStyle(.plain)
        .scaledFont(size: 11, weight: .medium)
        .foregroundColor(OmiColors.textSecondary)
      }
    }
  }

  // MARK: - Progress row

  @ViewBuilder
  private var progressRow: some View {
    if installer.currentStep == .failed || installer.currentStep == .done {
      EmptyView()
    } else if installer.currentStep == .downloadingModel || installer.modelDownloadProgress != nil {
      VStack(alignment: .leading, spacing: 4) {
        let hasTotal = installer.modelTotalBytes > 0
        if hasTotal {
          ProgressView(value: installer.modelDownloadProgress ?? 0)
            .progressViewStyle(LinearProgressViewStyle(tint: OmiColors.purplePrimary))
        } else {
          ProgressView()
            .progressViewStyle(LinearProgressViewStyle(tint: OmiColors.purplePrimary))
        }

        let downloaded = LocalAIInstaller.formattedBytes(installer.modelDownloadedBytes)
        if hasTotal {
          let pct = Int((installer.modelDownloadProgress ?? 0) * 100)
          let total = LocalAIInstaller.formattedBytes(installer.modelTotalBytes)
          Text("\(pct)% — \(downloaded) of \(total)")
            .scaledFont(size: 11)
            .foregroundColor(OmiColors.textTertiary)
        } else {
          Text("\(downloaded) downloaded")
            .scaledFont(size: 11)
            .foregroundColor(OmiColors.textTertiary)
        }
      }
    } else {
      ProgressView()
        .progressViewStyle(LinearProgressViewStyle(tint: OmiColors.purplePrimary))
    }
  }

  // MARK: - Details

  private var detailsView: some View {
    VStack(alignment: .leading, spacing: 12) {
      Divider().overlay(OmiColors.backgroundQuaternary)
      stepList
      logsView
    }
  }

  private var stepList: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(LocalAIInstaller.Step.displayed) { step in
        stepRow(step: step)
      }
    }
  }

  @ViewBuilder
  private func stepRow(step: LocalAIInstaller.Step) -> some View {
    let isCompleted = installer.completedSteps.contains(step) || installer.currentStep == .done
    let isCurrent = installer.currentStep == step && !isCompleted
    let isFailed = installer.currentStep == .failed
      && installer.completedSteps.contains(step) == false
      && LocalAIInstaller.Step.displayed.firstIndex(of: step)
        == LocalAIInstaller.Step.displayed.firstIndex(where: { !installer.completedSteps.contains($0) })

    HStack(alignment: .center, spacing: 8) {
      stepIcon(isCompleted: isCompleted, isCurrent: isCurrent, isFailed: isFailed)
        .frame(width: 14, height: 14)
      Text(step.rawValue)
        .scaledFont(size: 12, weight: isCurrent ? .medium : .regular)
        .foregroundColor(
          isCompleted || isCurrent ? OmiColors.textPrimary : OmiColors.textSecondary
        )
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder
  private func stepIcon(isCompleted: Bool, isCurrent: Bool, isFailed: Bool) -> some View {
    if isFailed {
      Image(systemName: "xmark.circle.fill")
        .scaledFont(size: 12)
        .foregroundColor(OmiColors.error)
    } else if isCompleted {
      Image(systemName: "checkmark.circle.fill")
        .scaledFont(size: 12)
        .foregroundColor(OmiColors.success)
    } else if isCurrent {
      ProgressView()
        .progressViewStyle(.circular)
        .controlSize(.mini)
        .tint(OmiColors.purplePrimary)
    } else {
      Image(systemName: "circle")
        .scaledFont(size: 12)
        .foregroundColor(OmiColors.textTertiary.opacity(0.6))
    }
  }

  private var logsView: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Output")
          .scaledFont(size: 11, weight: .medium)
          .foregroundColor(OmiColors.textTertiary)
        Spacer()
        Button("Copy") {
          let pb = NSPasteboard.general
          pb.clearContents()
          pb.setString(installer.logLines.joined(separator: "\n"), forType: .string)
        }
        .buttonStyle(.plain)
        .scaledFont(size: 11)
        .foregroundColor(OmiColors.purplePrimary)
      }
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(installer.logLines.enumerated()), id: \.offset) { (idx, line) in
              Text(line)
                .scaledFont(size: 10)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(OmiColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(idx)
            }
          }
          .padding(6)
        }
        .frame(height: 100)
        .background(OmiColors.backgroundPrimary)
        .cornerRadius(4)
        .onChange(of: installer.logLines.count) { _, newCount in
          if newCount > 0 {
            withAnimation { proxy.scrollTo(newCount - 1, anchor: .bottom) }
          }
        }
      }
    }
  }

  // MARK: - Helpers

  private var tierLabel: String {
    switch kind {
    case .mlx: return "Local Model"
    case .vlm: return "Vision Model"
    case .api: return "API Server"
    }
  }

  private var activeModelId: String? {
    switch kind {
    case .mlx: return installer.pendingMLXModelId
    case .vlm: return installer.pendingVLMModelId
    case .api: return nil
    }
  }
}
