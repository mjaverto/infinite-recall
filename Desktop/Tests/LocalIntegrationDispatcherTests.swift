import XCTest
import GRDB
@testable import Omi_Computer

/// Tests for `LocalIntegrationDispatcher.enqueueDispatch(memory:)`.
///
/// The dispatcher is a singleton that depends on the singletons
/// `LocalIntegrationStorage.shared`, `LocalIntegrationOutboxStorage.shared`,
/// `APIClient.shared`, and `LocalIntegrationDrainService.shared`. There is
/// no DI seam, so we follow the existing convention used by
/// `KnowledgeGraphStorageTests` and `PendingWorkStorageDelegateTests`:
/// drive the real storage actors against the real `RewindDatabase.shared`,
/// isolate per-test by creating uniquely-named integrations and cleaning
/// them (plus their outbox rows) up in `tearDown`.
///
/// Invariant: this suite temporarily disables user-owned integrations
/// during `setUp` and restores them in `tearDown` to prevent test memories
/// from being delivered to real filesystem/webhook destinations. Without
/// this guard, a real enabled filesystem integration (e.g. one writing to
/// the user's Obsidian/Google-Drive folder) would receive an outbox row
/// for every fan-out test memory and the drain service would render it
/// to disk before tearDown could intervene.
///
/// Scope: `enqueueDispatch(memory:)` only.
///
/// We deliberately skip `enqueueDispatch(conversationId:)` because that
/// path resolves the conversation via `APIClient.shared.getConversation(id:)`
/// — a real HTTP request to the local Rust backend — and there is no
/// DI/stub seam for the API client. Black-box integration testing of that
/// path would require a server fixture, which is out of scope for this
/// dispatcher unit. Coverage of the API client itself lives in
/// `APIClientRoutingTests`.
final class LocalIntegrationDispatcherTests: XCTestCase {

    /// Track every integration this test class creates so we can purge them
    /// (and their outbox rows) in tearDown — no matter which assertion fired.
    private var createdIntegrationIds: [String] = []

