import Foundation

enum OnboardingMemoryLogSource: String, CaseIterable, Sendable {
  case chatgpt
  case claude

  var displayName: String {
    switch self {
    case .chatgpt: return "ChatGPT"
    case .claude: return "Claude"
    }
  }

  var browserURL: URL {
    switch self {
    case .chatgpt: return URL(string: "https://chatgpt.com/")!
    case .claude: return URL(string: "https://claude.ai/")!
    }
  }

  var prefilledBrowserURL: URL {
    var components = URLComponents(url: browserURL, resolvingAgainstBaseURL: false)

    switch self {
    case .chatgpt:
      components?.path = "/"
      components?.queryItems = [URLQueryItem(name: "q", value: prompt)]
    case .claude:
      components?.path = "/new"
      components?.queryItems = [URLQueryItem(name: "q", value: prompt)]
    }

    return components?.url ?? browserURL
  }

  var tags: [String] {
    [rawValue, "import", "memory_log"]
  }

  var memorySource: String {
    "\(rawValue)_memory_log"
  }

  var headline: String {
    "\(displayName) Memory Import"
  }

  var prompt: String {
    """
    Return everything you know about me inside one fenced code block. Include long-term memory, bio details, and any model-set context you have with dates when available. I want a thorough memory export of what you've learned about me. Skip tool details and include only information that is actually about me. Be exhaustive and careful.
    """
  }
}

actor OnboardingMemoryLogImportService {
  static let shared = OnboardingMemoryLogImportService()

  func importMemoryLog(
    _ rawText: String,
    source: OnboardingMemoryLogSource
  ) async -> (memories: Int, profileSummary: String) {
    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return (0, "") }

    // Infinite Recall fork: agent bridge (Node.js synthesis path) was deleted with
    // the rest of the cloud agent runtime. Memory-log import is now a no-op until
    // a local-LLM synthesis path replaces it.
    log("OnboardingMemoryLogImportService: \(source.displayName) import skipped — AI synthesis disabled in local-first build")
    return (0, "")
  }

  private static func extractJSONObject(from text: String) -> String {
    var responseText = text.trimmingCharacters(in: .whitespacesAndNewlines)

    if responseText.hasPrefix("```") {
      if let firstNewline = responseText.firstIndex(of: "\n") {
        responseText = String(responseText[responseText.index(after: firstNewline)...])
      }
      if responseText.hasSuffix("```") {
        responseText = String(responseText.dropLast(3)).trimmingCharacters(
          in: .whitespacesAndNewlines)
      }
    }

    if let braceIndex = responseText.firstIndex(of: "{") {
      responseText = String(responseText[braceIndex...])
    }

    return responseText.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
