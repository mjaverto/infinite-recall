import Accelerate
import Foundation
import GRDB
import NaturalLanguage

// MARK: - LocalRAGService

/// Query-time retrieval service that fetches relevant local context (transcripts,
/// visual activity, memories, action items) to inject into the chat system prompt.
///
/// Design constraints:
/// - No new dependencies: NLEmbedding (Apple) + GRDB + raw SQL only.
/// - Must complete in < 200 ms; uses DB-side candidate pre-filtering before
///   cosine re-ranking.
/// - Total injected text is capped at ~12,000 chars (~3,000 tokens).
/// - Does NOT write to any tables; read-only access via RewindDatabase.shared.
actor LocalRAGService {
    static let shared = LocalRAGService()

    private init() {}

    // MARK: - Token budget

    private let maxContextChars = 12_000

    // MARK: - Public entry point

    /// Build a LOCAL CONTEXT block for `query` and return the formatted string.
    /// Returns an empty string when no data is found or the database is unavailable.
    func buildContext(for query: String) async -> String {
        let t0 = Date()

        guard let db = await RewindDatabase.shared.getDatabaseQueue() else {
            log("LocalRAGService: database not ready, skipping retrieval")
            return ""
        }

        async let transcriptHits = fetchTranscriptHits(query: query, db: db)
        async let visualHits = fetchVisualHits(query: query, db: db)
        async let memoryHits = fetchMemoryHits(query: query, db: db)
        async let actionHits = fetchActionItemHits(query: query, db: db)

        let (transcripts, visuals, memories, actions) = await (
            transcriptHits, visualHits, memoryHits, actionHits
        )

        let block = formatContextBlock(
            transcripts: transcripts,
            visuals: visuals,
            memories: memories,
            actions: actions
        )

        let elapsed = Date().timeIntervalSince(t0) * 1000
        log(
            "LocalRAGService: retrieval done in \(String(format: "%.0f", elapsed)) ms — "
                + "transcripts:\(transcripts.count) visuals:\(visuals.count) "
                + "memories:\(memories.count) actions:\(actions.count) "
                + "chars:\(block.count)"
        )

        return block
    }

    // MARK: - Transcript retrieval (semantic via NLEmbedding)

    private struct TranscriptHit {
        let date: Date
        let snippet: String
    }

    /// Embed the query, pull the top-100 session candidates ordered by recency,
    /// join their segments, concatenate per-session text, compute cosine, pick top-8.
    private func fetchTranscriptHits(query: String, db: DatabasePool) async -> [TranscriptHit] {
        let queryVec = embedText(query)
        guard !isZero(queryVec) else {
            return await fetchTranscriptsFallback(query: query, db: db)
        }

        do {
            // Pull up to 100 recent sessions with at least one segment.
            let sessions: [(id: Int64, startedAt: Date)] = try await db.read { database in
                try Row.fetchAll(
                    database,
                    sql: """
                        SELECT ts.id, ts.startedAt
                        FROM transcription_sessions ts
                        WHERE ts.deleted = 0
                          AND ts.discarded = 0
                          AND ts.startedAt >= datetime('now', '-30 days')
                        ORDER BY ts.startedAt DESC
                        LIMIT 100
                        """
                ).compactMap { row -> (Int64, Date)? in
                    guard let id: Int64 = row["id"],
                        let startedAt: Date = row["startedAt"]
                    else { return nil }
                    return (id, startedAt)
                }
            }

            guard !sessions.isEmpty else { return [] }

            // For each session fetch concatenated segment text (capped to avoid huge blobs).
            var candidates: [(date: Date, text: String)] = []
            for session in sessions {
                let segText: String = try await db.read { database in
                    let rows = try Row.fetchAll(
                        database,
                        sql: """
                            SELECT text FROM transcription_segments
                            WHERE sessionId = ?
                            ORDER BY segmentOrder ASC
                            LIMIT 40
                            """,
                        arguments: [session.id]
                    )
                    return rows.compactMap { $0["text"] as? String }.joined(separator: " ")
                }
                if !segText.isEmpty {
                    candidates.append((date: session.startedAt, text: segText))
                }
            }

            guard !candidates.isEmpty else { return [] }

            // Score each candidate by cosine similarity against the query vector.
            var scored: [(similarity: Float, date: Date, text: String)] = candidates.map {
                let docVec = embedText($0.text)
                let sim = isZero(docVec) ? 0 : dotProduct(queryVec, docVec)
                return (sim, $0.date, $0.text)
            }
            scored.sort { $0.similarity > $1.similarity }

            return scored.prefix(8).map { item in
                let snippet = String(item.text.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
                return TranscriptHit(date: item.date, snippet: snippet)
            }
        } catch {
            logError("LocalRAGService: transcript fetch failed", error: error)
            return []
        }
    }

    /// Fallback when NLEmbedding returns zero vector: return most recent 5 sessions.
    private func fetchTranscriptsFallback(query: String, db: DatabasePool) async -> [TranscriptHit] {
        do {
            return try await db.read { database in
                let rows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT ts.startedAt, ts.title, seg.text
                        FROM transcription_sessions ts
                        LEFT JOIN (
                            SELECT sessionId, text FROM transcription_segments
                            WHERE segmentOrder = (
                                SELECT MIN(segmentOrder) FROM transcription_segments ts2
                                WHERE ts2.sessionId = transcription_segments.sessionId
                            )
                        ) seg ON seg.sessionId = ts.id
                        WHERE ts.deleted = 0 AND ts.discarded = 0
                        ORDER BY ts.startedAt DESC
                        LIMIT 5
                        """
                )
                return rows.compactMap { row -> TranscriptHit? in
                    guard let startedAt: Date = row["startedAt"] else { return nil }
                    let text: String =
                        (row["text"] as? String) ?? (row["title"] as? String) ?? "(no text)"
                    return TranscriptHit(date: startedAt, snippet: String(text.prefix(200)))
                }
            }
        } catch {
            return []
        }
    }

    // MARK: - Visual activity retrieval (FTS5)

    private struct VisualHit {
        let date: Date
        let appName: String
        let windowTitle: String?
        let summary: String?
    }

    private func fetchVisualHits(query: String, db: DatabasePool) async -> [VisualHit] {
        let ftsQuery = sanitizeFTSQuery(query)
        guard !ftsQuery.isEmpty else { return [] }

        do {
            return try await db.read { database in
                let rows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT va.sampledAt, va.appName, va.windowTitle, va.visualSummary
                        FROM visual_activity va
                        JOIN visual_activity_fts fts ON fts.rowid = va.id
                        WHERE visual_activity_fts MATCH ?
                          AND va.sampledAt >= datetime('now', '-14 days')
                        ORDER BY bm25(visual_activity_fts) ASC, va.sampledAt DESC
                        LIMIT 4
                        """,
                    arguments: [ftsQuery]
                )
                return rows.compactMap { row -> VisualHit? in
                    guard let sampledAt: Date = row["sampledAt"] else { return nil }
                    return VisualHit(
                        date: sampledAt,
                        appName: (row["appName"] as? String) ?? "Unknown",
                        windowTitle: row["windowTitle"] as? String,
                        summary: row["visualSummary"] as? String
                    )
                }
            }
        } catch {
            logError("LocalRAGService: visual_activity FTS failed", error: error)
            return []
        }
    }

    // MARK: - Memory retrieval (LIKE)

    private struct MemoryHit {
        let content: String
    }

    private func fetchMemoryHits(query: String, db: DatabasePool) async -> [MemoryHit] {
        // Simple keyword LIKE — memories are short facts, no need for FTS overhead.
        let keywords = extractKeywords(from: query)
        guard !keywords.isEmpty else { return await fetchRecentMemories(db: db) }

        do {
            return try await db.read { database in
                // Build OR of LIKE clauses for each keyword.
                let conditions = keywords.map { _ in "content LIKE ?" }.joined(separator: " OR ")
                let args: [DatabaseValueConvertible] = keywords.map { "%\($0)%" }

                let sql = """
                    SELECT content FROM memories
                    WHERE deleted = 0 AND (\(conditions))
                    ORDER BY createdAt DESC
                    LIMIT 4
                    """
                return try Row.fetchAll(database, sql: sql, arguments: StatementArguments(args))
                    .compactMap { row -> MemoryHit? in
                        guard let content: String = row["content"] else { return nil }
                        return MemoryHit(content: content)
                    }
            }
        } catch {
            logError("LocalRAGService: memory fetch failed", error: error)
            return []
        }
    }

    private func fetchRecentMemories(db: DatabasePool) async -> [MemoryHit] {
        do {
            return try await db.read { database in
                try Row.fetchAll(
                    database,
                    sql: """
                        SELECT content FROM memories
                        WHERE deleted = 0
                        ORDER BY createdAt DESC
                        LIMIT 4
                        """
                ).compactMap { row -> MemoryHit? in
                    guard let content: String = row["content"] else { return nil }
                    return MemoryHit(content: content)
                }
            }
        } catch {
            return []
        }
    }

    // MARK: - Action item retrieval (FTS5)

    private struct ActionHit {
        let description: String
        let completed: Bool
    }

    private func fetchActionItemHits(query: String, db: DatabasePool) async -> [ActionHit] {
        let ftsQuery = sanitizeFTSQuery(query)
        guard !ftsQuery.isEmpty else { return await fetchRecentActionItems(db: db) }

        do {
            return try await db.read { database in
                let rows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT a.description, a.completed
                        FROM action_items a
                        JOIN action_items_fts fts ON fts.rowid = a.id
                        WHERE action_items_fts MATCH ?
                          AND a.deleted = 0
                        ORDER BY bm25(action_items_fts) ASC
                        LIMIT 4
                        """,
                    arguments: [ftsQuery]
                )
                return rows.compactMap { row -> ActionHit? in
                    guard let desc: String = row["description"] else { return nil }
                    return ActionHit(description: desc, completed: (row["completed"] as? Bool) ?? false)
                }
            }
        } catch {
            logError("LocalRAGService: action_items FTS failed", error: error)
            return []
        }
    }

    private func fetchRecentActionItems(db: DatabasePool) async -> [ActionHit] {
        do {
            return try await db.read { database in
                try Row.fetchAll(
                    database,
                    sql: """
                        SELECT description, completed FROM action_items
                        WHERE deleted = 0 AND completed = 0
                        ORDER BY createdAt DESC
                        LIMIT 4
                        """
                ).compactMap { row -> ActionHit? in
                    guard let desc: String = row["description"] else { return nil }
                    return ActionHit(description: desc, completed: false)
                }
            }
        } catch {
            return []
        }
    }

    // MARK: - Context block formatter

    private func formatContextBlock(
        transcripts: [TranscriptHit],
        visuals: [VisualHit],
        memories: [MemoryHit],
        actions: [ActionHit]
    ) -> String {
        var parts: [String] = []
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]

        if !transcripts.isEmpty {
            var lines = ["RECENT CONVERSATIONS (top by relevance, last 30 days):"]
            for hit in transcripts {
                lines.append("- \(df.string(from: hit.date)) | \"\(hit.snippet)\"")
            }
            parts.append(lines.joined(separator: "\n"))
        }

        if !visuals.isEmpty {
            var lines = ["SCREEN ACTIVITY (visual context, last 14 days):"]
            for hit in visuals {
                var line = "- \(df.string(from: hit.date)) | \(hit.appName)"
                if let title = hit.windowTitle, !title.isEmpty {
                    line += " | \"\(title)\""
                }
                if let summary = hit.summary, !summary.isEmpty {
                    line += " — \(String(summary.prefix(120)))"
                }
                lines.append(line)
            }
            parts.append(lines.joined(separator: "\n"))
        }

        if !memories.isEmpty {
            var lines = ["MEMORIES:"]
            for hit in memories {
                lines.append("- \(hit.content)")
            }
            parts.append(lines.joined(separator: "\n"))
        }

        if !actions.isEmpty {
            var lines = ["ACTION ITEMS (open):"]
            for hit in actions {
                let marker = hit.completed ? "[x]" : "[ ]"
                lines.append("- \(marker) \(hit.description)")
            }
            parts.append(lines.joined(separator: "\n"))
        }

        guard !parts.isEmpty else { return "" }

        let joined = parts.joined(separator: "\n\n")
        // Hard-cap to maxContextChars
        if joined.count > maxContextChars {
            return String(joined.prefix(maxContextChars))
        }
        return joined
    }

    // MARK: - Embedding helpers

    /// Embed text synchronously using the shared NLEmbedding sentence model.
    /// Returns a zero vector when the model is unavailable.
    private func embedText(_ text: String) -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return zeroVec() }

        // Truncate to 2000 chars for the NLEmbedding model; longer strings are
        // fine to trim because the first portion dominates the query intent.
        let input = String(trimmed.prefix(2000))

        guard let model = NLEmbedding.sentenceEmbedding(for: .english),
              let vec = model.vector(for: input)
        else {
            return zeroVec()
        }

        return l2Normalize(vec.map { Float($0) })
    }

    private func zeroVec() -> [Float] {
        [Float](repeating: 0, count: 512)
    }

    private func isZero(_ vec: [Float]) -> Bool {
        var norm: Float = 0
        vDSP_svesq(vec, 1, &norm, vDSP_Length(vec.count))
        return norm < 1e-8
    }

    private func dotProduct(_ a: [Float], _ b: [Float]) -> Float {
        let len = min(a.count, b.count)
        guard len > 0 else { return 0 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(len))
        return result
    }

    private func l2Normalize(_ vec: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(vec, 1, &norm, vDSP_Length(vec.count))
        norm = sqrt(norm)
        guard norm > 1e-8 else { return vec }
        var out = [Float](repeating: 0, count: vec.count)
        var divisor = norm
        vDSP_vsdiv(vec, 1, &divisor, &out, 1, vDSP_Length(vec.count))
        return out
    }

    // MARK: - FTS / keyword helpers

    /// Sanitize input for FTS5 MATCH: keep letters, numbers, spaces, and *.
    private func sanitizeFTSQuery(_ query: String) -> String {
        let words = query
            .map { $0.isLetter || $0.isNumber || $0 == " " ? $0 : Character(" ") }
            .map(String.init)
            .joined()
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty && $0.count >= 3 }
        // Join with AND so all words must match (more precise than OR for RAG).
        return words.joined(separator: " ")
    }

    /// Extract short, meaningful keywords from a natural-language query.
    private func extractKeywords(from query: String) -> [String] {
        let stopwords: Set<String> = [
            "a", "an", "the", "is", "are", "was", "were", "be", "been", "being",
            "have", "has", "had", "do", "does", "did", "will", "would", "shall",
            "should", "may", "might", "must", "can", "could", "not", "no",
            "and", "or", "but", "in", "on", "at", "to", "for", "of", "with",
            "i", "my", "me", "you", "your", "we", "our", "it", "its",
            "what", "when", "where", "who", "how", "why", "which", "that", "this",
            "any", "all", "some", "just", "about", "up", "out", "if",
            "read", "know", "get", "tell", "show", "give", "use", "need",
            "can", "could", "also", "like", "then", "than", "so", "very",
            "convos", "conversations", "previous", "last", "recent",
        ]
        return query
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && $0.count >= 3 && !stopwords.contains($0) }
    }
}
