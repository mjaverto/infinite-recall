import Foundation

/// Writes a memory payload to a user-picked folder. Path scheme:
/// `<root>/YYYY/MM-DD/HHMMSS-<slug>.<ext>` in the user's local timezone
/// (matches what they see in the IR UI).
///
/// The app is non-sandboxed, so a plain path string is the I/O source of
/// truth — no security-scoped bookmarks. (Bookmarks were the cause of
/// intermittent Cocoa 259 "bookmark unresolvable" errors when Google
/// Drive's File Provider remounted and changed the volume UUID.)
enum FilesystemWriter {
  /// Builds the dated path and writes atomically.
  ///
  /// - Empty `folderPath`: `.permanentFailure` (caller should never pass
  ///   one, but defend so a bad row can't loop forever).
  /// - File I/O errors: treated as `.retry` (assume transient — better
  ///   to retry than lose data; iCloud-not-downloaded is the common case).
  static func write(
    payload: MemoryPayload,
    payloadJSON: Data,
    format: LocalIntegrationFormat,
    folderPath: String
  ) async -> DispatchOutcome {
    guard !folderPath.isEmpty else {
      return .permanentFailure(reason: "no folder path")
    }
    let rootURL = URL(fileURLWithPath: folderPath)

    // Compute dated subfolder + filename in the user's local timezone.
    // Calendar.current uses the user's default TZ — do not pass an
    // explicit TimeZone, per spec.
    let cal = Calendar.current
    let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: payload.createdAt)
    guard let year = comps.year, let month = comps.month, let day = comps.day,
          let hour = comps.hour, let minute = comps.minute, let second = comps.second
    else {
      return .permanentFailure(reason: "could not extract date components from createdAt")
    }

    let yearStr = String(format: "%04d", year)
    let monthDayStr = String(format: "%02d-%02d", month, day)
    let timeStr = String(format: "%02d%02d%02d", hour, minute, second)

    let slug = slugify(payload.title)
    let ext: String
    let body: Data
    switch format {
    case .json:
      ext = "json"
      body = payloadJSON
    case .markdown:
      ext = "md"
      let rendered = MarkdownRenderer.render(payload)
      // .data(using: .utf8) on a Swift String is non-throwing-non-nil for
      // valid Strings; force-unwrap is safe here but we guard for paranoia.
      guard let utf8 = rendered.data(using: .utf8) else {
        return .permanentFailure(reason: "could not utf8-encode markdown")
      }
      body = utf8
    }

    let dailyFolder = rootURL
      .appendingPathComponent(yearStr, isDirectory: true)
      .appendingPathComponent(monthDayStr, isDirectory: true)
    let fileURL = dailyFolder.appendingPathComponent("\(timeStr)-\(slug).\(ext)")

    // Create directory + write atomically.
    do {
      try FileManager.default.createDirectory(
        at: dailyFolder,
        withIntermediateDirectories: true
      )
      try body.write(to: fileURL, options: .atomic)
      return .success
    } catch let nsError as NSError {
      // Map known transient cases to retry. Anything we don't recognize
      // also retries — losing a memory snapshot is worse than a redundant
      // retry tick.
      let domain = nsError.domain
      let code = nsError.code
      let reason = "\(domain) \(code): \(nsError.localizedDescription)"
      // File-already-exists means a previous attempt already wrote this
      // payload to disk and we crashed before `markSuccess` could delete the
      // outbox row. Treat as idempotent success so the retry doesn't loop
      // forever and eventually escalate to permanent failure.
      if domain == NSCocoaErrorDomain && code == NSFileWriteFileExistsError {
        log("FilesystemWriter: file already exists at \(fileURL.path) — treating as idempotent success")
        return .success
      }
      // TCC denial / read-only filesystem / explicit "no permission" — retrying
      // is futile until the user grants access in System Settings → Privacy &
      // Security → Files and Folders. Mark permanent so the row parks (30 days)
      // and the lastError surfaces in the integrations table; user can re-pick
      // or "Retry now" once they've fixed the permission.
      if (domain == NSCocoaErrorDomain && code == NSFileWriteNoPermissionError)
          || (domain == NSPOSIXErrorDomain && code == Int(EACCES)) {
        return .permanentFailure(reason: reason)
      }
      // Everything else: retry. Losing a memory snapshot is worse than a
      // redundant retry tick.
      return .retry(reason: reason)
    }
  }

  /// Slug rules: lowercase ASCII, runs of non-`[a-z0-9]` collapse to a
  /// single `-`, trim leading/trailing `-`, max 60 chars, fall back to
  /// `"untitled"` if empty.
  ///
  /// Non-ASCII characters (accents, CJK, emoji) are dropped on the
  /// `applyingTransform` step. A title of pure non-ASCII therefore slugs
  /// to `"untitled"` — flagged for human review.
  private static func slugify(_ raw: String) -> String {
    // Strip diacritics + transliterate to Latin where possible.
    let folded = raw
      .applyingTransform(.toLatin, reverse: false)?
      .applyingTransform(.stripDiacritics, reverse: false) ?? raw

    let lowered = folded.lowercased()

    // Replace any run of non-[a-z0-9] with a single '-'.
    var out = ""
    var lastWasDash = false
    for scalar in lowered.unicodeScalars {
      let c = Character(scalar)
      let isAllowed = (c >= "a" && c <= "z") || (c >= "0" && c <= "9")
      if isAllowed {
        out.append(c)
        lastWasDash = false
      } else {
        if !lastWasDash {
          out.append("-")
          lastWasDash = true
        }
      }
    }

    // Trim leading/trailing dashes.
    while out.first == "-" { out.removeFirst() }
    while out.last == "-" { out.removeLast() }

    // Cap at 60 chars; re-trim trailing dash in case the cut landed on one.
    if out.count > 60 {
      out = String(out.prefix(60))
      while out.last == "-" { out.removeLast() }
    }

    return out.isEmpty ? "untitled" : out
  }
}
