import Combine
import Foundation
import SwiftUI

// MARK: - Safe Mode State

enum SafeModeState: Equatable {
  case off  // recording active
  case pausedFor(seconds: Int, until: Date, lastUsedDuration: Int)
  case pausedIndefinitely(lastUsedDuration: Int?)

  var isPaused: Bool {
    if case .off = self { return false }
    return true
  }

  /// Most recently chosen preset duration (in seconds), if any.
  var lastUsedDuration: Int? {
    switch self {
    case .off:
      return nil
    case .pausedFor(_, _, let last):
      return last
    case .pausedIndefinitely(let last):
      return last
    }
  }
}

// MARK: - Persistence keys

private enum SafeModeDefaults {
  static let stateKey = "safeMode_state"  // "off" | "for" | "indef"
  static let untilKey = "safeMode_until"  // Date
  static let lastUsedKey = "safeMode_lastUsed"  // Int seconds
}

// MARK: - SafeModeController

/// Singleton that pauses BOTH audio recording (transcription) and screen
/// capture (ProactiveAssistantsPlugin monitoring) with one click, time-boxed,
/// and restores the previous recording state when the timer expires.
///
/// This intentionally does NOT touch APIClient, AppState internals, or any
/// other source of truth — it drives pause/resume through the same hooks the
/// existing menu bar / Settings toggles use:
///   - Audio: posts `.toggleTranscriptionRequested` (DesktopHomeView listens
///     and calls AppState.startTranscription / stopTranscription).
///   - Screen: ProactiveAssistantsPlugin.shared.startMonitoring/stopMonitoring.
final class SafeModeController: ObservableObject {
  static let shared = SafeModeController()

  // MARK: Published state

  @Published private(set) var state: SafeModeState = .off
  @Published private(set) var displayCountdown: String = ""

  /// Posted whenever the controller's state changes (so menu rebuilders /
  /// status icon refreshers can react without holding a Combine sink).
  static let stateDidChange = Notification.Name("safeMode_stateDidChange")

  // MARK: Internals

  private var tickTimer: Timer?
  private let defaults = UserDefaults.standard
  private var hasRestoredOnLaunch = false

  // MARK: API

  /// Pause both pipelines for `forSeconds` seconds, or indefinitely if nil.
  func pause(forSeconds: Int? = nil) {
    let now = Date()
    let priorLast = state.lastUsedDuration

    if let secs = forSeconds, secs > 0 {
      let until = now.addingTimeInterval(TimeInterval(secs))
      state = .pausedFor(seconds: secs, until: until, lastUsedDuration: secs)
    } else {
      state = .pausedIndefinitely(lastUsedDuration: priorLast)
    }

    applyPipelineStop()
    persist()
    refreshCountdown()
    startTickerIfNeeded()
    notifyStateChanged()
  }

  /// Resume both pipelines and clear Safe Mode.
  func resume() {
    let last = state.lastUsedDuration
    state = .off
    stopTicker()
    applyPipelineStart()
    persist(lastUsedOverride: last)
    refreshCountdown()
    notifyStateChanged()
  }

  /// Toggle: if paused, resume; otherwise pause for last-used duration
  /// (or 15 minutes if there's no recorded preset yet).
  func toggle() {
    switch state {
    case .off:
      let last =
        defaults.object(forKey: SafeModeDefaults.lastUsedKey) as? Int ?? (15 * 60)
      pause(forSeconds: last)
    case .pausedFor, .pausedIndefinitely:
      resume()
    }
  }

  /// Seconds remaining for a time-boxed pause, or nil for indefinite/off.
  var remainingSeconds: Int? {
    if case .pausedFor(_, let until, _) = state {
      return max(0, Int(until.timeIntervalSinceNow.rounded()))
    }
    return nil
  }

  // MARK: Launch restore

  /// Call from app launch (after AppState exists but before pipelines fully
  /// initialize) to restore persisted state. If a time-boxed pause has
  /// already expired, transition to .off and start the pipelines back up.
  func restoreOnLaunch() {
    guard !hasRestoredOnLaunch else { return }
    hasRestoredOnLaunch = true

    let raw = defaults.string(forKey: SafeModeDefaults.stateKey) ?? "off"
    let lastUsed = defaults.object(forKey: SafeModeDefaults.lastUsedKey) as? Int

    switch raw {
    case "for":
      let until =
        defaults.object(forKey: SafeModeDefaults.untilKey) as? Date
        ?? Date.distantPast
      let remaining = until.timeIntervalSinceNow
      let last = lastUsed ?? 0
      if remaining > 0 && last > 0 {
        // Restore an active timed pause.
        state = .pausedFor(seconds: last, until: until, lastUsedDuration: last)
        applyPipelineStop()
        startTickerIfNeeded()
        refreshCountdown()
      } else {
        // Already expired — transition to off and resume.
        state = .off
        applyPipelineStart()
        persist(lastUsedOverride: last > 0 ? last : nil)
      }
    case "indef":
      state = .pausedIndefinitely(lastUsedDuration: lastUsed)
      applyPipelineStop()
      refreshCountdown()
    default:
      state = .off
    }
    notifyStateChanged()
  }

