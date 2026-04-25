import Foundation
import GRDB

/// One row of the `visual_activity` table.
///
/// Produced by `VisualActivityIndexer` for each frame that
/// `VisualActivitySampler` decides is interesting (scene change, app switch,
/// or 60s time floor). Joined back to `screenshots` via `screenshotId` so the
/// underlying frame can be loaded for re-display.
///
/// The text columns (`visualSummary`, `uiState`, `ocrTextSnapshot`,
/// `appName`, `windowTitle`) are mirrored into `visual_activity_fts` via
/// triggers — search hits there for fuzzy "what was I doing yesterday at 3pm"
/// style queries.
struct VisualActivityRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var id: Int64?

    /// FK to `screenshots.id`. Cascade-deletes when the underlying frame is
    /// pruned by the retention sweep.
    var screenshotId: Int64

    /// When the sampler captured this frame (matches the `screenshots.timestamp`
    /// for the source row, but stored locally to avoid a join on hot search paths).
    var sampledAt: Date

    var appName: String?
    var windowTitle: String?

    /// 1-2 sentence VLM description of what's happening on screen. Nil if the
    /// VLM was unreachable when this row was inserted (we still index OCR so
    /// the row isn't useless).
    var visualSummary: String?

    /// JSON blob of structured UI state (extractStructured call), or nil.
    var uiState: String?

    /// Snapshot of the OCR text at sampling time. Stored redundantly so a
    /// search query against `visual_activity_fts` doesn't need to join
    /// `ocr_texts`/`ocr_occurrences`.
    var ocrTextSnapshot: String?

    /// Hex-encoded perceptual hash (8x8 dHash, 64 bits = 16 hex chars). Used
    /// by the sampler for scene-change detection and by the indexer for
    /// near-duplicate suppression.
    var perceptualHash: String?

    var createdAt: Date

    static let databaseTableName = "visual_activity"

    init(
        id: Int64? = nil,
        screenshotId: Int64,
        sampledAt: Date,
        appName: String? = nil,
        windowTitle: String? = nil,
        visualSummary: String? = nil,
        uiState: String? = nil,
        ocrTextSnapshot: String? = nil,
        perceptualHash: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.screenshotId = screenshotId
        self.sampledAt = sampledAt
        self.appName = appName
        self.windowTitle = windowTitle
        self.visualSummary = visualSummary
        self.uiState = uiState
        self.ocrTextSnapshot = ocrTextSnapshot
        self.perceptualHash = perceptualHash
        self.createdAt = createdAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
