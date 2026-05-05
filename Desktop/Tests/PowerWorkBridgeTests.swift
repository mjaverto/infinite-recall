import XCTest
@testable import Omi_Computer

/// Unit tests for `PowerWorkBridge._handleSummarizePayload` — the testable
/// seam extracted from `handleSummarize` in PR #30 follow-up. Asserts the
/// three pre-decided semantics:
///   (a) undecodable payload → no throw, no notify, no processor call
///   (b) success → processor called with the decoded sessionId, notify
///       called with the same sessionId
///   (c) processor throw → re-thrown, no notify
final class PowerWorkBridgeTests: XCTestCase {

    // MARK: - (a) Undecodable payload

    func test_handleSummarizePayload_undecodable_doesNotThrow_doesNotNotify_doesNotCallProcessor() async throws {
        let payload = Data("not even close to JSON".utf8)
        var processorCallCount = 0
        var notifyCallCount = 0

        try await PowerWorkBridge._handleSummarizePayload(
            payload,
            processor: { _ in
                processorCallCount += 1
            },
            notify: { _ in
                notifyCallCount += 1
            }
        )

        XCTAssertEqual(processorCallCount, 0, "processor must not be called for undecodable payload")
        XCTAssertEqual(notifyCallCount, 0, "notify must not be called for undecodable payload")
    }

