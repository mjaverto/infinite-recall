// Infinite Recall fork: reusable banner that informs the user when local AI
// is unavailable. Memories and tasks both depend on `mlx-lm.server`; without
// it the relevant pages render empty with no obvious explanation.
//
// The banner subscribes to `MLXLifecycleManager.shared` published state and
// renders one of three visibility states:
//   - hidden — server is running and the model is present on disk
//   - install needed — neither server nor model present; offers "Set up"
//   - server down — model present but server stopped; offers "Start"
//
// While `LocalAIInstaller.shared.isRunning` is true the banner shows a
// "Setting up Local AI…" spinner state instead of the call-to-action button.
//
// The banner is dismissable per-app-launch via an `@AppStorage` key keyed on
// a session UUID generated lazily; that defaults entry is reset every launch
// so the banner reappears on the next run.

import SwiftUI

/// Per-launch session UUID used to scope the dismissed-banner @AppStorage key.
/// Recomputed on first access each app launch so the dismissal does not persist
/// across runs.
private enum LocalAIStatusBannerSession {
  static let id: String = {
    UUID().uuidString
  }()

  static var dismissKey: String {
    "dismissedAIBanner_\(id)"
  }
}

struct LocalAIStatusBanner: View {

  /// Called when the user taps "Set up". The parent owns the install sheet
  /// presentation state; the banner just signals intent.
  var onSetUpTapped: () -> Void

  @StateObject private var lifecycle = MLXLifecycleManager.shared
  @StateObject private var installer = LocalAIInstaller.shared

  @AppStorage(LocalAIStatusBannerSession.dismissKey) private var dismissed: Bool = false

  var body: some View {
    Group {
      if let state = visibilityState {
        bannerView(for: state)
          .transition(.opacity)
      }
    }
  }

  // MARK: - State resolution

  private enum State {
    case installNeeded
    case serverDown
    case installing
  }

  private var visibilityState: State? {
    // Don't show during the brief startup window before we have any signal.
    guard lifecycle.hasRefreshedAtLeastOnce else { return nil }
    if dismissed { return nil }

    if installer.isRunning {
      return .installing
    }

    let running = lifecycle.serverRunning
    let present = lifecycle.modelPresent

    if running && present {
      return nil
    }
    if !running && !present {
      return .installNeeded
    }
    if !running && present {
      return .serverDown
    }
    // Server reportedly running but model missing — odd, surface as install.
    return .installNeeded
  }

  // MARK: - View

  @ViewBuilder
  private func bannerView(for state: State) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundColor(OmiColors.warning)

      VStack(alignment: .leading, spacing: 2) {
        Text(title(for: state))
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(OmiColors.textPrimary)
        Text(subtitle(for: state))
          .font(.system(size: 13))
          .foregroundColor(OmiColors.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      actionButton(for: state)

      Button {
        withAnimation(.easeInOut(duration: 0.15)) {
          dismissed = true
        }
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
          .foregroundColor(OmiColors.textSecondary)
          .padding(6)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Dismiss until next launch")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(OmiColors.warning.opacity(0.12))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(OmiColors.warning.opacity(0.5), lineWidth: 1)
    )
    .padding(.horizontal, 16)
    .padding(.top, 8)
  }

  @ViewBuilder
  private func actionButton(for state: State) -> some View {
    switch state {
    case .installNeeded:
      Button(action: onSetUpTapped) {
        Text("Set up")
          .font(.system(size: 13, weight: .semibold))
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
    case .serverDown:
      Button {
        Task {
          await MLXLifecycleManager.shared.startServer()
          await MLXLifecycleManager.shared.refresh()
        }
      } label: {
        Text("Start")
          .font(.system(size: 13, weight: .semibold))
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
    case .installing:
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.small)
          .scaleEffect(0.7)
        Text("Setting up…")
          .font(.system(size: 12, weight: .medium))
          .foregroundColor(OmiColors.textSecondary)
      }
    }
  }

  // MARK: - Copy

  private func title(for state: State) -> String {
    switch state {
    case .installNeeded: return "Local AI not set up"
    case .serverDown: return "Local AI is stopped"
    case .installing: return "Setting up Local AI…"
    }
  }

  private func subtitle(for state: State) -> String {
    switch state {
    case .installNeeded:
      return "Memories and tasks need Local AI to extract them."
    case .serverDown:
      return "Memories aren't being extracted right now."
    case .installing:
      return "This can take a few minutes — model download is in progress."
    }
  }
}
