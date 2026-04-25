// Infinite Recall fork: catalog of supported local VLM (vision-language)
// models surfaced in Settings → AI / Models → Vision Model card.
//
// Mirrors LocalModelCatalog exactly — same data shape, same lookup helpers —
// but for models served via mlx-vlm.server on 127.0.0.1:8081.

import Foundation

/// One row in the Vision Model picker.
struct VisionModelOption: Identifiable, Hashable {
  /// Hugging Face repo path. Used as the unique id and as the value passed
  /// to `mlx_vlm.server --model ...` and `snapshot_download`.
  let id: String

  /// Human-friendly short label (e.g. "Qwen3-VL-8B").
  let displayName: String

  /// Short tagline shown next to the name (e.g. "Default (recommended)").
  let badge: String

  /// Approximate peak resident memory while serving, in GB. Display only.
  let approxRamGB: Double

  /// Approximate on-disk footprint of the 4-bit weights, in GB.
  let approxDiskGB: Double

  /// SPDX-ish short license string (e.g. "Apache 2.0").
  let license: String

  /// Maximum context / image-token window the model claims. Display only.
  let contextWindow: Int
}

/// Static registry of supported local vision models. Order here is the order
/// the picker renders them.
enum VisionModelCatalog {

  /// All catalog entries, in display order.
  static let all: [VisionModelOption] = [
    .init(
      id: "mlx-community/Qwen3-VL-8B-Instruct-4bit",
      displayName: "Qwen3-VL-8B",
      badge: "Default (recommended)",
      approxRamGB: 8,
      approxDiskGB: 5.5,
      license: "Apache 2.0",
      contextWindow: 32_768),
    .init(
      id: "mlx-community/Qwen2.5-VL-7B-Instruct-4bit",
      displayName: "Qwen2.5-VL-7B",
      badge: "Fallback",
      approxRamGB: 7,
      approxDiskGB: 4.5,
      license: "Apache 2.0",
      contextWindow: 32_768),
  ]

  /// Look up an option by Hugging Face id. Returns nil if no entry matches.
  static func option(forId id: String) -> VisionModelOption? {
    all.first(where: { $0.id == id })
  }

  /// The "default" option. Matches `VLMLifecycleManager.defaultModelID`, or
  /// the first entry as a fallback.
  static var recommended: VisionModelOption {
    option(forId: VLMLifecycleManager.defaultModelID) ?? all[0]
  }
}
