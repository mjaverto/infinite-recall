import Foundation

/// Result of a filesystem dispatch. Carries the standard `DispatchOutcome`
/// plus an optional refreshed bookmark — non-nil only when the resolved
/// bookmark was `isStale` and we successfully re-created one. The caller
/// persists the new bookmark blob to the integrations table.
///
/// INVARIANT (not enforced by the type): `refreshedBookmark` is nil whenever
/// `outcome` is `.permanentFailure`. The producer (`FilesystemWriter.write`)
/// upholds this; safe-to-persist on any outcome via `if let refreshed`.
/// Revisit as a `WriteOutcome` enum (bookmark on success/retry only) post-v1.
struct WriteResult {
  let outcome: DispatchOutcome
  let refreshedBookmark: Data?
}

/// Writes a memory payload to a user-picked folder via security-scoped
/// bookmark. Path scheme: `<root>/YYYY/MM-DD/HHMMSS-<slug>.<ext>` in the
/// user's local timezone (matches what they see in the IR UI).
enum FilesystemWriter {
  /// Resolves the bookmark, builds the dated path, writes atomically.
  ///
  /// - Stale bookmark that we refresh successfully: returns the new
  ///   bookmark in `refreshedBookmark` AND continues with the write.
  /// - Bookmark resolve throws: `.permanentFailure` (user likely deleted
  ///   or unmounted the folder).
  /// - File I/O errors: treated as `.retry` (assume transient — better
  ///   to retry than lose data; iCloud-not-downloaded is the common case).
  static func write(
    payload: MemoryPayload,
    payloadJSON: Data,
    format: LocalIntegrationFormat,
    bookmark: Data
  ) async -> WriteResult {
    // 1. Resolve the security-scoped bookmark.
    var isStale = false
    let rootURL: URL
    do {
      rootURL = try URL(
        resolvingBookmarkData: bookmark,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
    } catch {
      return WriteResult(
        outcome: .permanentFailure(reason: "bookmark unresolvable: \(error.localizedDescription)"),
        refreshedBookmark: nil
      )
    }

    // 2. If stale, try to refresh — but don't fail the write if refresh
    //    itself throws; the resolved URL still works for this attempt.
    var refreshedBookmark: Data? = nil
    if isStale {
      do {
        refreshedBookmark = try rootURL.bookmarkData(
          options: [.withSecurityScope],
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        )
      } catch {
        // Stale and we can't re-bookmark — log so the failure isn't silent,
        // then keep going. The resolved URL still works for THIS write, but
        // on next launch the stale bookmark will resolve again (or fail).
        // Caller sees refreshedBookmark == nil.
        logError("FilesystemWriter: stale bookmark refresh failed; proceeding with this write but next launch may degrade", error: error)
      }
    }

    // 3. Acquire scope. ALWAYS pair with stop in defer.
    let didStart = rootURL.startAccessingSecurityScopedResource()
    defer {
      if didStart { rootURL.stopAccessingSecurityScopedResource() }
    }

    // 4. Compute dated subfolder + filename in the user's local timezone.
    //    Calendar.current uses the user's default TZ — do not pass an
    //    explicit TimeZone, per spec.
    let cal = Calendar.current
    let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: payload.createdAt)
    guard let year = comps.year, let month = comps.month, let day = comps.day,
          let hour = comps.hour, let minute = comps.minute, let second = comps.second
    else {
      return WriteResult(
        outcome: .permanentFailure(reason: "could not extract date components from createdAt"),
        refreshedBookmark: refreshedBookmark
      )
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
        return WriteResult(
          outcome: .permanentFailure(reason: "could not utf8-encode markdown"),
          refreshedBookmark: refreshedBookmark
        )
      }
      body = utf8
    }

    let dailyFolder = rootURL
      .appendingPathComponent(yearStr, isDirectory: true)
      .appendingPathComponent(monthDayStr, isDirectory: true)
    let fileURL = dailyFolder.appendingPathComponent("\(timeStr)-\(slug).\(ext)")

    // 5. Create directory + write atomically.
    do {
      try FileManager.default.createDirectory(
        at: dailyFolder,
        withIntermediateDirectories: true
      )
      try body.write(to: fileURL, options: .atomic)
      return WriteResult(outcome: .success, refreshedBookmark: refreshedBookmark)
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
        return WriteResult(outcome: .success, refreshedBookmark: refreshedBookmark)
      }
      // Everything else: retry. Losing a memory snapshot is worse than a
      // redundant retry tick.
      return WriteResult(outcome: .retry(reason: reason), refreshedBookmark: refreshedBookmark)
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
