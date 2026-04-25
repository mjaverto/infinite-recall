import Accelerate
import Foundation
import NaturalLanguage

/// Actor-based service for on-device embeddings using Apple's NaturalLanguage
/// framework (NLEmbedding.sentenceEmbedding(for: .english), 512-dim).
///
/// Embeddings via Apple NLEmbedding — on-device, no download. L2-normalized
/// so cosine similarity reduces to a simple dot product (see vDSP path in
/// `cosineSimilarity`).
///
/// Upgrade path: if quality is insufficient, swap `Self.loadModel` to load a
/// Core ML port of `mxbai-embed-large-v1` or `snowflake-arctic-embed-m`,
/// update `embeddingDimension`, and run a one-shot rebuild against existing
/// rows. Old rows are filtered out at search time by exact-dimension match
/// (see `dataToFloats`).
actor EmbeddingService {
  static let shared = EmbeddingService()

  /// Apple NLEmbedding sentence model is 512-dim on English (macOS 14+).
  /// Validated at first load; if Apple ever changes this we'll log + clamp.
  static let embeddingDimension = 512
  static let modelName = "NLEmbedding.sentenceEmbedding(.english)"

  /// In-memory index: action_item.id -> normalized embedding
  private var index: [Int64: [Float]] = [:]
  private var isIndexLoaded = false

  /// Cap in-memory embeddings to limit memory (~2KB each at 512-dim, 5000 = ~10MB max)
  private let maxIndexSize = 5000

  private init() {}

  // MARK: - Model Loading

  /// Lazily-loaded NLEmbedding models. Loading is heavy (mmaps a model file),
  /// so we do it once. `nonisolated(unsafe)` is fine because NLEmbedding is
  /// thread-safe for inference and we only assign once via dispatch_once
  /// semantics in Swift's lazy static.
  private struct Models {
    let sentence: NLEmbedding?
    let word: NLEmbedding?
  }

  private static let models: Models = {
    let sentence = NLEmbedding.sentenceEmbedding(for: .english)
    let word = NLEmbedding.wordEmbedding(for: .english)
    if let s = sentence {
      log("EmbeddingService: loaded NLEmbedding.sentence (\(s.dimension)-dim)")
    } else if let w = word {
      log("EmbeddingService: sentence model unavailable, falling back to word embeddings (\(w.dimension)-dim, will average)")
    } else {
      logError("EmbeddingService: no NLEmbedding models available for English — returning zero vectors")
    }
    return Models(sentence: sentence, word: word)
  }()

  // MARK: - Embedding API

  /// Embed a single text using Apple NLEmbedding (on-device).
  /// L2-normalized output. Empty/whitespace input returns the zero vector
  /// (signal "no info"). `taskType` is accepted for source-compat with the
  /// previous Gemini-shaped API but is unused locally.
  func embed(text: String, taskType: String? = nil) async throws -> [Float] {
    return Self.embedSync(text)
  }

  /// Batch embed. NLEmbedding has no true batch API — we just loop.
  /// Still cheap because the model is loaded once and inference is local.
  func embedBatch(texts: [String], taskType: String? = nil) async throws -> [[Float]] {
    return texts.map { Self.embedSync($0) }
  }

  /// Compute a normalized embedding synchronously. Internal helper; safe to
  /// call from any thread because NLEmbedding inference is thread-safe and
  /// the model is a let-bound static.
  private static func embedSync(_ text: String) -> [Float] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return [Float](repeating: 0, count: embeddingDimension)
    }

    // Prefer the sentence model.
    if let sentence = models.sentence,
       let vec = sentence.vector(for: trimmed) {
      return normalizeAndPad(vec, target: embeddingDimension)
    }

    // Fall back to averaging word embeddings.
    if let word = models.word {
      var sum = [Double](repeating: 0, count: word.dimension)
      var count = 0
      // Tokenize with NLTokenizer for proper word boundaries.
      let tokenizer = NLTokenizer(unit: .word)
      tokenizer.string = trimmed
      tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
        let token = String(trimmed[range]).lowercased()
        if let v = word.vector(for: token) {
          for i in 0..<min(v.count, sum.count) { sum[i] += v[i] }
          count += 1
        }
        return true
      }
      if count > 0 {
        let avg = sum.map { $0 / Double(count) }
        return normalizeAndPad(avg, target: embeddingDimension)
      }
    }

    return [Float](repeating: 0, count: embeddingDimension)
  }

  /// L2-normalize a Double vector and project it to `target` dimension
  /// (truncate if longer, zero-pad if shorter). Returns Float for storage.
  private static func normalizeAndPad(_ vec: [Double], target: Int) -> [Float] {
    var floats = [Float](repeating: 0, count: target)
    let n = min(vec.count, target)
    for i in 0..<n { floats[i] = Float(vec[i]) }

    // L2 normalize
    var norm: Float = 0
    vDSP_svesq(floats, 1, &norm, vDSP_Length(target))
    norm = sqrt(norm)
    guard norm > 0 else { return floats }
    var divisor = norm
    var result = [Float](repeating: 0, count: target)
    vDSP_vsdiv(floats, 1, &divisor, &result, 1, vDSP_Length(target))
    return result
  }

  // MARK: - In-Memory Index

  /// Load embeddings from SQLite into memory (action_items + staged_tasks, capped)
  func loadIndex() async {
    do {
      let rows = try await ActionItemStorage.shared.getAllEmbeddings()
      index.removeAll(keepingCapacity: true)
      // Only keep the most recent embeddings (suffix = highest IDs = newest)
      for (id, data) in rows.suffix(maxIndexSize) {
        if let floats = dataToFloats(data) {
          index[id] = floats
        }
      }
      let actionCount = index.count

      // Also load staged task embeddings (fill remaining capacity)
      let remaining = maxIndexSize - index.count
      if remaining > 0 {
        let stagedRows = try await StagedTaskStorage.shared.getAllEmbeddings()
        for (id, data) in stagedRows.suffix(remaining) {
          if let floats = dataToFloats(data) {
            index[id] = floats
          }
        }
      }

      isIndexLoaded = true
      log(
        "EmbeddingService: Loaded \(index.count) embeddings into memory (\(actionCount) action_items, \(index.count - actionCount) staged_tasks, cap=\(maxIndexSize))"
      )
    } catch {
      logError("EmbeddingService: Failed to load index", error: error)
    }
  }

  /// Add a single embedding to the in-memory index (respects maxIndexSize)
  func addToIndex(id: Int64, embedding: [Float]) {
    // If at capacity and this is a new key, evict the oldest (lowest ID)
    if index[id] == nil && index.count >= maxIndexSize {
      if let oldestKey = index.keys.min() {
        index.removeValue(forKey: oldestKey)
      }
    }
    index[id] = embedding
  }

  /// Remove an entry from the index
  func removeFromIndex(id: Int64) {
    index.removeValue(forKey: id)
  }

  /// Search for similar items using cosine similarity via Accelerate/vDSP
  func searchSimilar(query: [Float], topK: Int = 10) -> [(id: Int64, similarity: Float)] {
    guard !index.isEmpty else { return [] }

    var results: [(id: Int64, similarity: Float)] = []
    results.reserveCapacity(index.count)

    for (id, stored) in index {
      let sim = cosineSimilarity(query, stored)
      results.append((id, sim))
    }

    // Sort descending by similarity and take topK
    results.sort { $0.similarity > $1.similarity }
    return Array(results.prefix(topK))
  }

  /// Whether the index has been loaded
  var indexLoaded: Bool { isIndexLoaded }

  /// Number of items in the index
  var indexSize: Int { index.count }

  // MARK: - Backfill

  /// Batch-embed all tasks missing embeddings (action_items + staged_tasks)
  func backfillIfNeeded() async {
    let batchSize = 100
    var totalProcessed = 0

    do {
      // Backfill action_items
      while true {
        let items = try await ActionItemStorage.shared.getItemsMissingEmbeddings(limit: batchSize)
        if items.isEmpty { break }

        let texts = items.map { $0.description }
        let embeddings = try await embedBatch(texts: texts)

        for (i, embedding) in embeddings.enumerated() where i < items.count {
          let item = items[i]
          let data = floatsToData(embedding)
          try await ActionItemStorage.shared.updateEmbedding(id: item.id, embedding: data)
          addToIndex(id: item.id, embedding: embedding)
        }

        totalProcessed += items.count
        log("EmbeddingService: Backfill progress: \(totalProcessed) action_items")

        // Small delay to avoid rate limiting
        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms
      }

      // Backfill staged_tasks
      while true {
        let items = try await StagedTaskStorage.shared.getItemsMissingEmbeddings(limit: batchSize)
        if items.isEmpty { break }

        let texts = items.map { $0.description }
        let embeddings = try await embedBatch(texts: texts)

        for (i, embedding) in embeddings.enumerated() where i < items.count {
          let item = items[i]
          let data = floatsToData(embedding)
          try await StagedTaskStorage.shared.updateEmbedding(id: item.id, embedding: data)
          addToIndex(id: item.id, embedding: embedding)
        }

        totalProcessed += items.count
        log("EmbeddingService: Backfill progress: \(totalProcessed) total (incl. staged)")

        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms
      }

      if totalProcessed > 0 {
        log("EmbeddingService: Backfill complete — \(totalProcessed) items embedded")
      }
    } catch {
      logError("EmbeddingService: Backfill failed after \(totalProcessed) items", error: error)
    }
  }

  // MARK: - Helpers

  /// Cosine similarity using Accelerate vDSP for performance
  private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0
    vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
    // Vectors are pre-normalized, so dot product = cosine similarity
    return dot
  }

  /// Normalize a vector to unit length
  private func normalize(_ vector: [Float]) -> [Float] {
    var norm: Float = 0
    vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
    norm = sqrt(norm)
    guard norm > 0 else { return vector }
    var result = [Float](repeating: 0, count: vector.count)
    var divisor = norm
    vDSP_vsdiv(vector, 1, &divisor, &result, 1, vDSP_Length(vector.count))
    return result
  }

  /// Convert [Float] to Data (for SQLite BLOB storage)
  func floatsToData(_ floats: [Float]) -> Data {
    return floats.withUnsafeBufferPointer { buffer in
      Data(buffer: buffer)
    }
  }

  /// Convert Data (BLOB) back to [Float]. Returns nil when the BLOB does not
  /// match `embeddingDimension` — this filters out stale rows (e.g. legacy
  /// 3072-dim Gemini zero placeholders) at search time without a migration.
  func dataToFloats(_ data: Data) -> [Float]? {
    let floatSize = MemoryLayout<Float>.size
    let floatCount = data.count / floatSize

    guard floatCount == Self.embeddingDimension else {
      return nil
    }

    return data.withUnsafeBytes { raw in
      Array(raw.bindMemory(to: Float.self))
    }
  }

  // MARK: - Errors

  enum EmbeddingError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case serverError(statusCode: Int, body: String)

    var errorDescription: String? {
      switch self {
      case .missingAPIKey: return "AI features are not configured. Please update the app."
      case .invalidResponse: return "AI service returned an unexpected response. Please try again."
      case .serverError(let statusCode, let body): return "Embedding API error (HTTP \(statusCode)): \(body)"
      }
    }
  }
}
