import Foundation

/// Renders a `MemoryPayload` as straight ASCII Markdown for the filesystem
/// integration. Pure function — same input always produces the same output,
/// renders from the captured payload (not a re-fetch), so the outbox
/// snapshot is authoritative.
enum MarkdownRenderer {
  /// Layout:
  /// 1. `# <title>` (or `# Untitled` if empty)
  /// 2. `*<ISO8601 createdAt>* — <category>` (omit ` — <category>` if empty)
  /// 3. `## Overview` + body, only if overview is non-empty
  /// 4. `## Action Items` + `- [ ] ...` checklist, only if any
  /// 5. `## Transcript` with `**speaker** _[mm:ss → mm:ss]_  text`
  ///    paragraphs, blank line between
  /// 6. Trailing newline.
  static func render(_ payload: MemoryPayload) -> String {
    var lines: [String] = []

    let title = payload.title.isEmpty ? "Untitled" : payload.title
    lines.append("# \(title)")
    lines.append("")

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    let timestamp = iso.string(from: payload.createdAt)
    if payload.category.isEmpty {
      lines.append("*\(timestamp)*")
    } else {
      lines.append("*\(timestamp)* — \(payload.category)")
    }
    lines.append("")

    if !payload.overview.isEmpty {
      lines.append("## Overview")
      lines.append("")
      lines.append(payload.overview)
      lines.append("")
    }

    if !payload.actionItems.isEmpty {
      lines.append("## Action Items")
      lines.append("")
      for item in payload.actionItems {
        lines.append("- [ ] \(item)")
      }
      lines.append("")
    }

    if !payload.transcriptSegments.isEmpty {
      lines.append("## Transcript")
      lines.append("")
      for (idx, segment) in payload.transcriptSegments.enumerated() {
        let speaker = (segment.speaker?.isEmpty == false) ? segment.speaker! : "Unknown"
        let startStr = formatMMSS(segment.start)
        let endStr = formatMMSS(segment.end)
        lines.append("**\(speaker)** _[\(startStr) → \(endStr)]_  \(segment.text)")
        if idx != payload.transcriptSegments.count - 1 {
          lines.append("")
        }
      }
      lines.append("")
    }

    // Single trailing newline. Joining with "\n" plus a final "\n".
    return lines.joined(separator: "\n") + "\n"
  }

  /// Formats seconds-from-start as `mm:ss`. Negative or NaN inputs clamp
  /// to `00:00`. Minutes are not padded past two digits — a 100-minute
  /// segment renders as `100:00`, which is fine for Markdown display.
  private static func formatMMSS(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "00:00" }
    let total = Int(seconds.rounded(.down))
    let m = total / 60
    let s = total % 60
    return String(format: "%02d:%02d", m, s)
  }
}
