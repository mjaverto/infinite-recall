import XCTest
@testable import Omi_Computer

/// Regression tests for #125 — `MemoryAssistantSettings.minConfidence` and
/// `extractionInterval` must honor an explicitly-persisted `0` instead of
/// silently reverting to the registered default.
///
/// `UserDefaults.double(forKey:)` returns `0` for both an absent key and an
/// explicit zero, so the previous `value > 0 ? value : default` getter
/// conflated the two cases. The fix uses `object(forKey:)` to detect
/// presence; these tests pin that invariant.
@MainActor
final class MemoryAssistantSettingsZeroPersistenceTests: XCTestCase {

    private let intervalKey = "memoryExtractionInterval"
    private let confidenceKey = "memoryMinConfidence"

    override func setUp() async throws {
        try await super.setUp()
        // Start each test from a clean slate — wipe any stale value from
        // prior runs so we can prove the round-trip is honest.
        UserDefaults.standard.removeObject(forKey: intervalKey)
        UserDefaults.standard.removeObject(forKey: confidenceKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: intervalKey)
        UserDefaults.standard.removeObject(forKey: confidenceKey)
        try await super.tearDown()
    }

    func testExtractionIntervalZeroIsHonored() {
        MemoryAssistantSettings.shared.extractionInterval = 0
        XCTAssertEqual(
            MemoryAssistantSettings.shared.extractionInterval, 0,
            "Persisting 0 must read back as 0, not the default; otherwise users " +
            "cannot opt into 'extract every frame' (issue #125)."
        )
    }

    func testMinConfidenceZeroIsHonored() {
        MemoryAssistantSettings.shared.minConfidence = 0
        XCTAssertEqual(
            MemoryAssistantSettings.shared.minConfidence, 0,
            "Persisting 0 must read back as 0, not the default; otherwise users " +
            "cannot opt into 'accept any confidence' (issue #125)."
        )
    }

    func testAbsentKeysFallBackToDefaults() {
        // No prior write -> getter must surface the documented defaults.
        XCTAssertEqual(
            MemoryAssistantSettings.shared.extractionInterval, 600.0,
            "Missing key must surface the registered 10-minute default."
        )
        XCTAssertEqual(
            MemoryAssistantSettings.shared.minConfidence, 0.7,
            "Missing key must surface the registered 0.7 default."
        )
    }

    func testNonZeroValuesRoundTrip() {
        MemoryAssistantSettings.shared.extractionInterval = 30
        MemoryAssistantSettings.shared.minConfidence = 0.5
        XCTAssertEqual(MemoryAssistantSettings.shared.extractionInterval, 30)
        XCTAssertEqual(MemoryAssistantSettings.shared.minConfidence, 0.5)
    }
}
