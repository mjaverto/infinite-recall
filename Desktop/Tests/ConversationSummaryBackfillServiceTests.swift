import XCTest
@testable import Omi_Computer

/// Tests for `ConversationSummaryBackfillService` — ambient-fallback
/// detection, pending-work payload contract, and dedup-key format.
///
/// Database-bound paths (placeholder writes, repair SQL) are covered by
/// `TranscriptionStorageRepairTests` against an in-memory GRDB instance.
/// These tests focus on pure-function invariants that don't depend on the
/// `RewindDatabase.shared` singleton.
final class ConversationSummaryBackfillServiceTests: XCTestCase {

    // MARK: - Ambient / non-speech detection

    func testAmbientDetectorFlagsBracketedMusicTranscript() {
        let transcript = "[Music] [Music] [Applause] [Music]"
        XCTAssertTrue(
            ConversationSummaryBackfillService.isMostlyNonSpeech(transcript),
            "All-bracketed transcript must be classified as ambient"
        )
    }

    func testAmbientDetectorFlagsBlankAudioToken() {
        // WhisperKit-style blank-audio markers seen in the wild.
        let transcript = "[BLANK_AUDIO] [BLANK_AUDIO] [Music] [BLANK_AUDIO]"
        XCTAssertTrue(
            ConversationSummaryBackfillService.isMostlyNonSpeech(transcript),
            "All-bracketed blank/music transcript must be classified as ambient"
        )
    }

    func testAmbientDetectorPassesRealSpeechThrough() {
        let transcript = "Hi everyone, today we're going to talk about scheduling drains and battery awareness, then walk through the new Memory Saver behaviour together for about thirty minutes."
        XCTAssertFalse(
            ConversationSummaryBackfillService.isMostlyNonSpeech(transcript),
            "Real speech transcript must NOT be classified as ambient"
        )
    }

    func testAmbientDetectorPassesMixedTranscriptThrough() {
        // Real speech with occasional bracketed cues should still be summarized.
        let transcript = "[Music] Welcome to the standup. Yesterday I shipped the scheduler change and today I'm wiring up the autonomous drain. [Applause] Any blockers?"
        XCTAssertFalse(
            ConversationSummaryBackfillService.isMostlyNonSpeech(transcript),
            "Mixed-but-mostly-speech transcript must NOT be classified as ambient"
        )
    }

    func testAmbientDetectorTreatsEmptyAsNotAmbient() {
        // Empty string is handled by the upstream short-transcript guard, so
        // the detector should not claim it. Ensures we don't double-fire.
        XCTAssertFalse(
            ConversationSummaryBackfillService.isMostlyNonSpeech(""),
            "Empty transcript must not be classified as ambient (short-path handles it)"
        )
    }

    // MARK: - Pending-work payload contract

    func testPendingPayloadEncodesAsContractuallyDefinedJSON() throws {
        let payload = ConversationSummaryBackfillService.PendingPayload(session_id: 4242)
        let data = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        // Contract: payload shape is exactly {"session_id": Int64}.
        XCTAssertEqual(json.keys.sorted(), ["session_id"])
        XCTAssertEqual(json["session_id"] as? Int64, 4242)
    }

    func testPendingPayloadDecodesRoundTrip() throws {
        let original = ConversationSummaryBackfillService.PendingPayload(session_id: 1)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            ConversationSummaryBackfillService.PendingPayload.self,
            from: data
        )
        XCTAssertEqual(decoded.session_id, original.session_id)
    }

    // MARK: - Dedup-key contract

    func testDedupKeyMatchesContract() {
        // Contract: dedup key format is "summarize:<session_id>".
        XCTAssertEqual(
            ConversationSummaryBackfillService.dedupKey(for: 0),
            "summarize:0"
        )
        XCTAssertEqual(
            ConversationSummaryBackfillService.dedupKey(for: 99_999_999_999),
            "summarize:99999999999"
        )
    }

    // MARK: - Workflow invariant: blocked-readiness path enqueues

    /// The whole point of the rewrite is that even when heavy work is NOT
    /// allowed, work is durably enqueued instead of dropped. This test
    /// verifies the API surface that guarantees that invariant exists with
    /// the contract-required signature.
    ///
    /// Functional verification (does enqueue actually call PendingWorkStorage)
    /// requires the `RewindDatabase.shared` singleton and is exercised by
    /// the manual scenarios in `context.md` (#5: Local AI unavailable, #6:
    /// historical untitled transcripts) plus integration testing.
    func testEnqueueSummaryAndProcessSummaryHaveContractSignatures() {
        // Compile-time assertion: these methods exist with exact signatures.
        // If the contract drifts, this test stops compiling.
        let svc = ConversationSummaryBackfillService.shared
        let _: (Int64, String) async -> Void = { sid, reason in
            await svc.enqueueSummary(sessionId: sid, reason: reason)
        }
        let _: (String) async -> Void = { reason in
            await svc.enqueueHistoricalSummariesIfNeeded(reason: reason)
        }
        let _: (Int64, Bool) async throws -> Void = { sid, autonomous in
            try await svc.processSummary(sessionId: sid, autonomous: autonomous)
        }
        XCTAssertNotNil(svc)
    }
}
