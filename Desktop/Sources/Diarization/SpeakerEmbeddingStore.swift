// Infinite Recall fork: on-device speaker diarization. No cloud calls.
//
// Persists per-segment speaker embeddings to GRDB and answers nearest-neighbor
// queries used by `SpeakerDiarizationService` to map a fresh embedding to an
// existing person (cosine threshold ~0.65).

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

/// Actor that owns DB I/O for speaker embeddings + the in-memory match index.
actor SpeakerEmbeddingStore {
    static let shared = SpeakerEmbeddingStore()

    /// Cosine-similarity threshold for matching a new embedding to an existing
    /// person. v1 default is intentionally a touch loose so the user gets useful
    /// auto-tagging on day one; tightens once we have a neural embedding.
    static let defaultMatchThreshold: Float = 0.65

    /// Cached centroid embedding per person (mean of their stored embeddings).
    /// Recomputed lazily on first match call after a new embedding is recorded.
    private var personCentroids: [String: [Float]] = [:]
    private var centroidsLoaded: Bool = false

    private init() {}

    // MARK: - Insertion

    @discardableResult
    func recordEmbedding(
        sessionId: Int64,
        chunkId: Int64?,
        embedding: [Float],
        startTime: Double,
        endTime: Double,
        speakerId: Int?,
        personId: String?
    ) async -> Int64? {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            log("SpeakerEmbeddingStore: DB not initialized — dropping embedding")
            return nil
        }
        var record = SpeakerEmbeddingRecord(
            id: nil,
            sessionId: sessionId,
            chunkId: chunkId,
            embedding: SpeakerEmbeddingRecord.encode(embedding),
            embeddingDim: embedding.count,
            startTime: startTime,
            endTime: endTime,
            speakerId: speakerId,
            personId: personId,
            createdAt: Date()
        )
        do {
            try await dbQueue.write { db in
                try record.insert(db)
            }
            // If this embedding is associated with a person, invalidate the centroid.
            if let pid = personId {
                personCentroids.removeValue(forKey: pid)
            }
            return record.id
        } catch {
            logError("SpeakerEmbeddingStore: insert failed", error: error)
            await RewindDatabase.shared.reportQueryError(error)
            return nil
        }
    }

    /// Backfill `personId` on previously-recorded embeddings (e.g. when the
    /// user names "Speaker 1" mid-conversation).
    func assignPersonToEmbeddings(
        sessionId: Int64,
        speakerId: Int,
        personId: String?
    ) async {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return }
        do {
            try await dbQueue.write { db in
                try db.execute(
                    sql: """
                        UPDATE speaker_embeddings
                        SET personId = ?
                        WHERE sessionId = ? AND speakerId = ?
                        """,
                    arguments: [personId, sessionId, speakerId]
                )
            }
            // Invalidate cached centroid so next match call rebuilds it.
            if let pid = personId {
                personCentroids.removeValue(forKey: pid)
            } else {
                personCentroids.removeAll()
            }
        } catch {
            logError("SpeakerEmbeddingStore: backfill failed", error: error)
            await RewindDatabase.shared.reportQueryError(error)
        }
    }

    // MARK: - Matching

    /// Find the most similar known person to the given embedding, returning
    /// `(personId, similarity)` if any match crosses `threshold`.
    func matchPerson(
        embedding: [Float],
        threshold: Float = SpeakerEmbeddingStore.defaultMatchThreshold
    ) async -> (personId: String, similarity: Float)? {
        await ensureCentroidsLoaded()
        var bestId: String?
        var bestSim: Float = -.infinity
        for (pid, centroid) in personCentroids {
            guard centroid.count == embedding.count else { continue }
            let sim = cosineSimilarity(embedding, centroid)
            if sim > bestSim {
                bestSim = sim
                bestId = pid
            }
        }
        guard let pid = bestId, bestSim >= threshold else { return nil }
        return (pid, bestSim)
    }

    /// Drop all in-memory caches — call on user/session switch.
    func reset() {
        personCentroids.removeAll()
        centroidsLoaded = false
    }

    // MARK: - Centroid management

    private func ensureCentroidsLoaded() async {
        guard !centroidsLoaded else { return }
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return }
        do {
            let rows: [SpeakerEmbeddingRecord] = try await dbQueue.read { db in
                try SpeakerEmbeddingRecord
                    .filter(Column("personId") != nil)
                    .fetchAll(db)
            }
            // Group by personId and average.
            var grouped: [String: [[Float]]] = [:]
            for row in rows {
                guard let pid = row.personId else { continue }
                let v = row.vector
                guard !v.isEmpty else { continue }
                grouped[pid, default: []].append(v)
            }
            var centroids: [String: [Float]] = [:]
            for (pid, vectors) in grouped {
                guard let first = vectors.first else { continue }
                var mean = [Float](repeating: 0, count: first.count)
                for v in vectors {
                    guard v.count == first.count else { continue }
                    for i in 0..<first.count {
                        mean[i] += v[i]
                    }
                }
                let n = Float(vectors.count)
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
                    centroids[pid] = mean
                }
            }
            personCentroids = centroids
            centroidsLoaded = true
            log("SpeakerEmbeddingStore: Loaded centroids for \(centroids.count) people")
        } catch {
            logError("SpeakerEmbeddingStore: centroid load failed", error: error)
            await RewindDatabase.shared.reportQueryError(error)
        }
    }
}
