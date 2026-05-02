import XCTest
@testable import Omi_Computer

/// Tests for `LegacyUserDirMigrator`, the one-time auth-strip migration that
/// copies the user's pre-strip Firebase-UID directory into
/// `users/anonymous/` on launch.
///
/// All tests inject a temp dir as the support root and an isolated
/// UserDefaults suite so nothing touches `~/Library` or the real defaults.
final class LegacyUserDirMigratorTests: XCTestCase {

    private var tempDir: URL!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-migrate-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defaultsSuiteName = "legacy-migrate-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        XCTAssertNotNil(defaults)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        if let defaults, let suite = defaultsSuiteName {
            defaults.removePersistentDomain(forName: suite)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Create a `users/<name>/omi.db` file with the given size in bytes.
    @discardableResult
    private func makeUserDir(_ name: String, dbSize: Int) throws -> URL {
        let dir = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("omi.db")
        let bytes = Data(count: dbSize)
        try bytes.write(to: dbURL)
        return dir
    }

    /// Same as makeUserDir but does NOT create an omi.db file.
    @discardableResult
    private func makeEmptyUserDir(_ name: String) throws -> URL {
        let dir = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func dbSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? NSNumber
        else { return -1 }
        return n.int64Value
    }

    // MARK: - Tests

    /// Zero candidates → no-op, no flag set.
    func testNoCandidates_NoOp() throws {
        // Empty users root.
        LegacyUserDirMigrator.runIfNeeded(usersRoot: tempDir, defaults: defaults)

        XCTAssertFalse(
            defaults.bool(forKey: LegacyUserDirMigrator.completedFlagKey),
            "Completion flag must NOT be set when there's nothing to migrate")
        XCTAssertFalse(
            defaults.bool(forKey: LegacyUserDirMigrator.multipleCandidatesFlagKey))

        let anonDB = tempDir.appendingPathComponent("anonymous/omi.db")
        XCTAssertFalse(FileManager.default.fileExists(atPath: anonDB.path))
    }

    /// One legacy candidate with non-empty omi.db → copied, flag set, anon
    /// has non-zero db.
    func testOneCandidate_Migrates() throws {
        let legacyName = "mpwtlyQCq9h4XWwpgVPRGOyNEgh1"
        let legacy = try makeUserDir(legacyName, dbSize: 4096)
        // Also seed a sibling file inside legacy/ to verify recursive copy.
        let videosDir = legacy.appendingPathComponent("Videos", isDirectory: true)
        try FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: videosDir.appendingPathComponent("clip.bin"))

        LegacyUserDirMigrator.runIfNeeded(usersRoot: tempDir, defaults: defaults)

