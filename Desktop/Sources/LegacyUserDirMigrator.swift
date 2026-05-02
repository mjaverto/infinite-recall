import AppKit
import Foundation
import SwiftUI

/// One-time filesystem migrator for the auth-strip rebuild: copies a pre-strip
/// `users/<firebase-uid>/` dir into `users/anonymous/` so existing users don't
/// upgrade into an empty conversation list.
enum LegacyUserDirMigrator {

    static let completedFlagKey = "legacyAnonymousMigrationCompleted"
    static let multipleCandidatesFlagKey = "legacyMigrationSkipped_multipleCandidates"

    enum MigrationOutcome: Equatable {
        case noop
        case migrated(sourceName: String)
        case skippedMultipleCandidates(names: [String])
        case failed(reason: String)
    }

    static func defaultSupportRoot() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("Omi", isDirectory: true)
            .appendingPathComponent("users", isDirectory: true)
    }

    /// Run the migration. Safe to call repeatedly.
    ///
    /// File I/O runs on a background executor so a multi-GB copy doesn't trip
    /// the macOS launch watchdog. To retry after a multi-candidate skip the UI
    /// must clear both `multipleCandidatesFlagKey` and `completedFlagKey`.
    static func runIfNeeded(
        usersRoot: URL = defaultSupportRoot(),
        defaults: UserDefaults = .standard
    ) async -> MigrationOutcome {
        await Task.detached(priority: .userInitiated) {
            performMigration(usersRoot: usersRoot, defaults: defaults)
        }.value
    }

    static func performMigration(
        usersRoot: URL,
        defaults: UserDefaults
    ) -> MigrationOutcome {
        if defaults.bool(forKey: completedFlagKey) {
            return .noop
        }
        if defaults.bool(forKey: multipleCandidatesFlagKey) {
            return .skippedMultipleCandidates(names: [])
        }

        let fm = FileManager.default
        cleanupOrphanedTempDirs(in: usersRoot, fileManager: fm)

        let anonymousDir = usersRoot.appendingPathComponent("anonymous", isDirectory: true)
        let anonymousDB = anonymousDir.appendingPathComponent("omi.db")

        // Don't open the DB to count rows — at this point in launch GRDB
        // hasn't run migrations yet and opening it would be racy.
        if !isEmptyDB(at: anonymousDB) {
            return .noop
        }

        let candidates = findCandidates(in: usersRoot, fileManager: fm)

        switch candidates.count {
        case 0:
            return .noop

        case 1:
            let source = candidates[0]
            do {
                try migrate(from: source, to: anonymousDir, fileManager: fm)
                defaults.set(true, forKey: completedFlagKey)
                log(
                    "[legacy-migrate] Successfully migrated \(source.lastPathComponent) "
                        + "-> anonymous/. Original retained as safety net.")
                return .migrated(sourceName: source.lastPathComponent)
            } catch {
                logError(
                    "[legacy-migrate] FAILED to copy \(source.lastPathComponent) to "
                        + "anonymous/. Manual recovery: copy the contents of "
                        + "\(source.path) into \(anonymousDir.path) and set "
                        + "UserDefaults key '\(completedFlagKey)' to true.",
                    error: error)
                return .failed(reason: error.localizedDescription)
            }

        default:
            let names = candidates.map { $0.lastPathComponent }.sorted()
            let joined = names.joined(separator: ", ")
            log(
                "[legacy-migrate] Skipping migration: multiple candidate user dirs found "
                    + "(\(joined)). Refusing to guess. Set "
                    + "UserDefaults key '\(completedFlagKey)' to true to suppress this "
                    + "and migrate manually.")
            defaults.set(true, forKey: multipleCandidatesFlagKey)
            return .skippedMultipleCandidates(names: names)
        }
    }

    // MARK: - Helpers

    private static func isEmptyDB(at url: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return true }
        return fileSize(at: url) == 0
    }

    private static func fileSize(at url: URL) -> Int64 {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let n = attrs[.size] as? NSNumber else { return 0 }
            return n.int64Value
        } catch {
            logError("[legacy-migrate] could not stat \(url.path)", error: error)
            return 0
        }
    }

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
            if isBackupName(name) { return false }
            let dbURL = url.appendingPathComponent("omi.db")
            guard fm.fileExists(atPath: dbURL.path) else { return false }
            return fileSize(at: dbURL) > 0
        }
    }

    /// Anchored backup-name match: literal `.bak` suffix, timestamped `.bak.<digits>`
    /// suffix (matches our own `anonymous.empty.bak.<ts>`), or a `backup` prefix.
    /// A real legacy uid containing the substring "backup" is NOT filtered out.
    static func isBackupName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasSuffix(".bak") { return true }
        if lower.hasPrefix("backup") { return true }
        if let range = lower.range(of: #"\.bak\.\d+$"#, options: .regularExpression),
           range.upperBound == lower.endIndex
        {
            return true
        }
        return false
    }

    private static func isDirectory(_ url: URL, fileManager fm: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }

    /// Atomic copy: stage into `.anonymous.tmp.<pid>.<ts>/`, only then move
    /// any pre-existing `anonymous/` aside, then rename tmp -> final. Same-volume
    /// rename is atomic, so a power loss at any point leaves the legacy source
    /// intact and `anonymous/` either pristine-old or pristine-new.
    private static func migrate(
        from source: URL,
        to destination: URL,
        fileManager fm: FileManager
    ) throws {
        let dbSize = fileSize(at: source.appendingPathComponent("omi.db"))
        log(
            "[legacy-migrate] Migrating user dir: source=\(source.lastPathComponent) "
                + "omi.db size=\(dbSize) bytes")

        let parent = destination.deletingLastPathComponent()
        let pid = ProcessInfo.processInfo.processIdentifier
        let ts = Int(Date().timeIntervalSince1970)
        let tmpDir = parent.appendingPathComponent(
            ".anonymous.tmp.\(pid).\(ts)", isDirectory: true)

        do {
            try fm.copyItem(at: source, to: tmpDir)
        } catch {
            try? fm.removeItem(at: tmpDir)
            throw error
        }

        if fm.fileExists(atPath: destination.path) {
            logExistingAnonymousContents(destination, fileManager: fm)
            let backup = parent.appendingPathComponent(
                "anonymous.empty.bak.\(ts)", isDirectory: true)
            do {
                try fm.moveItem(at: destination, to: backup)
                log("[legacy-migrate] Moved pre-existing anonymous/ to \(backup.lastPathComponent)")
            } catch {
                try? fm.removeItem(at: tmpDir)
                throw error
            }
        }

        do {
            try fm.moveItem(at: tmpDir, to: destination)
        } catch {
            try? fm.removeItem(at: tmpDir)
            throw error
        }
    }

    /// Forensics breadcrumb: log the top-level contents (filenames + sizes,
    /// capped at 50) of an `anonymous/` we're about to move aside, so a user
    /// who later asks "where did my data go" can find it in the logs.
    private static func logExistingAnonymousContents(
        _ destination: URL, fileManager fm: FileManager
    ) {
        let cap = 50
        do {
            let entries = try fm.contentsOfDirectory(
                at: destination,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [])
            let total = entries.count
            let described = entries.prefix(cap).map { url -> String in
                let name = url.lastPathComponent
                let size = fileSize(at: url)
                return "\(name)(\(size))"
            }.joined(separator: ", ")
            let suffix = total > cap ? " ...and \(total - cap) more" : ""
            log("[legacy-migrate] Pre-existing anonymous/ contents: [\(described)]\(suffix)")
        } catch {
            logError("[legacy-migrate] Could not list pre-existing anonymous/", error: error)
        }
    }

    /// Sweep `users/.anonymous.tmp.*` left behind by a previous interrupted run.
    /// Anything matching is incomplete by definition.
    private static func cleanupOrphanedTempDirs(in usersRoot: URL, fileManager fm: FileManager) {
        guard fm.fileExists(atPath: usersRoot.path) else { return }
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: usersRoot,
                includingPropertiesForKeys: nil,
                options: [])
        } catch {
            return
        }
        for url in entries where url.lastPathComponent.hasPrefix(".anonymous.tmp.") {
            log("[legacy-migrate] Removing orphaned tmp dir: \(url.lastPathComponent)")
            try? fm.removeItem(at: url)
        }
    }
}

