import Foundation
import GRDB

/// Reserved memoryId for onboarding bulk writes (saveGraph). Excluded from
/// per-memory provenance counts and UI denominators.
let ONBOARDING_SENTINEL: Int64 = -1

/// Candidate node DTO produced by the LLM extraction layer. `id` is a raw
/// slug that this storage layer canonicalizes before persistence.
struct ExtractedKGNode: Sendable, Equatable {
    let id: String
    let label: String
    let type: KnowledgeGraphNodeType
    let aliases: [String]
}

/// Candidate edge DTO produced by the LLM extraction layer. `sourceId` and
/// `targetId` reference raw node slugs that this layer canonicalizes.
struct ExtractedKGEdge: Sendable, Equatable {
    let sourceId: String
    let targetId: String
    let label: String
}

/// Result of an `upsert` call.
struct KGUpsertResult: Sendable {
    let nodesInserted: Int
    let nodesMerged: Int
    let edgesInserted: Int
}

/// Actor for local knowledge graph CRUD operations
actor KnowledgeGraphStorage {
    static let shared = KnowledgeGraphStorage()

    private var _dbQueue: DatabasePool?

    private init() {}

    private func ensureDB() async throws -> DatabasePool {
        if let db = _dbQueue { return db }

        try await RewindDatabase.shared.initialize()
        guard let db = await RewindDatabase.shared.getDatabaseQueue() else {
            throw NSError(domain: "KnowledgeGraphStorage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Database not initialized"])
        }
        _dbQueue = db
        return db
    }

    func invalidateCache() {
        _dbQueue = nil
    }

    /// Load the local knowledge graph as an API-compatible response
    func loadGraph() async -> KnowledgeGraphResponse {
        guard let db = try? await ensureDB() else {
            return KnowledgeGraphResponse(nodes: [], edges: [])
        }

        do {
            return try await db.read { database in
                let nodeRecords = try LocalKGNodeRecord.fetchAll(database)
                let edgeRecords = try LocalKGEdgeRecord.fetchAll(database)

                let nodes = nodeRecords.map { $0.toKnowledgeGraphNode() }
                let edges = edgeRecords.map { $0.toKnowledgeGraphEdge() }

                return KnowledgeGraphResponse(nodes: nodes, edges: edges)
            }
        } catch {
            log("KnowledgeGraphStorage: Failed to load graph: \(error.localizedDescription)")
            return KnowledgeGraphResponse(nodes: [], edges: [])
        }
    }

    /// Save nodes and edges (clears existing data first). Onboarding bulk
    /// write — also writes provenance rows under `ONBOARDING_SENTINEL` so
    /// these rows survive the cascade behavior of `removeProvenance`.
    func saveGraph(nodes: [LocalKGNodeRecord], edges: [LocalKGEdgeRecord]) async throws {
        let db = try await ensureDB()

        try await db.write { database in
            try database.execute(sql: "DELETE FROM local_kg_edge_sources")
            try database.execute(sql: "DELETE FROM local_kg_node_sources")
            try database.execute(sql: "DELETE FROM local_kg_edges")
            try database.execute(sql: "DELETE FROM local_kg_nodes")

            for node in nodes {
                let record = node
                try record.insert(database)
                try database.execute(
                    sql: """
                        INSERT OR IGNORE INTO local_kg_node_sources (memoryId, nodeId)
                        VALUES (?, ?)
                        """,
                    arguments: [ONBOARDING_SENTINEL, node.nodeId]
                )
            }
            for edge in edges {
                let record = edge
                try record.insert(database)
                try database.execute(
                    sql: """
                        INSERT OR IGNORE INTO local_kg_edge_sources (memoryId, edgeId)
                        VALUES (?, ?)
                        """,
                    arguments: [ONBOARDING_SENTINEL, edge.edgeId]
                )
            }
        }

        log("KnowledgeGraphStorage: Saved \(nodes.count) nodes, \(edges.count) edges")
    }

    /// Merge nodes and edges into existing data (upsert, no delete)
    func mergeGraph(nodes: [LocalKGNodeRecord], edges: [LocalKGEdgeRecord]) async throws {
        let db = try await ensureDB()

        try await db.write { database in
            for node in nodes {
                try database.execute(
                    sql: """
                        INSERT OR REPLACE INTO local_kg_nodes (nodeId, label, nodeType, aliasesJson, sourceFileIds, createdAt, updatedAt)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [node.nodeId, node.label, node.nodeType, node.aliasesJson, node.sourceFileIds, node.createdAt, node.updatedAt]
                )
            }
            for edge in edges {
                try database.execute(
                    sql: """
                        INSERT OR REPLACE INTO local_kg_edges (edgeId, sourceNodeId, targetNodeId, label, createdAt)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [edge.edgeId, edge.sourceNodeId, edge.targetNodeId, edge.label, edge.createdAt]
                )
            }
        }

        log("KnowledgeGraphStorage: Merged \(nodes.count) nodes, \(edges.count) edges")
    }

    /// Delete all local knowledge graph data, including provenance tables.
    func clearAll() async {
        guard let db = try? await ensureDB() else { return }
        do {
            try await db.write { database in
                try database.execute(sql: "DELETE FROM local_kg_edge_sources")
                try database.execute(sql: "DELETE FROM local_kg_node_sources")
                try database.execute(sql: "DELETE FROM local_kg_edges")
                try database.execute(sql: "DELETE FROM local_kg_nodes")
            }
            log("KnowledgeGraphStorage: Cleared all graph data")
        } catch {
            log("KnowledgeGraphStorage: Failed to clear graph: \(error.localizedDescription)")
        }
    }

    /// Check if the local graph has any data
    func isEmpty() async -> Bool {
        guard let db = try? await ensureDB() else { return true }

        do {
            return try await db.read { database in
                let count = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM local_kg_nodes") ?? 0
                return count == 0
            }
        } catch {
            return true
        }
    }
}

