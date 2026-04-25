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
            // Update segment rows by their backend segment id (which is a UUID
            // generated locally for fork-mode segments — see TranscriptionService).
            let resolvedPerson = isUser ? nil : personId
            let resolvedIsUser = isUser
            try await dbQueue.write { db in
                for segId in segmentIds {
                    try db.execute(
                        sql: """
                            UPDATE transcription_segments
                            SET personId = ?, isUser = ?
                            WHERE sessionId = ? AND segmentId = ?
                            """,
                        arguments: [resolvedPerson, resolvedIsUser, sessionId, segId]
                    )
                }
            }

            // Backfill embeddings for the speakerIds covered by these segments.
            // We look up each segment's `speaker` column and call into the
            // embedding store.
            let speakerIds: [Int] = try await dbQueue.read { db in
                let placeholders = segmentIds.map { _ in "?" }.joined(separator: ",")
                let sql = """
                    SELECT DISTINCT speaker FROM transcription_segments
                    WHERE sessionId = ? AND segmentId IN (\(placeholders))
                    """
                let args: [DatabaseValueConvertible] = [sessionId] + segmentIds
                return try Int.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }
            for sid in speakerIds {
                await SpeakerEmbeddingStore.shared.assignPersonToEmbeddings(
                    sessionId: sessionId,
                    speakerId: sid,
                    personId: isUser ? nil : personId
                )
            }
            return true
        } catch {
            logError("PeopleStore: assignSegments failed", error: error)
            await RewindDatabase.shared.reportQueryError(error)
            return false
        }
    }
}
