import XCTest
@testable import Omi_Computer

/// Regression tests for the Apps cluster batch fix (issues #122, #126, #131).
///
/// - #122: APIClient.createMemory short-circuited in local-only mode and every
///   Imports / Reader / Assistant caller reported "saved=0".
/// - #126: ImportConnectorStatusStore kept Apple Notes pinned to "Connected /
///   Folder granted" after the underlying NoteStore read failed.
/// - #131: There was no Disconnect flow; UserDefaults state for connectors
///   accumulated forever.
@MainActor
final class AppsImportsRegressionTests: XCTestCase {

    // MARK: - #122: createMemory persists locally instead of throwing

    /// In the bug, `APIClient.createMemory` ran the generic `post()`
    /// short-circuit, `synthesizeEmpty()` failed because `CreateMemoryResponse`
    /// requires a non-optional `id`, and the call threw `APIError.localOnlyMode`.
    /// After the fix, the call must return a synthetic response keyed off the
    /// local row id without ever attempting a network request.
    ///
    /// Note: this test points the shared `RewindDatabase` at a unique
    /// per-test user id and invalidates the `MemoryStorage` cache so the
    /// memory write goes to a sandboxed DB and never collides with the
    /// `anonymous` DB used by sibling test suites (e.g.
    /// `LocalIntegrationDispatcherTests`).
    func testCreateMemoryPersistsLocallyInLocalOnlyMode() async throws {
        let testUserId = "test-apps-imports-122-\(UUID().uuidString)"
        await RewindDatabase.shared.configure(userId: testUserId)
        try await RewindDatabase.shared.initialize()
        await MemoryStorage.shared.invalidateCache()
        defer {
            Task { await RewindDatabase.shared.close() }
        }

        let client = APIClient.shared  // no testAuthHeader → isLocalOnlyMode == true

        let unique = "regression-122-\(UUID().uuidString)"
        let response = try await client.createMemory(
            content: unique,
            tags: ["test", "regression"],
            source: "apps_import_regression_test",
            headline: "Regression #122"
        )

        // Must come back with a non-empty synthetic id; the fork prefixes
        // local rows with "local-" so this is the contract callers can rely on.
        XCTAssertFalse(response.id.isEmpty,
                       "createMemory must return a non-empty id even in local-only mode")
        XCTAssertTrue(response.id.hasPrefix("local-"),
                      "Local-only createMemory must return a synthetic 'local-' prefixed id")
    }

    // MARK: - #126: Apple Notes connector reflects read failure

    /// In the bug, `snapshot()` returned `isConnected = true` purely because
    /// `availabilityText` was non-nil, even after a downstream read had thrown.
    /// After the fix, a latched `lastError` must flip the snapshot to a
    /// reconnect state regardless of any leftover availability/source counts.
    func testAppleNotesSnapshotReflectsLatchedError() {
        let suiteName = "AppsImportsRegressionTests.AppleNotesError-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ImportConnectorStatusStore(defaults: defaults)
        let appleNotes = ImportConnector.all.first(where: { $0.id == "apple-notes" })!

        // Seed a previously-successful sync: source count, availability text.
        store.markSynced(
            connectorID: appleNotes.id,
            sourceCount: 42,
            availabilityText: "Private notes accessible"
        )
        let healthy = store.snapshot(for: appleNotes)
        XCTAssertTrue(healthy.isConnected,
                      "Sanity check: a successful sync must render as Connected")

        // Subsequent read fails — latch the error.
        store.markFailed(
            connectorID: appleNotes.id,
            error: "NoteStore.sqlite is unreadable"
        )

        let snap = store.snapshot(for: appleNotes)
        XCTAssertFalse(snap.isConnected,
                       "A latched lastError must override stale availability text")
        XCTAssertEqual(snap.actionTitle, "Reconnect",
                       "Error state must surface a Reconnect affordance")
        XCTAssertNotNil(snap.errorMessage,
                        "Snapshot must propagate the error message to the UI")
    }

