// Pure validator + persistence-key constants for user-supplied Hugging Face
// model ids in the Local Model and Vision Model pickers.
//
// No network calls — this only enforces shape (`org/repo`) so the UI can
// surface an inline error before kicking off the installer. Real failures
// (404, gated repo, non-MLX weights) surface from `snapshot_download` via
// LocalAIInstaller.

import Foundation

enum CustomHFError: LocalizedError, Equatable {
  case empty
  case malformed
  case tooLong

  var errorDescription: String? {
    switch self {
    case .empty:
      return "Enter a Hugging Face repo (e.g. mlx-community/Llama-3.2-3B-Instruct-4bit)."
    case .malformed:
      return "Must be in the form org/repo using letters, digits, dot, underscore, or hyphen."
    case .tooLong:
      return "Too long — keep it under \(CustomHFModelID.maxLength) characters."
    }
  }
}

enum CustomHFModelID {
  static let pattern = #"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"#
  static let maxLength = 200

  static func validate(_ raw: String) -> Result<String, CustomHFError> {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .failure(.empty) }
    if trimmed.count > maxLength { return .failure(.tooLong) }
    if trimmed.range(of: pattern, options: .regularExpression) == nil {
      return .failure(.malformed)
    }
    return .success(trimmed)
  }
}

/// UserDefaults keys for the freeform HF id the user typed into each picker.
/// These persist across catalog/custom toggles so the TextField repopulates.
/// The *active* model id (curated or custom) still lives under the existing
/// `activeLocalModelID` / `activeVisionModelID` keys read by the lifecycle
/// managers — these keys hold the draft separately.
enum CustomHFModelDefaults {
  static let localKey = "customLocalModelID"
  static let visionKey = "customVisionModelID"
}
