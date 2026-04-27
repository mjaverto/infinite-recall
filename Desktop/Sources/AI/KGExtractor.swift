import Foundation

// MARK: - Outcome

struct KGExtraction: Sendable {
  let nodes: [ExtractedKGNode]
  let edges: [ExtractedKGEdge]
  let outcome: ParseOutcome
}

enum ParseOutcome: Sendable, Equatable {
  case parsed
  case recovered
  case truncatedRetried
  case empty(reason: EmptyReason)
  case failed(reason: FailReason)
}

enum EmptyReason: String, Sendable { case modelReturnedNone, allNodesInvalid, contentTooShort }
enum FailReason: String, Sendable { case llmError, jsonUnsalvageable, lengthTruncatedTwice }

// MARK: - LLM seam

/// Non-pinning LLM JSON-extraction surface. Implementations MUST route
/// through `chatAutonomous` (or equivalent non-pinning path) so the
/// idle-unload watchdog keeps ticking during deferred drain.
protocol AutonomousLLMCalling: Sendable {
  func extractJSON(prompt: String, maxTokens: Int, temperature: Double, seed: UInt64?) async throws -> String
}

extension AutonomousLLMCalling {
  /// Two-arg convenience used by the extractor. `prompt` is the system+user
  /// concatenation; the protocol implementation may split.
  func extractJSON(prompt: String, maxTokens: Int) async throws -> String {
    try await extractJSON(prompt: prompt, maxTokens: maxTokens, temperature: 0.0, seed: KGExtractor.fixedSeed)
  }
}

// MARK: - LocalLLMClient bridge
//
// The locked seam is `extractJSON(prompt:maxTokens:temperature:seed:) -> String`.
// `LocalLLMClient.chatAutonomous(...)` returns a streamed
// `AsyncThrowingStream<LLM.ChatChunk, Error>`; we collect it into a single
// string here. Temperature/seed are passed forward in spirit — mlx-lm.server's
// current request body doesn't accept those fields from this client, but the
// seam contract is honored at the type level so a future server upgrade is
// a one-line change.

extension LocalLLMClient: AutonomousLLMCalling {
  func extractJSON(
    prompt: String, maxTokens: Int, temperature: Double, seed: UInt64?
  ) async throws -> String {
    // `prompt` is split: first line "SYSTEM:" preamble, rest is user. To keep
    // call sites simple we model it as one user message with the prompt as
    // content — KGExtractor builds two messages explicitly via the helper
    // below. We expose both shapes.
    let messages = [LLM.ChatMessage(role: .user, content: prompt)]
    return try await collectAutonomous(messages: messages)
  }

  /// Two-message variant used by `KGExtractor`.
  func extractJSONMessages(
    system: String, user: String, maxTokens: Int, temperature: Double, seed: UInt64?
  ) async throws -> String {
    let messages = [
      LLM.ChatMessage(role: .system, content: system),
      LLM.ChatMessage(role: .user, content: user),
    ]
    return try await collectAutonomous(messages: messages)
  }

  private func collectAutonomous(messages: [LLM.ChatMessage]) async throws -> String {
    let stream = try await chatAutonomous(messages: messages, stream: false)
    var out = ""
    var finish: String? = nil
    for try await chunk in stream {
      out += chunk.delta
      if chunk.finishReason != nil { finish = chunk.finishReason }
    }
    // Encode the finish reason into a sentinel suffix the parser can detect
    // for length-truncation. We use a private marker the model itself can
    // never emit (it's stripped before parsing).
    if finish == "length" {
      out += KGExtractor.lengthTruncationMarker
    }
    return out
  }
}

// MARK: - Extractor

protocol KGExtracting: Sendable {
  func extract(memoryId: Int64, content: String, sourceApp: String?) async throws
    -> KGExtraction
}

