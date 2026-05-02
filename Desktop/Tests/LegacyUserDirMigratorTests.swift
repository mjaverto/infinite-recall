import XCTest
@testable import Omi_Computer

/// Tests for `LegacyUserDirMigrator`. All tests inject a temp dir as the
/// support root and an isolated UserDefaults suite so nothing touches
/// `~/Library` or the real defaults.
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

    @discardableResult
    private func makeUserDir(_ name: String, dbSize: Int) throws -> URL {
        let dir = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("omi.db")
        let bytes = Data(count: dbSize)
        try bytes.write(to: dbURL)
        return dir
    }

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

    private func runMigration() async -> LegacyUserDirMigrator.MigrationOutcome {
        await LegacyUserDirMigrator.runIfNeeded(usersRoot: tempDir, defaults: defaults)
    }

    // MARK: - Tests

    func testNoCandidates_NoOp() async throws {
        let outcome = await runMigration()

        XCTAssertEqual(outcome, .noop)
        XCTAssertFalse(defaults.bool(forKey: LegacyUserDirMigrator.completedFlagKey))
        XCTAssertFalse(defaults.bool(forKey: LegacyUserDirMigrator.multipleCandidatesFlagKey))

        let anonDB = tempDir.appendingPathComponent("anonymous/omi.db")
        XCTAssertFalse(FileManager.default.fileExists(atPath: anonDB.path))
    }

    func testOneCandidate_Migrates() async throws {
        let legacyName = "mpwtlyQCq9h4XWwpgVPRGOyNEgh1"
        let legacy = try makeUserDir(legacyName, dbSize: 4096)
        let videosDir = legacy.appendingPathComponent("Videos", isDirectory: true)
        try FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: videosDir.appendingPathComponent("clip.bin"))

        let outcome = await runMigration()
        XCTAssertEqual(outcome, .migrated(sourceName: legacyName))

        let anonDB = tempDir.appendingPathComponent("anonymous/omi.db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: anonDB.path))
        XCTAssertEqual(dbSize(at: anonDB), 4096)

        let copiedClip = tempDir.appendingPathComponent("anonymous/Videos/clip.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copiedClip.path))

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: legacy.appendingPathComponent("omi.db").path),
            "Legacy dir must be retained as safety net (copy not move)")

        XCTAssertTrue(defaults.bool(forKey: LegacyUserDirMigrator.completedFlagKey))
    }

    func testAnonymousAlreadyPopulated_NoOp() async throws {
        try makeUserDir("anonymous", dbSize: 8192)
        try makeUserDir("oldFirebaseUid", dbSize: 4096)

        let outcome = await runMigration()
        XCTAssertEqual(outcome, .noop)

        let anonDB = tempDir.appendingPathComponent("anonymous/omi.db")
        XCTAssertEqual(dbSize(at: anonDB), 8192)
        XCTAssertFalse(defaults.bool(forKey: LegacyUserDirMigrator.completedFlagKey))
    }

    func testMultipleCandidates_RefusesAndFlags() async throws {
        try makeUserDir("uidA", dbSize: 4096)
        try makeUserDir("uidB", dbSize: 4096)

        let outcome = await runMigration()
        if case .skippedMultipleCandidates(let names) = outcome {
            XCTAssertEqual(names.sorted(), ["uidA", "uidB"])
        } else {
            XCTFail("Expected skippedMultipleCandidates, got \(outcome)")
        }

        let anonDB = tempDir.appendingPathComponent("anonymous/omi.db")
        XCTAssertFalse(FileManager.default.fileExists(atPath: anonDB.path))

        XCTAssertFalse(defaults.bool(forKey: LegacyUserDirMigrator.completedFlagKey))
        XCTAssertTrue(defaults.bool(forKey: LegacyUserDirMigrator.multipleCandidatesFlagKey))
    }

    func testFlagAlreadyCompleted_NoOp() async throws {
        try makeUserDir("oldFirebaseUid", dbSize: 4096)
        defaults.set(true, forKey: LegacyUserDirMigrator.completedFlagKey)

        let outcome = await runMigration()
        XCTAssertEqual(outcome, .noop)

        let anonDB = tempDir.appendingPathComponent("anonymous/omi.db")
        XCTAssertFalse(FileManager.default.fileExists(atPath: anonDB.path))
    }

    // MARK: - Filter coverage

    func testIgnoresBackupAndEmptyDBDirs() async throws {
        try makeUserDir("realUid", dbSize: 4096)
        try makeUserDir("realUid.bak", dbSize: 4096)
        try makeUserDir("backup-2024", dbSize: 4096)
        try makeUserDir("zeroByteUid", dbSize: 0)
        try makeEmptyUserDir("noDbAtAll")

        let outcome = await runMigration()
        XCTAssertEqual(outcome, .migrated(sourceName: "realUid"))

        let anonDB = tempDir.appendingPathComponent("anonymous/omi.db")
        XCTAssertEqual(dbSize(at: anonDB), 4096)
        XCTAssertTrue(defaults.bool(forKey: LegacyUserDirMigrator.completedFlagKey))
    }

    func testEmptyAnonymousIsMovedAsideBeforeCopy() async throws {
        try makeEmptyUserDir("anonymous")
        try makeUserDir("oldUid", dbSize: 4096)

        let outcome = await runMigration()
        XCTAssertEqual(outcome, .migrated(sourceName: "oldUid"))

        let anonDB = tempDir.appendingPathComponent("anonymous/omi.db")
        XCTAssertEqual(dbSize(at: anonDB), 4096)
        XCTAssertTrue(defaults.bool(forKey: LegacyUserDirMigrator.completedFlagKey))

        let entries =
            (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        let backups = entries.filter { $0.hasPrefix("anonymous.empty.bak.") }
        XCTAssertEqual(backups.count, 1, "found: \(entries)")
    }

    // MARK: - Round-2 fixes

    /// `users/anonymous/omi.db` exists but is 0 bytes (matches actual prod
    /// state when GRDB pre-creates the file before migrations run).
    func testEmptyAnonymousDBFile_TriggersMigration() async throws {
        try makeUserDir("anonymous", dbSize: 0)
        try makeUserDir("oldUid", dbSize: 4096)

        let outcome = await runMigration()
        XCTAssertEqual(outcome, .migrated(sourceName: "oldUid"))

        let anonDB = tempDir.appendingPathComponent("anonymous/omi.db")
        XCTAssertEqual(dbSize(at: anonDB), 4096)
    }

    /// Inject a copy failure by chmod'ing the users root to read-only so the
    /// staging-tmp copy throws. Verify rollback: completion flag stays unset,
    /// source dir intact, no leftover tmp staging dirs.
    func testCopyFailureLeavesFlagUnset() async throws {
        let legacy = try makeUserDir("oldUid", dbSize: 4096)

        // Chmod usersRoot to read-only so writes throw EACCES.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: tempDir.path)
        defer {
            // Restore so tearDown can rm -rf cleanly.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
        }

        let outcome = await runMigration()
        if case .failed = outcome {
            // expected
        } else {
            XCTFail("Expected .failed outcome, got \(outcome)")
        }

        XCTAssertFalse(defaults.bool(forKey: LegacyUserDirMigrator.completedFlagKey))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: legacy.appendingPathComponent("omi.db").path),
            "Source legacy dir must remain intact after a failed migration")

        // Tmp staging dir must have been cleaned up.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
        let entries =
            (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        let leftoverTmp = entries.filter { $0.hasPrefix(".anonymous.tmp.") }
        XCTAssertEqual(leftoverTmp, [], "tmp dirs must be cleaned on failure")
    }

    /// Calling `runIfNeeded` twice on the same fixture: the second call must
    /// short-circuit at the completion flag without re-enumerating.
    func testIdempotentReRunAfterSuccess() async throws {
        try makeUserDir("oldUid", dbSize: 4096)

        let first = await runMigration()
        XCTAssertEqual(first, .migrated(sourceName: "oldUid"))

        // Sanity: flag is set.
        XCTAssertTrue(defaults.bool(forKey: LegacyUserDirMigrator.completedFlagKey))

        // Add a *second* candidate. If the migrator re-enumerated, it would
        // now see two candidates (the one we just migrated and a new one) and
        // either set the multi-candidate flag or pick one. A true no-op leaves
        // both flags untouched and returns .noop.
        try makeUserDir("anotherOldUid", dbSize: 4096)

        let second = await runMigration()
        XCTAssertEqual(second, .noop)
        XCTAssertFalse(
            defaults.bool(forKey: LegacyUserDirMigrator.multipleCandidatesFlagKey),
            "Second call must not re-enumerate")
    }

    /// `multipleCandidatesFlagKey` set on a prior launch must short-circuit
    /// the gate without re-enumerating.
    func testMultipleCandidatesFlagSuppressesSecondCall() async throws {
        try makeUserDir("uidA", dbSize: 4096)
        try makeUserDir("uidB", dbSize: 4096)
        defaults.set(true, forKey: LegacyUserDirMigrator.multipleCandidatesFlagKey)

        let outcome = await runMigration()
        if case .skippedMultipleCandidates(let names) = outcome {
            XCTAssertEqual(names, [], "Should short-circuit without re-enumerating")
        } else {
            XCTFail("Expected skippedMultipleCandidates, got \(outcome)")
        }

        let anonDB = tempDir.appendingPathComponent("anonymous/omi.db")
        XCTAssertFalse(FileManager.default.fileExists(atPath: anonDB.path))
    }

    /// The migrator's own backup naming `anonymous.empty.bak.<ts>` must be
    /// filtered out of candidates (anchored regex match).
    func testDecoyFilter_anonymousEmptyBakTimestamp() async throws {
        try makeUserDir("realUid", dbSize: 4096)
        try makeUserDir("anonymous.empty.bak.1777000000", dbSize: 4096)

        let outcome = await runMigration()
        XCTAssertEqual(outcome, .migrated(sourceName: "realUid"))
    }

    /// A real legacy uid that contains the literal substring "backup" must
    /// NOT be filtered (pins behavior of fix #6 anchored matching).
    func testDecoyFilter_realUidContainingBackupText() async throws {
        try makeUserDir("abc123backup456", dbSize: 4096)

        let outcome = await runMigration()
        XCTAssertEqual(outcome, .migrated(sourceName: "abc123backup456"))
    }

    /// Pre-existing non-empty `anonymous/` (no omi.db, but with other content)
    /// is moved aside and its top-level contents are logged before the move.
    func testNonEmptyNonDBContentLoggedBeforeMove() async throws {
        let anonDir = try makeEmptyUserDir("anonymous")
        let videosDir = anonDir.appendingPathComponent("Videos", isDirectory: true)
        try FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: videosDir.appendingPathComponent("clip.bin"))
        try makeUserDir("oldUid", dbSize: 4096)

        let outcome = await runMigration()
        XCTAssertEqual(outcome, .migrated(sourceName: "oldUid"))

        // Backup dir must contain the pre-existing contents (forensics).
        let entries =
            (try? FileManager.default.contentsOfDirectory(atPath: tempDir.path)) ?? []
        let backupName = entries.first { $0.hasPrefix("anonymous.empty.bak.") }
        XCTAssertNotNil(backupName, "Pre-existing anonymous/ should be moved aside")
        if let backupName {
            let backupVideos = tempDir.appendingPathComponent(backupName)
                .appendingPathComponent("Videos/clip.bin")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: backupVideos.path),
                "Pre-existing contents must be preserved in backup")
        }
    }

    /// An orphaned `.anonymous.tmp.*` from a previous interrupted run must be
    /// cleaned up at launch.
    func testInterruptedTempDirCleanedUp() async throws {
        let orphan = tempDir.appendingPathComponent(".anonymous.tmp.999.999", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: orphan.appendingPathComponent("garbage"))

        _ = await runMigration()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphan.path),
            "Orphaned tmp dir from prior run must be cleaned up")
    }

    // MARK: - Decoy filter unit coverage

    func testIsBackupName_anchoredMatching() {
        XCTAssertTrue(LegacyUserDirMigrator.isBackupName("foo.bak"))
        XCTAssertTrue(LegacyUserDirMigrator.isBackupName("anonymous.empty.bak.1777000000"))
        XCTAssertTrue(LegacyUserDirMigrator.isBackupName("backup-2024"))
        XCTAssertTrue(LegacyUserDirMigrator.isBackupName("backupOldUid"))

        XCTAssertFalse(LegacyUserDirMigrator.isBackupName("abc123backup456"))
        XCTAssertFalse(LegacyUserDirMigrator.isBackupName("foo.bakery"))
        XCTAssertFalse(LegacyUserDirMigrator.isBackupName("realUid"))
    }
}