  // MARK: - Pipeline control

  private func applyPipelineStop() {
    DispatchQueue.main.async {
      // Audio: route through the existing notification the menu bar
      // already uses (DesktopHomeView listens and stops AppState).
      AssistantSettings.shared.transcriptionEnabled = false
      NotificationCenter.default.post(
        name: .toggleTranscriptionRequested,
        object: nil,
        userInfo: ["enabled": false]
      )
      // Screen capture: same path the existing screen-capture toggle uses.
      AssistantSettings.shared.screenAnalysisEnabled = false
      ProactiveAssistantsPlugin.shared.stopMonitoring()
    }
  }

  private func applyPipelineStart() {
    DispatchQueue.main.async {
      AssistantSettings.shared.transcriptionEnabled = true
      NotificationCenter.default.post(
        name: .toggleTranscriptionRequested,
        object: nil,
        userInfo: ["enabled": true]
      )
      AssistantSettings.shared.screenAnalysisEnabled = true
      if ProactiveAssistantsPlugin.shared.hasScreenRecordingPermission {
        ProactiveAssistantsPlugin.shared.startMonitoring { _, _ in }
      }
    }
  }

  // MARK: - Ticker

  private func startTickerIfNeeded() {
    guard case .pausedFor = state else {
      stopTicker()
      return
    }
    stopTicker()
    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.handleTick()
    }
    RunLoop.main.add(timer, forMode: .common)
    tickTimer = timer
  }

  private func stopTicker() {
    tickTimer?.invalidate()
    tickTimer = nil
  }

  private func handleTick() {
    guard case .pausedFor(_, let until, _) = state else {
      stopTicker()
      refreshCountdown()
      notifyStateChanged()
      return
    }
    if Date() >= until {
      // Expired — auto-resume.
      resume()
      return
    }
    refreshCountdown()
    notifyStateChanged()
  }

  // MARK: - Display

  private func refreshCountdown() {
    switch state {
    case .off:
      displayCountdown = ""
    case .pausedIndefinitely:
      displayCountdown = "Until I resume"
    case .pausedFor(_, let until, _):
      let remaining = max(0, Int(until.timeIntervalSinceNow.rounded()))
      displayCountdown = Self.formatRemaining(remaining)
    }
  }

  /// Compact string used inside the menu ("23 min left", "1h 12m left").
  static func formatRemaining(_ seconds: Int) -> String {
    if seconds <= 0 { return "0 min left" }
    let mins = seconds / 60
    if mins < 60 {
      let m = max(1, mins)
      return "\(m) min left"
    }
    let hours = mins / 60
    let rem = mins % 60
    if rem == 0 { return "\(hours)h left" }
    return "\(hours)h \(rem)m left"
  }

  /// Compact string used in the menu-bar status item title ("23m", "1h 12m").
  static func formatStatusBarTitle(_ seconds: Int) -> String {
    if seconds <= 0 { return "0m" }
    let mins = seconds / 60
    if mins < 60 {
      return "\(max(1, mins))m"
    }
    let hours = mins / 60
    let rem = mins % 60
    if rem == 0 { return "\(hours)h" }
    return "\(hours)h \(rem)m"
  }

  // MARK: - Persistence

  private func persist(lastUsedOverride: Int? = nil) {
    switch state {
    case .off:
      defaults.set("off", forKey: SafeModeDefaults.stateKey)
      defaults.removeObject(forKey: SafeModeDefaults.untilKey)
      if let last = lastUsedOverride {
        defaults.set(last, forKey: SafeModeDefaults.lastUsedKey)
      }
    case .pausedFor(_, let until, let last):
      defaults.set("for", forKey: SafeModeDefaults.stateKey)
      defaults.set(until, forKey: SafeModeDefaults.untilKey)
      defaults.set(last, forKey: SafeModeDefaults.lastUsedKey)
    case .pausedIndefinitely(let last):
      defaults.set("indef", forKey: SafeModeDefaults.stateKey)
      defaults.removeObject(forKey: SafeModeDefaults.untilKey)
      if let last = last {
        defaults.set(last, forKey: SafeModeDefaults.lastUsedKey)
      }
    }
  }

  // MARK: - Notify

  private func notifyStateChanged() {
    NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
  }
}