    /// Snapshot of user-owned integrations that were enabled at setUp time.
    /// We disable them for the duration of the suite so the dispatcher's
    /// fan-out doesn't hit real filesystem/webhook destinations, and
    /// re-enable them in tearDown.
    private var disabledUserIntegrationIds: [String] = []

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        // Real `try` — if `listEnabled()` fails we MUST NOT proceed: the
        // dispatcher fan-out below would otherwise write test memories to
        // whatever real integrations the user has enabled. Letting setUp
        // throw is correct here — XCTest marks the test failed without
        // running the body.
        let enabled = try await LocalIntegrationStorage.shared.listEnabled()
        disabledUserIntegrationIds = enabled.map { $0.id }
        for id in disabledUserIntegrationIds {
            // Breadcrumb: if the test process crashes between here and
            // tearDown's restore loop, the user has a record of which ids
            // to flip back on manually (SELECT id, enabled FROM
            // local_integrations;).
            log("LocalIntegrationDispatcherTests: setUp disabled user integration id=\(id)")
            try await LocalIntegrationStorage.shared.setEnabled(id: id, false)
        }
    }

    override func tearDown() async throws {
        // Defensive sweep: drop every outbox row that belongs to one of our
        // test integrations, then drop the integrations themselves. Other
        // tests (and prior runs of this suite) may have left rows; we only
        // touch ones we own.
        for id in createdIntegrationIds {
            try? await LocalIntegrationOutboxStorage.shared.clearAll(forIntegrationId: id)
            try? await LocalIntegrationStorage.shared.delete(id: id)
        }
        createdIntegrationIds.removeAll()

        // Restore user-owned integrations. We attempt every id even if some
        // fail, then XCTFail loudly with the collected errors so the user
        // notices and fixes the sqlite state instead of silently losing
        // exports. Each call is in do/catch (not `try?`) so we capture the
        // actual error.
        var restoreFailures: [(id: String, error: Error)] = []
        for id in disabledUserIntegrationIds {
            do {
                try await LocalIntegrationStorage.shared.setEnabled(id: id, true)
            } catch {
                restoreFailures.append((id: id, error: error))
            }
        }
        disabledUserIntegrationIds.removeAll()

        if !restoreFailures.isEmpty {
            XCTFail(
                "Failed to re-enable user integrations: \(restoreFailures). " +
                "Manually verify with: SELECT id, enabled FROM local_integrations;"
            )
        }

        try await super.tearDown()
    }

    /// Belt-and-suspenders sweep called inside each fan-out test method
    /// after `enqueueDispatch` returns but before assertions: count any
    /// outbox rows that snuck in for the snapshotted user integrations
    /// during the async window between setUp's disable and the dispatcher
    /// reading `listEnabled()`, ASSERT the count is zero (the disable
    /// must have propagated), then still clear so we don't leave rows for
    /// the next test.
    ///
    /// `LocalIntegrationOutboxStorage.clearAll(forIntegrationId:)` returns
    /// `Void`, so we cannot get a cleared-row count from it. Per the
    /// no-production-signature-changes constraint we read the count via
    /// the existing `outboxRows(forIntegrationId:)` helper before clearing.
    private func sweepUserIntegrationOutbox() async throws {
        for id in disabledUserIntegrationIds {
            let preCount = try await outboxRows(forIntegrationId: id).count
            XCTAssertEqual(
                preCount, 0,
                "Sweep would clear \(preCount) rows for id=\(id) — disable did not propagate before dispatcher read listEnabled()"
            )
            // Cleanup so we don't leak rows into later tests even if the
            // assertion above fired.
            try await LocalIntegrationOutboxStorage.shared.clearAll(forIntegrationId: id)
        }
    }

    // MARK: - Helpers

    /// Insert a webhook integration with a deliberately invalid URL so the
    /// drain service (which `kick()` may spawn) fails delivery fast and
    /// keeps the outbox row around — `markFailure` preserves the row, only
    /// touching `attempts`, `lastError`, and `nextRetryAt`. Our assertions
    /// look at `integrationId`, count, and `payloadJson`, none of which the
    /// drain mutates.
    @discardableResult
    private func createEnabledWebhook(name: String) async throws -> LocalIntegrationRecord {
        let record = LocalIntegrationRecord(
            id: "test-\(UUID().uuidString)",
            name: name,
            kind: LocalIntegrationKind.webhook.rawValue,
            enabled: true,
            // Invalid host — guaranteed-DNS-failure URL. The dispatcher does
            // not look at the URL, only the drain service does.
            webhookURL: "http://invalid-test-host.invalid/dispatcher-tests"
        )
        let inserted = try await LocalIntegrationStorage.shared.create(record)
        createdIntegrationIds.append(inserted.id)
        return inserted
    }

    /// Build a realistic Layer-2 `MemoryRecord` fixture. The ID is
    /// nil/zero — `MemoryPayload(from: MemoryRecord)` falls back to
    /// `"local_<rowid>"` form, which is stable enough for assertion.
    private func makeMemory(
        backendId: String? = nil,
        headline: String? = "Test memory headline",
        content: String = "This is the body of the test memory.",
        category: String = "system"
    ) -> MemoryRecord {
        return MemoryRecord(
            id: nil,
            backendId: backendId,
            backendSynced: false,
            content: content,
            category: category,
            tagsJson: nil,
            reviewed: false,
            manuallyAdded: false,
            source: "desktop",
            headline: headline,
            isRead: false,
            isDismissed: false,
            deleted: false,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    /// Direct GRDB query to count outbox rows for a given integration id.
    /// Used instead of `pendingCount(forIntegrationId:)` so the test owns
    /// the read explicitly and can also pull the full row when needed.
    private func outboxRows(
        forIntegrationId integrationId: String
    ) async throws -> [LocalIntegrationOutboxRecord] {
        try await RewindDatabase.shared.initialize()
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }
        return try await dbQueue.read { db in
            try LocalIntegrationOutboxRecord
                .filter(Column("integrationId") == integrationId)
                .fetchAll(db)
        }
    }

    // MARK: - Tests

    /// With zero enabled integrations, the dispatcher must be a silent no-op.
    /// We seed a DISABLED integration to prove that `listEnabled()` filters
    /// it out; without that, the test would also pass against a totally
    /// empty registry, which doesn't actually exercise the filter.
    func test_enqueueDispatch_memory_noEnabledIntegrations_writesNothing() async throws {
        // Seed one disabled integration so we know the registry isn't empty.
        let disabled = LocalIntegrationRecord(
            id: "test-\(UUID().uuidString)",
            name: "disabled fixture",
            kind: LocalIntegrationKind.webhook.rawValue,
            enabled: false,
            webhookURL: "http://invalid-test-host.invalid/disabled"
        )
        let insertedDisabled = try await LocalIntegrationStorage.shared.create(disabled)
        createdIntegrationIds.append(insertedDisabled.id)

        let memory = makeMemory(headline: "no-subscribers")
        await LocalIntegrationDispatcher.shared.enqueueDispatch(memory: memory)
        try await sweepUserIntegrationOutbox()

        // The disabled integration must have NO outbox rows. (The dispatcher
        // shouldn't have looked at it, but we assert on the row state to be
        // explicit.)
        let rows = try await outboxRows(forIntegrationId: insertedDisabled.id)
        XCTAssertEqual(
            rows.count, 0,
            "Disabled integration must not receive outbox rows"
        )
    }

    /// One enabled integration → exactly one outbox row, addressed to that
    /// integration, with a `payloadJson` that decodes back to a
    /// `MemoryPayload` matching the source record's id/title/overview.
    func test_enqueueDispatch_memory_oneEnabled_writesOneRowWithDecodablePayload() async throws {
        let integration = try await createEnabledWebhook(name: "single-enabled")

        let backendId = "backend-\(UUID().uuidString)"
        let memory = makeMemory(
            backendId: backendId,
            headline: "Quarterly planning recap",
            content: "We agreed to ship the dispatcher refactor by EOQ."
        )

        await LocalIntegrationDispatcher.shared.enqueueDispatch(memory: memory)
        try await sweepUserIntegrationOutbox()

        let rows = try await outboxRows(forIntegrationId: integration.id)
        XCTAssertEqual(rows.count, 1, "Exactly one outbox row expected")

        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.integrationId, integration.id)
        XCTAssertEqual(row.memoryId, backendId, "memoryId column tracks payload id")

        // Decode the snapshotted payload and confirm the contract fields.
        let data = try XCTUnwrap(row.payloadJson.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(MemoryPayload.self, from: data)

        XCTAssertEqual(payload.id, backendId)
        XCTAssertEqual(payload.title, "Quarterly planning recap")
        XCTAssertEqual(payload.overview, "We agreed to ship the dispatcher refactor by EOQ.")
    }

    /// Pins MemoryPayload's title-from-headline path so first-line-of-content fallback can't collapse title and overview.
    func test_focusMemoryRecord_titleAndOverviewAreDistinct() throws {
        let analysis = ScreenAnalysis(
            status: .focused,
            appOrSite: "Infinite Recall",
            description: "Infinite Recall app is open",
            message: nil
        )
        let strings = FocusAssistant.buildFocusMemoryStrings(
            analysis: analysis,
            windowTitle: "ProjectsView",
            priorState: nil
        )

        XCTAssertEqual(strings.headline, "Focused on Infinite Recall")
        XCTAssertTrue(strings.content.contains("App: Infinite Recall · Window: ProjectsView"))
        XCTAssertTrue(strings.content.contains("Transition: new session → focused"))
        XCTAssertNotEqual(strings.headline, strings.content)

        let record = MemoryRecord(
            backendSynced: false,
            content: strings.content,
            category: "system",
            tagsJson: nil,
            source: "desktop",
            sourceApp: "Infinite Recall",
            windowTitle: "ProjectsView",
            contextSummary: analysis.description,
            headline: strings.headline
        )
        let payload = MemoryPayload(from: record)

        XCTAssertEqual(payload.title, "Focused on Infinite Recall")
        XCTAssertEqual(payload.overview, strings.content)
        XCTAssertNotEqual(payload.title, payload.overview)
    }

    /// Multiple enabled integrations → exactly one outbox row per
    /// integration, all referencing the same memory id. Verifies the fan-out
    /// loop visits every enabled integration without duplicates or drops.
    func test_enqueueDispatch_memory_multipleEnabled_writesOneRowPerIntegration() async throws {
        let a = try await createEnabledWebhook(name: "fanout-A")
        let b = try await createEnabledWebhook(name: "fanout-B")
        let c = try await createEnabledWebhook(name: "fanout-C")

        let backendId = "backend-fanout-\(UUID().uuidString)"
        let memory = makeMemory(
            backendId: backendId,
            headline: "Fan-out memory",
            content: "Three integrations are listening."
        )

        await LocalIntegrationDispatcher.shared.enqueueDispatch(memory: memory)
        try await sweepUserIntegrationOutbox()

        let rowsA = try await outboxRows(forIntegrationId: a.id)
        let rowsB = try await outboxRows(forIntegrationId: b.id)
        let rowsC = try await outboxRows(forIntegrationId: c.id)

        XCTAssertEqual(rowsA.count, 1, "Integration A must receive exactly one row")
        XCTAssertEqual(rowsB.count, 1, "Integration B must receive exactly one row")
        XCTAssertEqual(rowsC.count, 1, "Integration C must receive exactly one row")

        // Every row must reference the same memory id.
        XCTAssertEqual(rowsA.first?.memoryId, backendId)
        XCTAssertEqual(rowsB.first?.memoryId, backendId)
        XCTAssertEqual(rowsC.first?.memoryId, backendId)

        // Cross-integration: NO outbox row for integration A should carry
        // integrationId B, etc. (Filtered query already guarantees this, but
        // assert the integrationId field on each fetched row to be explicit
        // in case the schema changes underfoot.)
        XCTAssertEqual(rowsA.first?.integrationId, a.id)
        XCTAssertEqual(rowsB.first?.integrationId, b.id)
        XCTAssertEqual(rowsC.first?.integrationId, c.id)
    }

    /// Mixed enabled+disabled registry: only the enabled rows receive
    /// outbox rows. Belt-and-suspenders for the `listEnabled()` filter, run
    /// alongside the fan-out path so a regression that broke either filter
    /// or fan-out would still be caught.
    func test_enqueueDispatch_memory_mixedEnabledDisabled_onlyEnabledReceiveRows() async throws {
        let enabled = try await createEnabledWebhook(name: "mixed-enabled")

        let disabled = LocalIntegrationRecord(
            id: "test-\(UUID().uuidString)",
            name: "mixed-disabled",
            kind: LocalIntegrationKind.webhook.rawValue,
            enabled: false,
            webhookURL: "http://invalid-test-host.invalid/mixed-disabled"
        )
        let insertedDisabled = try await LocalIntegrationStorage.shared.create(disabled)
        createdIntegrationIds.append(insertedDisabled.id)

        let memory = makeMemory(
            backendId: "backend-\(UUID().uuidString)",
            headline: "mixed test"
        )
        await LocalIntegrationDispatcher.shared.enqueueDispatch(memory: memory)
        try await sweepUserIntegrationOutbox()

        let enabledRows = try await outboxRows(forIntegrationId: enabled.id)
        let disabledRows = try await outboxRows(forIntegrationId: insertedDisabled.id)

        XCTAssertEqual(enabledRows.count, 1, "Enabled integration receives the row")
        XCTAssertEqual(disabledRows.count, 0, "Disabled integration receives nothing")
    }

    /// Pin the `backendId == nil` fallback branch of
    /// `MemoryPayload(from: MemoryRecord)`. With an explicit `id: 42` and no
    /// backendId, the outbox row's `memoryId` MUST be `"local_42"` —
    /// underscore, matching `MemoryRecord.toServerMemory()`. A regression
    /// that flipped this back to a hyphen (`"local-42"`) would break any
    /// future dedup that joins outbox `memoryId` against the canonical
    /// memory id, and silently confuse log correlation today. This test
    /// exists so that flip can never happen quietly.
    func test_enqueueDispatch_memory_localFallback_usesUnderscoreFormat() async throws {
        let integration = try await createEnabledWebhook(name: "local-fallback")

        // Explicit rowid, no backendId — exercises the fallback branch.
        let memory = MemoryRecord(
            id: 42,
            backendId: nil,
            backendSynced: false,
            content: "Body for the local-fallback assertion.",
            category: "system",
            tagsJson: nil,
            reviewed: false,
            manuallyAdded: false,
            source: "desktop",
            headline: "Local fallback id test",
            isRead: false,
            isDismissed: false,
            deleted: false,
            createdAt: Date(),
            updatedAt: Date()
        )

        await LocalIntegrationDispatcher.shared.enqueueDispatch(memory: memory)
        try await sweepUserIntegrationOutbox()

        let rows = try await outboxRows(forIntegrationId: integration.id)
        XCTAssertEqual(rows.count, 1, "Exactly one outbox row expected")

        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(
            row.memoryId, "local_42",
            "Fallback id MUST use underscore to match toServerMemory()"
        )

        // Belt-and-suspenders: the snapshotted payload's id field also has
        // to carry the underscore form, since downstream readers decode it.
        let data = try XCTUnwrap(row.payloadJson.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(MemoryPayload.self, from: data)
        XCTAssertEqual(payload.id, "local_42")
    }
}
