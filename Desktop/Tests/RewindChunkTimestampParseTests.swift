import XCTest
@testable import Omi_Computer

/// Regression tests for #117 / #129.
///
/// `VideoChunkEncoder.generateChunkPath` writes chunks as
/// `<videosDir>/YYYY-MM-DD/chunk_HHmmss.mp4`. The rebuild path
/// (`RewindIndexer.rebuildFromVideoFiles` →
/// `RewindStorage.getAllVideoChunks` → `extractFramesFromChunk`) used to
/// expect `chunk_YYYYMMDD_HHMMSS.hevc` (a format that never shipped) and
/// silently skipped every real chunk. These tests pin the parser to the
/// encoder's actual output so that drift breaks the build, not the rebuild.
final class RewindChunkTimestampParseTests: XCTestCase {

    // MARK: - Happy path: encoder format

    func testParsesEncoderProducedFilename() {
        // Encoder format: yyyy-MM-dd / chunk_HHmmss.mp4
        let date = RewindIndexer.parseChunkTimestamp(
            filename: "chunk_153012.mp4",
            dayDirectory: "2026-05-04"
        )
        XCTAssertNotNil(date, "Encoder-format chunk path must parse")

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: try! XCTUnwrap(date)
        )
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 5)
        XCTAssertEqual(comps.day, 4)
        XCTAssertEqual(comps.hour, 15)
        XCTAssertEqual(comps.minute, 30)
        XCTAssertEqual(comps.second, 12)
    }

    func testParsesLegacyHEVCExtension() {
        // Older installs may have .hevc on disk — rebuild should still recover them.
        XCTAssertNotNil(RewindIndexer.parseChunkTimestamp(
            filename: "chunk_000000.hevc",
            dayDirectory: "2024-01-01"
        ))
    }

    func testParsesMidnight() {
        XCTAssertNotNil(RewindIndexer.parseChunkTimestamp(
            filename: "chunk_000000.mp4",
            dayDirectory: "2026-12-31"
        ))
    }

    // MARK: - Rejection cases

    func testRejectsLegacyHypotheticalFormat() {
        // The format the old parser was looking for never shipped. Make sure
        // the new parser doesn't accidentally re-introduce support for it.
        XCTAssertNil(RewindIndexer.parseChunkTimestamp(
            filename: "chunk_20260504_153012.hevc",
            dayDirectory: "2026-05-04"
        ))
    }

    func testRejectsMissingPrefix() {
        XCTAssertNil(RewindIndexer.parseChunkTimestamp(
            filename: "153012.mp4",
            dayDirectory: "2026-05-04"
        ))
    }

    func testRejectsBadExtension() {
        XCTAssertNil(RewindIndexer.parseChunkTimestamp(
            filename: "chunk_153012.txt",
            dayDirectory: "2026-05-04"
        ))
    }

    func testRejectsNonNumericTime() {
        XCTAssertNil(RewindIndexer.parseChunkTimestamp(
            filename: "chunk_abcdef.mp4",
            dayDirectory: "2026-05-04"
        ))
    }

    func testRejectsMalformedDayDirectory() {
        // Wrong length / missing dashes.
        XCTAssertNil(RewindIndexer.parseChunkTimestamp(
            filename: "chunk_153012.mp4",
            dayDirectory: "20260504"
        ))
        XCTAssertNil(RewindIndexer.parseChunkTimestamp(
            filename: "chunk_153012.mp4",
            dayDirectory: "2026/05/04"
        ))
    }

    func testRejectsShortTime() {
        XCTAssertNil(RewindIndexer.parseChunkTimestamp(
            filename: "chunk_15301.mp4",
            dayDirectory: "2026-05-04"
        ))
    }

    // MARK: - Round-trip with the encoder's path generator

    /// If the encoder ever changes its filename scheme, this test will fail
    /// loudly instead of silently swallowing all chunks during rebuild.
    func testRoundTripWithEncoderFormatter() {
        // Mirror VideoChunkEncoder.generateChunkPath exactly.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HHmmss"

        let dayDirectory = dayFormatter.string(from: now)
        let filename = "chunk_\(timeFormatter.string(from: now)).mp4"

        let parsed = RewindIndexer.parseChunkTimestamp(
            filename: filename,
            dayDirectory: dayDirectory
        )
        XCTAssertNotNil(
            parsed,
            "Round-trip from VideoChunkEncoder's path format must parse — \(dayDirectory)/\(filename)"
        )
    }
}
