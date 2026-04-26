import Foundation

/// JSON payload shape for local integration dispatches.
///
/// Single source of truth for the body sent to webhook integrations and
/// written by the filesystem JSON formatter. The Markdown writer renders
/// from the same struct so the two outputs cannot drift.
///
/// Construct via `init(from: ServerConversation)` and serialize via
/// `encodedJSON()`. The `memory_created` event in this fork actually
/// delivers a finished conversation (legacy Omi naming) — the dispatcher
/// resolves the conversation by ID and hands it here.
struct MemoryPayload: Codable {
  let id: String
  let title: String
  let overview: String
  let category: String
  let createdAt: Date
  let transcriptSegments: [Segment]
  let actionItems: [String]
  let tags: [String]

  /// One row of the conversation transcript, normalized for export.
  struct Segment: Codable {
    /// Raw speaker label from the transcriber (e.g. `"SPEAKER_0"`); the
    /// resolved person name when available is not yet plumbed through.
    let speaker: String?
    let text: String
    /// Seconds from session start.
    let start: Double
    let end: Double
  }

  /// Maps a finished `ServerConversation` into the export shape.
  ///
  /// Action items that were soft-deleted by the user are dropped. Tags
  /// fall back to a single-element array containing the category, matching
  /// the convention `ServerMemory.tags` uses elsewhere in the codebase.
  init(from conversation: ServerConversation) {
    self.id = conversation.id
    self.title = conversation.structured.title
    self.overview = conversation.structured.overview
    self.category = conversation.structured.category
    self.createdAt = conversation.createdAt
    self.transcriptSegments = conversation.transcriptSegments.map { segment in
      Segment(
        speaker: segment.speaker,
        text: segment.text,
        start: segment.start,
        end: segment.end
      )
    }
    self.actionItems = conversation.structured.actionItems
      .filter { !$0.deleted }
      .map { $0.description }
    self.tags = conversation.structured.category.isEmpty
      ? []
      : [conversation.structured.category]
  }

  /// Serializes the payload as the canonical JSON body used by all
  /// integration senders. Pretty-printed with sorted keys so byte output
  /// is stable for snapshotting in the outbox.
  func encodedJSON() throws -> Data {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try enc.encode(self)
  }
}
