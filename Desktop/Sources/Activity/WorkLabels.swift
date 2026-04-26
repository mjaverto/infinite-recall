// Activity Tab — Stream E.
//
// `humanLabel(_ work: PendingWork) -> String` — converts a scheduler
// `PendingWork` into a user-facing label like
// `"Transcribing 14:22:01 → 14:25:00 (en)"`.
//
// Used by:
//   - Stream G when reporting in-flight rows to Rust
//   - This module's UI when rendering rows
//
// Decoding is best-effort: every payload is opaque `Data`, but each
// producer (TranscriptionService, RewindIndexer, MemoryAssistant, etc.)
// follows a known JSON shape. If decoding fails we fall back to a
// generic "{Kind}…" label rather than crash.

import Foundation

public enum WorkLabels {

    // MARK: - Public API

    /// Produce a single-line, user-readable description of a PendingWork.
    public static func humanLabel(_ work: PendingWork) -> String {
        switch work.kind {
        case .transcribe:        return transcribeLabel(work.payload)
        case .ocr:               return ocrLabel(work.payload)
        case .summarize:         return summarizeLabel(work.payload)
        case .extractMemory:     return extractMemoryLabel(work.payload)
        case .extractActionItems: return extractActionItemsLabel(work.payload)
        }
    }

    // MARK: - Per-kind decoders

    /// Payload shape (TranscriptionService.swift §349):
    ///   { started_at: ISO8601, ended_at: ISO8601, duration_sec: Double,
    ///     language: String, mode: "ptt"|"conversation" }
    private static func transcribeLabel(_ payload: Data) -> String {
        guard let dict = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return "Transcribing audio…"
        }
        let lang = (dict["language"] as? String) ?? "?"
        let started = parseISO8601(dict["started_at"] as? String)
        let ended   = parseISO8601(dict["ended_at"] as? String)
        if let s = started, let e = ended {
            return "Transcribing \(timeStr(s)) → \(timeStr(e)) (\(lang))"
        }
        if let s = started {
            return "Transcribing from \(timeStr(s)) (\(lang))"
        }
        return "Transcribing audio (\(lang))"
    }

    /// Payload shape (RewindIndexer.swift §169):
    ///   { screenshot_id: Int }
    private static func ocrLabel(_ payload: Data) -> String {
        guard let dict = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return "Reading screen capture"
        }
        if let id = dict["screenshot_id"] as? Int {
            return "Reading screen capture #\(id)"
        }
        if let n = dict["screenshot_id"] as? NSNumber {
            return "Reading screen capture #\(n.intValue)"
        }
        return "Reading screen capture"
    }

    /// Payload shape (assistant): { id: Int|String, ... }
    private static func summarizeLabel(_ payload: Data) -> String {
        if let id = decodeId(payload) {
            return "Summarizing conversation #\(id)"
        }
        return "Summarizing conversation"
    }

    private static func extractMemoryLabel(_ payload: Data) -> String {
        if let id = decodeId(payload) {
            return "Extracting memories from #\(id)"
        }
        return "Extracting memories"
    }

    private static func extractActionItemsLabel(_ payload: Data) -> String {
        if let id = decodeId(payload) {
            return "Finding action items in #\(id)"
        }
        return "Finding action items"
    }

    // MARK: - Helpers

    /// Look for a common `id` field in an opaque JSON payload.
    /// Accepts: id, conversation_id, transcript_id, source_id.
    private static func decodeId(_ payload: Data) -> String? {
        guard let dict = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        for key in ["id", "conversation_id", "transcript_id", "source_id"] {
            if let v = dict[key] as? Int { return String(v) }
            if let v = dict[key] as? NSNumber { return v.stringValue }
            if let v = dict[key] as? String, !v.isEmpty { return v }
        }
        return nil
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601NoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseISO8601(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        return iso8601.date(from: s) ?? iso8601NoFrac.date(from: s)
    }

    private static let hms: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func timeStr(_ d: Date) -> String { hms.string(from: d) }
}
