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
        "mem_mb": 2342,
        "gpu_system_percent": 38.0,
        "thermal_state": "fair",
        "on_battery": false,
        "low_power": false,
        "process_breakdown": [
          { "name": "infinite-recall-api", "pid": 1234, "cpu_percent": 12.4, "mem_mb": 84 },
          { "name": "Infinite Recall",     "pid": 1235, "cpu_percent": 51.2, "mem_mb": 760 },
          { "name": "mlx-lm.server",       "pid": 1236, "cpu_percent": 78.4, "mem_mb": 1498 }
        ]
      },
      "processing_gate": {
        "state": "blocked",
        "reason": "device_active",
        "since": "2026-04-26T14:25:00.000Z",
        "waiting_for": { "type": "idle_for", "duration_secs": 120 }
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
        XCTAssertEqual(res.memMb, 2342)
        XCTAssertEqual(res.gpuSystemPercent ?? -1, 38.0, accuracy: 0.001)
        XCTAssertEqual(res.thermalState, .fair)
        XCTAssertFalse(res.onBattery)
        XCTAssertFalse(res.lowPower)
        XCTAssertEqual(res.processBreakdown.count, 3)
        XCTAssertEqual(res.processBreakdown[2].name, "mlx-lm.server")
        XCTAssertEqual(res.processBreakdown[2].pid, 1236)
        XCTAssertEqual(res.processBreakdown[2].cpuPercent, 78.4, accuracy: 0.001)
        XCTAssertEqual(res.processBreakdown[2].memMb, 1498)

        // Gate state — issue #35: `processingGate` is now a sum-type
        // mirror of Rust's `GateState`. Pattern-match and assert each
        // field of the `Blocked` variant.
        XCTAssertFalse(snap.processingGate.isAllowed)
        guard case .blocked(let reason, _, let waitingFor) = snap.processingGate else {
            return XCTFail("expected .blocked variant; got \(snap.processingGate)")
        }
        XCTAssertEqual(reason, .deviceActive)
        XCTAssertEqual(waitingFor, .idleFor(seconds: 120))
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
          "mem_mb": 100,
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

    // Issue #35: GateState is a sum type. The pre-#35 "waiting_for may
    // be omitted/null" semantics no longer apply — `Allowed` doesn't
    // carry one at all, and `Blocked` requires it. Replaced with the
    // sum-type round-trip tests below.

    func testGateStateAllowedRoundTrips() throws {
        let json = """
        { "state": "allowed", "since": "2026-04-26T14:25:00.000Z" }
        """
        let g = try Self.makeDecoder().decode(GateState.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(g.isAllowed)
        XCTAssertNil(g.blockReason)
        XCTAssertNil(g.waitingFor)

        // Re-encode → decode → equal.
        let data = try Self.makeEncoder().encode(g)
        let str = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("\"state\":\"allowed\""), "got: \(str)")
        XCTAssertFalse(str.contains("\"reason\""), "Allowed must not encode reason: \(str)")
        XCTAssertFalse(str.contains("\"waiting_for\""),
                       "Allowed must not encode waiting_for: \(str)")
        let back = try Self.makeDecoder().decode(GateState.self, from: data)
        XCTAssertEqual(back, g)
    }

    func testGateStateBlockedRoundTripsTypedWaitingFor() throws {
        let json = """
        {
          "state": "blocked",
          "reason": "device_active",
          "since": "2026-04-26T14:25:00.000Z",
          "waiting_for": { "type": "idle_for", "duration_secs": 120 }
        }
        """
        let g = try Self.makeDecoder().decode(GateState.self, from: json.data(using: .utf8)!)
        XCTAssertFalse(g.isAllowed)
        XCTAssertEqual(g.blockReason, .deviceActive)
        XCTAssertEqual(g.waitingFor, .idleFor(seconds: 120))

        let data = try Self.makeEncoder().encode(g)
        let back = try Self.makeDecoder().decode(GateState.self, from: data)
        XCTAssertEqual(back, g)
    }

    func testGateStateBlockedRequiresWaitingFor() {
        // Sum-type discipline: Blocked without waiting_for is illegal.
        let json = """
        { "state": "blocked", "reason": "device_active",
          "since": "2026-04-26T14:25:00.000Z" }
        """
        XCTAssertThrowsError(
            try Self.makeDecoder().decode(GateState.self, from: json.data(using: .utf8)!)
        )
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

    func testBlockReasonEveryEnumValueDecodes() throws {
        // Issue #35: BlockReason replaces GateReason. The pre-#35 `idle`
        // and `none` reasons are gone — they map to `Allowed` now.
        // PR #40 review: `initializing` is the placeholder reason returned
        // by Rust's `BridgedProcessingGate` during the brief boot window
        // before the first `ProcessingGateReporter` POST arrives — it MUST
        // decode + encode like every other variant so the UI can render an
        // honest "initializing" banner.
        let cases: [(String, BlockReason)] = [
            ("device_active", .deviceActive),
            ("on_battery",    .onBattery),
            ("thermal",       .thermal),
            ("locked",        .locked),
            ("manual_pause",  .manualPause),
            ("initializing",  .initializing),
        ]
        for (wire, expected) in cases {
            let json = """
            { "state": "blocked", "reason": "\(wire)",
              "since": "2026-04-26T14:25:00.000Z",
              "waiting_for": { "type": "manual" } }
            """
            let g = try Self.makeDecoder().decode(GateState.self, from: json.data(using: .utf8)!)
            XCTAssertEqual(g.blockReason, expected,
                           "wire value \(wire) should decode to \(expected)")

            // Re-encoded body must round-trip through the same wire shape.
            let data = try Self.makeEncoder().encode(g)
            let back = try Self.makeDecoder().decode(GateState.self, from: data)
            XCTAssertEqual(back.blockReason, expected,
                           "round-trip mismatch for \(wire)")
        }
    }

    func testWaitConditionEveryVariantRoundTrips() throws {
        let cases: [(String, WaitCondition)] = [
            (#"{"type":"idle_for","duration_secs":120}"#, .idleFor(seconds: 120)),
            (#"{"type":"ac_power"}"#,                     .acPower),
            (#"{"type":"thermal_cooldown"}"#,             .thermalCooldown),
            (#"{"type":"unlock"}"#,                       .unlock),
            (#"{"type":"manual"}"#,                       .manual),
        ]
        for (json, expected) in cases {
            let decoded = try Self.makeDecoder()
                .decode(WaitCondition.self, from: json.data(using: .utf8)!)
            XCTAssertEqual(decoded, expected, "decode mismatch for \(json)")
            // Re-encoded must round-trip.
            let data = try Self.makeEncoder().encode(decoded)
            let back = try Self.makeDecoder().decode(WaitCondition.self, from: data)
            XCTAssertEqual(back, expected, "round-trip mismatch for \(json)")
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
            { "cpu_percent": 0, "mem_mb": 0, "gpu_system_percent": null,
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

    // MARK: - ProcessKind decoding (forward-compat with newer daemons)

    func testProcessBreakdownDecodesLocalModelKind() throws {
        let json = """
        { "name": "mlx-lm", "pid": 1236, "cpu_percent": 78.4, "mem_mb": 1498,
          "kind": "local_model" }
        """
        let p = try Self.makeDecoder()
            .decode(ProcessBreakdown.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(p.kind, .localModel)
    }

    func testProcessBreakdownDecodesCoreKind() throws {
        let json = """
        { "name": "infinite-recall-api", "pid": 1234, "cpu_percent": 12.4, "mem_mb": 84,
          "kind": "core" }
        """
        let p = try Self.makeDecoder()
            .decode(ProcessBreakdown.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(p.kind, .core)
    }

    func testProcessBreakdownDecodesUnknownKindAsUnknown() throws {
        let json = """
        { "name": "future-proc", "pid": 9999, "cpu_percent": 1.0, "mem_mb": 10,
          "kind": "future_unknown" }
        """
        let p = try Self.makeDecoder()
            .decode(ProcessBreakdown.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(p.kind, .unknown)
    }

    func testProcessBreakdownDecodesMissingKindAsNil() throws {
        let json = """
        { "name": "infinite-recall-api", "pid": 1234, "cpu_percent": 12.4, "mem_mb": 84 }
        """
        let p = try Self.makeDecoder()
            .decode(ProcessBreakdown.self, from: json.data(using: .utf8)!)
        XCTAssertNil(p.kind)
    }
}
