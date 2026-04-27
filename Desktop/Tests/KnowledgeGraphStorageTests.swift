import XCTest
import GRDB
@testable import Omi_Computer

/// Tests for `KnowledgeGraphStorage`'s provenance + atomic incremental
/// upsert seam. Scoped against `KnowledgeGraphStorage.shared` and the real
/// `RewindDatabase.shared` (matches the existing storage-test convention,
/// e.g. `PendingWorkStorageDelegateTests`).
///
/// Each test claims a unique memoryId range so concurrent test runs and
/// stale rows from other test classes don't collide.
final class KnowledgeGraphStorageTests: XCTestCase {

    /// A high, distinctive base so we don't collide with any onboarding
    /// sentinel (-1) or real memory rowids inserted by other tests.
    private static let memoryIdBase: Int64 = 9_000_000

    /// Per-test unique memoryId, derived from a shared atomic counter so two
    /// methods in the same suite run never reuse the same id.
    private nonisolated(unsafe) static var counter: Int64 = 0
    private static let counterLock = NSLock()

    private func nextMemoryId() -> Int64 {
        Self.counterLock.lock(); defer { Self.counterLock.unlock() }
        Self.counter += 1
        return Self.memoryIdBase + Self.counter
    }

    /// Remove provenance for any memory ids this test created so subsequent
    /// runs (and other tests) start clean.
    private func cleanup(_ memoryIds: [Int64]) async {
        for mid in memoryIds {
            try? await KnowledgeGraphStorage.shared.removeProvenance(forMemoryId: mid)
            // Also strip the seeded `memories` row so subsequent runs of
            // these tests don't accumulate fixtures. The B3 guard rejects
            // upserts against missing/deleted rows, which is why we seed
            // one in the first place — see `seedMemoryRow`.
            try? await deleteMemoryRow(id: mid)
        }
    }

