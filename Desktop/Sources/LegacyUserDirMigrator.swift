import Foundation

/// One-time migrator for the auth-strip rebuild.
///
/// Background: prior to the auth strip, user data lived under
/// `~/Library/Application Support/Omi/users/<firebase-uid>/` (e.g.
/// `mpwtlyQCq9h4XWwpgVPRGOyNEgh1`). After the strip, the userId is hardcoded
/// to the literal string `anonymous`. Without this migrator, an existing user
/// upgrades and sees an empty conversation list because the new build looks
/// at `users/anonymous/` while the historical data sits orphaned at
/// `users/<old-uid>/`.
///
/// Behavior: on launch, if `users/anonymous/omi.db` is missing or 0 bytes
/// **and** there is exactly one sibling user dir with a non-zero `omi.db`,
/// copy that sibling into `users/anonymous/`. Filesystem-only — no SQL, no
/// GRDB, no schema knowledge. GRDB runs its own pending migrations on first
/// open as it normally does.
///
/// Runs once: a UserDefaults flag (`legacyAnonymousMigrationCompleted`) gates
/// re-runs across launches even if `anonymous/` later becomes empty again
/// (e.g. user wipes data deliberately).
enum LegacyUserDirMigrator {

    static let completedFlagKey = "legacyAnonymousMigrationCompleted"
    static let multipleCandidatesFlagKey = "legacyMigrationSkipped_multipleCandidates"

    /// Default support root: `~/Library/Application Support/Omi/users/`.
    /// Mirrors the path computed inside `RewindDatabase.userBaseDirectory()`.
    static func defaultSupportRoot() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Omi", isDirectory: true)
            .appendingPathComponent("users", isDirectory: true)
    }

    /// Run the migration. Safe to call repeatedly; the flag short-circuits
    /// after a successful copy.
    ///
    /// - Parameters:
    ///   - usersRoot: Directory containing per-user folders (defaults to the
    ///     real Application Support path). Tests inject a temp dir.
    ///   - defaults: UserDefaults to read/write the completion flag against.
    ///     Tests inject an isolated suite.
    static func runIfNeeded(
        usersRoot: URL = defaultSupportRoot(),
        defaults: UserDefaults = .standard
    ) {
        // 1. Hard gate: if we already migrated, never run again.
        if defaults.bool(forKey: completedFlagKey) {
            return
        }

        let fm = FileManager.default
        let anonymousDir = usersRoot.appendingPathComponent("anonymous", isDirectory: true)
        let anonymousDB = anonymousDir.appendingPathComponent("omi.db")

        // 2. Decide if anonymous is "empty" using filesystem state only.
        //    Empty = dir doesn't exist, OR file missing, OR file is 0 bytes.
        //    Do NOT open the DB to count rows — at this point in launch
        //    GRDB hasn't run migrations yet and opening it would be racy.
        if !isEmptyDB(at: anonymousDB) {
            return
        }

        // 3. Enumerate candidate sibling directories.
        let candidates = findCandidates(in: usersRoot, fileManager: fm)

        switch candidates.count {
        case 0:
            // Fresh install or already-migrated state we can't tell apart
            // from fresh. Either way: nothing to do.
            return

        case 1:
            let source = candidates[0]
            do {
                try migrate(
                    from: source,
                    to: anonymousDir,
                    fileManager: fm
                )
                defaults.set(true, forKey: completedFlagKey)
                log(
                    "[legacy-migrate] Successfully migrated \(source.lastPathComponent) "
                        + "-> anonymous/. Original retained as safety net.")
            } catch {
                // Don't mark the flag — let the user retry on next launch.
                // Better to see no conversations than a half-copied DB.
                logError(
                    "[legacy-migrate] FAILED to copy \(source.lastPathComponent) to "
                        + "anonymous/. Manual recovery: copy the contents of "
                        + "\(source.path) into \(anonymousDir.path) and set "
                        + "UserDefaults key '\(completedFlagKey)' to true.",
                    error: error)
            }

        default:
            // Multiple candidates — refuse to guess. Set a flag so we don't
            // re-log on every launch.
            let names = candidates.map { $0.lastPathComponent }.sorted().joined(separator: ", ")
            log(
                "[legacy-migrate] Skipping migration: multiple candidate user dirs found "
                    + "(\(names)). Refusing to guess. Set "
                    + "UserDefaults key '\(completedFlagKey)' to true to suppress this "
                    + "and migrate manually.")
            defaults.set(true, forKey: multipleCandidatesFlagKey)
        }
    }

    // MARK: - Helpers

    /// `omi.db` at `path` is considered empty if it doesn't exist or is 0 bytes.
    private static func isEmptyDB(at url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return true }
        let size = fileSize(at: url)
        return size == 0
    }

    /// Returns the file size in bytes, or 0 if it can't be determined.
    private static func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? NSNumber
        else { return 0 }
        return n.int64Value
    }

    /// Finds sibling user dirs under `usersRoot` that look like real legacy
    /// data we should consider migrating. Skips:
    ///   - `anonymous` itself
    ///   - hidden dirs (start with `.`)
    ///   - backup/bak names
    ///   - dirs without an `omi.db` file
    ///   - dirs whose `omi.db` is 0 bytes
    private static func findCandidates(
        in usersRoot: URL, fileManager fm: FileManager
    ) -> [URL] {
        guard fm.fileExists(atPath: usersRoot.path) else { return [] }

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: usersRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        } catch {
            logError("[legacy-migrate] Failed to list \(usersRoot.path)", error: error)
            return []
        }

        return entries.filter { url in
            guard isDirectory(url, fileManager: fm) else { return false }
            let name = url.lastPathComponent
            if name == "anonymous" { return false }
            if name.hasPrefix(".") { return false }
            let lower = name.lowercased()
            if lower.contains(".bak") || lower.contains("backup") { return false }
            let dbURL = url.appendingPathComponent("omi.db")
            guard fm.fileExists(atPath: dbURL.path) else { return false }
            return fileSize(at: dbURL) > 0
        }
    }

    private static func isDirectory(_ url: URL, fileManager fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }

    /// Copy `source` to `destination`. If `destination` already exists (an
    /// empty `users/anonymous/` created earlier in launch by the new build),
    /// rename it aside first so `copyItem` can succeed.
    private static func migrate(
        from source: URL,
        to destination: URL,
        fileManager fm: FileManager
    ) throws {
        let dbSize = fileSize(at: source.appendingPathComponent("omi.db"))
        log(
            "[legacy-migrate] Migrating user dir: source=\(source.lastPathComponent) "
                + "omi.db size=\(dbSize) bytes")

        // If the empty anonymous dir exists, move it aside first.
        if fm.fileExists(atPath: destination.path) {
            let ts = Int(Date().timeIntervalSince1970)
            let backup = destination.deletingLastPathComponent()
                .appendingPathComponent("anonymous.empty.bak.\(ts)", isDirectory: true)
            try fm.moveItem(at: destination, to: backup)
            log("[legacy-migrate] Moved pre-existing empty anonymous/ to \(backup.lastPathComponent)")
        }

        // Copy (not move) — keep the original intact as a safety net.
        try fm.copyItem(at: source, to: destination)
    }
}
