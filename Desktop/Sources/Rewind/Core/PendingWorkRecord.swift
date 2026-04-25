import Foundation
import GRDB

// MARK: - Status enum

/// Valid status values for a pending_work row.
/// Stored as TEXT in SQLite for readability.
enum PendingWorkStatus: String {
    case queued   = "queued"    // Ready to be claimed
    case claimed  = "claimed"   // A worker holds a lease
    case done     = "done"      // Handler returned normally (kept 24h for debuggability)
    case failed   = "failed"    // Handler threw; will retry after scheduledFor
    case dead     = "dead"      // attempts >= maxAttempts; manual intervention only
}

// MARK: - PendingWorkRecord

/// GRDB record for the `pending_work` table.
///
/// Mirrors `ActionItemRecord` in shape: Codable + FetchableRecord + PersistableRecord.
///
/// NOTE: This is the *persistent* deferred-work queue that backs
/// `BatteryAwareScheduler`. It is NOT related to the per-assistant
/// `clearPendingWork()` methods on `FocusAssistant`, `MemoryAssistant`, and
/// `AssistantCoordinator` — those clear transient in-flight ML tasks under
/// memory pressure and live entirely in memory.
struct PendingWorkRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?

    /// Discriminator — matches `PendingWork.Kind` raw values:
    /// "transcribe", "ocr", "extractMemory", "extractActionItems", "summarize".
    /// Stored as String (not enum) for forward-compatibility with new kinds added
    /// without a schema migration.
    var workType: String

    /// Caller-supplied opaque payload (JSON today, BLOB in schema).
    /// The queue stays kind-agnostic — same contract as `PendingWork.payload`.
    var payload: Data

    /// One of: "queued", "claimed", "done", "failed", "dead".
    var status: String

    // MARK: Lease bookkeeping (nil when status != claimed)

    var claimedAt: Date?
    /// Process/worker tag, e.g. "PowerWorkBridge#<pid>"
    var claimedBy: String?
    var leaseExpiresAt: Date?

    // MARK: Retry bookkeeping

    var attempts: Int
    var maxAttempts: Int
    /// Truncated to ~2 KB at write time.
    var lastError: String?

    /// Don't claim before this timestamp. Default = createdAt (immediate).
    var scheduledFor: Date

    /// Optional natural-key for producer-side dedup.
    /// When non-nil a partial-unique index prevents duplicate active rows.
    var dedupKey: String?

    // MARK: Bookkeeping

    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "pending_work"

    // MARK: - Initialization

    init(
        id: Int64? = nil,
        workType: String,
        payload: Data,
        status: String = PendingWorkStatus.queued.rawValue,
        claimedAt: Date? = nil,
        claimedBy: String? = nil,
        leaseExpiresAt: Date? = nil,
        attempts: Int = 0,
        maxAttempts: Int = 8,
        lastError: String? = nil,
        scheduledFor: Date = Date(),
        dedupKey: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workType = workType
        self.payload = payload
        self.status = status
        self.claimedAt = claimedAt
        self.claimedBy = claimedBy
        self.leaseExpiresAt = leaseExpiresAt
        self.attempts = attempts
        self.maxAttempts = maxAttempts
        self.lastError = lastError
        self.scheduledFor = scheduledFor
        self.dedupKey = dedupKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - GRDB callback

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - Helpers

    /// Convert to the `PendingWork` value type used by `BatteryAwareScheduler`.
    func toPendingWork() -> PendingWork? {
        guard let kind = PendingWork.Kind(rawValue: workType),
              let rowId = id else { return nil }
        return PendingWork(
            id: UUID(),       // scheduler uses storage id as authoritative key
            kind: kind,
            payload: payload,
            queuedAt: createdAt,
            storageId: rowId
        )
    }
}
