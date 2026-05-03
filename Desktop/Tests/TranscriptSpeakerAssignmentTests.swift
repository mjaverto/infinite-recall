import XCTest
import GRDB

@testable import Omi_Computer

final class TranscriptSpeakerAssignmentTests: XCTestCase {
  func testTranscriptSegmentDecodingPreservesBackendId() throws {
    let json = """
      {
        "id": "seg_backend_123",
        "text": "Hello",
        "speaker": "SPEAKER_01",
        "is_user": false,
        "person_id": "person_abc",
        "start": 1.25,
        "end": 2.5
      }
      """.data(using: .utf8)!

    let segment = try JSONDecoder().decode(TranscriptSegment.self, from: json)

    XCTAssertEqual(segment.id, "seg_backend_123")
    XCTAssertEqual(segment.backendId, "seg_backend_123")
    XCTAssertEqual(segment.personId, "person_abc")
  }

  func testTranscriptSegmentDecodingFallsBackToEphemeralIdWhenBackendIdMissing() throws {
    let json = """
      {
        "text": "Hello",
        "speaker": "SPEAKER_01",
        "is_user": false,
        "start": 1.25,
        "end": 2.5
      }
      """.data(using: .utf8)!

    let segment = try JSONDecoder().decode(TranscriptSegment.self, from: json)

    XCTAssertFalse(segment.id.isEmpty)
    XCTAssertNil(segment.backendId)
  }

  func testTranscriptionSegmentRecordRoundTripKeepsBackendId() {
    let record = TranscriptionSegmentRecord(
      sessionId: 1,
      speaker: 1,
      text: "Hello",
      startTime: 1.25,
      endTime: 2.5,
      segmentOrder: 0,
      segmentId: "seg_backend_123",
      speakerLabel: "SPEAKER_01",
      isUser: false,
      personId: "person_abc"
    )

    let segment = record.toTranscriptSegment()

    XCTAssertEqual(segment.id, "seg_backend_123")
    XCTAssertEqual(segment.backendId, "seg_backend_123")
    XCTAssertEqual(segment.personId, "person_abc")
  }

  // MARK: - SpeakerSegment isUser Tests

  func testSpeakerSegmentIsUserTrueWithNonZeroSpeaker() {
    // Backend can return is_user=true with speaker_id != 0 (speech profile match)
    let segment = SpeakerSegment(
      speaker: 1,
      text: "Hello from user",
      start: 0,
      end: 1,
      isUser: true
    )

    XCTAssertTrue(segment.isUser, "Segment with isUser=true should be treated as user regardless of speaker ID")
    XCTAssertEqual(segment.speaker, 1, "Speaker ID should remain 1")
  }

  func testSpeakerSegmentIsUserFalseWithZeroSpeaker() {
    // A segment from speaker 0 that isn't the user (e.g., no speech profile match)
    let segment = SpeakerSegment(
      speaker: 0,
      text: "Hello from someone else",
      start: 0,
      end: 1,
      isUser: false
    )

    XCTAssertFalse(segment.isUser, "Segment with isUser=false should not be treated as user even with speaker 0")
  }

  func testSpeakerSegmentDefaultsIsUserToFalse() {
    let segment = SpeakerSegment(
      speaker: 0,
      text: "Test",
      start: 0,
      end: 1
    )

    XCTAssertFalse(segment.isUser, "isUser should default to false")
  }

  // MARK: - Transcript Export isUser Tests

