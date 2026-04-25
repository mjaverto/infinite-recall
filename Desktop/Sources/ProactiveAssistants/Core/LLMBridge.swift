// Infinite Recall fork: shim that lets the proactive assistants talk to whatever
// LLM provider the AIProviderRegistry hands out (currently LocalLLMClient on
// 127.0.0.1:8080 via mlx-lm.server). Replaces the assistants' previous direct
// dependency on GeminiClient.
//
// Design: present a tiny, prompt-shaped surface the assistants can call without
// caring about provider plumbing. Vision input and function-calling are not
// supported by the v1 local provider — those calls degrade gracefully.

import Foundation

/// Helpers that forward to whichever LLM client `AIProviderRegistry.shared`
/// returns. Each call resolves the client lazily so a missing provider just
/// makes the call return nil rather than throwing.
enum LLMBridge {

  /// Resolve the current registry client on the main actor.
  /// Returns nil if no provider is wired up (e.g. local server offline or
  /// cloud provider not yet implemented).
  static func currentClient() async -> (any LLMClient)? {
    await MainActor.run {
      try? AIProviderRegistry.shared.makeClient()
    }
  }

  /// Run a non-streaming chat call and return the full text response.
  /// Returns nil on any error (including server unreachable). Callers log
  /// their own context.
  static func generate(
    systemPrompt: String,
    userPrompt: String,
    label: String
  ) async -> String? {
    guard let client = await currentClient() else {
      log("[\(label)] no LLM client available — skipping")
      return nil
    }

    let messages: [LLM.ChatMessage] = [
      .init(role: .system, content: systemPrompt),
      .init(role: .user, content: userPrompt),
    ]

    do {
      let stream = try await client.chat(messages: messages, stream: false)
      var fullText = ""
      for try await chunk in stream {
        fullText += chunk.delta
      }
      return fullText
    } catch {
      log("[\(label)] LLM call failed: \(error.localizedDescription)")
      return nil
    }
  }

  /// Same as `generate` but with a JSON-shaped response. The system prompt is
  /// augmented with an instruction to emit JSON only, and the response is
  /// best-effort cleaned of code-fence wrappers before returning.
  static func generateJSON(
    systemPrompt: String,
    userPrompt: String,
    label: String
  ) async -> String? {
    let augmentedSystem = systemPrompt + "\n\nRespond ONLY with a single valid JSON object that conforms to the schema described in the user prompt. Do not include code fences, prose, or commentary."
    guard let raw = await generate(
      systemPrompt: augmentedSystem,
      userPrompt: userPrompt,
      label: label
    ) else {
      return nil
    }
    return Self.stripJSONWrapper(raw)
  }

  /// Strip ```json ... ``` fences and leading/trailing whitespace from a model
  /// response. Handles bare JSON unchanged.
  static func stripJSONWrapper(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // Remove an opening ``` or ```json fence
    if s.hasPrefix("```") {
      if let firstNewline = s.firstIndex(of: "\n") {
        s = String(s[s.index(after: firstNewline)...])
      } else {
        s = String(s.dropFirst(3))
      }
    }
    // Remove a trailing ``` fence
    if s.hasSuffix("```") {
      s = String(s.dropLast(3))
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
