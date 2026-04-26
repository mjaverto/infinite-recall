// Activity Tab — Stream I.
//
// Codable round-trip tests for the Phase 0 contract types in
// `Desktop/Sources/Activity/ActivityModels.swift`. The wire format is
// snake_case JSON shaped per `Backend-Rust/src/activity/contract.md`.
//
// What we verify:
//   1. A canonical fixture matching the contract decodes into our Swift
//      types with every field present and correctly typed.
//   2. Re-encoding the decoded value and decoding it again yields a value
//      equal to the original (round-trip stability).
//   3. Optional fields are honoured in both directions (nullability,
//      omission of `waiting_for`, `gpu_system_percent`, etc).
//   4. Every `GateReason` enum value decodes from its snake_case wire form.
//   5. Every `WorkKind`, `CaptureKind`, `ThermalState`, `PauseTargetId`
//      enum value decodes from its snake_case wire form.
//   6. Request bodies (`PauseRequest`, `ResumeRequest`, `InflightUpdate`)
//      encode to the wire shape Stream A expects.
//   7. Issue #34: `PauseTargetId` sum type makes illegal `(target,id)`
//      pairs unrepresentable; `PauseRequest.init` rejects `minutes == 0`.

import XCTest
@testable import Omi_Computer

final class ActivityModelsTests: XCTestCase {

    // MARK: - Helpers