  func testTranscriptExportUsesIsUserForSpeakerLabel() {
    let segments = [
      TranscriptSegment(
        id: "seg1",
        text: "Hello from user",
        speaker: "SPEAKER_01",
        isUser: true,
        personId: nil,
        start: 0,
        end: 1
      ),
      TranscriptSegment(
        id: "seg2",
        text: "Hello from other",
        speaker: "SPEAKER_00",
        isUser: false,
        personId: nil,
        start: 1,
        end: 2
      ),
    ]

    let conversation = ServerConversation(
      id: "test",
      createdAt: Date(),
      startedAt: nil,
      finishedAt: nil,
      structured: Structured(
        title: "Test",
        overview: "",
        emoji: "",
        category: "other",
        actionItems: [],
        events: []
      ),
      transcriptSegments: segments,
      geolocation: nil,
      photos: [],
      appsResults: [],
      source: nil,
      language: nil,
      status: .completed,
      discarded: false,
      deleted: false,
      isLocked: false,
      starred: false,
      folderId: nil,
      inputDeviceName: nil
    )

    let transcript = conversation.transcript

    // isUser=true speaker 1 should show "You", not "Speaker 1"
    XCTAssertTrue(transcript.contains("You: Hello from user"), "User segment should use 'You' label based on isUser, not speaker ID")

    // isUser=false speaker 0 should show "Speaker 0", not "You"
    XCTAssertTrue(transcript.contains("Speaker 0: Hello from other"), "Non-user segment with speaker 0 should NOT use 'You' label")
  }

  // MARK: - Translation Tests

  func testTranscriptSegmentDecodesTranslations() throws {
    let json = """
      {
        "id": "seg_trans_1",
        "text": "こんにちは",
        "speaker": "SPEAKER_00",
        "is_user": false,
        "start": 0.0,
        "end": 1.5,
        "translations": [
          {"lang": "en", "text": "Hello"},
          {"lang": "es", "text": "Hola"}
        ]
      }
      """.data(using: .utf8)!

    let segment = try JSONDecoder().decode(TranscriptSegment.self, from: json)

    XCTAssertEqual(segment.translations.count, 2)
    XCTAssertEqual(segment.translations[0].lang, "en")
    XCTAssertEqual(segment.translations[0].text, "Hello")
    XCTAssertEqual(segment.translations[1].lang, "es")
    XCTAssertEqual(segment.translations[1].text, "Hola")
  }

  func testTranscriptSegmentDefaultsToEmptyTranslations() throws {
    let json = """
      {
        "id": "seg_no_trans",
        "text": "Hello",
        "speaker": "SPEAKER_00",
        "is_user": false,
        "start": 0.0,
        "end": 1.0
      }
      """.data(using: .utf8)!

    let segment = try JSONDecoder().decode(TranscriptSegment.self, from: json)
    XCTAssertTrue(segment.translations.isEmpty, "Translations should default to empty array when not present in JSON")
  }

  func testSpeakerSegmentTranslationsPreserved() {
    let translations = [
      SegmentTranslation(lang: "en", text: "Hello"),
      SegmentTranslation(lang: "fr", text: "Bonjour")
    ]
    let segment = SpeakerSegment(
      speaker: 0,
      text: "こんにちは",
      start: 0,
      end: 1,
      isUser: false,
      translations: translations
    )

    XCTAssertEqual(segment.translations.count, 2)
    XCTAssertEqual(segment.translations[0].lang, "en")
    XCTAssertEqual(segment.translations[1].text, "Bonjour")
  }

  func testTranslationsPreservedDuringReassignment() {
    // Simulates the code path in ConversationDetailView.updateDisplayedConversation
    // and AppState.assignSpeakerToSegments where TranscriptSegment is rebuilt
    let original = TranscriptSegment(
      id: "seg1",
      backendId: "backend_seg1",
      text: "こんにちは",
      speaker: "SPEAKER_00",
      isUser: false,
      personId: nil,
      suggestedPersonId: "person_suggested",
      suggestedSimilarity: 0.91,
      suggestedMargin: 0.07,
      suggestedSampleCount: 4,
      start: 0,
      end: 1,
      translations: [
        TranscriptTranslation(lang: "en", text: "Hello"),
        TranscriptTranslation(lang: "fr", text: "Bonjour")
      ]
    )

    // Rebuild like ConversationDetailView does during speaker reassignment
    let reassigned = TranscriptSegment(
      id: original.id,
      backendId: original.backendId,
      text: original.text,
      speaker: original.speaker,
      isUser: true,
      personId: nil,
      suggestedPersonId: original.suggestedPersonId,
      suggestedSimilarity: original.suggestedSimilarity,
      suggestedMargin: original.suggestedMargin,
      suggestedSampleCount: original.suggestedSampleCount,
      start: original.start,
      end: original.end,
      translations: original.translations
    )

    XCTAssertEqual(reassigned.translations.count, 2, "Translations must survive reassignment")
    XCTAssertEqual(reassigned.translations[0].lang, "en")
    XCTAssertEqual(reassigned.translations[0].text, "Hello")
    XCTAssertEqual(reassigned.backendId, "backend_seg1", "backendId must survive reassignment")
    XCTAssertTrue(reassigned.isUser)

    XCTAssertEqual(reassigned.suggestedPersonId, "person_suggested")
    XCTAssertEqual(reassigned.suggestedSimilarity, 0.91)
    XCTAssertEqual(reassigned.suggestedMargin, 0.07)
    XCTAssertEqual(reassigned.suggestedSampleCount, 4)
  }

