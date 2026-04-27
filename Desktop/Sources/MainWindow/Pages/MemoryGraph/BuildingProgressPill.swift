import SwiftUI

/// Compact progress pill rendered in the Brain Map header (and as the empty-state
/// indicator). Reads a `KGBuildProgress` snapshot and renders a single line of
/// state-aware copy plus a small spinner when work is in flight.
struct BuildingProgressPill: View {
  let progress: KGBuildProgress
  /// Smaller variant for inline cards (Memories tab).
  var compact: Bool = false

  var body: some View {
    HStack(spacing: 8) {
      if showsSpinner {
        ProgressView()
          .scaleEffect(compact ? 0.5 : 0.55)
          .tint(.white.opacity(0.7))
          .frame(width: compact ? 12 : 14, height: compact ? 12 : 14)
      } else {
        Image(systemName: stateIcon)
          .scaledFont(size: compact ? 10 : 11, weight: .medium)
          .foregroundColor(.white.opacity(0.6))
      }

      Text(label)
        .scaledFont(size: compact ? 11 : 12, weight: .medium)
        .foregroundColor(.white.opacity(0.8))
        .lineLimit(1)
    }
    .padding(.horizontal, compact ? 10 : 12)
    .padding(.vertical, compact ? 5 : 6)
    .background(
      Capsule(style: .continuous)
        .fill(Color.white.opacity(0.07))
    )
    .overlay(
      Capsule(style: .continuous)
        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
    )
  }

  private var showsSpinner: Bool {
    switch progress.state {
    case .building: return true
    case .pausedThermal, .pausedBattery, .pausedNotIdle, .modelNotReady, .idleNoWork:
      return false
    }
  }

  private var stateIcon: String {
    switch progress.state {
    case .idleNoWork: return "checkmark.circle.fill"
    case .building: return "brain"
    case .pausedThermal: return "thermometer.high"
    case .pausedBattery: return "battery.25"
    case .pausedNotIdle: return "moon.zzz"
    case .modelNotReady: return "hourglass"
    }
  }

  private var label: String {
    let processed = progress.processedMemories
    let total = progress.totalMemories
    let nodes = progress.totalNodes

    switch progress.state {
    case .idleNoWork:
      if total == 0 {
        return "Brain map ready"
      }
      return "Brain map up to date — \(nodes) entities"
    case .building:
      if let eta = progress.etaSeconds, eta > 0 {
        return "Building — \(processed) / \(total) - \(formatETA(eta))"
      }
      return "Building — \(processed) / \(total)"
    case .pausedThermal:
      return "Paused (cooling) — \(processed) / \(total)"
    case .pausedBattery:
      return "Paused (on battery) — \(processed) / \(total)"
    case .pausedNotIdle:
      return "Resumes when Mac is idle — \(processed) / \(total)"
    case .modelNotReady:
      return "Waiting for model — \(processed) / \(total)"
    }
  }

  private func formatETA(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s left" }
    let m = seconds / 60
    if m < 60 { return "\(m) min left" }
    let h = m / 60
    let rem = m % 60
    return rem == 0 ? "\(h)h left" : "\(h)h \(rem)m left"
  }
}