    /// Decoder configured for the contract's ISO-8601 timestamps with
    /// fractional seconds (e.g. `2026-04-26T14:22:03.812Z`).
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let container = try d.singleValueContainer()
            let s = try container.decode(String.self)
            if let date = isoFractional.date(from: s) ?? isoPlain.date(from: s) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unparseable ISO8601: \(s)"
            )
        }
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(isoFractional.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Fixture (matches §contract.md verbatim)

    /// Verbatim fixture from contract.md — exercises every field with a
    /// non-default value where possible.
    private static let fixtureSnapshotJSON = """
    {
      "kinds": [
        {
          "kind": "transcribe",
          "in_flight": {
            "label": "Transcribing 14:22:01→14:25:00 (en)",
            "started_at": "2026-04-26T14:22:03.812Z"
          },
          "queued": 47,
          "failed": 0,
          "last_done_at": "2026-04-26T14:21:58.000Z",
          "paused_until": null
        },
        {
          "kind": "ocr",
          "in_flight": null,
          "queued": 12,
          "failed": 3,
          "last_done_at": null,
          "paused_until": "2026-04-26T14:40:00.000Z"
        }
      ],
      "capture": [
        { "kind": "audio",  "running": true,  "paused_until": null },
        { "kind": "screen", "running": false, "paused_until": "2026-04-26T14:30:00.000Z" }
      ],
      "resources": {
        "cpu_percent": 142.0,
        "rss_mb": 2342,
        "gpu_system_percent": 38.0,
        "thermal_state": "fair",
        "on_battery": false,
        "low_power": false,
        "process_breakdown": [
          { "name": "infinite-recall-api", "pid": 1234, "cpu_percent": 12.4, "rss_mb": 84 },
          { "name": "Infinite Recall",     "pid": 1235, "cpu_percent": 51.2, "rss_mb": 760 },
          { "name": "mlx-lm.server",       "pid": 1236, "cpu_percent": 78.4, "rss_mb": 1498 }
        ]
      },
      "processing_gate": {
        "allowed": false,
        "reason": "device_active",
        "since": "2026-04-26T14:25:00.000Z",
        "waiting_for": "2 min of idle"
      },
      "generated_at": "2026-04-26T14:25:30.512Z"
    }
    """

    // MARK: - Snapshot decode: every field

    func testDecodeSnapshotPopulatesAllFields() throws {
        let snap = try Self.makeDecoder()
            .decode(ActivitySnapshot.self, from: Self.fixtureSnapshotJSON.data(using: .utf8)!)

        // Top-level
        XCTAssertEqual(snap.kinds.count, 2)
        XCTAssertEqual(snap.capture.count, 2)

        // First kind row — populated in_flight, no pause
        let transcribe = snap.kinds[0]
        XCTAssertEqual(transcribe.kind, .transcribe)
        XCTAssertEqual(transcribe.queued, 47)
        XCTAssertEqual(transcribe.failed, 0)
        XCTAssertNotNil(transcribe.lastDoneAt)
        XCTAssertNil(transcribe.pausedUntil)
        XCTAssertEqual(transcribe.inFlight?.label, "Transcribing 14:22:01→14:25:00 (en)")
        XCTAssertNotNil(transcribe.inFlight?.startedAt)

        // Second kind row — empty in_flight, paused
        let ocr = snap.kinds[1]
        XCTAssertEqual(ocr.kind, .ocr)
        XCTAssertNil(ocr.inFlight)
        XCTAssertEqual(ocr.queued, 12)
        XCTAssertEqual(ocr.failed, 3)
        XCTAssertNil(ocr.lastDoneAt)
        XCTAssertNotNil(ocr.pausedUntil)

        // Capture rows — one running, one paused
        XCTAssertEqual(snap.capture[0].kind, .audio)
        XCTAssertTrue(snap.capture[0].running)
        XCTAssertNil(snap.capture[0].pausedUntil)
        XCTAssertEqual(snap.capture[1].kind, .screen)
        XCTAssertFalse(snap.capture[1].running)
        XCTAssertNotNil(snap.capture[1].pausedUntil)

        // Resources — every field
        let res = snap.resources
        XCTAssertEqual(res.cpuPercent, 142.0, accuracy: 0.001)
        XCTAssertEqual(res.rssMb, 2342)
        XCTAssertEqual(res.gpuSystemPercent ?? -1, 38.0, accuracy: 0.001)
        XCTAssertEqual(res.thermalState, .fair)
        XCTAssertFalse(res.onBattery)
        XCTAssertFalse(res.lowPower)
        XCTAssertEqual(res.processBreakdown.count, 3)
        XCTAssertEqual(res.processBreakdown[2].name, "mlx-lm.server")
        XCTAssertEqual(res.processBreakdown[2].pid, 1236)
        XCTAssertEqual(res.processBreakdown[2].cpuPercent, 78.4, accuracy: 0.001)
        XCTAssertEqual(res.processBreakdown[2].rssMb, 1498)

        // Gate state
        XCTAssertFalse(snap.processingGate.allowed)
        XCTAssertEqual(snap.processingGate.reason, .deviceActive)
        XCTAssertEqual(snap.processingGate.waitingFor, "2 min of idle")
    }

    // MARK: - Round-trip stability

    func testSnapshotRoundTrip() throws {
        let decoder = Self.makeDecoder()
        let encoder = Self.makeEncoder()

        let original = try decoder
            .decode(ActivitySnapshot.self, from: Self.fixtureSnapshotJSON.data(using: .utf8)!)
        let reEncoded = try encoder.encode(original)
        let reDecoded = try decoder.decode(ActivitySnapshot.self, from: reEncoded)

        // Hashable conformance lets us compare without writing field-by-field
        // assertions, but we keep targeted ones below for debuggability.
        XCTAssertEqual(original, reDecoded)
        XCTAssertEqual(original.kinds, reDecoded.kinds)
        XCTAssertEqual(original.capture, reDecoded.capture)
        XCTAssertEqual(original.resources, reDecoded.resources)
        XCTAssertEqual(original.processingGate, reDecoded.processingGate)
        XCTAssertEqual(original.generatedAt, reDecoded.generatedAt)
    }

    // MARK: - Optional / variant cases

    func testGpuSystemPercentMayBeNull() throws {
        // Apple Silicon with GPU sampler unavailable / non-AS hosts.
        let json = """
        {
          "cpu_percent": 8.0,
          "rss_mb": 100,
          "gpu_system_percent": null,
          "thermal_state": "nominal",
          "on_battery": true,
          "low_power": true,
          "process_breakdown": []
        }
        """
        let r = try Self.makeDecoder().decode(ResourceSample.self, from: json.data(using: .utf8)!)
        XCTAssertNil(r.gpuSystemPercent)
        XCTAssertTrue(r.onBattery)
        XCTAssertTrue(r.lowPower)
        XCTAssertEqual(r.processBreakdown.count, 0)
    }

    func testGateStateWaitingForMayBeOmitted() throws {
        // Rust serializes this with `skip_serializing_if = "Option::is_none"`,
        // so the field can be absent (not just null) on the wire.
        let json = """
        { "allowed": true, "reason": "none", "since": "2026-04-26T14:25:00.000Z" }
        """
        let g = try Self.makeDecoder().decode(GateState.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(g.allowed)
        XCTAssertEqual(g.reason, .none)
        XCTAssertNil(g.waitingFor)
    }

    func testGateStateWaitingForExplicitNullDecodes() throws {
        let json = """
        { "allowed": true, "reason": "none", "since": "2026-04-26T14:25:00.000Z", "waiting_for": null }
        """
        let g = try Self.makeDecoder().decode(GateState.self, from: json.data(using: .utf8)!)
        XCTAssertNil(g.waitingFor)
    }

    func testEmptyInFlightMapAndQueuedZero() throws {
        // The "Up to date" UX state from the plan §UX scenario 5.
        let json = """
        {
          "kind": "summarize",
          "in_flight": null,
          "queued": 0,
          "failed": 0,
          "last_done_at": null,
          "paused_until": null
        }
        """
        let row = try Self.makeDecoder().decode(KindRow.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(row.kind, .summarize)
        XCTAssertNil(row.inFlight)
        XCTAssertEqual(row.queued, 0)
    }

    // MARK: - Enum coverage (every wire value)

    func testGateReasonEveryEnumValueDecodes() throws {
        let cases: [(String, GateReason)] = [
            ("idle",          .idle),
            ("device_active", .deviceActive),
            ("on_battery",    .onBattery),
            ("thermal",       .thermal),
            ("locked",        .locked),
            ("manual_pause",  .manualPause),
            ("none",          .none),
        ]
        for (wire, expected) in cases {
            let json = """
            { "allowed": false, "reason": "\(wire)", "since": "2026-04-26T14:25:00.000Z" }
            """
            let g = try Self.makeDecoder().decode(GateState.self, from: json.data(using: .utf8)!)
            XCTAssertEqual(g.reason, expected, "wire value \(wire) should decode to \(expected)")
        }
    }

    func testWorkKindEveryEnumValueRoundTrips() throws {
        let cases: [(String, WorkKind)] = [
            ("transcribe",            .transcribe),
            ("ocr",                   .ocr),
            ("summarize",             .summarize),
            ("extract_memory",        .extractMemory),
            ("extract_action_items",  .extractActionItems),
        ]
        for (wire, expected) in cases {
            let json = """
            { "kind": "\(wire)", "in_flight": null, "queued": 0, "failed": 0,
              "last_done_at": null, "paused_until": null }
            """
            let row = try Self.makeDecoder().decode(KindRow.self, from: json.data(using: .utf8)!)
            XCTAssertEqual(row.kind, expected)

            // Encode back — wire representation must match the snake_case input.
            let encoded = try Self.makeEncoder().encode(row)
            let str = String(data: encoded, encoding: .utf8) ?? ""
            XCTAssertTrue(str.contains("\"\(wire)\""),
                          "encoded form should contain \"\(wire)\"; got: \(str)")
        }
    }

    func testCaptureKindEveryEnumValueRoundTrips() throws {
        for (wire, expected) in [("audio", CaptureKind.audio), ("screen", .screen)] {
            let json = """
            { "kind": "\(wire)", "running": true, "paused_until": null }
            """
            let row = try Self.makeDecoder().decode(CaptureRow.self, from: json.data(using: .utf8)!)
            XCTAssertEqual(row.kind, expected)
        }
    }

    func testThermalStateEveryEnumValueDecodes() throws {
        let cases: [(String, ThermalState)] = [
            ("nominal",  .nominal),
            ("fair",     .fair),
            ("serious",  .serious),
            ("critical", .critical),
        ]
        for (wire, expected) in cases {
            let json = """
            { "cpu_percent": 0, "rss_mb": 0, "gpu_system_percent": null,
              "thermal_state": "\(wire)", "on_battery": false, "low_power": false,
              "process_breakdown": [] }
            """
            let r = try Self.makeDecoder().decode(ResourceSample.self, from: json.data(using: .utf8)!)
            XCTAssertEqual(r.thermalState, expected)
        }
    }

    // Issue #34: `PauseTargetId` is a typed sum — every legal combination
    // round-trips, every illegal combination fails to decode.

    func testPauseTargetIdEveryKindRoundTrips() throws {
        let cases: [(String, WorkKind)] = [
            ("transcribe",            .transcribe),
            ("ocr",                   .ocr),
            ("summarize",             .summarize),
            ("extract_memory",        .extractMemory),
            ("extract_action_items",  .extractActionItems),
        ]
        for (wireId, expected) in cases {
            let json = """
            { "target": "kind", "id": "\(wireId)", "minutes": 15 }
            """
            let req = try Self.makeDecoder()
                .decode(PauseRequest.self, from: json.data(using: .utf8)!)
            XCTAssertEqual(req.target, .kind(expected))
            XCTAssertEqual(req.minutes, 15)

            // Re-encoded body must round-trip through the same wire shape.
            let data = try Self.makeEncoder().encode(req)
            let s = String(data: data, encoding: .utf8) ?? ""
            XCTAssertTrue(s.contains("\"target\":\"kind\""), "got: \(s)")
            XCTAssertTrue(s.contains("\"id\":\"\(wireId)\""), "got: \(s)")
            XCTAssertTrue(s.contains("\"minutes\":15"), "got: \(s)")
        }
    }

    func testPauseTargetIdEveryCaptureRoundTrips() throws {
        for (wireId, expected) in [("audio", CaptureKind.audio), ("screen", .screen)] {
            let json = """
            { "target": "capture", "id": "\(wireId)", "minutes": 5 }
            """
            let req = try Self.makeDecoder()
                .decode(PauseRequest.self, from: json.data(using: .utf8)!)
            XCTAssertEqual(req.target, .capture(expected))

            let data = try Self.makeEncoder().encode(req)
            let s = String(data: data, encoding: .utf8) ?? ""
            XCTAssertTrue(s.contains("\"target\":\"capture\""), "got: \(s)")
            XCTAssertTrue(s.contains("\"id\":\"\(wireId)\""), "got: \(s)")
        }
    }

    func testPauseRequestRejectsKindWithCaptureId() {
        // `kind`+`"audio"` is unrepresentable — WorkKind has no `audio`.
        let json = """
        { "target": "kind", "id": "audio", "minutes": 5 }
        """
        XCTAssertThrowsError(
            try Self.makeDecoder().decode(PauseRequest.self, from: json.data(using: .utf8)!)
        )
    }

    func testPauseRequestRejectsCaptureWithKindId() {
        let json = """
        { "target": "capture", "id": "ocr", "minutes": 5 }
        """
        XCTAssertThrowsError(
            try Self.makeDecoder().decode(PauseRequest.self, from: json.data(using: .utf8)!)
        )
    }

    func testPauseRequestRejectsUnknownTarget() {
        let json = """
        { "target": "nope", "id": "ocr", "minutes": 5 }
        """
        XCTAssertThrowsError(
            try Self.makeDecoder().decode(PauseRequest.self, from: json.data(using: .utf8)!)
        )
    }

    func testPauseRequestRejectsZeroMinutesInDecode() {
        // Mirrors Rust's `NonZeroU32` reject at the deserialize layer.
        let json = """
        { "target": "kind", "id": "ocr", "minutes": 0 }
        """
        XCTAssertThrowsError(
            try Self.makeDecoder().decode(PauseRequest.self, from: json.data(using: .utf8)!)
        )
    }

    func testPauseRequestInitThrowsForZeroMinutes() {
        XCTAssertThrowsError(try PauseRequest(target: .kind(.ocr), minutes: 0)) { err in
            XCTAssertEqual(err as? PauseRequestError, .zeroMinutes)
        }
    }

    // MARK: - Request bodies serialise to wire shape Stream A expects

    func testPauseRequestEncodesSnakeCase() throws {
        let req = try PauseRequest(target: .kind(.ocr), minutes: 15)
        let data = try Self.makeEncoder().encode(req)
        let str = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("\"target\":\"kind\""), "got: \(str)")
        XCTAssertTrue(str.contains("\"id\":\"ocr\""),     "got: \(str)")
        XCTAssertTrue(str.contains("\"minutes\":15"),     "got: \(str)")
    }

    func testResumeRequestEncodesSnakeCase() throws {
        let req = ResumeRequest(target: .capture(.audio))
        let data = try Self.makeEncoder().encode(req)
        let str = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("\"target\":\"capture\""), "got: \(str)")
        XCTAssertTrue(str.contains("\"id\":\"audio\""),       "got: \(str)")
    }

    func testResumeRequestRoundTripsForEveryVariant() throws {
        let kindCases: [(String, WorkKind)] = [
            ("transcribe", .transcribe),
            ("ocr", .ocr),
            ("summarize", .summarize),
            ("extract_memory", .extractMemory),
            ("extract_action_items", .extractActionItems),
        ]
        for (wireId, kind) in kindCases {
            let json = """
            { "target": "kind", "id": "\(wireId)" }
            """
            let req = try Self.makeDecoder()
                .decode(ResumeRequest.self, from: json.data(using: .utf8)!)
            XCTAssertEqual(req.target, .kind(kind))
        }
        for (wireId, cap) in [("audio", CaptureKind.audio), ("screen", .screen)] {
            let json = """
            { "target": "capture", "id": "\(wireId)" }
            """
            let req = try Self.makeDecoder()
                .decode(ResumeRequest.self, from: json.data(using: .utf8)!)
            XCTAssertEqual(req.target, .capture(cap))
        }
    }

    func testInflightUpdateEncodesNullClearing() throws {
        // NOTE: Swift's default JSONEncoder OMITS nil optionals rather than
        // emitting `"in_flight":null`. The Rust receiver in Stream A uses
        // `serde::Deserialize` on `in_flight: Option<InFlight>`, which treats
        // an absent field as `None` — so omission and `null` are wire-equivalent.
        // We assert Swift's actual behaviour here so a future encoder swap
        // (e.g. to one that emits explicit nulls) is a deliberate change with
        // a failing test as the heads-up.
        let cleared = InflightUpdate(kind: .transcribe, inFlight: nil)
        let data = try Self.makeEncoder().encode(cleared)
        let str = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("\"kind\":\"transcribe\""), "got: \(str)")
        // Either omitted (Swift default) or explicit null is acceptable.
        let omitted = !str.contains("\"in_flight\"")
        let explicitNull = str.contains("\"in_flight\":null")
        XCTAssertTrue(omitted || explicitNull,
                      "expected `in_flight` omitted or null; got: \(str)")

        // Round-trip: the receiver must decode this back to nil.
        let decoded = try Self.makeDecoder().decode(InflightUpdate.self, from: data)
        XCTAssertEqual(decoded.kind, .transcribe)
        XCTAssertNil(decoded.inFlight)
    }

    func testInflightUpdateEncodesPopulated() throws {
        let date = Self.isoFractional.date(from: "2026-04-26T14:22:03.812Z")!
        let upd = InflightUpdate(
            kind: .transcribe,
            inFlight: InFlight(label: "Transcribing 14:22:01→14:25:00 (en)", startedAt: date)
        )
        let data = try Self.makeEncoder().encode(upd)
        let str = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("\"kind\":\"transcribe\""))
        // CodingKeys map startedAt → "started_at" and inFlight → "in_flight".
        XCTAssertTrue(str.contains("\"in_flight\""), "got: \(str)")
        XCTAssertTrue(str.contains("\"started_at\""), "got: \(str)")
        XCTAssertTrue(str.contains("\"label\":\"Transcribing 14:22:01→14:25:00 (en)\""),
                      "got: \(str)")
    }

    // MARK: - Notification & defaults constants are stable

    func testNotificationNameMatchesContract() {
        // contract.md pins this string; G/H rely on it cross-stream.
        XCTAssertEqual(ActivityNotifications.pauseChanged.rawValue, "activityPauseChanged")
    }

    func testDefaultsKeyMatchesContract() {
        XCTAssertEqual(ActivityDefaultsKeys.lastGateStateJSON, "activity.lastGateStateJSON")
    }
}
