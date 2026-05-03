// Infinite Recall fork: on-device speaker diarization. No cloud calls.
//
// Local-first replacement for the cloud Person store. The fork's existing
// NameSpeakerSheet UI consumes `Person` (declared in APIClient.swift) which
// originally came from `/v1/users/people`; we keep the same struct shape and
// hand it data from this GRDB-backed store instead.
//
// Used by AppState's `fetchPeople` / `createPerson` / `assignSpeakerToSegments`
// calls in the local-first fork.

import Foundation
import GRDB

/// One row in `people` (see migration in RewindDatabase.swift).
struct PersonRecord: Codable, FetchableRecord, PersistableRecord {
    var id: String
    var displayName: String
    var defaultEmoji: String?
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "people"

    /// Convert to the existing `Person` type used by the SwiftUI layer.
    func toPerson() -> Person {
        return Person(
            id: id,
            name: displayName,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

actor PeopleStore {
    static let shared = PeopleStore()

    private init() {}

    static func splitAssignmentTargets(_ segmentIds: [String]) -> (backendIds: [String], fallbackOrders: [Int]) {
        let backendIds = segmentIds.filter { !$0.hasPrefix("#index:") }
        let fallbackOrders = segmentIds.compactMap { token -> Int? in
            guard token.hasPrefix("#index:") else { return nil }
            return Int(token.dropFirst("#index:".count))
        }
        return (backendIds, fallbackOrders)
    }

    private static func canUseSegmentForVoiceTraining(text: String, start: Double, end: Double) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard end - start >= SpeakerEmbeddingStore.minimumMatchDuration else { return false }
        return !isNoiseOnly(trimmed)
    }

    private static func isNoiseOnly(_ text: String) -> Bool {
        let lowered = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lowered.isEmpty else { return true }

        let noiseWords = [
            "music", "gentle music", "background music", "noise", "silence",
            "applause", "laughter", "inaudible", "static", "beep", "tone"
        ]
        if noiseWords.contains(lowered) { return true }
        return noiseWords.contains { lowered == "[\($0)]" || lowered == "(\($0))" }
    }

    // MARK: - Read

    /// Fetch all known people, ordered by display name.
    func fetchAll() async -> [Person] {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return [] }
        do {
            let records: [PersonRecord] = try await dbQueue.read { db in
                try PersonRecord
                    .order(Column("displayName").asc)
                    .fetchAll(db)
            }
            return records.map { $0.toPerson() }
        } catch {
            logError("PeopleStore: fetchAll failed", error: error)
            await RewindDatabase.shared.reportQueryError(error)
            return []
        }
    }

    /// Look up by id.
    func fetch(id: String) async -> Person? {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return nil }
        do {
            return try await dbQueue.read { db in
                try PersonRecord.fetchOne(db, key: id)?.toPerson()
            }
        } catch {
            logError("PeopleStore: fetch(id:) failed", error: error)
            return nil
        }
    }

    // MARK: - Write

