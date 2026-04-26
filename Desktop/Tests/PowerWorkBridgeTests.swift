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
}