// MARK: - Provenance + atomic incremental upsert

extension KnowledgeGraphStorage {

    /// Single atomic transaction: upserts nodes, upserts edges, writes
    /// provenance rows for both. Idempotent on (memoryId, nodeId) and
    /// (memoryId, edgeId). On shared nodeId across memories, aliases are
    /// merged and the first-writer label/type wins unless an incoming
    /// alias promotes a better canonical.
    func upsert(memoryId: Int64,
                nodes: [ExtractedKGNode],
                edges: [ExtractedKGEdge]) async throws -> KGUpsertResult {
        let db = try await ensureDB()

        // Validate inputs up front so a bad row aborts before we touch the
        // database. Atomicity inside `db.write` is then simply: any throw
        // rolls back the whole thing.
        for node in nodes {
            let canonical = canonicalize(node.id)
            if canonical.isEmpty {
                throw NSError(
                    domain: "KnowledgeGraphStorage", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Empty canonical node id from \(node.id)"]
                )
            }
            if node.label.isEmpty {
                throw NSError(
                    domain: "KnowledgeGraphStorage", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Empty label for node \(node.id)"]
                )
            }
        }
        for edge in edges {
            let src = canonicalize(edge.sourceId)
            let dst = canonicalize(edge.targetId)
            if src.isEmpty || dst.isEmpty || edge.label.isEmpty {
                throw NSError(
                    domain: "KnowledgeGraphStorage", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid edge \(edge.sourceId) -> \(edge.targetId)"]
                )
            }
        }

        var nodesInserted = 0
        var nodesMerged = 0
        var edgesInserted = 0

        try await db.write { database in
            let now = Date()

            for node in nodes {
                let canonical = Self.canonicalize(node.id)
                let existing = try LocalKGNodeRecord
                    .filter(Column("nodeId") == canonical)
                    .fetchOne(database)

                if var existing = existing {
                    // Merge aliases (case-insensitive dedup, preserve order:
                    // existing first, then any new entries).
                    let existingAliases = Self.decodeAliases(existing.aliasesJson)
                    let merged = Self.mergeAliases(existing: existingAliases, incoming: node.aliases)
                    if merged != existingAliases {
                        existing.aliasesJson = Self.encodeAliases(merged)
                        existing.updatedAt = now
                        try existing.update(database)
                    }
                    nodesMerged += 1
                } else {
                    let record = LocalKGNodeRecord(
                        id: nil,
                        nodeId: canonical,
                        label: node.label,
                        nodeType: node.type.rawValue,
                        aliasesJson: Self.encodeAliases(node.aliases),
                        sourceFileIds: nil,
                        createdAt: now,
                        updatedAt: now
                    )
                    var inserting = record
                    try inserting.insert(database)
                    nodesInserted += 1
                }

                // Provenance row — idempotent on (memoryId, nodeId).
                try database.execute(
                    sql: """
                        INSERT OR IGNORE INTO local_kg_node_sources (memoryId, nodeId)
                        VALUES (?, ?)
                        """,
                    arguments: [memoryId, canonical]
                )
            }

            for edge in edges {
                let src = Self.canonicalize(edge.sourceId)
                let dst = Self.canonicalize(edge.targetId)
                let edgeId = Self.edgeId(source: src, label: edge.label, target: dst)

                let existing = try LocalKGEdgeRecord
                    .filter(Column("edgeId") == edgeId)
                    .fetchOne(database)

                if existing == nil {
                    let record = LocalKGEdgeRecord(
                        id: nil,
                        edgeId: edgeId,
                        sourceNodeId: src,
                        targetNodeId: dst,
                        label: edge.label,
                        createdAt: now
                    )
                    var inserting = record
                    try inserting.insert(database)
                    edgesInserted += 1
                }

                try database.execute(
                    sql: """
                        INSERT OR IGNORE INTO local_kg_edge_sources (memoryId, edgeId)
                        VALUES (?, ?)
                        """,
                    arguments: [memoryId, edgeId]
                )
            }
        }

        return KGUpsertResult(
            nodesInserted: nodesInserted,
            nodesMerged: nodesMerged,
            edgesInserted: edgesInserted
        )
    }

