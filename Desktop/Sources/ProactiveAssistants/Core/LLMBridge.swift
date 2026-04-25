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

// MARK: - JSON-mode Tool Calling
//
// The local mlx-lm model (Qwen 2.5-32B Instruct) does not natively expose
// OpenAI-style function-calling JSON, but it reliably emits structured JSON
// when prompted. We describe the tool catalog in the system prompt as a JSON
// schema and ask the model to respond with EITHER a `call_tool` action or a
// `final_answer` action. The harness loops, executing the tool the model
// requests and feeding the result back in, until the model emits a final
// answer or we hit `maxIterations`.

/// One available tool the model can call. Parameters use OpenAPI-style schema
/// dictionaries (the model is shown the raw schema as JSON in its prompt).
struct ToolDefinition: Sendable {
  let name: String
  let description: String
  let parametersJSONSchema: [String: Any]

  init(name: String, description: String, parametersJSONSchema: [String: Any]) {
    self.name = name
    self.description = description
    self.parametersJSONSchema = parametersJSONSchema
  }
}

/// Result of one model turn in JSON-mode tool calling. The bridge does not
/// reuse Gemini's `ToolCall` struct (that one is used by the cloud chat tool
/// loop) — these cases describe what to do next given the model's text.
enum LLMToolCall {
  /// Model asked to invoke a tool with the given JSON arguments.
  case callTool(name: String, arguments: [String: Any])
  /// Model finished and produced a textual answer.
  case finalAnswer(text: String)
  /// Model emitted text that didn't parse as the expected envelope.
  case malformed(raw: String)
}

extension LLMBridge {

  /// Single model turn against the JSON-mode tool envelope. The model is told
  /// (via the system prompt) to respond with EXACTLY one JSON object describing
  /// either a tool call or a final answer.
  static func callWithTools(
    systemPrompt: String,
    userPrompt: String,
    tools: [ToolDefinition],
    maxTokens: Int = 1024
  ) async -> LLMToolCall {
    let envelope = buildToolEnvelopeSystem(base: systemPrompt, tools: tools)
    guard let raw = await generate(
      systemPrompt: envelope,
      userPrompt: userPrompt,
      label: "tool-call"
    ) else {
      return .malformed(raw: "")
    }
    return parseToolEnvelope(raw)
  }

  /// Multi-step JSON-mode tool loop.
  ///
  /// Each iteration sends the running conversation to the model as a single
  /// user-prompt blob (system + tool catalog stays constant; tool results are
  /// appended as additional context). When the model returns `.finalAnswer`,
  /// the loop returns its text. When it returns `.callTool`, we invoke
  /// `executeTool` and append the result to the conversation. We stop after
  /// `maxIterations` and return nil (logged as a warning by callers).
  ///
  /// Throws only if `executeTool` throws. Malformed JSON / max iterations
  /// surface as nil so assistants can stay graceful.
  static func runToolLoop(
    systemPrompt: String,
    userPrompt: String,
    tools: [ToolDefinition],
    maxIterations: Int = 5,
    executeTool: (String, [String: Any]) async throws -> String
  ) async throws -> String? {
    let envelope = buildToolEnvelopeSystem(base: systemPrompt, tools: tools)
    var conversation = userPrompt

    for iteration in 0..<maxIterations {
      guard let raw = await generate(
        systemPrompt: envelope,
        userPrompt: conversation,
        label: "tool-loop[\(iteration)]"
      ) else {
        log("[LLMBridge.runToolLoop] empty response on iteration \(iteration), bailing")
        return nil
      }

      switch parseToolEnvelope(raw) {
      case .finalAnswer(let text):
        return text

      case .callTool(let name, let arguments):
        let argsPreview = (try? JSONSerialization.data(withJSONObject: arguments))
          .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        log("[LLMBridge.runToolLoop] iter \(iteration) → tool '\(name)' args=\(argsPreview)")
        let result = try await executeTool(name, arguments)
        // Truncate long tool results before feeding them back; most models
        // start to drift past 4–6 KB of injected context per turn.
        let truncated = result.count > 4000
          ? String(result.prefix(4000)) + "... (truncated)"
          : result
        conversation += "\n\nPREVIOUS TOOL CALL: \(name)\nARGUMENTS: \(argsPreview)\nTOOL RESULT:\n\(truncated)\n\nNow respond with the next JSON action (another tool call or final_answer)."

      case .malformed(let raw):
        log("[LLMBridge.runToolLoop] malformed JSON on iteration \(iteration): \(raw.prefix(300))")
        return nil
      }
    }

    log("[LLMBridge.runToolLoop] hit maxIterations=\(maxIterations) without final_answer")
    return nil
  }