    func test_handleSummarizePayload_undecodableEmptyJSON_doesNotThrow_doesNotNotify() async throws {
        // Valid JSON but missing required `session_id` field — same outcome as
        // unparseable bytes: drop silently with logError, no retry value here.
        let payload = Data(#"{"foo": 1}"#.utf8)
        var processorCallCount = 0
        var notifyCallCount = 0

        try await PowerWorkBridge._handleSummarizePayload(
            payload,
            processor: { _ in processorCallCount += 1 },
            notify: { _ in notifyCallCount += 1 }
        )

        XCTAssertEqual(processorCallCount, 0)
        XCTAssertEqual(notifyCallCount, 0)
    }

    // MARK: - (b) Success path

    func test_handleSummarizePayload_success_callsProcessorAndNotifyWithSessionId() async throws {
        let payload = try JSONEncoder().encode(
            ConversationSummaryBackfillService.PendingPayload(session_id: 4242)
        )

        var processorSeen: Int64?
        var notifySeen: Int64?

        try await PowerWorkBridge._handleSummarizePayload(
            payload,
            processor: { sid in processorSeen = sid },
            notify: { sid in notifySeen = sid }
        )

        XCTAssertEqual(processorSeen, 4242, "processor must receive the decoded session_id")
        XCTAssertEqual(notifySeen, 4242, "notify must receive the same session_id on success")
    }

    // MARK: - (c) Processor throw is re-thrown without notifying

    func test_handleSummarizePayload_processorThrow_isReThrown_andNoNotify() async throws {
        let payload = try JSONEncoder().encode(
            ConversationSummaryBackfillService.PendingPayload(session_id: 99)
        )

        struct DeliberateError: Error {}
        var notifyCallCount = 0

        do {
            try await PowerWorkBridge._handleSummarizePayload(
                payload,
                processor: { _ in throw DeliberateError() },
                notify: { _ in notifyCallCount += 1 }
            )
            XCTFail("processor threw — expected the seam to re-throw")
        } catch is DeliberateError {
            // expected
        } catch {
            XCTFail("expected DeliberateError, got \(error)")
        }

        XCTAssertEqual(notifyCallCount, 0, "notify must not fire when processor throws")
    }

    // MARK: - .extractActionItems seam

    /// Same three-cases-plus-empty contract as `_handleSummarizePayload`:
    ///   (a) undecodable payload → no throw, no processor, no notify
    ///   (b) success → processor + notify both called with decoded sessionId
    ///   (c) processor throw → re-thrown, no notify
    ///   (d) success with empty result is the processor's responsibility (no
    ///       inserts happen) — the seam still calls notify so any observer
    ///       that wants to e.g. dismiss a "in flight" badge can react.

    func test_handleExtractActionItemsPayload_undecodable_doesNotThrow_doesNotNotify_doesNotCallProcessor() async throws {
        let payload = Data("definitely not JSON".utf8)
        var processorCallCount = 0
        var notifyCallCount = 0

        try await PowerWorkBridge._handleExtractActionItemsPayload(
            payload,
            processor: { _ in processorCallCount += 1 },
            notify: { _ in notifyCallCount += 1 }
        )

        XCTAssertEqual(processorCallCount, 0, "processor must not be called for undecodable payload")
        XCTAssertEqual(notifyCallCount, 0, "notify must not be called for undecodable payload")
    }

    func test_handleExtractActionItemsPayload_success_callsProcessorAndNotifyWithSessionId() async throws {
        let payload = try JSONEncoder().encode(
            ConversationActionItemsBackfillService.PendingPayload(session_id: 7777)
        )

        var processorSeen: Int64?
        var notifySeen: Int64?

        try await PowerWorkBridge._handleExtractActionItemsPayload(
            payload,
            processor: { sid in processorSeen = sid },
            notify: { sid in notifySeen = sid }
        )

        XCTAssertEqual(processorSeen, 7777, "processor must receive the decoded session_id")
        XCTAssertEqual(notifySeen, 7777, "notify must receive the same session_id on success")
    }

    func test_handleExtractActionItemsPayload_processorThrow_isReThrown_andNoNotify() async throws {
        let payload = try JSONEncoder().encode(
            ConversationActionItemsBackfillService.PendingPayload(session_id: 12)
        )

        struct DeliberateError: Error {}
        var notifyCallCount = 0

        do {
            try await PowerWorkBridge._handleExtractActionItemsPayload(
                payload,
                processor: { _ in throw DeliberateError() },
                notify: { _ in notifyCallCount += 1 }
            )
            XCTFail("processor threw — expected the seam to re-throw")
        } catch is DeliberateError {
            // expected
        } catch {
            XCTFail("expected DeliberateError, got \(error)")
        }

        XCTAssertEqual(notifyCallCount, 0, "notify must not fire when processor throws")
    }

    // FIX 3: removed `test_handleExtractActionItemsPayload_processorEmptyResult_callsNotify` —
    // it was functionally identical to the success test (the seam can't
    // observe "empty result" vs "success-with-items"; that branching lives
    // inside the real processor). Empty-vs-populated branches are covered
    // against `_processExtractActionItems` below where the seams actually
    // exist.

    // MARK: - _processExtractActionItems (atomicity + per-item failures)

    /// Cases under test:
    ///   (a) all inserts succeed → markExtracted called once, no throw
    ///   (b) mid-loop insert throws → loop completes attempts, markExtracted
    ///       NOT called, error re-thrown so PendingWork retries the job
    ///   (c) single-item failure → same as (b)
    ///   (d) empty LLM result → markExtracted called, no inserts, no throw
    ///   (e) short transcript → no LLM call, markExtracted called, no throw
    ///   (f) markExtracted failure on short branch → swallowed (FIX 7)
    ///   (g) markExtracted failure on empty-result branch → swallowed (FIX 7)

    private static func makeItem(_ desc: String) -> PowerWorkBridge.LLMActionItem {
        return PowerWorkBridge.LLMActionItem(description: desc)
    }

    func test_processExtractActionItems_allInsertsSucceed_marksExtractedOnce() async throws {
        var inserted: [String] = []
        var markCallCount = 0

        try await PowerWorkBridge._processExtractActionItems(
            sessionId: 1,
            loadTranscript: { _ in String(repeating: "x", count: 200) },
            extractItems: { _, _ in [Self.makeItem("a"), Self.makeItem("b")] },
            insert: { record in inserted.append(record.description) },
            markExtracted: { _ in markCallCount += 1 }
        )

        XCTAssertEqual(inserted, ["a", "b"])
        XCTAssertEqual(markCallCount, 1, "All inserts succeeded → markExtracted exactly once")
    }

    func test_processExtractActionItems_midLoopInsertFailure_reThrowsAndDoesNotMark() async throws {
        struct InsertFailure: Error {}
        var insertAttempts = 0
        var markCallCount = 0

        do {
            try await PowerWorkBridge._processExtractActionItems(
                sessionId: 2,
                loadTranscript: { _ in String(repeating: "y", count: 200) },
                extractItems: { _, _ in [Self.makeItem("a"), Self.makeItem("b"), Self.makeItem("c")] },
                insert: { _ in
                    insertAttempts += 1
                    if insertAttempts == 2 { throw InsertFailure() }
                },
                markExtracted: { _ in markCallCount += 1 }
            )
            XCTFail("Expected re-throw on mid-loop insert failure")
        } catch is InsertFailure {
            // expected
        }

        XCTAssertEqual(insertAttempts, 3, "Loop must keep going after mid-failure to attempt every item")
        XCTAssertEqual(markCallCount, 0, "markExtracted MUST NOT fire when any insert failed")
    }

    func test_processExtractActionItems_singleItemFailure_reThrowsAndDoesNotMark() async throws {
        struct InsertFailure: Error {}
        var markCallCount = 0

        do {
            try await PowerWorkBridge._processExtractActionItems(
                sessionId: 3,
                loadTranscript: { _ in String(repeating: "z", count: 200) },
                extractItems: { _, _ in [Self.makeItem("only")] },
                insert: { _ in throw InsertFailure() },
                markExtracted: { _ in markCallCount += 1 }
            )
            XCTFail("Expected re-throw on lone insert failure")
        } catch is InsertFailure {
            // expected
        }

        XCTAssertEqual(markCallCount, 0)
    }

    func test_processExtractActionItems_emptyLLMResult_marksExtractedNoInserts() async throws {
        var insertCount = 0
        var markCallCount = 0

        try await PowerWorkBridge._processExtractActionItems(
            sessionId: 4,
            loadTranscript: { _ in String(repeating: "k", count: 200) },
            extractItems: { _, _ in [] },
            insert: { _ in insertCount += 1 },
            markExtracted: { _ in markCallCount += 1 }
        )

        XCTAssertEqual(insertCount, 0)
        XCTAssertEqual(markCallCount, 1)
    }

    func test_processExtractActionItems_shortTranscript_skipsLLMAndMarksExtracted() async throws {
        var llmCallCount = 0
        var insertCount = 0
        var markCallCount = 0

        try await PowerWorkBridge._processExtractActionItems(
            sessionId: 5,
            loadTranscript: { _ in "tiny" },  // < minTranscriptLength
            extractItems: { _, _ in
                llmCallCount += 1
                return []
            },
            insert: { _ in insertCount += 1 },
            markExtracted: { _ in markCallCount += 1 }
        )

        XCTAssertEqual(llmCallCount, 0, "LLM must not be called on short transcript")
        XCTAssertEqual(insertCount, 0)
        XCTAssertEqual(markCallCount, 1, "Short branch still marks the session so it stops re-qualifying")
    }

    /// FIX 7: short-branch markExtracted failure must NOT propagate. The LLM
    /// didn't run, so re-throwing only burns the next drain re-checking the
    /// same too-short transcript. Eligibility query naturally re-picks the
    /// row next launch if it stays unmarked.
    func test_processExtractActionItems_shortTranscript_swallowsMarkFailure() async throws {
        struct MarkFailure: Error {}

        do {
            try await PowerWorkBridge._processExtractActionItems(
                sessionId: 6,
                loadTranscript: { _ in "tiny" },
                extractItems: { _, _ in [] },
                insert: { _ in },
                markExtracted: { _ in throw MarkFailure() }
            )
        } catch {
            XCTFail("Short-transcript branch must swallow markExtracted failure, got \(error)")
        }
    }

    /// FIX 7: empty-result branch markExtracted failure must NOT propagate.
    /// The LLM already ran and returned an empty result. Re-throwing burns
    /// another LLM call; the eligibility query handles recovery.
    func test_processExtractActionItems_emptyResult_swallowsMarkFailure() async throws {
        struct MarkFailure: Error {}

        do {
            try await PowerWorkBridge._processExtractActionItems(
                sessionId: 7,
                loadTranscript: { _ in String(repeating: "p", count: 200) },
                extractItems: { _, _ in [] },
                insert: { _ in },
                markExtracted: { _ in throw MarkFailure() }
            )
        } catch {
            XCTFail("Empty-result branch must swallow markExtracted failure, got \(error)")
        }
    }

    /// Populated branch: a markExtracted failure DOES propagate (opposite
    /// policy from short/empty branches). Inserts have user-visible
    /// consequences — losing the mark means the eligibility query picks the
    /// session up next launch and re-runs the LLM, but at least the items
    /// already in the local DB are preserved.
    func test_processExtractActionItems_populated_propagatesMarkFailure() async throws {
        struct MarkFailure: Error {}
        var insertCount = 0

        do {
            try await PowerWorkBridge._processExtractActionItems(
                sessionId: 8,
                loadTranscript: { _ in String(repeating: "q", count: 200) },
                extractItems: { _, _ in [Self.makeItem("only")] },
                insert: { _ in insertCount += 1 },
                markExtracted: { _ in throw MarkFailure() }
            )
            XCTFail("Populated branch must re-throw markExtracted failure")
        } catch is MarkFailure {
            // expected
        }

        XCTAssertEqual(insertCount, 1, "Insert ran before mark failed")
    }

    // MARK: - #120: voice-extracted source mapping

    /// `transcription_sessions.source = "omi"` → `"transcription:omi"` so the
    /// task lands in the *Transcription Omi* filter bucket on TasksPage.
    func test_taskSourceForSessionSource_omi_mapsToTranscriptionOmi() {
        XCTAssertEqual(PowerWorkBridge.taskSourceForSessionSource("omi"), "transcription:omi")
    }

    /// `transcription_sessions.source = "desktop"` → `"transcription:desktop"`.
    func test_taskSourceForSessionSource_desktop_mapsToTranscriptionDesktop() {
        XCTAssertEqual(PowerWorkBridge.taskSourceForSessionSource("desktop"), "transcription:desktop")
    }

    /// Anything else (nil, "unknown", legacy values) falls back to the
    /// pre-#120 "conversation" bucket so non-omi/desktop voice paths still
    /// match the legacy behavior.
    func test_taskSourceForSessionSource_unknown_fallsBackToConversation() {
        XCTAssertEqual(PowerWorkBridge.taskSourceForSessionSource(nil), "conversation")
        XCTAssertEqual(PowerWorkBridge.taskSourceForSessionSource("unknown"), "conversation")
        XCTAssertEqual(PowerWorkBridge.taskSourceForSessionSource("phone"), "conversation")
    }

    /// End-to-end through the seam: when `loadSessionSource` returns "omi",
    /// the inserted record carries `source = "transcription:omi"`. This is
    /// the regression guard for #120 — the previous code hard-coded
    /// `"conversation"` and the Tasks UI's source filters never matched.
    func test_processExtractActionItems_resolvesSessionSourceForInsertedRecord() async throws {
        var inserted: [ActionItemRecord] = []

        try await PowerWorkBridge._processExtractActionItems(
            sessionId: 99,
            loadTranscript: { _ in String(repeating: "x", count: 200) },
            loadSessionSource: { _ in "omi" },
            extractItems: { _, _ in [Self.makeItem("voice task")] },
            insert: { record in inserted.append(record) },
            markExtracted: { _ in }
        )

        XCTAssertEqual(inserted.count, 1)
        XCTAssertEqual(inserted.first?.source, "transcription:omi",
                       "voice-extracted task must map omi session → transcription:omi (fixes #120)")
    }
}
