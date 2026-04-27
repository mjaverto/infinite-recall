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

    // MARK: - Lifecycle

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
        try await super.tearDown()
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
    /// `"local-<rowid>"` form, which is stable enough for assertion.
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

        let enabledRows = try await outboxRows(forIntegrationId: enabled.id)
        let disabledRows = try await outboxRows(forIntegrationId: insertedDisabled.id)

        XCTAssertEqual(enabledRows.count, 1, "Enabled integration receives the row")
        XCTAssertEqual(disabledRows.count, 0, "Disabled integration receives nothing")
    }
}
