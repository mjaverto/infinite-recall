import XCTest
@testable import Omi_Computer

// MARK: - Fake LLM

/// In-memory `AutonomousLLMCalling` that returns scripted replies and records
/// every call for assertion. Sequencing: `replies` are popped in FIFO order
/// per call. If exhausted, the test fails fast.
private final class FakeAutonomousLLM: AutonomousLLMCalling, @unchecked Sendable {
  struct Call: Equatable {
    let prompt: String
    let maxTokens: Int
    let temperature: Double
    let seed: UInt64?
  }

  private let lock = NSLock()
  private var queue: [String]
  private(set) var calls: [Call] = []

  init(replies: [String]) { self.queue = replies }

  func extractJSON(prompt: String, maxTokens: Int, temperature: Double, seed: UInt64?) async throws -> String {
    lock.lock()
    defer { lock.unlock() }
    calls.append(Call(prompt: prompt, maxTokens: maxTokens, temperature: temperature, seed: seed))
    guard !queue.isEmpty else {
      XCTFail("FakeAutonomousLLM ran out of replies on call #\(calls.count)")
      return ""
    }
    return queue.removeFirst()
  }
}

// MARK: - Tests

final class KGExtractorTests: XCTestCase {

  // 1. Happy path strict JSON
  func test_happyPath_strictJSON_returnsParsed() async throws {
    let json = """
      {"nodes":[
        {"id":"alice","label":"Alice","type":"person","aliases":[]},
        {"id":"acme","label":"Acme","type":"organization","aliases":[]}
      ],"edges":[
        {"source":"alice","target":"acme","label":"works at"}
      ]}
      """
    let fake = FakeAutonomousLLM(replies: [json])
    let extractor = KGExtractor(llm: fake)
    let result = try await extractor.extract(memoryId: 1, content: "Alice works at Acme.", sourceApp: nil)

    XCTAssertEqual(result.outcome, .parsed)
    XCTAssertEqual(result.nodes.count, 2)
    XCTAssertEqual(result.edges.count, 1)
    XCTAssertEqual(result.nodes[0].id, "alice")
    XCTAssertEqual(result.nodes[0].type, .person)
  }

  // 2. Code-fenced JSON -> .parsed (after strip)
  func test_codeFencedJSON_returnsParsed() async throws {
    let fenced = """
      ```json
      {"nodes":[{"id":"bob","label":"Bob","type":"person","aliases":[]}],"edges":[]}
      ```
      """
    let fake = FakeAutonomousLLM(replies: [fenced])
    let extractor = KGExtractor(llm: fake)
    let result = try await extractor.extract(memoryId: 2, content: "Bob said hi.", sourceApp: nil)
    XCTAssertEqual(result.outcome, .parsed)
    XCTAssertEqual(result.nodes.first?.id, "bob")
  }

  // 3. Prose-wrapped JSON -> .recovered
  func test_proseWrappedJSON_returnsRecovered() async throws {
    let raw = """
      Sure, here is the graph:
      {"nodes":[{"id":"carol","label":"Carol","type":"person","aliases":[]}],"edges":[]}
      Hope that helps!
      """
    let fake = FakeAutonomousLLM(replies: [raw])
    let extractor = KGExtractor(llm: fake)
    let result = try await extractor.extract(memoryId: 3, content: "Carol called.", sourceApp: nil)
    XCTAssertEqual(result.outcome, .recovered)
    XCTAssertEqual(result.nodes.first?.id, "carol")
  }

  // 4. Truncated mid-object twice -> .failed(.lengthTruncatedTwice)
  func test_truncatedTwice_returnsFailedLengthTruncatedTwice() async throws {
    let truncated = "{\"nodes\":[{\"id\":\"da" + KGExtractor.lengthTruncationMarker
    let fake = FakeAutonomousLLM(replies: [truncated, truncated])
    let extractor = KGExtractor(llm: fake)
    let result = try await extractor.extract(memoryId: 4, content: "Some content.", sourceApp: nil)
    XCTAssertEqual(result.outcome, .failed(reason: .lengthTruncatedTwice))
    XCTAssertEqual(fake.calls.count, 2)
    // Second call must use 2x maxTokens.
    XCTAssertEqual(fake.calls[1].maxTokens, fake.calls[0].maxTokens * 2)
  }

  // 4b. Truncated then retry succeeds -> .truncatedRetried
  func test_truncatedThenRecovered_returnsTruncatedRetried() async throws {
    let truncated = "{\"nodes\":[{\"id\":\"da" + KGExtractor.lengthTruncationMarker
    let good = """
      {"nodes":[{"id":"dan","label":"Dan","type":"person","aliases":[]}],"edges":[]}
      """
    let fake = FakeAutonomousLLM(replies: [truncated, good])
    let extractor = KGExtractor(llm: fake)
    let result = try await extractor.extract(memoryId: 5, content: "Dan came over.", sourceApp: nil)
    XCTAssertEqual(result.outcome, .truncatedRetried)
    XCTAssertEqual(result.nodes.first?.id, "dan")
  }

  // 5. All-invalid enum -> .empty(.allNodesInvalid)
  func test_allInvalidEnum_returnsEmptyAllNodesInvalid() async throws {
    let raw = """
      {"nodes":[
        {"id":"x","label":"X","type":"alien","aliases":[]},
        {"id":"y","label":"Y","type":"vehicle","aliases":[]}
      ],"edges":[]}
      """
    let fake = FakeAutonomousLLM(replies: [raw])
    let extractor = KGExtractor(llm: fake)
    let result = try await extractor.extract(memoryId: 6, content: "Some content.", sourceApp: nil)
    XCTAssertEqual(result.outcome, .empty(reason: .allNodesInvalid))
    XCTAssertTrue(result.nodes.isEmpty)
    XCTAssertTrue(result.edges.isEmpty)
  }