        let anonDB = tempDir.appendingPathComponent("anonymous/omi.db")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: anonDB.path),
            "anonymous/omi.db should exist after migration")
        XCTAssertEqual(
            dbSize(at: anonDB), 4096,
            "anonymous/omi.db size should match the legacy db size")

        let copiedClip = tempDir.appendingPathComponent("anonymous/Videos/clip.bin")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: copiedClip.path),
            "Subdir contents should be copied recursively")

        // Original retained as safety net.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: legacy.appendingPathComponent("omi.db").path),
            "Legacy dir must be retained as safety net (copy not move)")

        XCTAssertTrue(
            defaults.bool(forKey: LegacyUserDirMigrator.completedFlagKey),
            "Completion flag must be set after a successful migration")
    }

    /// One legacy candidate but anonymous already has non-empty omi.db → no-op.
    /// The file-emptiness gate fires before candidate enumeration.
    func testAnonymousAlreadyPopulated_NoOp() throws {
        try makeUserDir("anonymous", dbSize: 8192)
        try makeUserDir("oldFirebaseUid", dbSize: 4096)

        LegacyUserDirMigrator.runIfNeeded(usersRoot: tempDir, defaults: defaults)

        let anonDB = tempDir.appendingPathComponent("anonymous/omi.db")
        XCTAssertEqual(
            dbSize(at: anonDB), 8192,
            "anonymous/omi.db must be untouched when it's already non-empty")

        XCTAssertFalse(
            defaults.bool(forKey: LegacyUserDirMigrator.completedFlagKey),
            "Flag should not be set — we did nothing")
    }

    /// Two legacy candidates → no-op, multipleCandidates flag set, anon stays empty.
    func testMultipleCandidates_RefusesAndFlags() throws {
        try makeUserDir("uidA", dbSize: 4096)
        try makeUserDir("uidB", dbSize: 4096)

        LegacyUserDirMigrator.runIfNeeded(usersRoot: tempDir, defaults: defaults)

        let anonDB = tempDir.appendingPathComponent("anonymous/omi.db")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: anonDB.path),
            "Must NOT copy when multiple candidates exist — we refuse to guess")

        XCTAssertFalse(
            defaults.bool(forKey: LegacyUserDirMigrator.completedFlagKey))
        XCTAssertTrue(
            defaults.bool(forKey: LegacyUserDirMigrator.multipleCandidatesFlagKey),
            "Multiple-candidate skip flag must be set so we don't re-log every launch")
    }

    /// Flag already completed → no-op even when conditions would otherwise match.
    func testFlagAlreadyCompleted_NoOp() throws {
        try makeUserDir("oldFirebaseUid", dbSize: 4096)
        defaults.set(true, forKey: LegacyUserDirMigrator.completedFlagKey)

        LegacyUserDirMigrator.runIfNeeded(usersRoot: tempDir, defaults: defaults)

        let anonDB = tempDir.appendingPathComponent("anonymous/omi.db")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: anonDB.path),
            "Flag gate must short-circuit migration even when a candidate exists")
    }

    // MARK: - Filter coverage

    /// Backup dirs and zero-byte dbs must NOT count as candidates. Combined
    /// with one real legacy dir, this still ends up as the single-candidate
    /// happy path.
    func testIgnoresBackupAndEmptyDBDirs() throws {
        try makeUserDir("realUid", dbSize: 4096)
        try makeUserDir("realUid.bak.123", dbSize: 4096)  // backup name -> skip
        try makeUserDir("backup-2024", dbSize: 4096)  // contains "backup" -> skip
        try makeUserDir("zeroByteUid", dbSize: 0)  // 0-byte db -> skip
        try makeEmptyUserDir("noDbAtAll")  // missing db -> skip

        LegacyUserDirMigrator.runIfNeeded(usersRoot: tempDir, defaults: defaults)

        let anonDB = tempDir.appendingPathComponent("anonymous/omi.db")
        XCTAssertEqual(
            dbSize(at: anonDB), 4096,
            "Should have migrated the single real candidate, ignoring decoys")
        XCTAssertTrue(
            defaults.bool(forKey: LegacyUserDirMigrator.completedFlagKey))
    }

    /// If `users/anonymous/` already exists empty (e.g. created earlier in
    /// launch) it must be moved aside so copyItem can succeed.
    func testEmptyAnonymousIsMovedAsideBeforeCopy() throws {
        try makeEmptyUserDir("anonymous")  // exists, but no omi.db
        try makeUserDir("oldUid", dbSize: 4096)

        LegacyUserDirMigrator.runIfNeeded(usersRoot: tempDir, defaults: defaults)

        let anonDB = tempDir.appendingPathComponent("anonymous/omi.db")
        XCTAssertEqual(
            dbSize(at: anonDB), 4096,
            "anonymous/omi.db must exist post-migration")
        XCTAssertTrue(
            defaults.bool(forKey: LegacyUserDirMigrator.completedFlagKey))

        // A backup of the empty dir should exist as anonymous.empty.bak.<ts>
        let entries =
            (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        let backups = entries.filter { $0.hasPrefix("anonymous.empty.bak.") }
        XCTAssertEqual(
            backups.count, 1,
            "Pre-existing empty anonymous/ should be renamed aside, found: \(entries)")
    }
}
