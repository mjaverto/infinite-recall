import XCTest
@testable import Omi_Computer

/// Tests for `TranscriptionService` — the on-device WhisperKit transcription engine.
///
/// HISTORY: This file originally exercised the Python backend WebSocket protocol
/// (`parseBackendResponse(_:)`, `handleDisconnection()`, `cleanupAndReconnect()`,
/// `reconnectAttempts`, `maxReconnectAttempts`). The Infinite Recall fork removed
/// that entire cloud path — see the commented-out "Legacy cloud WebSocket path"
/// block at the bottom of `TranscriptionService.swift`. Tests that asserted on
/// behaviors which no longer exist in the codebase are documented as DROPPED
/// below (intent preserved as comments so the original test signal is traceable).
///
/// What IS still tested here:
///   1. `BackendSegment` JSON decoding — the struct is preserved verbatim for
///      AppState compatibility, so its `Decodable` contract is still load-bearing.
///   2. `start(...)` / `stop()` lifecycle — fires `onConnected`/`onDisconnected`
///      callbacks and toggles `isConnected`.
///   3. `int16PCMToFloat32` audio conversion math.
///   4. `sendAudio(_:)` is a no-op when not connected (guard branch).
final class ListenProtocolTests: XCTestCase {

    // MARK: - BackendSegment Decoding
    //
    // These tests are unchanged from the original file. The `BackendSegment`
    // shape is preserved so AppState's `handleBackendSegments` still compiles
    // and the on-device WhisperKit pipeline produces identical payloads.

    func testDecodeSegmentWithAllFields() throws {
        let json = """
        [{"id":"seg-1","text":"hello world","speaker":"SPEAKER_00","speaker_id":0,"is_user":true,"person_id":"p1","start":1.5,"end":3.2}]
        """
        let data = json.data(using: .utf8)!
        let segments = try JSONDecoder().decode([TranscriptionService.BackendSegment].self, from: data)

        XCTAssertEqual(segments.count, 1)
        let seg = segments[0]
        XCTAssertEqual(seg.id, "seg-1")
        XCTAssertEqual(seg.text, "hello world")
        XCTAssertEqual(seg.speaker, "SPEAKER_00")
        XCTAssertEqual(seg.speaker_id, 0)
        XCTAssertTrue(seg.is_user)
        XCTAssertEqual(seg.person_id, "p1")
        XCTAssertEqual(seg.start, 1.5)
        XCTAssertEqual(seg.end, 3.2)
    }

    func testDecodeSegmentWithNullOptionals() throws {
        let json = """
        [{"id":null,"text":"test","speaker":null,"speaker_id":null,"is_user":false,"person_id":null,"start":0.0,"end":1.0}]
        """
        let data = json.data(using: .utf8)!
        let segments = try JSONDecoder().decode([TranscriptionService.BackendSegment].self, from: data)

        XCTAssertEqual(segments.count, 1)
        let seg = segments[0]
        XCTAssertNil(seg.id)
        XCTAssertNil(seg.speaker)
        XCTAssertNil(seg.speaker_id)
        XCTAssertNil(seg.person_id)
        XCTAssertFalse(seg.is_user)
    }

