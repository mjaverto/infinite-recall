// Infinite Recall fork: local LLM via mlx-lm.server. No cloud calls.
//
// LocalLLMClient — talks to an OpenAI-compatible HTTP endpoint hosted by
// `mlx-lm.server` running on 127.0.0.1:8080. Streams responses via SSE.
//
// This file deliberately avoids the existing top-level `ChatMessage` type
// (defined in Providers/ChatProvider.swift for the chat UI). All LLM-facing
// types live under the `LLM` enum-namespace below (`LLM.ChatMessage`, etc.)
// so call sites are explicit about which surface they're using.

import Foundation

// MARK: - LLM Namespace

/// Namespace for shared LLM client types. Avoids collision with the existing
/// UI-side `ChatMessage` in `Providers/ChatProvider.swift`.
enum LLM {
  /// OpenAI-style chat message.
  struct ChatMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
      case system
      case user
      case assistant
      case tool
    }

    let role: Role
    let content: String

    init(role: Role, content: String) {
      self.role = role
      self.content = content
    }

    // Persist `role` as a raw string for OpenAI compatibility.
    private enum CodingKeys: String, CodingKey {
      case role, content
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      let raw = try c.decode(String.self, forKey: .role)
      self.role = Role(rawValue: raw) ?? .user
      self.content = try c.decode(String.self, forKey: .content)
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(role.rawValue, forKey: .role)
      try c.encode(content, forKey: .content)
    }
  }

  /// One streamed delta from an OpenAI-compatible /v1/chat/completions stream.
  struct ChatChunk: Sendable {
    /// Incremental text delta from the model. May be empty for keep-alives.
    let delta: String
    /// Set on the final chunk, if the server reports one ("stop", "length", …).
    let finishReason: String?
  }
}

// MARK: - LLMClient protocol

/// Protocol all AI providers conform to. v1 only `LocalLLMClient` implements it;
/// other providers (Anthropic / OpenAI / LocalCLI) are stubs that throw.
protocol LLMClient: Sendable {
  func chat(
    messages: [LLM.ChatMessage],
    stream: Bool
  ) async throws -> AsyncThrowingStream<LLM.ChatChunk, Error>
}

// MARK: - LocalLLMClient

