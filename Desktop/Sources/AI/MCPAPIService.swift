// Infinite Recall fork: lifecycle + status surface for the local read-only
// REST API daemon (`Backend-Rust/`) that backs MCP integrations.
//
// Unlike `MLXLifecycleManager` (which manages the LLM sidecar), this service:
//   1. Knows where the API binary lives (under
//      `~/Library/Application Support/InfiniteRecall/bin/infinite-recall-api`).
//   2. Reads the bearer token from
//      `~/Library/Application Support/InfiniteRecall/api-token.txt`.
//   3. Pings `http://127.0.0.1:7331/v1/health` for liveness.
//   4. Drives the launchd agent under label `com.infiniterecall.api`.
//   5. Exposes a `testConnection()` that pretty-prints the actual API response
//      so users can verify their token works before wiring it into Claude
//      Code or Cursor.
//
// All `@Published` mutations stay on @MainActor.

import AppKit
import Foundation

@MainActor
final class MCPAPIService: ObservableObject {

  // MARK: - Singleton

  static let shared = MCPAPIService()

  // MARK: - Configuration

  /// Reverse-DNS label of the launchd agent. Must match the plist `Label` key
  /// emitted by `setup-api-server.sh` / `BundledScripts.apiLaunchdPlist`.
  static let launchdLabel = "com.infiniterecall.api"

  /// Loopback URL the daemon binds to.
  static let baseURL = URL(string: "http://127.0.0.1:7331")!

