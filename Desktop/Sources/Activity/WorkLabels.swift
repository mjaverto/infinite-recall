// Activity Tab — Phase 0 stub.
//
// TODO: Stream E. `humanLabel(_ work: PendingWork) -> String` — converts a
// scheduler `PendingWork` into a user-facing label like
// `"Transcribing 14:22:01→14:25:00 (en)"`. Used by Stream G when reporting
// in-flight to Rust and by the UI when rendering rows.

import Foundation

// === activity:G stub ===
// Minimal placeholder so Stream G's in-flight wrap compiles before Stream E
// lands the real label generator. Stream E MUST replace this entire
// `// === activity:G stub ===` block with the proper humanLabel implementation
// that decodes `work.payload` per kind.
public enum WorkLabels {
    public static func humanLabel(_ work: PendingWork) -> String {
        // Until Stream E lands, fall back to the kind name. The real impl
        // will return things like "Transcribing 14:22:01→14:25:00 (en)".
        return work.kind.rawValue.capitalized
    }
}
// === /activity:G stub ===