/// UI surface for the migrator. The launch sequence holds the main window's
/// content gated on `isReady` so the FS copy can run on a background thread
/// without tripping the macOS launch watchdog. `pendingMultiCandidateNames`
/// drives a one-time alert that nags every launch until the user resolves.
@MainActor
final class LegacyMigrationGate: ObservableObject {
    static let shared = LegacyMigrationGate()

    @Published var isReady: Bool = false
    @Published var pendingMultiCandidateNames: [String] = []

    private var continuations: [CheckedContinuation<Void, Never>] = []

    private init() {}

    func markReady(outcome: LegacyUserDirMigrator.MigrationOutcome) {
        switch outcome {
        case .skippedMultipleCandidates(let names) where !names.isEmpty:
            pendingMultiCandidateNames = names
        default:
            break
        }
        isReady = true
        let pending = continuations
        continuations.removeAll()
        for c in pending { c.resume() }
    }

    /// Suspend until migration completes. Cheap no-op once `isReady`.
    func waitUntilReady() async {
        if isReady { return }
        await withCheckedContinuation { continuation in
            if isReady {
                continuation.resume()
            } else {
                continuations.append(continuation)
            }
        }
    }

    /// On launch, surface the alert if a previous run skipped on multi-candidate.
    /// Reads UserDefaults directly so the prompt persists across launches even
    /// when the migrator short-circuits at the gate without enumerating.
    func checkPersistedMultiCandidateFlag(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: LegacyUserDirMigrator.completedFlagKey),
              defaults.bool(forKey: LegacyUserDirMigrator.multipleCandidatesFlagKey)
        else { return }
        if pendingMultiCandidateNames.isEmpty {
            pendingMultiCandidateNames = ["(see app log for paths)"]
        }
    }

    func presentAlertIfNeeded(defaults: UserDefaults = .standard) {
        guard !pendingMultiCandidateNames.isEmpty else { return }
        let names = pendingMultiCandidateNames
        let alert = NSAlert()
        alert.messageText = "Multiple legacy data folders found"
        alert.informativeText =
            "Infinite Recall found multiple legacy data folders and didn't pick one "
            + "automatically:\n\n  \(names.joined(separator: "\n  "))\n\n"
            + "Open the user data folder, keep only the one you want as 'anonymous', "
            + "then click Retry migration."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Retry migration")
        alert.addButton(withTitle: "Dismiss")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            defaults.removeObject(forKey: LegacyUserDirMigrator.completedFlagKey)
            defaults.removeObject(forKey: LegacyUserDirMigrator.multipleCandidatesFlagKey)
            pendingMultiCandidateNames = []
            log("[legacy-migrate] User clicked Retry — flags cleared, will re-run on next launch")
        }
    }
}
