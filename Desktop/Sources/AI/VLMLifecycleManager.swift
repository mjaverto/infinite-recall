// Infinite Recall fork: local VLM (vision-language model) sidecar via
// mlx-vlm.server. Mirrors MLXLifecycleManager but for the image-text-to-text
// tier on 127.0.0.1:8081.
//
// Two-tier architecture: text tier (mlx-lm.server, 8080) handles transcripts +
// extraction; vision tier (mlx-vlm.server, 8081) handles screenshot/frame
// analysis. Each owns its own launchd agent + Python toolchain.

import Foundation
import SwiftUI

@MainActor
final class VLMLifecycleManager: ObservableObject {

  // MARK: - Singleton

  static let shared = VLMLifecycleManager()

  // MARK: - Configuration

  /// Reverse-DNS label of the launchd agent. Must match the plist `Label` key.
  static let launchdLabel = "com.infiniterecall.vlm"

  /// Default vision model id. Verified on huggingface.co:
  ///   - mlx-community/Qwen3-VL-8B-Instruct-4bit
  ///   - pipeline_tag: image-text-to-text
  ///   - license: Apache 2.0
  ///   - converted via mlx-vlm 0.3.4
  ///   - ~5–6 GB on disk for 4-bit weights
  static let defaultModelID = "mlx-community/Qwen3-VL-8B-Instruct-4bit"

  /// Path to the launchd plist once installed.
  static var installedPlistURL: URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home
      .appendingPathComponent("Library/LaunchAgents/\(launchdLabel).plist")
  }

  /// Path to the on-disk huggingface snapshot for the default model.
  static var defaultModelCacheURL: URL {
    modelCacheURL(for: defaultModelID)
  }

  static func modelCacheURL(for modelId: String) -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let slug = modelId.replacingOccurrences(of: "/", with: "--")
    return home
      .appendingPathComponent(".cache/huggingface/hub/models--\(slug)")
  }

  /// `@AppStorage("activeVisionModelID")` key. Mirrors the text tier pattern.
  static let activeModelDefaultsKey = "activeVisionModelID"

  /// The vision model id the user has selected, falling back to the default.
  static var activeModelID: String {
    UserDefaults.standard.string(forKey: activeModelDefaultsKey) ?? defaultModelID
  }

  // MARK: - Published state

  @Published private(set) var serverRunning: Bool = false
  @Published private(set) var agentInstalled: Bool = false
  @Published private(set) var modelPresent: Bool = false
  @Published private(set) var modelDownloadProgress: Double? = nil
  @Published private(set) var lastError: String? = nil
  @Published private(set) var hasRefreshedAtLeastOnce: Bool = false

  // MARK: - Polling

  private var pollTask: Task<Void, Never>?

  private init() {
    refreshSync()
  }

  func refreshSync() {
    let fm = FileManager.default
    self.agentInstalled = fm.fileExists(atPath: Self.installedPlistURL.path)
    self.modelPresent = fm.fileExists(atPath: Self.defaultModelCacheURL.path)
    self.hasRefreshedAtLeastOnce = true
  }

  func refresh() async {
    refreshSync()
    let reachable = await VisionLLMClient.shared.isReachable()
    self.serverRunning = reachable
    self.hasRefreshedAtLeastOnce = true
  }

  func startPolling(interval: TimeInterval = 5) {
    pollTask?.cancel()
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refresh()
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
      }
    }
  }

  func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
  }

  // MARK: - Per-model install state

  func isModelInstalled(modelId: String) -> Bool {
    FileManager.default.fileExists(
      atPath: Self.modelCacheURL(for: modelId).path)
  }

  // MARK: - launchctl commands

  @discardableResult
  func startServer() async -> Bool {
    guard agentInstalled else {
      lastError = "launchd agent not installed — run scripts/setup-vlm-server.sh"
      return false
    }
    let result = Self.runShell(
      "/bin/launchctl", arguments: ["start", Self.launchdLabel])
    if let err = result.stderr, !err.isEmpty {
      lastError = err
    }
    return result.exitCode == 0
  }

  @discardableResult
  func stopServer() async -> Bool {
    guard agentInstalled else { return false }
    let result = Self.runShell(
      "/bin/launchctl", arguments: ["stop", Self.launchdLabel])
    if let err = result.stderr, !err.isEmpty {
      lastError = err
    }
    return result.exitCode == 0
  }

  @discardableResult
  func loadAgent() async -> Bool {
    guard agentInstalled else { return false }
    let result = Self.runShell(
      "/bin/launchctl",
      arguments: ["load", Self.installedPlistURL.path])
    if let err = result.stderr, !err.isEmpty {
      lastError = err
    }
    return result.exitCode == 0
  }

  // MARK: - Process helper

  private struct ShellResult {
    let exitCode: Int32
    let stdout: String?
    let stderr: String?
  }

  private static func runShell(_ launchPath: String, arguments: [String]) -> ShellResult {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: launchPath)
    task.arguments = arguments

    let outPipe = Pipe()
    let errPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = errPipe

    do {
      try task.run()
    } catch {
      return ShellResult(
        exitCode: -1,
        stdout: nil,
        stderr: "Failed to launch \(launchPath): \(error.localizedDescription)")
    }

    task.waitUntilExit()

    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    return ShellResult(
      exitCode: task.terminationStatus,
      stdout: String(data: outData, encoding: .utf8),
      stderr: String(data: errData, encoding: .utf8))
  }
}