/// Talks to `mlx-lm.server` over the OpenAI-compatible REST API.
/// Streaming is via Server-Sent Events on `/v1/chat/completions`.
actor LocalLLMClient: LLMClient {

  static let shared = LocalLLMClient()

  // MARK: Configuration

  /// Base URL of the local mlx-lm.server. Hard-coded loopback by design —
  /// this client must never reach off-host. Override only for tests.
  private let baseURL: URL
  /// Model name to send in request bodies. mlx-lm.server ignores this when it
  /// was launched with `--model`, but we still send it for OpenAI-compat.
  private let modelName: String
  /// Max wait for the initial HTTP response (excludes generation time on a
  /// streamed call — bytes() keeps the connection open beyond this).
  private let requestTimeout: TimeInterval

  init(
    baseURL: URL = URL(string: "http://127.0.0.1:8080")!,
    modelName: String = "mlx-community/Qwen2.5-7B-Instruct-4bit",
    requestTimeout: TimeInterval = 30
  ) {
    self.baseURL = baseURL
    self.modelName = modelName
    self.requestTimeout = requestTimeout
  }

  // MARK: Errors

  enum LocalLLMError: LocalizedError {
    case serverUnreachable
    case invalidResponse
    case http(Int, String)
    case decodingFailed(String)

    var errorDescription: String? {
      switch self {
      case .serverUnreachable:
        return "Local LLM server (mlx-lm.server) is not reachable on 127.0.0.1:8080."
      case .invalidResponse:
        return "Local LLM server returned an unexpected response."
      case .http(let code, let body):
        return "Local LLM HTTP \(code): \(body)"
      case .decodingFailed(let detail):
        return "Failed to decode local LLM response: \(detail)"
      }
    }
  }

  // MARK: Public API

  /// Stream (or fetch) a chat completion.
  ///
  /// - Parameters:
  ///   - messages: OpenAI-style chat history (system / user / assistant / tool).
  ///   - stream: If true, the returned AsyncThrowingStream emits deltas as the
  ///     model generates them. If false, the stream emits exactly one chunk
  ///     containing the full response and then completes.
  /// - Returns: AsyncThrowingStream of ChatChunk.
  func chat(
    messages: [LLM.ChatMessage],
    stream: Bool = true
  ) async throws -> AsyncThrowingStream<LLM.ChatChunk, Error> {
    // Bump the idle-watchdog and auto-restart the server if it was stopped
    // due to idle. Must complete before the HTTP request goes out.
    await IdleAIController.shared.recordAICall()
    let request = try makeChatRequest(messages: messages, stream: stream)

    if stream {
      return makeStreamingChat(request: request)
    } else {
      return makeNonStreamingChat(request: request)
    }
  }

  /// Autonomous-mode chat. Same wire behavior as `chat(...)` but DOES NOT
  /// call `IdleAIController.shared.recordAICall()`.
  ///
  /// Why: autonomous summarize work runs while the user is locked or input-
  /// idle. If we bumped `lastAICall`, Memory Saver's idle-unload threshold
  /// would never elapse during a long drain, pinning the local LLM in memory
  /// indefinitely and defeating the user's "release on idle" preference.
  /// `BatteryAwareScheduler.drain()` calls
  /// `IdleAIController.releaseAfterAutonomousWorkIfAppropriate()` after each
  /// batch finishes so the server CAN unload once the queue is empty and the
  /// user is still away.
  ///
  /// This method MUST NOT be used by user-initiated chat paths — those keep
  /// using `chat(...)` so the idle watchdog continues to bump and the server
  /// auto-restarts on the next user request.
  ///
  /// INVARIANT: do not introduce a flag on `chat(...)` to share this body.
  /// Keeping the two entry points distinct makes the call-site contract
  /// (does this pin the model alive?) auditable from the call graph alone.
  func chatAutonomous(
    messages: [LLM.ChatMessage],
    stream: Bool = false
  ) async throws -> AsyncThrowingStream<LLM.ChatChunk, Error> {
    // Intentionally NO recordAICall() here.
    let request = try makeChatRequest(messages: messages, stream: stream)
    if stream {
      return makeStreamingChat(request: request)
    } else {
      return makeNonStreamingChat(request: request)
    }
  }

  /// Convenience: single-prompt completion. Returns the full text.
  func complete(prompt: String, maxTokens: Int = 512) async throws -> String {
    await IdleAIController.shared.recordAICall()
    let messages = [LLM.ChatMessage(role: .user, content: prompt)]
    let request = try makeChatRequest(
      messages: messages, stream: false, maxTokens: maxTokens)

    let (data, response) = try await URLSession.shared.data(for: request)
    try Self.checkHTTPStatus(response, data: data)

    do {
      let decoded = try JSONDecoder().decode(NonStreamingResponse.self, from: data)
      return decoded.choices.first?.message?.content ?? ""
    } catch {
      throw LocalLLMError.decodingFailed(String(describing: error))
    }
  }

  /// Pings `/v1/models`. Returns false if the server is offline, slow, or errors.
  func isReachable() async -> Bool {
    let url = baseURL.appendingPathComponent("v1/models")
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.timeoutInterval = 2  // quick probe

    do {
      let (_, response) = try await URLSession.shared.data(for: req)
      guard let http = response as? HTTPURLResponse else { return false }
      return (200..<300).contains(http.statusCode)
    } catch {
      return false
    }
  }

  // MARK: - Request construction

  private func makeChatRequest(
    messages: [LLM.ChatMessage],
    stream: Bool,
    maxTokens: Int? = nil
  ) throws -> URLRequest {
    let url = baseURL.appendingPathComponent("v1/chat/completions")
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = requestTimeout
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if stream {
      req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    }

    let body = ChatRequestBody(
      model: modelName,
      messages: messages,
      stream: stream,
      maxTokens: maxTokens
    )
    req.httpBody = try JSONEncoder().encode(body)
    return req
  }

  // MARK: - Streaming

  private nonisolated func makeStreamingChat(
    request: URLRequest
  ) -> AsyncThrowingStream<LLM.ChatChunk, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let (bytes, response) = try await URLSession.shared.bytes(for: request)
          try await Self.checkStreamingStatus(response, bytes: bytes)

          for try await line in bytes.lines {
            // SSE: each event is one or more `data: ...` lines, ending with `[DONE]`.
            guard line.hasPrefix("data:") else { continue }
            let payload = line
              .dropFirst(5)
              .trimmingCharacters(in: .whitespaces)

            if payload == "[DONE]" {
              continuation.finish()
              return
            }
            guard let data = payload.data(using: .utf8) else { continue }

            do {
              let chunk = try JSONDecoder().decode(StreamingChunk.self, from: data)
              if let choice = chunk.choices.first {
                let delta = choice.delta?.content ?? ""
                let chunk = LLM.ChatChunk(
                  delta: delta,
                  finishReason: choice.finishReason
                )
                if !delta.isEmpty || choice.finishReason != nil {
                  continuation.yield(chunk)
                }
              }
            } catch {
              // Tolerate occasional non-JSON keepalive lines.
              continue
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  // MARK: - Non-streaming (still uses AsyncThrowingStream for API symmetry)

  private nonisolated func makeNonStreamingChat(
    request: URLRequest
  ) -> AsyncThrowingStream<LLM.ChatChunk, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let (data, response) = try await URLSession.shared.data(for: request)
          try Self.checkHTTPStatus(response, data: data)

          let decoded = try JSONDecoder().decode(NonStreamingResponse.self, from: data)
          let text = decoded.choices.first?.message?.content ?? ""
          let finish = decoded.choices.first?.finishReason
          continuation.yield(LLM.ChatChunk(delta: text, finishReason: finish))
          continuation.finish()
        } catch let err as LocalLLMError {
          continuation.finish(throwing: err)
        } catch {
          continuation.finish(throwing: LocalLLMError.decodingFailed(String(describing: error)))
        }
      }

      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  // MARK: - HTTP helpers

  private static func checkHTTPStatus(_ response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else {
      throw LocalLLMError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data.prefix(512), encoding: .utf8) ?? ""
      throw LocalLLMError.http(http.statusCode, body)
    }
  }

  /// For streamed responses we don't have the body up front, so we just check
  /// the status code. If it's an error, drain a small prefix for context.
  private static func checkStreamingStatus(
    _ response: URLResponse,
    bytes: URLSession.AsyncBytes
  ) async throws {
    guard let http = response as? HTTPURLResponse else {
      throw LocalLLMError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      var preview = ""
      var iterator = bytes.lines.makeAsyncIterator()
      while preview.count < 512, let line = try await iterator.next() {
        preview += line + "\n"
      }
      throw LocalLLMError.http(http.statusCode, preview)
    }
  }
}

// MARK: - Wire types (private)

private struct ChatRequestBody: Encodable {
  let model: String
  let messages: [LLM.ChatMessage]
  let stream: Bool
  let maxTokens: Int?

  enum CodingKeys: String, CodingKey {
    case model, messages, stream
    case maxTokens = "max_tokens"
  }
}

private struct StreamingChunk: Decodable {
  let choices: [Choice]

  struct Choice: Decodable {
    let delta: Delta?
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
      case delta
      case finishReason = "finish_reason"
    }
  }

  struct Delta: Decodable {
    let role: String?
    let content: String?
  }
}

private struct NonStreamingResponse: Decodable {
  let choices: [Choice]

  struct Choice: Decodable {
    let message: Message?
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
      case message
      case finishReason = "finish_reason"
    }
  }

  struct Message: Decodable {
    let role: String?
    let content: String?
  }
}