  func testUpsertSegmentClearsSuggestedMetadataWhenNilPassed() async throws {
    let testUserId = "test-upsert-suggested-clear-\(UUID().uuidString)"
    await RewindDatabase.shared.configure(userId: testUserId)
    try await RewindDatabase.shared.initialize()
    defer {
      Task { await RewindDatabase.shared.close() }
    }

    guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
      throw XCTSkip("database queue unavailable")
    }

    let now = Date()
    let sessionId: Int64 = try await dbQueue.write { db in
      try db.execute(
        sql: """
          INSERT INTO transcription_sessions(startedAt, source, language, timezone, status, retryCount, backendSynced, createdAt, updatedAt, summary_state)
          VALUES(?, 'desktop', 'en', 'UTC', 'completed', 0, 0, ?, ?, 'pending')
          """,
        arguments: [now, now, now]
      )
      return db.lastInsertedRowID
    }

    _ = try await TranscriptionStorage.shared.upsertSegment(
      sessionId: sessionId,
      backendSegmentId: "seg0",
      speaker: 0,
      text: "hello",
      startTime: 0,
      endTime: 1,
      suggestedPersonId: "p1",
      suggestedSimilarity: 0.5,
      suggestedMargin: 0.1,
      suggestedSampleCount: 2
    )

    _ = try await TranscriptionStorage.shared.upsertSegment(
      sessionId: sessionId,
      backendSegmentId: "seg0",
      speaker: 0,
      text: "hello2",
      startTime: 0,
      endTime: 1,
      suggestedPersonId: nil,
      suggestedSimilarity: nil,
      suggestedMargin: nil,
      suggestedSampleCount: nil
    )

    let row: (String?, Double?, Double?, Int?) = try await dbQueue.read { db in
      let r = try Row.fetchOne(
        db,
        sql: """
          SELECT suggestedPersonId, suggestedSimilarity, suggestedMargin, suggestedSampleCount
          FROM transcription_segments
          WHERE sessionId = ? AND segmentId = ?
          """,
        arguments: [sessionId, "seg0"]
      )
      return (
        r?["suggestedPersonId"],
        r?["suggestedSimilarity"],
        r?["suggestedMargin"],
        r?["suggestedSampleCount"]
      )
    }