    /// Removes provenance rows for the given memory and cascades by deleting
    /// any node/edge whose only remaining provenance was this memory.
    func removeProvenance(forMemoryId memoryId: Int64) async throws {
        let db = try await ensureDB()

        try await db.write { database in
            // Snapshot the affected node/edge ids for this memory.
            let nodeIds = try String.fetchAll(
                database,
                sql: "SELECT nodeId FROM local_kg_node_sources WHERE memoryId = ?",
                arguments: [memoryId]
            )
            let edgeIds = try String.fetchAll(
                database,
                sql: "SELECT edgeId FROM local_kg_edge_sources WHERE memoryId = ?",
                arguments: [memoryId]
            )

            try database.execute(
                sql: "DELETE FROM local_kg_edge_sources WHERE memoryId = ?",
                arguments: [memoryId]
            )
            try database.execute(
                sql: "DELETE FROM local_kg_node_sources WHERE memoryId = ?",
                arguments: [memoryId]
            )

            // Cascade: delete edges with no remaining provenance.
            for edgeId in edgeIds {
                let remaining = try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM local_kg_edge_sources WHERE edgeId = ?",
                    arguments: [edgeId]
                ) ?? 0
                if remaining == 0 {
                    try database.execute(
                        sql: "DELETE FROM local_kg_edges WHERE edgeId = ?",
                        arguments: [edgeId]
                    )
                }
            }

            // Cascade: delete nodes with no remaining provenance. Note this
            // may leave dangling edges if other memories still reference the
            // same nodes via different edges; that's fine — edges have their
            // own provenance lifecycle.
            for nodeId in nodeIds {
                let remaining = try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM local_kg_node_sources WHERE nodeId = ?",
                    arguments: [nodeId]
                ) ?? 0
                if remaining == 0 {
                    try database.execute(
                        sql: "DELETE FROM local_kg_nodes WHERE nodeId = ?",
                        arguments: [nodeId]
                    )
                }
            }
        }
    }

    /// Count of distinct memoryIds in `local_kg_node_sources`, excluding the
    /// onboarding sentinel. Used by the UI as a progress denominator.
    func memoriesWithExtractedKGCount() async throws -> Int {
        let db = try await ensureDB()
        return try await db.read { database in
            try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(DISTINCT memoryId)
                    FROM local_kg_node_sources
                    WHERE memoryId != ?
                    """,
                arguments: [ONBOARDING_SENTINEL]
            ) ?? 0
        }
    }

    // MARK: - Helpers

    private func canonicalize(_ raw: String) -> String {
        Self.canonicalize(raw)
    }

    fileprivate static func canonicalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out = ""
        out.reserveCapacity(trimmed.count)
        var lastWasSep = false
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasSep = false
            } else if !out.isEmpty && !lastWasSep {
                out.append("-")
                lastWasSep = true
            }
        }
        if out.hasSuffix("-") { out.removeLast() }
        return out
    }

    fileprivate static func edgeId(source: String, label: String, target: String) -> String {
        let labelCanon = canonicalize(label)
        return "\(source)::\(labelCanon)::\(target)"
    }

    fileprivate static func decodeAliases(_ json: String?) -> [String] {
        guard let json = json,
              let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return parsed
    }

    fileprivate static func encodeAliases(_ aliases: [String]) -> String? {
        guard !aliases.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(aliases),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }

    fileprivate static func mergeAliases(existing: [String], incoming: [String]) -> [String] {
        var out: [String] = existing
        var seen = Set(existing.map { $0.lowercased() })
        for alias in incoming {
            let key = alias.lowercased()
            if !seen.contains(key) {
                out.append(alias)
                seen.insert(key)
            }
        }
        return out
    }
}
