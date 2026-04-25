// Infinite Recall fork: catalog of supported local MLX models surfaced in
// Settings → AI / Models → Local Model card.
//
// This is a static, hand-curated list. Adding a new model is a code change.
// Agent DD owns verifying the exact Hugging Face paths; the entries below
// may be re-pointed once that lands.
//
// Each entry carries enough metadata for the picker UI to show a "what does
// this cost me" line (RAM, disk, license, context window) without round-trips
// to HF.

import Foundation

/// One row in the Local Model picker.
struct LocalModelOption: Identifiable, Hashable {
  /// Hugging Face repo path. Used both as the unique id and as the value
  /// passed to `mlx_lm.server --model ...` and `snapshot_download`.
  let id: String

  /// Human-friendly short label (e.g. "Qwen3.5-9B").
  let displayName: String

  /// Short tagline shown next to the name (e.g. "Balanced (recommended)").
  let badge: String

  /// Approximate peak resident memory while serving, in GB. Used purely for
  /// display — we don't enforce it.
  let approxRamGB: Double

  /// Approximate on-disk footprint of the 4-bit weights, in GB.
  let approxDiskGB: Double

  /// SPDX-ish short license string (e.g. "Apache 2.0", "MIT").
  let license: String

  /// Maximum context window the model claims. Display only.
  let contextWindow: Int
}

/// Static registry of supported local models. Order here is the order the
/// picker renders them.
enum LocalModelCatalog {

  /// All catalog entries, in display order. Indices have no semantic
  /// meaning — always look entries up by `id`.
  static let all: [LocalModelOption] = [
    // NOTE: This catalog is for TEXT models served via mlx-lm.server.
    // Vision models (Qwen3.5-9B-MLX-4bit, Qwen3-VL-8B) require mlx-vlm
    // and run as a separate sidecar — see the Vision Model card.
    .init(
      id: "mlx-community/Qwen2.5-7B-Instruct-4bit",
      displayName: "Qwen2.5-7B",
      badge: "Balanced (recommended)",
      approxRamGB: 8,
      approxDiskGB: 4.3,
      license: "Apache 2.0",
      contextWindow: 32_768),
    .init(
      id: "mlx-community/Phi-4-mini-instruct-4bit",
      displayName: "Phi-4-mini",
      badge: "Fastest",
      approxRamGB: 5,
      approxDiskGB: 3.5,
      license: "MIT",
      contextWindow: 16_384),
    .init(
      id: "mlx-community/DeepSeek-R1-Distill-Qwen-7B-4bit",
      displayName: "DeepSeek-R1-Distill-Qwen-7B",
      badge: "Reasoning",
      approxRamGB: 6,
      approxDiskGB: 4.2,
      license: "MIT",
      contextWindow: 131_072),
    .init(
      id: "mlx-community/Qwen2.5-32B-Instruct-4bit",
      displayName: "Qwen2.5-32B",
      badge: "Maximum quality",
      approxRamGB: 20,
      approxDiskGB: 18,
      license: "Apache 2.0",
      contextWindow: 131_072),
  ]

  /// Look up an option by Hugging Face id. Returns nil if no entry matches —
  /// callers should fall back to the recommended option in that case.
  static func option(forId id: String) -> LocalModelOption? {
    all.first(where: { $0.id == id })
  }

  /// The "default" option to surface when nothing has been chosen yet. We
  /// pick whichever entry matches `MLXLifecycleManager.defaultModelID`, or
  /// the first entry if the default isn't in the catalog.
  static var recommended: LocalModelOption {
    option(forId: MLXLifecycleManager.defaultModelID) ?? all[0]
  }
}