    /// Create a new person with a random UUID id.
    func create(name: String) async -> Person? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return nil }
        let now = Date()
        let record = PersonRecord(
            id: UUID().uuidString,
            displayName: trimmed,
            defaultEmoji: nil,
            createdAt: now,
            updatedAt: now
        )
        do {
            try await dbQueue.write { db in
                try record.insert(db)
            }
            log("PeopleStore: Created '\(trimmed)' (id=\(record.id))")
            return record.toPerson()
        } catch {
            logError("PeopleStore: create failed", error: error)
            await RewindDatabase.shared.reportQueryError(error)
            return nil
        }
    }

    /// Assign segments in a transcription session to a person (or to "is_user").
    /// Updates both the cached `transcription_segments.personId` / `isUser`
    /// columns AND backfills `speaker_embeddings.personId` so future
    /// auto-matching works the next time we hear this voice.
    @discardableResult
    func assignSegments(
        sessionId: Int64,
        segmentIds: [String],
        personId: String?,
        isUser: Bool
    ) async -> Bool {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return false }
        do {
            let splitTargets = Self.splitAssignmentTargets(segmentIds)
            let backendIds = splitTargets.backendIds
            let fallbackOrders = splitTargets.fallbackOrders
            // Update segment rows by their backend segment id (which is a UUID
            // generated locally for fork-mode segments — see TranscriptionService).
            let resolvedPerson = isUser ? nil : personId
            let resolvedIsUser = isUser
            try await dbQueue.write { db in
                if !backendIds.isEmpty {
                    let encodedIds = String(
                        decoding: try JSONEncoder().encode(backendIds),
                        as: UTF8.self
                    )
                    try db.execute(
                        sql: """
                            UPDATE transcription_segments
                            SET personId = ?, isUser = ?
                            WHERE sessionId = ? AND segmentId IN (
                                SELECT value FROM json_each(?)
                            )
                            """,
                        arguments: [resolvedPerson, resolvedIsUser, sessionId, encodedIds]
                    )
                }
                if !fallbackOrders.isEmpty {
                    let encodedOrders = String(
                        decoding: try JSONEncoder().encode(fallbackOrders),
                        as: UTF8.self
                    )
                    try db.execute(
                        sql: """
                            UPDATE transcription_segments
                            SET personId = ?, isUser = ?
                            WHERE sessionId = ? AND segmentOrder IN (
                                SELECT value FROM json_each(?)
                            )
                            """,
                        arguments: [resolvedPerson, resolvedIsUser, sessionId, encodedOrders]
                    )
                }

                var clauses: [String] = []
                var args: [DatabaseValueConvertible] = [sessionId]
                if !backendIds.isEmpty {
                    let placeholders = backendIds.map { _ in "?" }.joined(separator: ",")
                    clauses.append("segmentId IN (\(placeholders))")
                    args.append(contentsOf: backendIds)
                }
                if !fallbackOrders.isEmpty {
                    let placeholders = fallbackOrders.map { _ in "?" }.joined(separator: ",")
                    clauses.append("segmentOrder IN (\(placeholders))")
                    args.append(contentsOf: fallbackOrders)
                }
                guard !clauses.isEmpty else { return }
                let sql = """
                    SELECT speaker, text, startTime, endTime
                    FROM transcription_segments
                    WHERE sessionId = ? AND (\(clauses.joined(separator: " OR ")))
                    """
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                var bySpeaker: [Int: [SpeakerEmbeddingStore.AssignmentRange]] = [:]
                for row in rows {
                    let speaker: Int = row["speaker"]
                    let text: String = row["text"] ?? ""
                    let start: Double = row["startTime"]
                    let end: Double = row["endTime"]
                    bySpeaker[speaker, default: []].append(
                        SpeakerEmbeddingStore.AssignmentRange(
                            start: start,
                            end: end,
                            allowsTraining: Self.canUseSegmentForVoiceTraining(
                                text: text,
                                start: start,
                                end: end
                            )
                        )
                    )
                }
                for (sid, ranges) in bySpeaker {
                    try SpeakerEmbeddingStore.assignPersonToEmbeddings(
                        in: db,
                        sessionId: sessionId,
                        speakerId: sid,
                        personId: resolvedPerson,
                        overlapping: ranges
                    )
                }
            }
            await SpeakerEmbeddingStore.shared.reset()
            return true
        } catch {
            logError("PeopleStore: assignSegments failed", error: error)
            await RewindDatabase.shared.reportQueryError(error)
            return false
        }
    }

    func resetVoiceProfile(personId: String) async {
        await SpeakerEmbeddingStore.shared.resetVoiceProfile(personId: personId)
    }

    @discardableResult
    func deletePerson(id: String) async -> Bool {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return false }
        do {
            try await dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE transcription_segments SET personId = NULL WHERE personId = ?",
                    arguments: [id]
                )
                try db.execute(
                    sql: """
                        UPDATE speaker_embeddings
                        SET personId = NULL,
                            assignmentSource = NULL,
                            matchConfidence = NULL,
                            isTrainingSample = 0
                        WHERE personId = ?
                        """,
                    arguments: [id]
                )
                try db.execute(sql: "DELETE FROM people WHERE id = ?", arguments: [id])
            }
            await SpeakerEmbeddingStore.shared.reset()
            return true
        } catch {
            logError("PeopleStore: deletePerson failed", error: error)
            await RewindDatabase.shared.reportQueryError(error)
            return false
        }
    }

    @discardableResult
    func mergePerson(sourcePersonId: String, into targetPersonId: String) async -> Bool {
        guard sourcePersonId != targetPersonId else { return true }
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return false }
        do {
            // Atomic merge: transcripts + embeddings + person deletion in one write.
            try await dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE transcription_segments SET personId = ? WHERE personId = ?",
                    arguments: [targetPersonId, sourcePersonId]
                )
                try db.execute(
                    sql: """
                        UPDATE speaker_embeddings
                        SET personId = ?,
                            isTrainingSample = CASE
                                WHEN embeddingModel = ? AND embeddingVersion = ? THEN isTrainingSample
                                ELSE 0
                            END
                        WHERE personId = ?
                        """,
                    arguments: [
                        targetPersonId,
                        SpeakerEmbeddingStore.defaultEmbeddingModel,
                        SpeakerEmbeddingStore.defaultEmbeddingVersion,
                        sourcePersonId
                    ]
                )
                try db.execute(sql: "DELETE FROM people WHERE id = ?", arguments: [sourcePersonId])
            }
            await SpeakerEmbeddingStore.shared.reset()
            return true
        } catch {
            logError("PeopleStore: mergePerson failed", error: error)
            await RewindDatabase.shared.reportQueryError(error)
            return false
        }
    }
}
