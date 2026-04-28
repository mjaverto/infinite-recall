import Foundation
import GRDB

/// Loads + assembles a conversation's transcript from the
/// `transcription_segments` table, applying the same WhisperKit `<|...|>`
/// token-strip / trim / join pipeline the rest of the codebase uses.
///
/// Extracted from duplicated logic in
/// `ConversationSummaryBackfillService.fetchSession` and
/// `PowerWorkBridge.processExtractActionItems` (which also redeclared the
/// same min/max length constants). Single source of truth lives here so
/// both summarization and action-item extraction stay in lock-step.
///
/// Truncation is intentionally NOT done by the loader — callers decide
/// whether they want the raw assembled transcript or a length-capped slice
/// for an LLM prompt.
enum ConversationTranscriptLoader {

    /// Minimum assembled transcript length (chars) below which downstream
    /// callers (summary, action-item extraction) should write a placeholder
    /// or no-op rather than calling the LLM.
    static let minTranscriptLength = 30

    /// Maximum transcript length (chars) we ship to the local LLM in a single
    /// prompt. Callers truncate themselves so they can append their own
    /// "...truncated" marker if they want one.
    static let maxTranscriptLength = 6000

    /// Load all segment text rows for `sessionId` from the supplied database
    /// pool, strip WhisperKit `<|...|>` tokens, trim, drop empties, and join
    /// with spaces.
    ///
    /// Returns:
    /// - `nil` when no rows exist for the session (caller decides whether
    ///   that's an error or a no-op).
    /// - the assembled transcript otherwise (may still be empty if every
    ///   segment was whitespace/tokens-only).
    static func loadAssembled(sessionId: Int64, dbQueue: DatabasePool) async throws -> String? {
        let segmentSQL = """
            SELECT text FROM transcription_segments
             WHERE sessionId = ?
             ORDER BY segmentOrder ASC
            """
        let rawTexts: [String] = try await dbQueue.read { db in
            try String.fetchAll(db, sql: segmentSQL, arguments: [sessionId])
        }

        guard !rawTexts.isEmpty else { return nil }

        return rawTexts
            .map {
                $0.replacingOccurrences(
                    of: #"<\|[^|>]+\|>"#,
                    with: "",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Convenience that fetches the shared `RewindDatabase` queue. Throws
    /// `TranscriptionStorageError.databaseNotInitialized` when the pool isn't
    /// available (matches the call sites that previously inlined this).
    static func loadAssembled(sessionId: Int64) async throws -> String? {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw TranscriptionStorageError.databaseNotInitialized
        }
        return try await loadAssembled(sessionId: sessionId, dbQueue: dbQueue)
    }
}
