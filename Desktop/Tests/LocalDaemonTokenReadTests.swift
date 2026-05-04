import XCTest
@testable import Omi_Computer

/// `LocalDaemonToken.read()` semantics — file presence, empty-file detection,
/// and round-trip of a valid token.
///
/// Renamed from `LocalDaemonTokenHealthGateTests` (Reviewer 3 follow-up):
/// the previous name overstated coverage. The actual health gate inside
/// `ConversationSummaryBackfillService.backfillDiscardEmptyShortRecordingsOnce`
/// is not exercised here — driving it requires a `RewindDatabase` setup and
/// a DI seam for the token reader, neither of which exists today. What the
/// tests in this file DO pin is the typed-error contract the gate keys off
/// (`TokenError.fileMissing` vs `.empty` vs success), so a regression in
/// `LocalDaemonToken` itself can't silently break the gate.
final class LocalDaemonTokenReadTests: XCTestCase {

    private var originalEnv: String?

    override func setUp() {
        super.setUp()
        originalEnv = ProcessInfo.processInfo.environment["INFINITE_RECALL_TOKEN_PATH"]
        LocalDaemonToken.resetCache()
    }

    override func tearDown() {
        if let val = originalEnv {
            setenv("INFINITE_RECALL_TOKEN_PATH", val, 1)
        } else {
            unsetenv("INFINITE_RECALL_TOKEN_PATH")
        }
        LocalDaemonToken.resetCache()
        super.tearDown()
    }

    func testMissingTokenThrowsFileMissing() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ir-token-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let path = tmpDir.appendingPathComponent("api-token.txt").path
        setenv("INFINITE_RECALL_TOKEN_PATH", path, 1)
        LocalDaemonToken.resetCache()

        XCTAssertThrowsError(try LocalDaemonToken.read()) { err in
            // The gate keys off this exact case; any other error means the
            // gate would (correctly) fall through to the sweep.
            switch err {
            case LocalDaemonToken.TokenError.fileMissing:
                return  // expected
            default:
                XCTFail("expected .fileMissing, got: \(err)")
            }
        }
    }

    func testEmptyTokenThrowsEmptyNotFileMissing() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ir-token-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let url = tmpDir.appendingPathComponent("api-token.txt")
        try Data().write(to: url)
        setenv("INFINITE_RECALL_TOKEN_PATH", url.path, 1)
        LocalDaemonToken.resetCache()

        XCTAssertThrowsError(try LocalDaemonToken.read()) { err in
            switch err {
            case LocalDaemonToken.TokenError.empty:
                return  // expected — gate must NOT treat this as fileMissing
            case LocalDaemonToken.TokenError.fileMissing:
                XCTFail("empty file misclassified as .fileMissing — gate would skip incorrectly")
            default:
                XCTFail("unexpected error: \(err)")
            }
        }
    }

    func testValidTokenRoundTrips() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ir-token-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let url = tmpDir.appendingPathComponent("api-token.txt")
        try "alive-token-abc\n".data(using: .utf8)!.write(to: url)
        setenv("INFINITE_RECALL_TOKEN_PATH", url.path, 1)
        LocalDaemonToken.resetCache()

        let token = try LocalDaemonToken.read()
        XCTAssertEqual(token, "alive-token-abc")
    }
}