    /// A successful `markSynced` must clear any latched error from a prior
    /// failed read so the card returns to a healthy state.
    func testMarkSyncedClearsLatchedError() {
        let suiteName = "AppsImportsRegressionTests.ClearError-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ImportConnectorStatusStore(defaults: defaults)
        let appleNotes = ImportConnector.all.first(where: { $0.id == "apple-notes" })!

        store.markFailed(connectorID: appleNotes.id, error: "boom")
        XCTAssertFalse(store.snapshot(for: appleNotes).isConnected)

        store.markSynced(
            connectorID: appleNotes.id,
            sourceCount: 7,
            availabilityText: "Private notes accessible"
        )
        let snap = store.snapshot(for: appleNotes)
        XCTAssertTrue(snap.isConnected,
                      "Successful sync must clear latched error and return to Connected")
        XCTAssertNil(snap.errorMessage)
    }

    // MARK: - #131: Disconnect flow clears persisted state

    /// `clear(connectorID:)` must remove every UserDefaults key the store ever
    /// writes for the connector plus connector-specific extras. After clearing,
    /// the snapshot must look exactly like a fresh-install state.
    func testClearRemovesAllConnectorState() {
        let suiteName = "AppsImportsRegressionTests.Clear-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Seed every UserDefaults key the store ever writes for apple-notes,
        // plus the connector-specific Apple Notes folder grant.
        defaults.set(42, forKey: "appsImportConnectorSourceCount.apple-notes")
        defaults.set(7, forKey: "appsImportConnectorMemoryCount.apple-notes")
        defaults.set(Date().timeIntervalSince1970,
                     forKey: "appsImportConnectorLastSyncedAt.apple-notes")
        defaults.set(3, forKey: "appsImportConnectorLastDeltaCount.apple-notes")
        defaults.set(true, forKey: "appsImportConnectorHasLastDelta.apple-notes")
        defaults.set("/Users/test/group.com.apple.notes",
                     forKey: "onboardingAppleNotesFolderPath")

        let store = ImportConnectorStatusStore(defaults: defaults)
        let appleNotes = ImportConnector.all.first(where: { $0.id == "apple-notes" })!

        // Sanity: the store hydrated the seeded state.
        XCTAssertTrue(store.snapshot(for: appleNotes).isConnected,
                      "Sanity check: hydrated state must render as Connected")

        store.clear(connectorID: appleNotes.id)

        // All UserDefaults keys are gone.
        XCTAssertNil(defaults.object(forKey: "appsImportConnectorSourceCount.apple-notes"))
        XCTAssertNil(defaults.object(forKey: "appsImportConnectorMemoryCount.apple-notes"))
        XCTAssertNil(defaults.object(forKey: "appsImportConnectorLastSyncedAt.apple-notes"))
        XCTAssertNil(defaults.object(forKey: "appsImportConnectorLastDeltaCount.apple-notes"))
        XCTAssertNil(defaults.object(forKey: "appsImportConnectorHasLastDelta.apple-notes"))
        XCTAssertNil(defaults.object(forKey: "onboardingAppleNotesFolderPath"),
                     "clear() for apple-notes must also drop the folder grant key")

        // Snapshot reflects the fresh-install state.
        let snap = store.snapshot(for: appleNotes)
        XCTAssertFalse(snap.isConnected,
                       "After clear() the connector must not render as Connected")
        XCTAssertEqual(snap.actionTitle, "Connect",
                       "After clear() the action title must revert to Connect")
        XCTAssertNil(snap.errorMessage)
    }

    /// `clear(connectorID:)` for the manual paste connectors (chatgpt, claude)
    /// must also wipe the legacy onboarding paste-count keys, otherwise
    /// `hydrateLegacyManualImports` will resurrect "Imported during onboarding"
    /// the next time the store is constructed.
    func testClearChatGPTRemovesLegacyOnboardingCount() {
        let suiteName = "AppsImportsRegressionTests.ClearChatGPT-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(12, forKey: "onboardingChatGPTImportedMemoriesCount")

        let store = ImportConnectorStatusStore(defaults: defaults)
        let chatgpt = ImportConnector.all.first(where: { $0.id == "chatgpt" })!

        XCTAssertTrue(store.snapshot(for: chatgpt).isConnected,
                      "Legacy onboarding count must hydrate as Connected")

        store.clear(connectorID: chatgpt.id)

        XCTAssertNil(defaults.object(forKey: "onboardingChatGPTImportedMemoriesCount"))
        // Reconstruct the store to verify hydration doesn't bring it back.
        let reborn = ImportConnectorStatusStore(defaults: defaults)
        XCTAssertFalse(reborn.snapshot(for: chatgpt).isConnected,
                       "After clear() a freshly hydrated store must show Not connected")
    }
}