  // 6. Edges referencing missing node ids -> dropped, valid kept
  func test_edgesReferencingMissingIds_areDropped() async throws {
    let raw = """
      {"nodes":[
        {"id":"eve","label":"Eve","type":"person","aliases":[]},
        {"id":"frank","label":"Frank","type":"person","aliases":[]}
      ],"edges":[
        {"source":"eve","target":"frank","label":"knows"},
        {"source":"eve","target":"ghost","label":"haunts"},
        {"source":"phantom","target":"frank","label":"chases"}
      ]}
      """
    let fake = FakeAutonomousLLM(replies: [raw])
    let extractor = KGExtractor(llm: fake)
    let result = try await extractor.extract(memoryId: 7, content: "Eve knows Frank.", sourceApp: nil)
    XCTAssertEqual(result.outcome, .parsed)
    XCTAssertEqual(result.nodes.count, 2)
    XCTAssertEqual(result.edges.count, 1)
    XCTAssertEqual(result.edges.first?.label, "knows")
  }

  // 7. Empty input -> .empty(.contentTooShort), no LLM call
  func test_emptyInput_returnsContentTooShort_noLLMCall() async throws {
    let fake = FakeAutonomousLLM(replies: [])
    let extractor = KGExtractor(llm: fake)
    let result1 = try await extractor.extract(memoryId: 8, content: "", sourceApp: nil)
    let result2 = try await extractor.extract(memoryId: 9, content: "   \n\t  ", sourceApp: "Mail")
    XCTAssertEqual(result1.outcome, .empty(reason: .contentTooShort))
    XCTAssertEqual(result2.outcome, .empty(reason: .contentTooShort))
    XCTAssertEqual(fake.calls.count, 0)
  }

  // 8. Chunked input: multiple extractJSON calls, union deduped by id
  func test_chunkedInput_callsMultipleAndDedupes() async throws {
    let chunkA = """
      {"nodes":[
        {"id":"shared","label":"Shared","type":"thing","aliases":[]},
        {"id":"only-a","label":"OnlyA","type":"concept","aliases":[]}
      ],"edges":[
        {"source":"only-a","target":"shared","label":"refers"}
      ]}
      """
    let chunkB = """
      {"nodes":[
        {"id":"shared","label":"Shared","type":"thing","aliases":[]},
        {"id":"only-b","label":"OnlyB","type":"concept","aliases":[]}
      ],"edges":[
        {"source":"only-b","target":"shared","label":"refers"}
      ]}
      """
    // 180 chars with maxContentChars=100, overlap=20 -> 2 chunks (0..100, 80..180).
    let fake = FakeAutonomousLLM(replies: [chunkA, chunkB])
    let extractor = KGExtractor(llm: fake, maxContentChars: 100, chunkOverlapChars: 20)
    let big = String(repeating: "abcdefghij", count: 18) // 180 chars
    let result = try await extractor.extract(memoryId: 10, content: big, sourceApp: nil)

    XCTAssertEqual(fake.calls.count, 2)
    XCTAssertEqual(result.outcome, .parsed)
    let ids = Set(result.nodes.map { $0.id })
    XCTAssertEqual(ids, Set(["shared", "only-a", "only-b"]))
    // Edges from both chunks should both survive (different source ids).
    XCTAssertEqual(result.edges.count, 2)
  }

  // 9. Determinism: same input + same fake -> identical output bytes
  //    AND temperature/seed are passed through.
  func test_determinism_passesTemperatureAndSeed() async throws {
    let json = """
      {"nodes":[{"id":"zoe","label":"Zoe","type":"person","aliases":[]}],"edges":[]}
      """
    let fake1 = FakeAutonomousLLM(replies: [json])
    let extractor1 = KGExtractor(llm: fake1)
    let r1 = try await extractor1.extract(memoryId: 11, content: "Zoe arrived.", sourceApp: nil)

    let fake2 = FakeAutonomousLLM(replies: [json])
    let extractor2 = KGExtractor(llm: fake2)
    let r2 = try await extractor2.extract(memoryId: 11, content: "Zoe arrived.", sourceApp: nil)

    XCTAssertEqual(r1.nodes, r2.nodes)
    XCTAssertEqual(r1.edges, r2.edges)
    XCTAssertEqual(r1.outcome, r2.outcome)

    XCTAssertEqual(fake1.calls.first?.temperature, 0.0)
    XCTAssertEqual(fake1.calls.first?.seed, KGExtractor.fixedSeed)
  }

  // Bonus: model returns explicit empty arrays -> .empty(.modelReturnedNone)
  func test_modelReturnsEmptyArrays_returnsModelReturnedNone() async throws {
    let raw = """
      {"nodes":[],"edges":[]}
      """
    let fake = FakeAutonomousLLM(replies: [raw])
    let extractor = KGExtractor(llm: fake)
    let result = try await extractor.extract(memoryId: 12, content: "Quiet day.", sourceApp: nil)
    XCTAssertEqual(result.outcome, .empty(reason: .modelReturnedNone))
  }

  // Bonus: jsonUnsalvageable when no braces at all and not truncated.
  func test_garbageReply_returnsJsonUnsalvageable() async throws {
    let raw = "I am not going to give you JSON, sorry."
    let fake = FakeAutonomousLLM(replies: [raw])
    let extractor = KGExtractor(llm: fake)
    let result = try await extractor.extract(memoryId: 13, content: "Whatever.", sourceApp: nil)
    XCTAssertEqual(result.outcome, .failed(reason: .jsonUnsalvageable))
  }
}