actor KGExtractor: KGExtracting {

  /// Marker the LocalLLMClient bridge appends when the server reports a
  /// `finish_reason` of "length" so this layer can distinguish a truncated
  /// reply from a genuinely-malformed one. Stripped before JSON parsing.
  static let lengthTruncationMarker = "\u{0001}__KGEXTRACTOR_LENGTH_TRUNCATED__\u{0001}"

  /// Fixed determinism seed. Passed to the LLM seam even when the underlying
  /// runtime currently ignores it — the contract is locked at the type layer.
  static let fixedSeed: UInt64 = 0xC0FFEE

  static let defaultMaxTokens = 1024

  private let llm: AutonomousLLMCalling
  private let maxContentChars: Int
  private let chunkOverlapChars: Int

  init(
    llm: AutonomousLLMCalling = LocalLLMClient.shared,
    maxContentChars: Int = 2500,
    chunkOverlapChars: Int = 200
  ) {
    self.llm = llm
    self.maxContentChars = maxContentChars
    self.chunkOverlapChars = chunkOverlapChars
  }

  // MARK: Public

  func extract(memoryId: Int64, content: String, sourceApp: String?) async throws -> KGExtraction {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return KGExtraction(nodes: [], edges: [], outcome: .empty(reason: .contentTooShort))
    }

    // Chunk if oversized, otherwise single pass.
    let chunks = chunkContent(trimmed)
    var unionNodes: [ExtractedKGNode] = []
    var unionEdges: [ExtractedKGEdge] = []
    var chunkOutcomes: [ParseOutcome] = []

    for chunk in chunks {
      let chunkResult = try await runOnce(content: chunk, sourceApp: sourceApp)
      chunkOutcomes.append(chunkResult.outcome)
      unionNodes.append(contentsOf: chunkResult.nodes)
      unionEdges.append(contentsOf: chunkResult.edges)
    }

    let aggregatedOutcome = aggregateOutcomes(chunkOutcomes)

    // Dedupe by id slug (nodes) and (source,target,label) (edges).
    let dedupedNodes = dedupeNodes(unionNodes)
    let dedupedEdges = dedupeEdges(unionEdges, validNodeIds: Set(dedupedNodes.map { $0.id }))

    if dedupedNodes.isEmpty && dedupedEdges.isEmpty {
      switch aggregatedOutcome {
      case .empty, .failed:
        return KGExtraction(nodes: [], edges: [], outcome: aggregatedOutcome)
      default:
        return KGExtraction(nodes: [], edges: [], outcome: .empty(reason: .modelReturnedNone))
      }
    }

    return KGExtraction(nodes: dedupedNodes, edges: dedupedEdges, outcome: aggregatedOutcome)
  }

  // MARK: Per-chunk pipeline

  /// Run the LLM on one content slice, with one length-truncation retry.
  private func runOnce(content: String, sourceApp: String?) async throws -> KGExtraction {
    let system = KGExtractorPrompt.systemPrompt
    let user = KGExtractorPrompt.userMessage(content: content, sourceApp: sourceApp)

    // First pass.
    let firstRaw: String
    do {
      firstRaw = try await callLLM(system: system, user: user, maxTokens: Self.defaultMaxTokens)
    } catch {
      return KGExtraction(nodes: [], edges: [], outcome: .failed(reason: .llmError))
    }

    let firstParse = parseAndValidate(raw: firstRaw, baseOutcome: .parsed)
    if case .truncationDetected = firstParse {
      // Retry once with 2x maxTokens.
      let retriedRaw: String
      do {
        retriedRaw = try await callLLM(system: system, user: user, maxTokens: Self.defaultMaxTokens * 2)
      } catch {
        return KGExtraction(nodes: [], edges: [], outcome: .failed(reason: .llmError))
      }
      let retriedParse = parseAndValidate(raw: retriedRaw, baseOutcome: .truncatedRetried)
      switch retriedParse {
      case .truncationDetected:
        return KGExtraction(nodes: [], edges: [], outcome: .failed(reason: .lengthTruncatedTwice))
      case .resolved(let extraction):
        return extraction
      }
    }
    if case .resolved(let extraction) = firstParse {
      return extraction
    }
    // Should not reach here.
    return KGExtraction(nodes: [], edges: [], outcome: .failed(reason: .jsonUnsalvageable))
  }

  private func callLLM(system: String, user: String, maxTokens: Int) async throws -> String {
    // Prefer the two-message bridge if the underlying llm is a LocalLLMClient.
    if let local = llm as? LocalLLMClient {
      return try await local.extractJSONMessages(
        system: system, user: user, maxTokens: maxTokens,
        temperature: 0.0, seed: Self.fixedSeed)
    }
    // Generic path: fold system + user into one prompt.
    let prompt = system + "\n\n" + user
    return try await llm.extractJSON(
      prompt: prompt, maxTokens: maxTokens, temperature: 0.0, seed: Self.fixedSeed)
  }

  // MARK: Parser

  private enum ParseStep {
    case truncationDetected
    case resolved(KGExtraction)
  }

  /// Parse pipeline:
  ///   1. strip fences, strict JSON decode -> .parsed (or carried baseOutcome)
  ///   2. else regex first balanced {...} -> .recovered
  ///   3. else if length truncation marker present -> .truncationDetected
  ///   4. else .failed(.jsonUnsalvageable)
  /// Followed by node/edge validation.
  private func parseAndValidate(raw: String, baseOutcome: ParseOutcome) -> ParseStep {
    // Detect truncation BEFORE stripping (the marker is appended by the bridge).
    let truncated = raw.contains(Self.lengthTruncationMarker)
    let cleaned = raw.replacingOccurrences(of: Self.lengthTruncationMarker, with: "")
    let stripped = stripJSONFences(cleaned)

    var stage: ParseOutcome = baseOutcome
    var envelope: RawEnvelope? = decodeStrict(stripped)
    if envelope == nil {
      if let recovered = extractFirstBalancedBraces(from: stripped),
         let env = decodeStrict(recovered) {
        envelope = env
        // If we started at baseOutcome .parsed, demote to .recovered.
        if stage == .parsed { stage = .recovered }
      }
    }

    guard let env = envelope else {
      if truncated {
        return .truncationDetected
      }
      return .resolved(KGExtraction(nodes: [], edges: [], outcome: .failed(reason: .jsonUnsalvageable)))
    }

    // Validate nodes.
    var validNodes: [ExtractedKGNode] = []
    var seenIds = Set<String>()
    for n in env.nodes {
      guard let label = n.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
            let idRaw = n.id?.trimmingCharacters(in: .whitespacesAndNewlines), !idRaw.isEmpty,
            let typeRaw = n.type,
            let typed = KnowledgeGraphNodeType(rawValue: typeRaw)
      else { continue }
      let slug = slugify(idRaw)
      if slug.isEmpty || seenIds.contains(slug) { continue }
      seenIds.insert(slug)
      let aliases = (n.aliases ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
      validNodes.append(ExtractedKGNode(id: slug, label: label, type: typed, aliases: aliases))
    }

    // If model returned at least one node candidate but ALL were invalid, signal allNodesInvalid.
    let modelReturnedAnyNodes = !env.nodes.isEmpty
    if modelReturnedAnyNodes && validNodes.isEmpty {
      return .resolved(
        KGExtraction(nodes: [], edges: [], outcome: .empty(reason: .allNodesInvalid)))
    }

    // Validate edges (drop those referencing missing node ids).
    let validIds = Set(validNodes.map { $0.id })
    var validEdges: [ExtractedKGEdge] = []
    for e in env.edges {
      guard let s = e.source?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
            let t = e.target?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
            let lbl = e.label?.trimmingCharacters(in: .whitespacesAndNewlines), !lbl.isEmpty
      else { continue }
      let sSlug = slugify(s)
      let tSlug = slugify(t)
      if !validIds.contains(sSlug) || !validIds.contains(tSlug) { continue }
      validEdges.append(ExtractedKGEdge(sourceId: sSlug, targetId: tSlug, label: lbl))
    }

    if validNodes.isEmpty && validEdges.isEmpty {
      return .resolved(
        KGExtraction(nodes: [], edges: [], outcome: .empty(reason: .modelReturnedNone)))
    }

    return .resolved(KGExtraction(nodes: validNodes, edges: validEdges, outcome: stage))
  }

  // MARK: JSON helpers

  private struct RawEnvelope: Decodable {
    let nodes: [RawNode]
    let edges: [RawEdge]
  }
  private struct RawNode: Decodable {
    let id: String?
    let label: String?
    let type: String?
    let aliases: [String]?
  }
  private struct RawEdge: Decodable {
    let source: String?
    let target: String?
    let label: String?
  }

  private func decodeStrict(_ s: String) -> RawEnvelope? {
    guard let data = s.data(using: .utf8) else { return nil }
    // Tolerate missing nodes/edges arrays at top level by decoding as a more
    // permissive envelope first.
    if let env = try? JSONDecoder().decode(RawEnvelope.self, from: data) {
      return env
    }
    if let any = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
      let nodesAny = any["nodes"] as? [[String: Any]] ?? []
      let edgesAny = any["edges"] as? [[String: Any]] ?? []
      let nodes: [RawNode] = nodesAny.map { dict in
        RawNode(
          id: dict["id"] as? String,
          label: dict["label"] as? String,
          type: dict["type"] as? String,
          aliases: (dict["aliases"] as? [Any])?.compactMap { $0 as? String }
        )
      }
      let edges: [RawEdge] = edgesAny.map { dict in
        RawEdge(
          source: dict["source"] as? String,
          target: dict["target"] as? String,
          label: dict["label"] as? String
        )
      }
      return RawEnvelope(nodes: nodes, edges: edges)
    }
    return nil
  }

  /// Find the first balanced `{...}` block. Brace-count scan; ignores braces
  /// inside double-quoted strings (with escape awareness).
  private func extractFirstBalancedBraces(from s: String) -> String? {
    let chars = Array(s)
    guard let start = chars.firstIndex(of: "{") else { return nil }
    var depth = 0
    var inString = false
    var escape = false
    var i = start
    while i < chars.count {
      let c = chars[i]
      if inString {
        if escape {
          escape = false
        } else if c == "\\" {
          escape = true
        } else if c == "\"" {
          inString = false
        }
      } else {
        if c == "\"" {
          inString = true
        } else if c == "{" {
          depth += 1
        } else if c == "}" {
          depth -= 1
          if depth == 0 {
            return String(chars[start...i])
          }
        }
      }
      i += 1
    }
    return nil
  }

  // MARK: Slug + chunk + dedupe

  private func slugify(_ s: String) -> String {
    let lowered = s.lowercased()
    var out = ""
    var lastWasHyphen = false
    for scalar in lowered.unicodeScalars {
      if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
        out.unicodeScalars.append(scalar)
        lastWasHyphen = false
      } else if !lastWasHyphen && !out.isEmpty {
        out.append("-")
        lastWasHyphen = true
      }
    }
    while out.hasSuffix("-") { out.removeLast() }
    return out
  }

  private func chunkContent(_ s: String) -> [String] {
    if s.count <= maxContentChars { return [s] }
    var pieces: [String] = []
    let chars = Array(s)
    var start = 0
    while start < chars.count {
      let end = min(start + maxContentChars, chars.count)
      pieces.append(String(chars[start..<end]))
      if end == chars.count { break }
      start = end - chunkOverlapChars
      if start < 0 { start = 0 }
    }
    return pieces
  }

  private func dedupeNodes(_ nodes: [ExtractedKGNode]) -> [ExtractedKGNode] {
    var seen = Set<String>()
    var out: [ExtractedKGNode] = []
    for n in nodes {
      if seen.insert(n.id).inserted {
        out.append(n)
      }
    }
    return out
  }

  private func dedupeEdges(_ edges: [ExtractedKGEdge], validNodeIds: Set<String>) -> [ExtractedKGEdge] {
    var seen = Set<String>()
    var out: [ExtractedKGEdge] = []
    for e in edges {
      guard validNodeIds.contains(e.sourceId), validNodeIds.contains(e.targetId) else { continue }
      let key = "\(e.sourceId)\u{1F}\(e.targetId)\u{1F}\(e.label)"
      if seen.insert(key).inserted {
        out.append(e)
      }
    }
    return out
  }

  // MARK: Outcome aggregation across chunks

  /// Aggregation rules:
  /// - Any chunk failed -> failed (worst failure wins; lengthTruncatedTwice
  ///   ranks above llmError ranks above jsonUnsalvageable for reporting).
  /// - Else if any chunk had non-empty success: pick the worst success-class
  ///   (truncatedRetried > recovered > parsed).
  /// - Else (all chunks empty): pick the worst empty reason
  ///   (allNodesInvalid > modelReturnedNone > contentTooShort).
  private func aggregateOutcomes(_ outcomes: [ParseOutcome]) -> ParseOutcome {
    if outcomes.isEmpty { return .empty(reason: .modelReturnedNone) }

    // Failed dominates.
    var failed: FailReason? = nil
    for o in outcomes {
      if case .failed(let r) = o {
        failed = worseFail(failed, r)
      }
    }
    if let f = failed { return .failed(reason: f) }

    // Successes — pick worst success-class among them.
    var successRank = -1
    var successOutcome: ParseOutcome? = nil
    for o in outcomes {
      let r: Int
      switch o {
      case .truncatedRetried: r = 3
      case .recovered: r = 2
      case .parsed: r = 1
      default: r = -1
      }
      if r > successRank {
        successRank = r
        successOutcome = o
      }
    }
    if let s = successOutcome { return s }

    // All empty — pick worst empty reason.
    var emptyRank = -1
    var emptyOutcome: ParseOutcome = .empty(reason: .modelReturnedNone)
    for o in outcomes {
      if case .empty(let reason) = o {
        let r: Int
        switch reason {
        case .allNodesInvalid: r = 2
        case .modelReturnedNone: r = 1
        case .contentTooShort: r = 0
        }
        if r > emptyRank {
          emptyRank = r
          emptyOutcome = o
        }
      }
    }
    return emptyOutcome
  }

  private func worseFail(_ a: FailReason?, _ b: FailReason) -> FailReason {
    func rank(_ r: FailReason) -> Int {
      switch r {
      case .lengthTruncatedTwice: return 3
      case .llmError: return 2
      case .jsonUnsalvageable: return 1
      }
    }
    guard let a = a else { return b }
    return rank(b) > rank(a) ? b : a
  }
}