    func testDecodeMultipleSegments() throws {
        let json = """
        [
            {"id":"s1","text":"first","speaker":"SPEAKER_00","speaker_id":0,"is_user":true,"person_id":null,"start":0.0,"end":1.0},
            {"id":"s2","text":"second","speaker":"SPEAKER_01","speaker_id":1,"is_user":false,"person_id":"p2","start":1.0,"end":2.5}
        ]
        """
        let data = json.data(using: .utf8)!
        let segments = try JSONDecoder().decode([TranscriptionService.BackendSegment].self, from: data)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].speaker_id, 0)
        XCTAssertTrue(segments[0].is_user)
        XCTAssertEqual(segments[1].speaker_id, 1)
        XCTAssertFalse(segments[1].is_user)
    }

    func testDecodeEmptySegmentArray() throws {
        let json = "[]"
        let data = json.data(using: .utf8)!
        let segments = try JSONDecoder().decode([TranscriptionService.BackendSegment].self, from: data)
        XCTAssertTrue(segments.isEmpty)
    }

    func testDecodeSegmentWithTranslations() throws {
        // BackendTranslation is also preserved — exercise its decoding too.
        let json = """
        [{"id":"s1","text":"hola","speaker":"SPEAKER_00","speaker_id":0,"is_user":true,"person_id":null,"start":0.0,"end":1.0,"translations":[{"lang":"en","text":"hello"}]}]
        """
        let data = json.data(using: .utf8)!
        let segments = try JSONDecoder().decode([TranscriptionService.BackendSegment].self, from: data)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].translations?.count, 1)
        XCTAssertEqual(segments[0].translations?[0].lang, "en")
        XCTAssertEqual(segments[0].translations?[0].text, "hello")
    }

    // MARK: - Lifecycle: start() / stop()
    //
    // The cloud WebSocket connect/disconnect lifecycle is gone. The current
    // contract is simpler: `start()` fires `onConnected` immediately (so the
    // mic capture pipeline can begin even before WhisperKit finishes loading
    // its ~140 MB model), and `stop()` fires `onDisconnected` and clears state.
    // We test that synchronous contract here without exercising WhisperKit
    // model loading (which would attempt a network download).

    func testStartFiresOnConnectedAndSetsIsConnected() throws {
        let connected = expectation(description: "onConnected fires")
        let service = try TranscriptionService(language: "en")
        service.start(
            onSegments: { _ in },
            onEvent: { _ in },
            onError: nil,
            onConnected: { connected.fulfill() },
            onDisconnected: nil
        )
        // `start` flips isConnected synchronously before dispatching the callback.
        XCTAssertTrue(service.isConnected)
        wait(for: [connected], timeout: 2.0)
        // Cancel the background model-load task so we don't hold a network handle.
        service.stop()
    }

    func testStopFiresOnDisconnectedAndClearsIsConnected() throws {
        let connected = expectation(description: "onConnected fires")
        let disconnected = expectation(description: "onDisconnected fires")
        let service = try TranscriptionService(language: "en")
        service.start(
            onSegments: { _ in },
            onEvent: { _ in },
            onError: nil,
            onConnected: { connected.fulfill() },
            onDisconnected: { disconnected.fulfill() }
        )
        wait(for: [connected], timeout: 2.0)
        XCTAssertTrue(service.isConnected)

        service.stop()

        XCTAssertFalse(service.isConnected)
        wait(for: [disconnected], timeout: 2.0)
    }

    func testConnectedAccessorMirrorsIsConnected() throws {
        let service = try TranscriptionService(language: "en")
        XCTAssertFalse(service.connected)
        service.isConnected = true
        XCTAssertTrue(service.connected)
        service.isConnected = false
        XCTAssertFalse(service.connected)
    }

    // MARK: - sendAudio guard

    func testSendAudioIsNoOpWhenNotConnected() throws {
        // When isConnected == false, sendAudio should silently drop samples.
        // Hard to observe directly (pcmBuffer is private), so we just assert
        // it doesn't crash. This was previously implicit in the cloud path
        // (no WebSocket → no send); the WhisperKit path makes it explicit.
        let service = try TranscriptionService(language: "en")
        XCTAssertFalse(service.isConnected)
        // Fake 100ms of silence at 16 kHz, Int16 mono = 1600 samples = 3200 bytes.
        let silence = Data(count: 3200)
        service.sendAudio(silence)  // should not throw, should not crash
    }

    // MARK: - PCM conversion math

    func testInt16PCMToFloat32EmptyData() {
        let result = TranscriptionService.int16PCMToFloat32(Data())
        XCTAssertTrue(result.isEmpty)
    }

    func testInt16PCMToFloat32OddByteCountTruncates() {
        // 3 bytes can only encode 1 Int16 sample (the trailing byte is dropped).
        let result = TranscriptionService.int16PCMToFloat32(Data([0x00, 0x00, 0xFF]))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], 0.0)
    }

    func testInt16PCMToFloat32NormalizesToUnitRange() {
        // Int16 0      → 0.0
        // Int16 16384  → 0.5  (= 16384 / 32768)
        // Int16 -16384 → -0.5
        let samples: [Int16] = [0, 16384, -16384]
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let result = TranscriptionService.int16PCMToFloat32(data)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], 0.0, accuracy: 1e-6)
        XCTAssertEqual(result[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(result[2], -0.5, accuracy: 1e-6)
    }

    // MARK: - DROPPED tests (behavior no longer exists in the codebase)
    //
    // The following tests were removed in this rewrite because the cloud
    // WebSocket path they exercised is entirely gone (see the commented-out
    // "Legacy cloud WebSocket path" block at the bottom of TranscriptionService.swift).
    // They are listed here so the original test intent stays discoverable in
    // git blame:
    //
    //   - testParserDispatchesSegmentCallback
    //   - testParserDispatchesEventCallback
    //   - testParserIgnoresPingHeartbeat
    //   - testParserIgnoresEmptySegmentArray
    //   - testParserHandlesInvalidJsonGracefully
    //   - testParserDispatchesSegmentsDeletedEvent
    //   - testParserDispatchesSpeakerLabelEvent
    //   - testParserIgnoresObjectWithoutType
    //   - testParserHandlesArrayOfInvalidSegments
    //   - testParserHandlesEventWithMissingNestedFields
    //   - testParserHandlesSegmentsDeletedWithMissingIds
    //   - testParserHandlesJsonNumber
    //   - testParserHandlesUnknownEventType
    //   - testParserDispatchesMultipleSegments
    //     → All exercised `parseBackendResponse(_:)`, which decoded a JSON
    //       text frame off the WebSocket. There is no JSON-frame ingest in
    //       the WhisperKit path; segments come straight from
    //       `WhisperKit.transcribe(audioArray:)` and are emitted via the
    //       private `emitSegments(from:)`. No public surface to assert on
    //       without modifying source.
    //
    //   - testHandleDisconnectionRequiresConnected
    //   - testHandleDisconnectionIncrementsAttempts
    //   - testCleanupAndReconnectWorksWhenNotConnected
    //   - testMaxReconnectAttemptsTriggersError
    //   - testCleanupAndReconnectMaxAttemptsTriggersError
    //   - testHandleDisconnectionCallsOnDisconnected
    //     → All exercised `handleDisconnection()`, `cleanupAndReconnect()`,
    //       `reconnectAttempts`, `maxReconnectAttempts`. There is no
    //       reconnect state machine in the on-device pipeline — there's
    //       nothing to reconnect to. `shouldReconnect` is preserved as a
    //       no-op field for source compatibility but has no behavior to
    //       assert on.
}
