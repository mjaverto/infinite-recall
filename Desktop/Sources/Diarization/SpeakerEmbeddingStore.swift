// Infinite Recall fork: on-device speaker diarization. No cloud calls.
//
// Persists per-segment speaker embeddings to GRDB and answers conservative
// nearest-neighbor queries used by `SpeakerDiarizationService` to map a fresh
// embedding to an existing person.

import Foundation
import GRDB

/// One row in `speaker_embeddings`. See migration in RewindDatabase.swift.
struct SpeakerEmbeddingRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var sessionId: Int64
    var chunkId: Int64?
    var embedding: Data        // Float32 little-endian vector
    var embeddingDim: Int
    var startTime: Double
    var endTime: Double
    var speakerId: Int?        // local cluster id within the session (0, 1, 2…)
    var personId: String?      // FK to people.id once user names this voice
    var assignmentSource: String?
    var matchConfidence: Double?
    var embeddingModel: String?
    var embeddingVersion: Int?
    var isTrainingSample: Bool?
    var createdAt: Date

    static let databaseTableName = "speaker_embeddings"

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    /// Decode the stored BLOB back into a Float32 vector.
    var vector: [Float] {
        let count = embedding.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        _ = out.withUnsafeMutableBytes { raw in
            embedding.copyBytes(to: raw)
        }
        return out
    }

    /// Encode a Float32 vector to a packed Data BLOB.
    static func encode(_ vector: [Float]) -> Data {
        return vector.withUnsafeBufferPointer { buf in
            Data(buffer: buf)
        }
    }
}

enum VoiceProfileAssignmentSource: String {
    case manual
    case autoHighConfidence = "auto_high_confidence"
    case suggestedConfirmed = "suggested_confirmed"
}

enum VoiceMatchDecision: Equatable {
    case known(personId: String, similarity: Float, margin: Float, sampleCount: Int)
    case suggested(personId: String, similarity: Float, margin: Float, sampleCount: Int)
    case unknown(bestSimilarity: Float?)

    var personIdForTranscript: String? {
        if case .known(let personId, _, _, _) = self { return personId }
        return nil
    }

    var similarity: Float? {
        switch self {
        case .known(_, let similarity, _, _), .suggested(_, let similarity, _, _):
            return similarity
        case .unknown(let bestSimilarity):
            return bestSimilarity
        }
    }
}

enum SpeakerEmbeddingStoreError: Error {
    case databaseUnavailable
}