  // MARK: - Envelope plumbing

  /// Build the system prompt that wraps the caller's base system prompt with
  /// the JSON-action contract and the tool catalog.
  fileprivate static func buildToolEnvelopeSystem(
    base: String,
    tools: [ToolDefinition]
  ) -> String {
    let toolCatalog = tools.map { tool -> String in
      let schemaJSON: String
      if let data = try? JSONSerialization.data(
        withJSONObject: tool.parametersJSONSchema,
        options: [.sortedKeys]
      ), let s = String(data: data, encoding: .utf8) {
        schemaJSON = s
      } else {
        schemaJSON = "{}"
      }
      return """
        - name: \(tool.name)
          description: \(tool.description)
          parameters_schema: \(schemaJSON)
        """
    }.joined(separator: "\n")

    return """
      \(base)

      You have access to the following tools. Call them by name when useful:
      \(toolCatalog)

      RESPONSE PROTOCOL — read carefully:

      You MUST respond with EXACTLY ONE JSON object on a single line, with no
      surrounding prose, no markdown fences, no commentary.

      To call a tool, respond with:
      {"action": "call_tool", "tool": "<tool_name>", "arguments": { <args matching the tool's parameters_schema> }}

      To finish and return a final answer, respond with:
      {"action": "final_answer", "text": "<your final answer here>"}

      Only one action per response. Do not include extra keys. Do not wrap in
      ```json fences. Do not add explanatory text before or after the JSON.
      """
  }

  /// Parse a single model turn's text into a `LLMToolCall`. Strips fences,
  /// trims whitespace, then extracts the first balanced JSON object.
  fileprivate static func parseToolEnvelope(_ raw: String) -> LLMToolCall {
    let stripped = stripJSONWrapper(raw)
    guard let jsonText = extractFirstJSONObject(from: stripped) else {
      return .malformed(raw: raw)
    }
    guard let data = jsonText.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let action = obj["action"] as? String
    else {
      return .malformed(raw: raw)
    }

    switch action {
    case "call_tool":
      guard let name = obj["tool"] as? String else {
        return .malformed(raw: raw)
      }
      let args = (obj["arguments"] as? [String: Any]) ?? [:]
      return .callTool(name: name, arguments: args)

    case "final_answer":
      let text = obj["text"] as? String ?? ""
      return .finalAnswer(text: text)

    default:
      return .malformed(raw: raw)
    }
  }

  /// Find the first balanced `{...}` substring. The model occasionally adds a
  /// stray sentence around its JSON; this lets us tolerate that without
  /// failing the whole turn.
  fileprivate static func extractFirstJSONObject(from text: String) -> String? {
    guard let start = text.firstIndex(of: "{") else { return nil }
    var depth = 0
    var inString = false
    var escape = false
    var i = start
    while i < text.endIndex {
      let c = text[i]
      if escape {
        escape = false
      } else if c == "\\" && inString {
        escape = true
      } else if c == "\"" {
        inString.toggle()
      } else if !inString {
        if c == "{" { depth += 1 }
        else if c == "}" {
          depth -= 1
          if depth == 0 {
            return String(text[start...i])
          }
        }
      }
      i = text.index(after: i)
    }
    return nil
  }
}