    XCTAssertNil(row.0)
    XCTAssertNil(row.1)
    XCTAssertNil(row.2)
    XCTAssertNil(row.3)
  }

  func testAssignmentMetadataUsesBackendIdsAndFallbackOrders() {
    let segments = [
      TranscriptSegment(
        id: "seg1",
        backendId: "backend_seg1",
        text: "Hello",
        speaker: "SPEAKER_01",
        isUser: false,
        personId: nil,
        start: 0,
        end: 1
      ),
      TranscriptSegment(
        id: "local-only",
        backendId: nil,
        text: "No backend id yet",
        speaker: "SPEAKER_01",
        isUser: false,
        personId: nil,
        start: 1,
        end: 2
      )
    ]

    let metadata = ConversationDetailView.assignmentMetadata(for: [0, 1], in: segments)

    XCTAssertEqual(metadata.targets, ["backend_seg1", "#index:1"])
    XCTAssertEqual(metadata.backendIds, ["backend_seg1"])
    XCTAssertEqual(metadata.fallbackOrders, [1])
  }

  func testPeopleStoreSplitsAssignmentTargetsForEmbeddingBackfill() {
    let split = PeopleStore.splitAssignmentTargets([
      "backend_seg1",
      "#index:2",
      "backend_seg3",
      "#index:not-a-number"
    ])

    XCTAssertEqual(split.backendIds, ["backend_seg1", "backend_seg3"])
    XCTAssertEqual(split.fallbackOrders, [2])
  }

  func testVoiceMatchDecisionOnlyKnownLabelsTranscript() {
    let known = VoiceMatchDecision.known(
      personId: "person-sarah",
      similarity: 0.91,
      margin: 0.12,
      sampleCount: 4
    )
    let suggested = VoiceMatchDecision.suggested(
      personId: "person-sarah",
      similarity: 0.74,
      margin: 0.05,
      sampleCount: 1
    )

    XCTAssertEqual(known.personIdForTranscript, "person-sarah")
    XCTAssertNil(suggested.personIdForTranscript)
    XCTAssertEqual(suggested.similarity, 0.74)
  }

  func testBackendSegmentDecodesTranslations() throws {
    let json = """
      {
        "id": "seg_1",
        "text": "テスト",
        "speaker": "SPEAKER_00",
        "speaker_id": 0,
        "is_user": false,
        "start": 0.0,
        "end": 1.5,
        "translations": [
          {"lang": "en", "text": "Test"}
        ]
      }
      """.data(using: .utf8)!

    let segment = try JSONDecoder().decode(TranscriptionService.BackendSegment.self, from: json)

    XCTAssertEqual(segment.translations?.count, 1)
    XCTAssertEqual(segment.translations?[0].lang, "en")
    XCTAssertEqual(segment.translations?[0].text, "Test")
  }

  // MARK: - TranscriptionSegmentRecord Translation Round-Trip Tests

  func testTranscriptionSegmentRecordRoundTripWithTranslations() {
    let translations = [
      TranscriptTranslation(lang: "en", text: "Hello"),
      TranscriptTranslation(lang: "es", text: "Hola"),
    ]
    let translationsJson = String(data: try! JSONEncoder().encode(translations), encoding: .utf8)

    let record = TranscriptionSegmentRecord(
      sessionId: 1,
      speaker: 0,
      text: "こんにちは",
      startTime: 0.0,
      endTime: 1.5,
      segmentOrder: 0,
      segmentId: "seg_trans_rt",
      isUser: false,
      translationsJson: translationsJson
    )

    let segment = record.toTranscriptSegment()

    XCTAssertEqual(segment.translations.count, 2)
    XCTAssertEqual(segment.translations[0].lang, "en")
    XCTAssertEqual(segment.translations[0].text, "Hello")
    XCTAssertEqual(segment.translations[1].lang, "es")
    XCTAssertEqual(segment.translations[1].text, "Hola")
  }

  func testTranscriptionSegmentRecordRoundTripNilTranslationsJson() {
    let record = TranscriptionSegmentRecord(
      sessionId: 1,
      speaker: 0,
      text: "Hello",
      startTime: 0.0,
      endTime: 1.0,
      segmentOrder: 0,
      segmentId: "seg_no_trans_rt"
    )

    let segment = record.toTranscriptSegment()
    XCTAssertTrue(segment.translations.isEmpty, "Nil translationsJson should produce empty translations array")
  }

  func testTranscriptionSegmentRecordFromSegmentEncodesTranslations() {
    let segment = TranscriptSegment(
      id: "seg_encode_1",
      backendId: "seg_encode_1",
      text: "テスト",
      speaker: "SPEAKER_00",
      isUser: false,
      personId: nil,
      start: 0,
      end: 1,
      translations: [
        TranscriptTranslation(lang: "en", text: "Test"),
        TranscriptTranslation(lang: "fr", text: "Essai"),
      ]
    )

    let record = TranscriptionSegmentRecord.from(segment, sessionId: 1, segmentOrder: 0)

    XCTAssertNotNil(record.translationsJson, "Non-empty translations should be encoded to JSON")

    // Decode back and verify
    let decoded = try! JSONDecoder().decode(
      [TranscriptTranslation].self,
      from: record.translationsJson!.data(using: .utf8)!
    )
    XCTAssertEqual(decoded.count, 2)
    XCTAssertEqual(decoded[0].lang, "en")
    XCTAssertEqual(decoded[1].lang, "fr")
  }

  func testTranscriptionSegmentRecordFromSegmentEmptyTranslations() {
    let segment = TranscriptSegment(
      id: "seg_empty_trans",
      text: "Hello",
      speaker: "SPEAKER_00",
      isUser: false,
      personId: nil,
      start: 0,
      end: 1
    )

    let record = TranscriptionSegmentRecord.from(segment, sessionId: 1, segmentOrder: 0)
    XCTAssertNil(record.translationsJson, "Empty translations should produce nil translationsJson")
  }

  // MARK: - In-Memory Translation Preservation Tests

  func testSpeakerSegmentUpdatePreservesExistingTranslations() {
    // Simulates handleBackendSegments logic: when a segment update arrives
    // without translations, existing translations should be preserved
    var existing = SpeakerSegment(
      segmentId: "seg_preserve",
      speaker: 0,
      text: "Original text",
      start: 0,
      end: 1,
      isUser: false,
      translations: [
        SegmentTranslation(lang: "en", text: "Original text translated"),
      ]
    )

    // Incoming update with no translations (e.g., text refinement)
    let incoming = SpeakerSegment(
      segmentId: "seg_preserve",
      speaker: 0,
      text: "Updated text",
      start: 0,
      end: 1.5,
      isUser: false,
      translations: []
    )

    // Apply the preservation logic from handleBackendSegments
    var updated = incoming
    if incoming.translations.isEmpty && !existing.translations.isEmpty {
      updated.translations = existing.translations
    }
    existing = updated

    XCTAssertEqual(existing.text, "Updated text", "Text should be updated")
    XCTAssertEqual(existing.end, 1.5, "End time should be updated")
    XCTAssertEqual(existing.translations.count, 1, "Translations should be preserved")
    XCTAssertEqual(existing.translations[0].text, "Original text translated")
  }

  func testSpeakerSegmentUpdateReplacesTranslationsWhenNewOnesProvided() {
    var existing = SpeakerSegment(
      segmentId: "seg_replace",
      speaker: 0,
      text: "Original",
      start: 0,
      end: 1,
      isUser: false,
      translations: [
        SegmentTranslation(lang: "en", text: "Old translation"),
      ]
    )

    let incoming = SpeakerSegment(
      segmentId: "seg_replace",
      speaker: 0,
      text: "Updated",
      start: 0,
      end: 1,
      isUser: false,
      translations: [
        SegmentTranslation(lang: "en", text: "New translation"),
        SegmentTranslation(lang: "fr", text: "Nouvelle traduction"),
      ]
    )

    // When incoming has translations, use them
    var updated = incoming
    if incoming.translations.isEmpty && !existing.translations.isEmpty {
      updated.translations = existing.translations
    }
    existing = updated

    XCTAssertEqual(existing.translations.count, 2, "New translations should replace old ones")
    XCTAssertEqual(existing.translations[0].text, "New translation")
    XCTAssertEqual(existing.translations[1].text, "Nouvelle traduction")
  }

  // MARK: - Assignment Metadata Tests

  func testAssignmentMetadataPrefersBackendIdsAndFallsBackToIndices() {
    let segments = [
      TranscriptSegment(
        id: UUID().uuidString,
        backendId: nil,
        text: "Local only",
        speaker: "SPEAKER_00",
        isUser: false,
        personId: nil,
        start: 0,
        end: 1
      ),
      TranscriptSegment(
        id: "seg_backend_123",
        backendId: "seg_backend_123",
        text: "Synced",
        speaker: "SPEAKER_01",
        isUser: false,
        personId: nil,
        start: 1,
        end: 2
      ),
      TranscriptSegment(
        id: "seg_backend_456",
        backendId: "seg_backend_456",
        text: "Also synced",
        speaker: "SPEAKER_02",
        isUser: false,
        personId: nil,
        start: 2,
        end: 3
      ),
    ]

    let assignment = ConversationDetailView.assignmentMetadata(
      for: [0, 1, 99, 2],
      in: segments
    )

    XCTAssertEqual(
      assignment.targets,
      ["#index:0", "seg_backend_123", "seg_backend_456"]
    )
    XCTAssertEqual(
      assignment.backendIds,
      ["seg_backend_123", "seg_backend_456"]
    )
    XCTAssertEqual(assignment.fallbackOrders, [0])
  }

  func testSpeakerReviewQueueExcludesUserShortAndNoiseOnlySegments() {
    let segments = [
      TranscriptSegment(
        id: "user",
        text: "this is mike",
        speaker: "SPEAKER_00",
        isUser: true,
        personId: nil,
        start: 0,
        end: 5
      ),
      TranscriptSegment(
        id: "short",
        text: "hi",
        speaker: "SPEAKER_01",
        isUser: false,
        personId: nil,
        start: 5,
        end: 5.5
      ),
      TranscriptSegment(
        id: "music",
        text: "(gentle music)",
        speaker: "SPEAKER_01",
        isUser: false,
        personId: nil,
        start: 6,
        end: 10
      ),
      TranscriptSegment(
        id: "reviewable",
        text: "We should label this voice.",
        speaker: "SPEAKER_02",
        isUser: false,
        personId: nil,
        start: 11,
        end: 15
      )
    ]

    let queue = SpeakerReviewQueueBuilder.makeQueue(from: segments)
    XCTAssertEqual(queue.count, 1)
    XCTAssertEqual(queue[0].speakerId, 2)
    XCTAssertEqual(queue[0].segmentIndices, [3])
    XCTAssertEqual(queue[0].samples.first?.start, 11)
    XCTAssertEqual(queue[0].samples.first?.end, 15)
  }

  func testSpeakerReviewQueueAssignsFullClusterWhileSamplingReviewableSegments() {
    let segments = [
      TranscriptSegment(
        id: "short",
        text: "ok",
        speaker: "SPEAKER_01",
        isUser: false,
        personId: nil,
        start: 0,
        end: 0.5
      ),
      TranscriptSegment(
        id: "music",
        text: "(gentle music)",
        speaker: "SPEAKER_01",
        isUser: false,
        personId: nil,
        start: 1,
        end: 4
      ),
      TranscriptSegment(
        id: "reviewable",
        text: "This is the sample we should review.",
        speaker: "SPEAKER_01",
        isUser: false,
        personId: nil,
        start: 5,
        end: 9
      ),
      TranscriptSegment(
        id: "already-named",
        text: "Already assigned should not be relabeled by this queue item.",
        speaker: "SPEAKER_01",
        isUser: false,
        personId: "existing-person",
        start: 10,
        end: 14
      )
    ]

    let queue = SpeakerReviewQueueBuilder.makeQueue(from: segments)

    XCTAssertEqual(queue.count, 1)
    XCTAssertEqual(queue[0].segmentIndices, [0, 1, 2])
    XCTAssertEqual(queue[0].samples.map(\.segmentIndex), [2])
  }

  func testSpeakerReviewQueueRequiresThreeSecondSamplesAndDoesNotCrossSegmentBounds() {
    let segments = [
      TranscriptSegment(
        id: "too-short",
        text: "This turn has words but is too short for review playback.",
        speaker: "SPEAKER_01",
        isUser: false,
        personId: nil,
        start: 1,
        end: 3.5
      ),
      TranscriptSegment(
        id: "reviewable",
        text: "This turn is long enough to review safely.",
        speaker: "SPEAKER_01",
        isUser: false,
        personId: nil,
        start: 10,
        end: 13.25
      )
    ]

    let queue = SpeakerReviewQueueBuilder.makeQueue(from: segments)

    XCTAssertEqual(queue.count, 1)
    XCTAssertEqual(queue[0].segmentIndices, [0, 1])
    XCTAssertEqual(queue[0].samples.map(\.segmentIndex), [1])
    XCTAssertEqual(queue[0].samples.first?.start, 10)
    XCTAssertEqual(queue[0].samples.first?.end, 13.25)
  }

  func testSpeakerReviewQueuePrioritizesSuggestedSpeakers() {
    let segments = [
      TranscriptSegment(
        id: "unknown",
        text: "Unknown speaker with enough speech.",
        speaker: "SPEAKER_03",
        isUser: false,
        personId: nil,
        start: 0,
        end: 4
      ),
      TranscriptSegment(
        id: "suggested",
        text: "Suggested speaker with enough speech.",
        speaker: "SPEAKER_01",
        isUser: false,
        personId: nil,
        suggestedPersonId: "p1",
        suggestedSimilarity: 0.78,
        suggestedMargin: 0.05,
        suggestedSampleCount: 2,
        start: 5,
        end: 9
      )
    ]

    let queue = SpeakerReviewQueueBuilder.makeQueue(from: segments)
    XCTAssertEqual(queue.map(\.speakerId), [1, 3])
    XCTAssertEqual(queue.first?.suggestedPersonId, "p1")
  }

  func testSpeakerReviewQueuePreservesSuggestionWhenLongestSampleIsUnknown() {
    let segments = [
      TranscriptSegment(
        id: "long-unknown",
        text: "This long sample lacks suggested identity metadata.",
        speaker: "SPEAKER_01",
        isUser: false,
        personId: nil,
        start: 0,
        end: 8
      ),
      TranscriptSegment(
        id: "short-suggested",
        text: "yes",
        speaker: "SPEAKER_01",
        isUser: false,
        personId: nil,
        suggestedPersonId: "p1",
        suggestedSimilarity: 0.82,
        suggestedMargin: 0.04,
        suggestedSampleCount: 2,
        start: 9,
        end: 9.5
      ),
      TranscriptSegment(
        id: "other-unknown",
        text: "Another unknown speaker with enough speech.",
        speaker: "SPEAKER_02",
        isUser: false,
        personId: nil,
        start: 10,
        end: 14
      )
    ]

    let queue = SpeakerReviewQueueBuilder.makeQueue(from: segments)

    XCTAssertEqual(queue.map(\.speakerId), [1, 2])
    XCTAssertEqual(queue.first?.suggestedPersonId, "p1")
    XCTAssertEqual(queue.first?.suggestedSimilarity, 0.82)
    XCTAssertEqual(queue.first?.segmentIndices, [0, 1])
    XCTAssertEqual(queue.first?.samples.map(\.segmentIndex), [0])
  }

  func testSpeakerAssignmentTargetEncodesYouAndPersonAssignments() {
    XCTAssertNil(SpeakerAssignmentTarget.you.personId)
    XCTAssertTrue(SpeakerAssignmentTarget.you.isUser)

    let personTarget = SpeakerAssignmentTarget.person("person-1")
    XCTAssertEqual(personTarget.personId, "person-1")
    XCTAssertFalse(personTarget.isUser)
  }

  func testTranscriptSegmentDecodesSuggestedCandidateMetadata() throws {
    let json = """
      {
        "id": "seg_suggested_1",
        "text": "Hello",
        "speaker": "SPEAKER_01",
        "is_user": false,
        "start": 1.0,
        "end": 2.0,
        "suggested_person_id": "person_candidate",
        "suggested_similarity": 0.74,
        "suggested_margin": 0.05,
        "suggested_sample_count": 2
      }
      """.data(using: .utf8)!

    let segment = try JSONDecoder().decode(TranscriptSegment.self, from: json)

    XCTAssertNil(segment.personId, "Suggested metadata must not imply a named transcript")
    XCTAssertEqual(segment.suggestedPersonId, "person_candidate")
    XCTAssertEqual(segment.suggestedSampleCount, 2)
    XCTAssertEqual(segment.suggestedSimilarity, 0.74)
  }
}
