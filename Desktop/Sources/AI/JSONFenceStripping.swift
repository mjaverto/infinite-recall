import Foundation

/// Strip ```json ... ``` and ``` ... ``` fences if a model wrapped its
/// reply against instructions. Idempotent on un-fenced input.
func stripJSONFences(_ s: String) -> String {
  var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
  if t.hasPrefix("```") {
    if let nl = t.firstIndex(of: "\n") {
      t = String(t[t.index(after: nl)...])
    }
    if t.hasSuffix("```") {
      t = String(t.dropLast(3))
    }
    t = t.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  return t
}