  /// Path to the installed binary (user-dir install path used by the in-app
  /// installer; the script also supports a `/usr/local/bin` install when run
  /// manually with sudo, but we treat the user-dir install as the canonical
  /// "is installed" signal for the UI).
  static var installedBinaryURL: URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(
      "Library/Application Support/InfiniteRecall/bin/infinite-recall-api")
  }

  /// Fallback binary location used by the manual sudo install.
  static let fallbackBinaryURL = URL(fileURLWithPath: "/usr/local/bin/infinite-recall-api")

  /// Path to the bearer token file (mode 0600, generated on first daemon run).
  static var tokenFileURL: URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(
      "Library/Application Support/InfiniteRecall/api-token.txt")
  }

  /// Path to the launchd plist once installed.
  static var installedPlistURL: URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(
      "Library/LaunchAgents/\(launchdLabel).plist")
  }

  // MARK: - Status types

  enum TestStatus: Equatable {
    case idle
    case testing
    case ok(httpStatus: Int, elapsedMs: Int)
    case failed(String)

    static func == (lhs: TestStatus, rhs: TestStatus) -> Bool {
      switch (lhs, rhs) {
      case (.idle, .idle), (.testing, .testing): return true
      case (.ok(let a, let b), .ok(let c, let d)): return a == c && b == d
      case (.failed(let a), .failed(let b)): return a == b
      default: return false
      }
    }
  }

  // MARK: - Published state

  /// True when the API binary exists at the expected install path.
  @Published private(set) var isInstalled: Bool = false
  /// True when `/v1/health` responds 200.
  @Published private(set) var isRunning: Bool = false
  /// Current bearer token from disk, or nil if the token file is missing.
  @Published private(set) var apiToken: String? = nil
  /// Result of the most recent `testConnection()` call.
  @Published private(set) var lastTestStatus: TestStatus = .idle
  /// Pretty-printed body of the most recent test response (truncated for UI).
  @Published private(set) var lastTestResponse: String = ""

  // MARK: - Private

  private var pollTask: Task<Void, Never>?
  /// Hard cap on `lastTestResponse` length so we never wedge the UI with a
  /// 50 KB JSON dump.
  private static let responsePreviewMaxChars = 4_000

  private init() {
    refreshSync()
  }

  // MARK: - Refresh

  /// Synchronously update everything we can read from disk (binary path +
  /// token file). Reachability stays async.
  func refreshSync() {
    let fm = FileManager.default
    let primary = fm.fileExists(atPath: Self.installedBinaryURL.path)
    let fallback = fm.fileExists(atPath: Self.fallbackBinaryURL.path)
    isInstalled = primary || fallback
    apiToken = readTokenFromDisk()
  }

  /// Async refresh: filesystem facts + a `/v1/health` ping.
  func refresh() async {
    refreshSync()
    isRunning = await pingHealth()
  }

  // MARK: - Polling

  /// Start a background poller that refreshes state every `interval` seconds.
  /// Idempotent — calling twice replaces the previous task.
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

  // MARK: - Connectivity

  private func pingHealth() async -> Bool {
    var req = URLRequest(url: Self.baseURL.appendingPathComponent("v1/health"))
    req.httpMethod = "GET"
    req.timeoutInterval = 2
    do {
      let (_, resp) = try await URLSession.shared.data(for: req)
      if let http = resp as? HTTPURLResponse {
        return (200...299).contains(http.statusCode)
      }
      return false
    } catch {
      return false
    }
  }

  // MARK: - Test connection

  /// Fires `GET /v1/health` followed by `GET /v1/conversations?limit=1` with
  /// the bearer token, and pretty-prints the second response into
  /// `lastTestResponse`. Sets `lastTestStatus` to `.ok` on overall success or
  /// `.failed` with a human-readable reason otherwise.
  func testConnection() async {
    lastTestStatus = .testing
    lastTestResponse = ""

    // 1. Health (no auth required).
    let healthURL = Self.baseURL.appendingPathComponent("v1/health")
    var healthReq = URLRequest(url: healthURL)
    healthReq.httpMethod = "GET"
    healthReq.timeoutInterval = 5

    let start = Date()
    let healthResult: (Data, URLResponse)
    do {
      healthResult = try await URLSession.shared.data(for: healthReq)
    } catch {
      lastTestStatus = .failed(
        "Couldn't reach \(healthURL.absoluteString): \(error.localizedDescription)")
      return
    }
    guard let healthHTTP = healthResult.1 as? HTTPURLResponse else {
      lastTestStatus = .failed("Unexpected response type from /v1/health")
      return
    }
    guard (200...299).contains(healthHTTP.statusCode) else {
      lastTestStatus = .failed("/v1/health returned HTTP \(healthHTTP.statusCode)")
      lastTestResponse = prettyJSON(from: healthResult.0) ?? Self.utf8Preview(healthResult.0)
      return
    }

    // 2. Authenticated probe.
    guard let token = apiToken ?? readTokenFromDisk(), !token.isEmpty else {
      lastTestStatus = .failed(
        "Token file missing at \(Self.tokenFileURL.path). Start the API once to generate it.")
      return
    }

    let convURL =
      Self.baseURL
      .appendingPathComponent("v1/conversations")
    var comps = URLComponents(url: convURL, resolvingAgainstBaseURL: false)!
    comps.queryItems = [URLQueryItem(name: "limit", value: "1")]
    var convReq = URLRequest(url: comps.url!)
    convReq.httpMethod = "GET"
    convReq.timeoutInterval = 5
    convReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    let convResult: (Data, URLResponse)
    do {
      convResult = try await URLSession.shared.data(for: convReq)
    } catch {
      lastTestStatus = .failed(
        "Couldn't reach /v1/conversations: \(error.localizedDescription)")
      return
    }
    let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

    guard let convHTTP = convResult.1 as? HTTPURLResponse else {
      lastTestStatus = .failed("Unexpected response type from /v1/conversations")
      return
    }

    let pretty = prettyJSON(from: convResult.0) ?? Self.utf8Preview(convResult.0)
    lastTestResponse = Self.truncatePreview(pretty)

    if (200...299).contains(convHTTP.statusCode) {
      lastTestStatus = .ok(httpStatus: convHTTP.statusCode, elapsedMs: elapsedMs)
    } else if convHTTP.statusCode == 401 {
      lastTestStatus = .failed("HTTP 401: token rejected. Check api-token.txt.")
    } else {
      lastTestStatus = .failed("/v1/conversations returned HTTP \(convHTTP.statusCode)")
    }
  }

  // MARK: - Pasteboard helpers

  /// Copy the bearer token to NSPasteboard. Returns true if a token was
  /// available and successfully written.
  @discardableResult
  func copyToken() -> Bool {
    guard let token = apiToken ?? readTokenFromDisk(), !token.isEmpty else {
      return false
    }
    let pb = NSPasteboard.general
    pb.clearContents()
    return pb.setString(token, forType: .string)
  }

  /// Copy the canonical `claude mcp add` one-liner (with the current token
  /// inlined) to the pasteboard. Returns true on success.
  @discardableResult
  func copyClaudeMCPAddCommand() -> Bool {
    guard let cmd = claudeMCPAddCommand() else { return false }
    let pb = NSPasteboard.general
    pb.clearContents()
    return pb.setString(cmd, forType: .string)
  }

  /// Build the canonical `claude mcp add` one-liner with the current token
  /// inlined, mirroring `docs/mcp-integration.md`. Returns nil if no token
  /// is available — the command is useless without one.
  func claudeMCPAddCommand() -> String? {
    guard let token = apiToken ?? readTokenFromDisk(), !token.isEmpty else { return nil }
    return
      "claude mcp add infinite-recall -- "
      + "npx -y mcp-rest-bridge "
      + "--base-url http://127.0.0.1:7331 "
      + "--bearer \"\(token)\""
  }

  /// User-facing masked form of the token: `••••••••••• …last4`. Returns a
  /// placeholder string when the token is missing.
  func maskedToken() -> String {
    guard let token = apiToken, !token.isEmpty else {
      return "(token file missing)"
    }
    let dots = String(repeating: "•", count: 11)
    let suffix = token.count >= 4 ? String(token.suffix(4)) : token
    return "\(dots) …\(suffix)"
  }

  // MARK: - launchctl wrappers

  /// Ask launchd to start the agent. Caller should `refresh()` afterwards.
  /// Returns false (no-op) if the launchd plist isn't installed yet.
  @discardableResult
  func startServer() async -> Bool {
    guard FileManager.default.fileExists(atPath: Self.installedPlistURL.path) else {
      return false
    }
    let r = Self.runShell("/bin/launchctl", arguments: ["start", Self.launchdLabel])
    return r.exitCode == 0
  }

  /// Ask launchd to stop the agent.
  @discardableResult
  func stopServer() async -> Bool {
    guard FileManager.default.fileExists(atPath: Self.installedPlistURL.path) else {
      return false
    }
    let r = Self.runShell("/bin/launchctl", arguments: ["stop", Self.launchdLabel])
    return r.exitCode == 0
  }

  /// Kick off the in-app API installer. Delegates to `LocalAIInstaller`.
  func installViaSheet() {
    Task { await LocalAIInstaller.shared.startAPIInstall() }
  }

  // MARK: - Implementation helpers

  private func readTokenFromDisk() -> String? {
    let url = Self.tokenFileURL
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let data = try? Data(contentsOf: url),
      let raw = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func prettyJSON(from data: Data) -> String? {
    guard !data.isEmpty,
      let obj = try? JSONSerialization.jsonObject(
        with: data, options: [.fragmentsAllowed]),
      let pretty = try? JSONSerialization.data(
        withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
      let s = String(data: pretty, encoding: .utf8)
    else {
      return nil
    }
    return s
  }

  private static func utf8Preview(_ data: Data) -> String {
    String(data: data, encoding: .utf8) ?? "(\(data.count) bytes, non-UTF-8)"
  }

  /// Cap the test-response preview so a giant payload doesn't blow up the UI.
  private static func truncatePreview(_ s: String) -> String {
    guard s.count > responsePreviewMaxChars else { return s }
    let idx = s.index(s.startIndex, offsetBy: responsePreviewMaxChars)
    return String(s[..<idx]) + "\n…(truncated)"
  }

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
        exitCode: -1, stdout: nil,
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
