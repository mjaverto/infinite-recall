// Singleton-fixer S1: read the local Rust daemon's bearer token from disk.
//
// The Rust daemon at `Backend-Rust/api/src/token.rs::token_path()` writes
// the token to:
//   ~/Library/Application Support/InfiniteRecall/api-token.txt
// (mode 0600; honours `INFINITE_RECALL_TOKEN_PATH` if set).
//
// The previous `activityHeaders()` implementation called
// `AuthService.shared.getAuthHeader()`, which throws `notSignedIn` in this
// fork (Firebase removed). The throw was swallowed by `try?`, so requests
// went out with NO `Authorization` header and the daemon's `authed`
// middleware (`Backend-Rust/api/src/auth.rs`) returned 401 for every
// Activity tab call. Tests use a hardcoded `TEST_TOKEN` so CI never saw
// the bug. This helper reads the same on-disk file the daemon generates
// and caches it in memory (token is regenerated only on file delete + the
// daemon restart, so caching across an app session is safe).

import Foundation

/// Reads the local Rust daemon's bearer token from disk.
///
/// Thread-safe via `os_unfair_lock`-equivalent NSLock. The cache is keyed
/// on the resolved file path so an env-var override (e.g. tests setting
/// `INFINITE_RECALL_TOKEN_PATH`) bypasses a stale cached value from the
/// default path.
enum LocalDaemonToken {

  /// Errors surfaced when the daemon token can't be read.
  enum TokenError: LocalizedError {
    case fileMissing(URL)
    case unreadable(URL, underlying: Error)
    case empty(URL)

    var errorDescription: String? {
      switch self {
      case .fileMissing(let url):
        return
          "daemon token unavailable — is the backend running? (no file at \(url.path))"
      case .unreadable(let url, let err):
        return "daemon token at \(url.path) unreadable: \(err.localizedDescription)"
      case .empty(let url):
        return "daemon token at \(url.path) is empty"
      }
    }
  }

  // Single in-memory cache. We deliberately do NOT invalidate on a timer:
  // the daemon writes the token once on first launch and never rotates it
  // within an app session. If the file is deleted out from under us, the
  // next 401 from the daemon will surface in `ActivityMonitorService.lastError`
  // and the user can fix it.
  private static let lock = NSLock()
  private static var cachedToken: String?
  private static var cachedFromPath: String?

  /// Resolve the token file URL. Mirrors `token::token_path()` on the Rust side.
  static var tokenFileURL: URL {
    if let override = ProcessInfo.processInfo.environment["INFINITE_RECALL_TOKEN_PATH"],
      !override.isEmpty
    {
      return URL(fileURLWithPath: override)
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(
      "Library/Application Support/InfiniteRecall/api-token.txt")
  }

  /// Read the daemon token from disk (cached in memory after first read).
  /// Throws a typed `TokenError` so callers can render a useful message
  /// rather than silently 401-looping.
  static func read() throws -> String {
    let url = tokenFileURL
    let path = url.path

    lock.lock()
    defer { lock.unlock() }

    if let cached = cachedToken, cachedFromPath == path, !cached.isEmpty {
      return cached
    }

    guard FileManager.default.fileExists(atPath: path) else {
      throw TokenError.fileMissing(url)
    }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw TokenError.unreadable(url, underlying: error)
    }
    let raw = String(data: data, encoding: .utf8) ?? ""
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      throw TokenError.empty(url)
    }
    cachedToken = trimmed
    cachedFromPath = path
    return trimmed
  }

  /// Test/diagnostic hook: clear the in-memory cache.
  static func resetCache() {
    lock.lock()
    defer { lock.unlock() }
    cachedToken = nil
    cachedFromPath = nil
  }
}
