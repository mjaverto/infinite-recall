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

    // MARK: - Autonomous LLM path: recordAICall invariant
    //
    // The autonomous summarize drain MUST NOT bump
    // `IdleAIController.shared.lastAICall`. If it did, Memory Saver's idle
    // threshold would never elapse during a long drain and the local LLM
    // would stay pinned in RAM. We verify this by exercising the LLM client
    // directly: `chat()` calls `recordAICall()` BEFORE issuing HTTP, so even
    // when the call fails (no real server) the timestamp advances; whereas
    // `chatAutonomous()` skips that bump entirely. (See LocalLLMClient.swift.)

    @MainActor
    func test_chatAutonomous_doesNotBumpLastAICall() async throws {
        // Capture the current timestamp; a small await ensures any preceding
        // ticks have settled.
        let before = await IdleAIController.shared.lastAICall
        // Tiny sleep so a sentinel timestamp can be detected if mutated.
        try await Task.sleep(nanoseconds: 10_000_000)  // 10 ms
        let messages: [LLM.ChatMessage] = [
            .init(role: .system, content: "test"),
            .init(role: .user, content: "test"),
        ]
        // Call must complete (throw or succeed) without bumping lastAICall.
        // We don't care if HTTP fails — server may not be running in CI.
        do {
            let stream = try await LocalLLMClient.shared.chatAutonomous(
                messages: messages,
                stream: false
            )
            // Drain a few chunks just in case; timestamp invariant still holds.
            for try await _ in stream { break }
        } catch {
            // ignore — local server availability is irrelevant to this assertion
        }
        let after = await IdleAIController.shared.lastAICall
        XCTAssertEqual(
            after, before,
            "chatAutonomous MUST NOT bump IdleAIController.lastAICall (Memory Saver invariant)"
        )
    }

    @MainActor
    func test_chat_doesBumpLastAICall() async throws {
        let before = await IdleAIController.shared.lastAICall
        try await Task.sleep(nanoseconds: 10_000_000)  // 10 ms — separation
        let messages: [LLM.ChatMessage] = [
            .init(role: .system, content: "test"),
            .init(role: .user, content: "test"),
        ]
        do {
            let stream = try await LocalLLMClient.shared.chat(
                messages: messages,
                stream: false
            )
            for try await _ in stream { break }
        } catch {
            // ignore — recordAICall fires BEFORE HTTP
        }
        let after = await IdleAIController.shared.lastAICall
        XCTAssertGreaterThan(
            after, before,
            "chat() MUST bump IdleAIController.lastAICall so the watchdog auto-restarts the server on next user-initiated chat"
        )
    }
}
