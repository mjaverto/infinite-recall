import Foundation
import SwiftUI

// Infinite Recall fork: Sparkle removed. This file is a minimal stub that preserves
// the public API surface callers depend on. No network calls, no update checks.

/// Update channel for staged releases (kept for SettingsSyncManager API compat)
enum UpdateChannel: String, CaseIterable {
  case stable = "stable"
  case beta = "beta"

  var displayName: String {
    switch self {
    case .stable: return "Stable"
    case .beta: return "Beta"
    }
  }

  var description: String {
    switch self {
    case .stable: return "Recommended for most users"
    case .beta: return "Early access to new features"
    }
  }

  static var appDisplayName: String {
    return "Infinite Recall"
  }
}

private let kUpdateChannelKey = "update_channel"

@MainActor
final class UpdaterViewModel: ObservableObject {
  static let shared = UpdaterViewModel()

  /// Always false — Sparkle removed, no update sessions can be in progress.
  nonisolated static var isUpdateInProgress: Bool { false }

  @Published var updateAvailable: Bool = false
  @Published var availableVersion: String = ""
  @Published var canCheckForUpdates: Bool = false
  @Published var automaticallyChecksForUpdates: Bool = false
  @Published var automaticallyDownloadsUpdates: Bool = false
  @Published var activeChannelLabel: String = ""
  @Published var updateChannel: UpdateChannel = .stable
  @Published private(set) var updateSessionInProgress: Bool = false

  var latestStableBuildNumber: Int? = nil
  var latestStableVersionString: String? = nil

  var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
  }

  var buildNumber: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
  }

  var isDowngradeToStable: Bool { false }
  var usesManagedUpdatePolicy: Bool { false }
  var lastUpdateCheckDate: Date? { nil }

  private init() {}

  func checkForUpdates() {
    log("[sparkle-removed] UpdaterViewModel.checkForUpdates: no-op")
  }

  func checkForUpdatesInBackground() {}

  func checkForUpdatesImmediatelyAfterLaunchIfNeeded() {}

  func applyManagedUpdatePolicy() {}
}