/// Actor that owns DB I/O for speaker embeddings + the in-memory match index.
actor SpeakerEmbeddingStore {
    static let shared = SpeakerEmbeddingStore()

    static let defaultEmbeddingModel = "mfcc"
    static let defaultEmbeddingVersion = 1
    static let knownMatchThreshold: Float = 0.82
    static let suggestedMatchThreshold: Float = 0.70
    static let knownMatchMargin: Float = 0.08
    static let suggestedMatchMargin: Float = 0.04
    static let minimumKnownSampleCount = 3
    static let minimumSuggestedSampleCount = 1
    static let minimumMatchDuration: Double = 0.8

    private struct PersonVoiceProfile {
        var centroid: [Float]
        var sampleCount: Int
        var totalDuration: Double
    }

    struct AssignmentRange {
        let start: Double
        let end: Double
        let allowsTraining: Bool

        init(start: Double, end: Double, allowsTraining: Bool = true) {
            self.start = start
            self.end = end
            self.allowsTraining = allowsTraining
        }
    }

    /// Cached centroid embedding per person (mean of their stored embeddings).
    /// Recomputed lazily on first match call after a new embedding is recorded.
    private var personProfiles: [String: PersonVoiceProfile] = [:]
    private var centroidsLoaded: Bool = false

    private init() {}

    private static func canUseAsTrainingSample(
        embeddingModel: String,
        embeddingVersion: Int,
        startTime: Double,
        endTime: Double
    ) -> Bool {
        embeddingModel == defaultEmbeddingModel
            && embeddingVersion == defaultEmbeddingVersion
            && max(0, endTime - startTime) >= minimumMatchDuration
    }

    // MARK: - Insertion

    @discardableResult
    func recordEmbedding(
        sessionId: Int64,
        chunkId: Int64?,
        embedding: [Float],
        startTime: Double,
        endTime: Double,
        speakerId: Int?,
        personId: String?,
        assignmentSource: VoiceProfileAssignmentSource? = nil,
        matchConfidence: Float? = nil,
        embeddingModel: String = SpeakerEmbeddingStore.defaultEmbeddingModel,
        embeddingVersion: Int = SpeakerEmbeddingStore.defaultEmbeddingVersion,
        isTrainingSample: Bool? = nil
    ) async -> Int64? {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            log("SpeakerEmbeddingStore: DB not initialized — dropping embedding")
            return nil
        }
        let canTrainThisSample = Self.canUseAsTrainingSample(
            embeddingModel: embeddingModel,
            embeddingVersion: embeddingVersion,
            startTime: startTime,
            endTime: endTime
        )
        let inferredTrainingSample = (personId != nil
                                      && canTrainThisSample
                                      && assignmentSource != .autoHighConfidence)
        let requestedTrainingSample = isTrainingSample ?? inferredTrainingSample
        let storedMatchConfidence = personId == nil ? nil : matchConfidence
        let record = SpeakerEmbeddingRecord(
            id: nil,
            sessionId: sessionId,
            chunkId: chunkId,
            embedding: SpeakerEmbeddingRecord.encode(embedding),
            embeddingDim: embedding.count,
            startTime: startTime,
            endTime: endTime,
            speakerId: speakerId,
            personId: personId,
            assignmentSource: assignmentSource?.rawValue,
            matchConfidence: storedMatchConfidence.map(Double.init),
            embeddingModel: embeddingModel,
            embeddingVersion: embeddingVersion,
            // Never treat short/noisy or non-default-model embeddings as MFCC training samples.
            isTrainingSample: requestedTrainingSample && canTrainThisSample,
            createdAt: Date()
        )
        do {
            let insertedId = try await dbQueue.write { db -> Int64 in
                try record.insert(db)
                return db.lastInsertedRowID
            }
            // If this embedding is associated with a person, invalidate the centroid.
            if let pid = personId {
                personProfiles.removeValue(forKey: pid)
                centroidsLoaded = false
            }
            return insertedId
        } catch {
            logError("SpeakerEmbeddingStore: insert failed", error: error)
            await RewindDatabase.shared.reportQueryError(error)
            return nil
        }
    }

    /// Backfill `personId` on previously-recorded embeddings (e.g. when the
    /// user names "Speaker 1" mid-conversation).
    @discardableResult
    func assignPersonToEmbeddings(
        sessionId: Int64,
        speakerId: Int,
        personId: String?
    ) async throws -> Int {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw SpeakerEmbeddingStoreError.databaseUnavailable
        }
        do {
            let updated = try await dbQueue.write { db in
                try Self.assignPersonToEmbeddings(
                    in: db,
                    sessionId: sessionId,
                    speakerId: speakerId,
                    personId: personId
                )
            }
            // Invalidate cached centroid so next match call rebuilds it.
            if let pid = personId { personProfiles.removeValue(forKey: pid) }
            centroidsLoaded = false
            return updated
        } catch {
            logError("SpeakerEmbeddingStore: backfill failed", error: error)
            await RewindDatabase.shared.reportQueryError(error)
            throw error
        }
    }

    /// Assign a person only for embeddings overlapping the provided time ranges.
    /// Used to avoid contaminating an entire session-local speaker cluster when
    /// the user tags only a subset of segments.
    @discardableResult
    func assignPersonToEmbeddings(
        sessionId: Int64,
        speakerId: Int,
        personId: String?,
        overlapping ranges: [(start: Double, end: Double)]
    ) async throws -> Int {
        guard !ranges.isEmpty else { return 0 }
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw SpeakerEmbeddingStoreError.databaseUnavailable
        }
        do {
            let assignmentRanges = ranges.map {
                AssignmentRange(start: $0.start, end: $0.end)
            }
            let updated = try await dbQueue.write { db in
                try Self.assignPersonToEmbeddings(
                    in: db,
                    sessionId: sessionId,
                    speakerId: speakerId,
                    personId: personId,
                    overlapping: assignmentRanges
                )
            }
            if let pid = personId { personProfiles.removeValue(forKey: pid) }
            centroidsLoaded = false
            return updated
        } catch {
            logError("SpeakerEmbeddingStore: ranged backfill failed", error: error)
            await RewindDatabase.shared.reportQueryError(error)
            throw error
        }
    }

    @discardableResult
    static func assignPersonToEmbeddings(
        in db: Database,
        sessionId: Int64,
        speakerId: Int,
        personId: String?,
        overlapping ranges: [AssignmentRange]? = nil
    ) throws -> Int {
        if let ranges {
            guard !ranges.isEmpty else { return 0 }
            return try assignPersonToEmbeddingsInRanges(
                in: db,
                sessionId: sessionId,
                speakerId: speakerId,
                personId: personId,
                ranges: ranges
            )
        }

        try db.execute(
            sql: """
                UPDATE speaker_embeddings
                SET personId = ?,
                    assignmentSource = ?,
                    matchConfidence = NULL,
                    isTrainingSample = CASE
                        WHEN ? IS NULL THEN 0
                        WHEN embeddingModel = ?
                          AND embeddingVersion = ?
                          AND (endTime - startTime) >= ? THEN 1
                        ELSE 0
                    END
                WHERE sessionId = ? AND speakerId = ?
                """,
            arguments: [
                personId,
                personId == nil ? nil : VoiceProfileAssignmentSource.manual.rawValue,
                personId,
                SpeakerEmbeddingStore.defaultEmbeddingModel,
                SpeakerEmbeddingStore.defaultEmbeddingVersion,
                SpeakerEmbeddingStore.minimumMatchDuration,
                sessionId,
                speakerId
            ]
        )
        return db.changesCount
    }

    private static func assignPersonToEmbeddingsInRanges(
        in db: Database,
        sessionId: Int64,
        speakerId: Int,
        personId: String?,
        ranges: [AssignmentRange]
    ) throws -> Int {
        var updatedRows = 0
        for range in ranges {
            // Overlap test: [startTime, endTime] intersects [range.start, range.end].
            try db.execute(
                sql: """
                    UPDATE speaker_embeddings
                    SET personId = ?,
                        assignmentSource = ?,
                        matchConfidence = NULL,
                        isTrainingSample = 0
                    WHERE sessionId = ?
                      AND speakerId = ?
                      AND NOT (endTime <= ? OR startTime >= ?)
                    """,
                arguments: [
                    personId,
                    personId == nil ? nil : VoiceProfileAssignmentSource.manual.rawValue,
                    sessionId,
                    speakerId,
                    range.start,
                    range.end
                ]
            )
            updatedRows += db.changesCount
        }

        guard personId != nil else { return updatedRows }

        for range in ranges where range.allowsTraining {
            try db.execute(
                sql: """
                    UPDATE speaker_embeddings
                    SET isTrainingSample = 1
                    WHERE sessionId = ?
                      AND speakerId = ?
                      AND personId = ?
                      AND embeddingModel = ?
                      AND embeddingVersion = ?
                      AND NOT (endTime <= ? OR startTime >= ?)
                      AND (MIN(endTime, ?) - MAX(startTime, ?)) >= ?
                    """,
                arguments: [
                    sessionId,
                    speakerId,
                    personId,
                    SpeakerEmbeddingStore.defaultEmbeddingModel,
                    SpeakerEmbeddingStore.defaultEmbeddingVersion,
                    range.start,
                    range.end,
                    range.end,
                    range.start,
                    SpeakerEmbeddingStore.minimumMatchDuration
                ]
            )
            updatedRows += db.changesCount
        }

        return updatedRows
    }

    // MARK: - Matching

    /// Classify a fresh speaker embedding as a known person, a suggested person,
    /// or unknown. Silent labels require stronger confidence than suggestions.
    func classifyPerson(
        embedding: [Float],
        duration: Double? = nil,
        embeddingModel: String = SpeakerEmbeddingStore.defaultEmbeddingModel,
        embeddingVersion: Int = SpeakerEmbeddingStore.defaultEmbeddingVersion
    ) async -> VoiceMatchDecision {
        guard embeddingModel == Self.defaultEmbeddingModel,
              embeddingVersion == Self.defaultEmbeddingVersion else {
            return .unknown(bestSimilarity: nil)
        }
        guard duration.map({ $0 >= Self.minimumMatchDuration }) ?? true else {
            return .unknown(bestSimilarity: nil)
        }
        await ensureCentroidsLoaded()
        var ranked: [(personId: String, similarity: Float, profile: PersonVoiceProfile)] = []
        for (pid, profile) in personProfiles {
            guard profile.centroid.count == embedding.count else { continue }
            let sim = cosineSimilarity(embedding, profile.centroid)
            ranked.append((pid, sim, profile))
        }
        ranked.sort { $0.similarity > $1.similarity }
        guard let best = ranked.first else { return .unknown(bestSimilarity: nil) }
        let runnerUp = ranked.dropFirst().first?.similarity ?? -.infinity
        let margin = best.similarity - runnerUp

        if best.profile.sampleCount >= Self.minimumKnownSampleCount,
           best.similarity >= Self.knownMatchThreshold,
           margin >= Self.knownMatchMargin {
            return .known(
                personId: best.personId,
                similarity: best.similarity,
                margin: margin,
                sampleCount: best.profile.sampleCount
            )
        }

        if best.profile.sampleCount >= Self.minimumSuggestedSampleCount,
           best.similarity >= Self.suggestedMatchThreshold,
           margin >= Self.suggestedMatchMargin {
            return .suggested(
                personId: best.personId,
                similarity: best.similarity,
                margin: margin,
                sampleCount: best.profile.sampleCount
            )
        }

        return .unknown(bestSimilarity: best.similarity)
    }

    /// Backward-compatible helper for callers that only need silent known labels.
    func matchPerson(embedding: [Float], duration: Double? = nil) async -> (personId: String, similarity: Float)? {
        switch await classifyPerson(embedding: embedding, duration: duration) {
        case .known(let personId, let similarity, _, _):
            return (personId, similarity)
        case .suggested, .unknown:
            return nil
        }
    }

    func resetVoiceProfile(personId: String) async {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return }
        do {
            try await dbQueue.write { db in
                try db.execute(
                    sql: """
                        UPDATE speaker_embeddings
                        SET personId = NULL,
                            assignmentSource = NULL,
                            matchConfidence = NULL,
                            isTrainingSample = 0
                        WHERE personId = ?
                        """,
                    arguments: [personId]
                )
            }
            personProfiles.removeValue(forKey: personId)
            centroidsLoaded = false
        } catch {
            logError("SpeakerEmbeddingStore: reset voice profile failed", error: error)
            await RewindDatabase.shared.reportQueryError(error)
        }
    }

    func mergeVoiceProfile(from sourcePersonId: String, into targetPersonId: String) async {
        guard sourcePersonId != targetPersonId else { return }
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return }
        do {
            try await dbQueue.write { db in
                try db.execute(
                    sql: """
                        UPDATE speaker_embeddings
                        SET personId = ?,
                            assignmentSource = ?,
                            isTrainingSample = CASE
                                WHEN embeddingModel = ?
                                  AND embeddingVersion = ?
                                  AND (endTime - startTime) >= ? THEN 1
                                ELSE 0
                            END
                        WHERE personId = ?
                        """,
                    arguments: [
                        targetPersonId,
                        VoiceProfileAssignmentSource.manual.rawValue,
                        SpeakerEmbeddingStore.defaultEmbeddingModel,
                        SpeakerEmbeddingStore.defaultEmbeddingVersion,
                        SpeakerEmbeddingStore.minimumMatchDuration,
                        sourcePersonId
                    ]
                )
            }
            personProfiles.removeAll()
            centroidsLoaded = false
        } catch {
            logError("SpeakerEmbeddingStore: merge voice profile failed", error: error)
            await RewindDatabase.shared.reportQueryError(error)
        }
    }

    /// Drop all in-memory caches — call on user/session switch.
    func reset() {
        personProfiles.removeAll()
        centroidsLoaded = false
    }

    // MARK: - Centroid management

    private func ensureCentroidsLoaded() async {
        guard !centroidsLoaded else { return }
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return }
        do {
            let rows: [SpeakerEmbeddingRecord] = try await dbQueue.read { db in
                try SpeakerEmbeddingRecord.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM speaker_embeddings
                        WHERE personId IS NOT NULL AND isTrainingSample = 1
                        """
                )
            }
            // Group by personId and average.
            var grouped: [String: [(vector: [Float], duration: Double)]] = [:]
            for row in rows {
                guard let pid = row.personId else { continue }
                let model = row.embeddingModel ?? Self.defaultEmbeddingModel
                let version = row.embeddingVersion ?? Self.defaultEmbeddingVersion
                guard model == Self.defaultEmbeddingModel, version == Self.defaultEmbeddingVersion else { continue }
                let v = row.vector
                guard !v.isEmpty else { continue }
                grouped[pid, default: []].append((v, max(0, row.endTime - row.startTime)))
            }
            var profiles: [String: PersonVoiceProfile] = [:]
            for (pid, vectors) in grouped {
                guard let first = vectors.first else { continue }
                var mean = [Float](repeating: 0, count: first.vector.count)
                var sampleCount = 0
                var totalDuration = 0.0
                for item in vectors {
                    guard item.vector.count == first.vector.count else { continue }
                    for i in 0..<first.vector.count {
                        mean[i] += item.vector[i]
                    }
                    sampleCount += 1
                    totalDuration += item.duration
                }
                guard sampleCount > 0 else { continue }
                let n = Float(sampleCount)
                for i in 0..<mean.count {
                    mean[i] /= n
                }
                // Re-normalize so cosine == dot product.
                var norm: Float = 0
                for x in mean { norm += x * x }
                norm = sqrt(norm)
                if norm > 1e-6 {
                    for i in 0..<mean.count {
                        mean[i] /= norm
                    }
                    profiles[pid] = PersonVoiceProfile(
                        centroid: mean,
                        sampleCount: sampleCount,
                        totalDuration: totalDuration
                    )
                }
            }
            personProfiles = profiles
            centroidsLoaded = true
            log("SpeakerEmbeddingStore: Loaded voice profiles for \(profiles.count) people")
        } catch {
            logError("SpeakerEmbeddingStore: centroid load failed", error: error)
            await RewindDatabase.shared.reportQueryError(error)
        }
    }
}
