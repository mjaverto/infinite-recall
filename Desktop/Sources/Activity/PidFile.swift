// Writes the running app's PID to
// `~/Library/Application Support/InfiniteRecall/swift.pid` so the Rust
// daemon's resource sampler (Backend-Rust/api/src/activity/resources.rs)
// can attribute CPU/RSS to the Swift app without having to shell out to
// pgrep on every poll.
//
// The file is removed on graceful quit by `PidFile.cleanup()`. A stale
// file from a crash is harmless: the daemon `kill(pid, 0)`s every entry
// and silently drops dead pids.

import Foundation

enum PidFile {
  /// Resolve the pidfile URL. Mirrors `default_support_dir()` + `swift.pid`
  /// on the Rust side.
  static var swiftPidURL: URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(
      "Library/Application Support/InfiniteRecall/swift.pid")
  }

  /// Write the current PID to the pidfile. Creates the parent dir if
  /// needed. Best-effort — failures are logged and swallowed because the
  /// daemon's pgrep fallback covers a missing pidfile.
  static func writeSelf() {
    let url = swiftPidURL
    let parent = url.deletingLastPathComponent()
    do {
      try FileManager.default.createDirectory(
        at: parent, withIntermediateDirectories: true)
      let pid = ProcessInfo.processInfo.processIdentifier
      try "\(pid)\n".write(to: url, atomically: true, encoding: .utf8)
      log("PidFile: wrote pid=\(pid) to \(url.path)")
    } catch {
      log("PidFile: failed to write \(url.path): \(error.localizedDescription)")
    }
  }

  /// Remove the pidfile. Safe to call when the file is missing.
  static func cleanup() {
    let url = swiftPidURL
    do {
      try FileManager.default.removeItem(at: url)
      log("PidFile: removed \(url.path)")
    } catch CocoaError.fileNoSuchFile {
      // Already gone — nothing to do.
    } catch {
      log("PidFile: failed to remove \(url.path): \(error.localizedDescription)")
    }
  }
}
