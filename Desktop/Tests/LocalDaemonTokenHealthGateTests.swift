import XCTest
@testable import Omi_Computer

/// Coverage for the daemon-health gate used by
/// `ConversationSummaryBackfillService.backfillDiscardEmptyShortRecordingsOnce`.
///
/// The gate's contract: when the daemon token file is missing,
/// `LocalDaemonToken.read()` throws `TokenError.fileMissing`, which the
/// sweep treats as a transient skip (return without setting the V2 flag).
/// All other token errors are surfaced and the sweep proceeds.
///
/// Driving the full backfill function requires `RewindDatabase` to be set
/// up, which is out of scope for a unit test. Instead we pin the load-bearing
/// behavior the gate depends on: the token reader emits the right typed
/// error, and pattern-matching on `TokenError.fileMissing` works.
final class LocalDaemonTokenHealthGateTests: XCTestCase {

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
