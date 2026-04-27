import Foundation

/// Typed enum for the `memories.kg_extraction_status` column.
///
/// Lane C originally used string literals (`"succeeded"`, `"empty"`, `"failed"`)
/// at every call site. Consensus review found the stringly-typed contract
/// fragile — a typo at any site would silently fall through to "no row counted
/// as processed", and the SQL filters in `KGProgressPublisher` /
/// `KGBackfillService` would diverge from the writer without any compiler help.
///
/// All writers now go through this enum; SQL filters use the enum's `rawValue`.
/// `pending` is reserved for future use (currently writers only ever land on
/// the three terminal states), but enumerating it here keeps the contract
/// closed.
enum KGExtractionStatus: String, Sendable, CaseIterable {
    case pending
    case succeeded
    case empty
    case failed
}