    /// Insert a minimal `memories` row at the given id so `upsert()`'s
    /// existence check (Cluster B3) passes. Uses `INSERT OR REPLACE` so a
    /// stale row from a previous run is overwritten cleanly. Mirrors the
    /// column set the migration test uses, which is known to match the
    /// live schema.
    private func seedMemoryRow(id: Int64) async throws {
        // Force the migrator to run before requesting the queue. Mirrors the
        // pattern in `test_migration_addsKGExtractionStatusColumn`.
        _ = try await KnowledgeGraphStorage.shared.memoriesWithExtractedKGCount()
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }
        let now = Date()
        try await dbQueue.write { db in
            // Drop any stale row first so we can reuse the id deterministically.
            try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id])
            try db.execute(
                sql: """
                    INSERT INTO memories (
                        id, backendId, backendSynced, content, category,
                        reviewed, manuallyAdded, isRead, isDismissed, deleted,
                        createdAt, updatedAt
                    ) VALUES (?, ?, 0, ?, 'manual', 0, 0, 0, 0, 0, ?, ?)
                """,
                arguments: [id, "fixture-\(id)", "fixture for memory \(id)", now, now]
            )
        }
    }

    private func deleteMemoryRow(id: Int64) async throws {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else { return }
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id])
        }
    }

    private func makeNode(
        id: String,
        label: String? = nil,
        type: KnowledgeGraphNodeType = .concept,
        aliases: [String] = []
    ) -> ExtractedKGNode {
        ExtractedKGNode(id: id, label: label ?? id, type: type, aliases: aliases)
    }

    private func nodeAliases(forCanonicalId nodeId: String) async throws -> [String] {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }
        return try await dbQueue.read { db in
            let json = try String.fetchOne(
                db,
                sql: "SELECT aliasesJson FROM local_kg_nodes WHERE nodeId = ?",
                arguments: [nodeId]
            )
            guard let json = json,
                  let data = json.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return parsed
        }
    }

    private func nodeExists(_ nodeId: String) async throws -> Bool {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }
        return try await dbQueue.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM local_kg_nodes WHERE nodeId = ?",
                arguments: [nodeId]
            ) ?? 0
            return count > 0
        }
    }

    private func provenanceCount(memoryId: Int64, nodeId: String) async throws -> Int {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }
        return try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM local_kg_node_sources WHERE memoryId = ? AND nodeId = ?",
                arguments: [memoryId, nodeId]
            ) ?? 0
        }
    }

    private func nodeProvenanceRowCount(memoryId: Int64) async throws -> Int {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }
        return try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM local_kg_node_sources WHERE memoryId = ?",
                arguments: [memoryId]
            ) ?? 0
        }
    }

    private func edgeProvenanceRowCount(memoryId: Int64) async throws -> Int {
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            throw XCTSkip("database queue unavailable")
        }
        return try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM local_kg_edge_sources WHERE memoryId = ?",
                arguments: [memoryId]
            ) ?? 0
        }
    }

    // MARK: - 1. Atomic: bad input rolls back the whole batch

    func test_upsert_atomic_badEdgeRollsBackEverything() async throws {
        let memoryId = nextMemoryId()
        defer { Task { await self.cleanup([memoryId]) } }
        try await seedMemoryRow(id: memoryId)

        let goodNode1 = makeNode(id: "atomic-alpha-\(memoryId)")
        let goodNode2 = makeNode(id: "atomic-beta-\(memoryId)")

        // An edge with empty target id — the seam validates inputs before
        // touching the DB and throws, so nothing should be persisted.
        let badEdge = ExtractedKGEdge(
            sourceId: goodNode1.id,
            targetId: "",
            label: "relates-to"
        )

        do {
            _ = try await KnowledgeGraphStorage.shared.upsert(
                memoryId: memoryId,
                nodes: [goodNode1, goodNode2],
                edges: [badEdge]
            )
            XCTFail("upsert should have thrown for invalid edge")
        } catch {
            // expected
        }

        let alphaExists = try await nodeExists("atomic-alpha-\(memoryId)")
        let betaExists = try await nodeExists("atomic-beta-\(memoryId)")
        XCTAssertFalse(alphaExists, "no nodes should be inserted when batch fails")
        XCTAssertFalse(betaExists, "no nodes should be inserted when batch fails")
        let provCount = try await nodeProvenanceRowCount(memoryId: memoryId)
        XCTAssertEqual(provCount, 0, "no provenance rows should be written when batch fails")
    }

    // MARK: - 2. Idempotent: same batch twice → no duplicate rows, 0 inserts on second call

    func test_upsert_idempotent_secondCallNoOps() async throws {
        let memoryId = nextMemoryId()
        defer { Task { await self.cleanup([memoryId]) } }
        try await seedMemoryRow(id: memoryId)

        let n1 = makeNode(id: "idem-one-\(memoryId)", aliases: ["alias-1"])
        let n2 = makeNode(id: "idem-two-\(memoryId)")
        let e1 = ExtractedKGEdge(sourceId: n1.id, targetId: n2.id, label: "knows")

        let first = try await KnowledgeGraphStorage.shared.upsert(
            memoryId: memoryId, nodes: [n1, n2], edges: [e1]
        )
        XCTAssertEqual(first.nodesInserted, 2)
        XCTAssertEqual(first.nodesMerged, 0)
        XCTAssertEqual(first.edgesInserted, 1)

        let second = try await KnowledgeGraphStorage.shared.upsert(
            memoryId: memoryId, nodes: [n1, n2], edges: [e1]
        )
        XCTAssertEqual(second.nodesInserted, 0, "no new nodes on second identical call")
        XCTAssertEqual(second.nodesMerged, 2, "both existing nodes merge as no-op")
        XCTAssertEqual(second.edgesInserted, 0, "no new edges on second identical call")

        let provN1 = try await provenanceCount(memoryId: memoryId, nodeId: "idem-one-\(memoryId)")
        XCTAssertEqual(provN1, 1, "no duplicate provenance rows after second call")
    }

    // MARK: - 3. Shared-node merge across memories

    func test_upsert_sharedNode_mergesAliasesAcrossMemories() async throws {
        let memA = nextMemoryId()
        let memB = nextMemoryId()
        defer { Task { await self.cleanup([memA, memB]) } }
        try await seedMemoryRow(id: memA)
        try await seedMemoryRow(id: memB)

        let sharedRaw = "shared-x-\(memA)-\(memB)"
        let nodeA = makeNode(id: sharedRaw, label: "X", aliases: ["a"])
        let nodeB = makeNode(id: sharedRaw, label: "X", aliases: ["b"])

        _ = try await KnowledgeGraphStorage.shared.upsert(
            memoryId: memA, nodes: [nodeA], edges: []
        )
        let secondResult = try await KnowledgeGraphStorage.shared.upsert(
            memoryId: memB, nodes: [nodeB], edges: []
        )
        XCTAssertEqual(secondResult.nodesInserted, 0,
                       "second memory inserts the shared node should be a merge, not insert")
        XCTAssertEqual(secondResult.nodesMerged, 1)

        // Both provenance rows must exist.
        let provA = try await provenanceCount(memoryId: memA, nodeId: sharedRaw)
        let provB = try await provenanceCount(memoryId: memB, nodeId: sharedRaw)
        XCTAssertEqual(provA, 1)
        XCTAssertEqual(provB, 1)

        // Aliases merged into a set {a, b}.
        let aliases = try await nodeAliases(forCanonicalId: sharedRaw)
        XCTAssertEqual(Set(aliases), Set(["a", "b"]),
                       "node aliases must be the union across memories")
    }

    // MARK: - 4. removeProvenance cascades selectively

    func test_removeProvenance_cascadesOnlyOrphans() async throws {
        let memA = nextMemoryId()
        let memB = nextMemoryId()
        defer { Task { await self.cleanup([memA, memB]) } }
        try await seedMemoryRow(id: memA)
        try await seedMemoryRow(id: memB)

        let sharedId = "cascade-shared-\(memA)-\(memB)"
        let aOnlyId = "cascade-aonly-\(memA)"

        _ = try await KnowledgeGraphStorage.shared.upsert(
            memoryId: memA,
            nodes: [makeNode(id: sharedId), makeNode(id: aOnlyId)],
            edges: []
        )
        _ = try await KnowledgeGraphStorage.shared.upsert(
            memoryId: memB,
            nodes: [makeNode(id: sharedId)],
            edges: []
        )

        try await KnowledgeGraphStorage.shared.removeProvenance(forMemoryId: memA)

        // memA's provenance is gone.
        let memARows = try await nodeProvenanceRowCount(memoryId: memA)
        XCTAssertEqual(memARows, 0)

        // The aOnly node had only memA as provenance → cascade-deleted.
        let aOnlyStillExists = try await nodeExists(aOnlyId)
        XCTAssertFalse(aOnlyStillExists,
                       "node referenced only by removed memory must be cascade-deleted")

        // The shared node is still referenced by memB → preserved.
        let sharedStillExists = try await nodeExists(sharedId)
        XCTAssertTrue(sharedStillExists,
                      "node still referenced by another memory must be preserved")
    }

    // MARK: - 5. memoriesWithExtractedKGCount excludes onboarding sentinel

    func test_memoriesWithExtractedKGCount_excludesOnboardingSentinel() async throws {
        let memA = nextMemoryId()
        let memB = nextMemoryId()
        defer { Task { await self.cleanup([memA, memB]) } }
        try await seedMemoryRow(id: memA)
        try await seedMemoryRow(id: memB)

        let baseline = try await KnowledgeGraphStorage.shared.memoriesWithExtractedKGCount()

        _ = try await KnowledgeGraphStorage.shared.upsert(
            memoryId: memA,
            nodes: [makeNode(id: "count-a-\(memA)")],
            edges: []
        )
        _ = try await KnowledgeGraphStorage.shared.upsert(
            memoryId: memB,
            nodes: [makeNode(id: "count-b-\(memB)")],
            edges: []
        )
        // Onboarding sentinel — must NOT count.
        _ = try await KnowledgeGraphStorage.shared.upsert(
            memoryId: ONBOARDING_SENTINEL,
            nodes: [makeNode(id: "count-onboarding-\(memA)")],
            edges: []
        )
        defer { Task { await self.cleanup([ONBOARDING_SENTINEL]) } }

        let after = try await KnowledgeGraphStorage.shared.memoriesWithExtractedKGCount()
        XCTAssertEqual(after - baseline, 2,
                       "count must increase by exactly the two non-sentinel memories")
    }

    // MARK: - 6. clearAll wipes provenance tables

    func test_clearAll_wipesProvenanceTables() async throws {
        let memoryId = nextMemoryId()
        // No defer cleanup — clearAll handles it.
        try await seedMemoryRow(id: memoryId)

        _ = try await KnowledgeGraphStorage.shared.upsert(
            memoryId: memoryId,
            nodes: [makeNode(id: "wipe-\(memoryId)")],
            edges: []
        )
        let beforeCount = try await nodeProvenanceRowCount(memoryId: memoryId)
        XCTAssertEqual(beforeCount, 1)

        await KnowledgeGraphStorage.shared.clearAll()

        let afterCount = try await nodeProvenanceRowCount(memoryId: memoryId)
        XCTAssertEqual(afterCount, 0, "clearAll must wipe local_kg_node_sources")

        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            return XCTFail("database queue unavailable")
        }
        let edgeRows = try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM local_kg_edge_sources") ?? 0
        }
        XCTAssertEqual(edgeRows, 0, "clearAll must wipe local_kg_edge_sources")
    }

    // MARK: - 7. Migration adds kg_extraction_status column (NULL for fresh row)

    func test_migration_addsKGExtractionStatusColumn() async throws {
        // Force the migrator to run by reaching the actor (which will
        // initialize RewindDatabase if not already done).
        _ = try await KnowledgeGraphStorage.shared.memoriesWithExtractedKGCount()

        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            return XCTFail("database queue unavailable")
        }

        // Verify the column exists.
        let columnExists = try await dbQueue.read { db -> Bool in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(memories)")
            return columns.contains { ($0["name"] as String?) == "kg_extraction_status" }
        }
        XCTAssertTrue(columnExists, "memories.kg_extraction_status column must exist after migration")

        // Insert a minimal memory row and confirm the new column reads as NULL.
        let now = Date()
        let probeKey = "kg-status-probe-\(UUID().uuidString)"
        let insertedId: Int64 = try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO memories (
                    backendId, backendSynced, content, category,
                    reviewed, manuallyAdded, isRead, isDismissed, deleted,
                    createdAt, updatedAt
                ) VALUES (?, 0, ?, 'manual', 0, 0, 0, 0, 0, ?, ?)
                """, arguments: [probeKey, "probe", now, now])
            return db.lastInsertedRowID
        }
        defer {
            Task {
                try? await dbQueue.write { db in
                    try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [insertedId])
                }
            }
        }

        let status: String? = try await dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT kg_extraction_status FROM memories WHERE id = ?",
                arguments: [insertedId]
            )
        }
        XCTAssertNil(status, "kg_extraction_status must default to NULL on a fresh memory row")
    }

    // MARK: - 8. Cluster B3 — upsert aborts cleanly against missing memory

    func test_upsert_abortsWhenMemoryMissing() async throws {
        // No seed — memory row never existed. Upsert must return zero
        // counts and write no provenance.
        let memoryId = nextMemoryId()
        defer { Task { await self.cleanup([memoryId]) } }

        let result = try await KnowledgeGraphStorage.shared.upsert(
            memoryId: memoryId,
            nodes: [makeNode(id: "missing-\(memoryId)")],
            edges: []
        )
        XCTAssertEqual(result.nodesInserted, 0,
                       "upsert against a missing memory must not insert nodes")
        XCTAssertEqual(result.nodesMerged, 0)
        XCTAssertEqual(result.edgesInserted, 0)

        let exists = try await nodeExists("missing-\(memoryId)")
        XCTAssertFalse(exists, "no node row should be written for a missing memory")

        let provCount = try await nodeProvenanceRowCount(memoryId: memoryId)
        XCTAssertEqual(provCount, 0, "no provenance should be written for a missing memory")
    }

    func test_upsert_abortsWhenMemorySoftDeleted() async throws {
        let memoryId = nextMemoryId()
        defer { Task { await self.cleanup([memoryId]) } }

        // Seed and immediately mark deleted = 1.
        try await seedMemoryRow(id: memoryId)
        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            return XCTFail("database queue unavailable")
        }
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE memories SET deleted = 1 WHERE id = ?",
                arguments: [memoryId]
            )
        }

        let result = try await KnowledgeGraphStorage.shared.upsert(
            memoryId: memoryId,
            nodes: [makeNode(id: "deleted-\(memoryId)")],
            edges: []
        )
        XCTAssertEqual(result.nodesInserted, 0,
                       "upsert against a soft-deleted memory must abort")
        let exists = try await nodeExists("deleted-\(memoryId)")
        XCTAssertFalse(exists, "no node row should be written for a deleted memory")
    }

    // MARK: - 9. Cluster B2 — terminalStatus written atomically with provenance

    func test_upsert_terminalStatusWrittenAtomicallyWithProvenance() async throws {
        let memoryId = nextMemoryId()
        defer { Task { await self.cleanup([memoryId]) } }
        try await seedMemoryRow(id: memoryId)

        _ = try await KnowledgeGraphStorage.shared.upsert(
            memoryId: memoryId,
            nodes: [makeNode(id: "atomic-status-\(memoryId)")],
            edges: [],
            terminalStatus: .succeeded
        )

        let provCount = try await nodeProvenanceRowCount(memoryId: memoryId)
        XCTAssertEqual(provCount, 1)

        guard let dbQueue = await RewindDatabase.shared.getDatabaseQueue() else {
            return XCTFail("database queue unavailable")
        }
        let status: String? = try await dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT kg_extraction_status FROM memories WHERE id = ?",
                arguments: [memoryId]
            )
        }
        XCTAssertEqual(status, KGExtractionStatus.succeeded.rawValue,
                       "terminalStatus must be written in the same transaction as provenance")
    }
}
