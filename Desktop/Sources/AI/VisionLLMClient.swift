// Infinite Recall fork: local Vision LLM client. Talks to mlx-vlm.server on
// 127.0.0.1:8081 over an OpenAI-compatible /v1/chat/completions endpoint.
//
// mlx-vlm exposes the same OpenAI multimodal message format as the upstream
// chat API: a user message's `content` becomes an array of typed parts, where
// each part is either `{type: "text", text: ...}` or
// `{type: "image_url", image_url: {url: "data:image/png;base64,..."}}`.
//
// We base64-encode the NSImage as PNG and embed it as a data: URL. No remote
// fetches — the server only ever sees inline data.

import AppKit
import Foundation

actor VisionLLMClient {

  static let shared = VisionLLMClient()

  // MARK: - Configuration

  /// Base URL of the local mlx-vlm.server. Hard-coded loopback by design —
  /// must never reach off-host. Override only for tests.
  private let baseURL: URL
  /// Model name to send in request bodies. mlx-vlm.server typically ignores
  /// this when launched with `--model`, but we still send it for OpenAI-compat.
  private let modelName: String
  private let requestTimeout: TimeInterval

  init(
    baseURL: URL = URL(string: "http://127.0.0.1:8081")!,
    modelName: String = "mlx-community/Qwen3-VL-8B-Instruct-4bit",
    requestTimeout: TimeInterval = 60
  ) {
    self.baseURL = baseURL
    self.modelName = modelName
    self.requestTimeout = requestTimeout
  }

  // MARK: - Errors

  enum VisionLLMError: LocalizedError {
    case serverUnreachable
    case invalidResponse
    case http(Int, String)
    case decodingFailed(String)
    case imageEncodingFailed

    var errorDescription: String? {
      switch self {
      case .serverUnreachable:
        return "Local VLM server (mlx-vlm.server) is not reachable on 127.0.0.1:8081."
      case .invalidResponse:
        return "Local VLM server returned an unexpected response."
      case .http(let code, let body):
        return "Local VLM HTTP \(code): \(body)"
      case .decodingFailed(let detail):
        return "Failed to decode local VLM response: \(detail)"
      case .imageEncodingFailed:
        return "Failed to PNG-encode the supplied image for the VLM payload."
      }
    }
  }

  // MARK: - Public API

  /// Pings `/v1/models`. Returns false if the server is offline, slow, or errors.
  func isReachable() async -> Bool {
    let url = baseURL.appendingPathComponent("v1/models")
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.timeoutInterval = 2

    do {
      let (_, response) = try await URLSession.shared.data(for: req)
      guard let http = response as? HTTPURLResponse else { return false }
      return (200..<300).contains(http.statusCode)
    } catch {
      return false
    }
  }

  /// Describe an image with a free-form prompt. Returns the assistant's full
  /// reply as plain text.
  func describe(image: NSImage, prompt: String) async throws -> String {
    let dataURL = try Self.encodeImageAsDataURL(image)
    let request = try makeChatRequest(
      dataURL: dataURL, text: prompt, maxTokens: 512)

    let (data, response) = try await URLSession.shared.data(for: request)
    try Self.checkHTTPStatus(response, data: data)

    do {
      let decoded = try JSONDecoder().decode(NonStreamingResponse.self, from: data)
      return decoded.choices.first?.message?.content ?? ""
    } catch {
      throw VisionLLMError.decodingFailed(String(describing: error))
    }
  }

  /// Ask the VLM to extract structured data from `image` according to
  /// `schemaJSON` (a JSON-schema-shaped string the caller supplies). The reply
  /// is parsed as JSON and returned as `[String: Any]`. Falls back to throwing
  /// `decodingFailed` if the model returns non-JSON.
  ///
  /// We instruct the model via the prompt; mlx-vlm doesn't yet support OpenAI's
  /// `response_format: json_schema` strict mode, so we lean on the chat
  /// template + a strong "respond ONLY with JSON" preamble.
  func extractStructured(
    image: NSImage,
    schemaJSON: String
  ) async throws -> [String: Any] {
    let dataURL = try Self.encodeImageAsDataURL(image)
    let prompt = """
      Extract structured data from this image. Respond with ONLY a JSON object \
      that matches the schema below. No prose, no code fences, no commentary.

      Schema:
      \(schemaJSON)
      """
    let request = try makeChatRequest(
      dataURL: dataURL, text: prompt, maxTokens: 1024)

    let (data, response) = try await URLSession.shared.data(for: request)
    try Self.checkHTTPStatus(response, data: data)

    let raw: String
    do {
      let decoded = try JSONDecoder().decode(NonStreamingResponse.self, from: data)
      raw = decoded.choices.first?.message?.content ?? ""
    } catch {
      throw VisionLLMError.decodingFailed(String(describing: error))
    }

    // Strip optional ```json fences before parsing.
    let stripped = stripJSONFences(raw)
    guard let payload = stripped.data(using: .utf8) else {
      throw VisionLLMError.decodingFailed("non-utf8 reply")
    }
    do {
      let any = try JSONSerialization.jsonObject(with: payload, options: [])
      if let dict = any as? [String: Any] { return dict }
      throw VisionLLMError.decodingFailed("expected JSON object, got \(type(of: any))")
    } catch let e as VisionLLMError {
      throw e
    } catch {
      throw VisionLLMError.decodingFailed(String(describing: error))
    }
  }

  // MARK: - Request construction

  private func makeChatRequest(
    dataURL: String,
    text: String,
    maxTokens: Int
  ) throws -> URLRequest {
    let url = baseURL.appendingPathComponent("v1/chat/completions")
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = requestTimeout
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

    // OpenAI-style multimodal payload. mlx-vlm accepts:
    //   messages: [
    //     { role: "user",
    //       content: [
    //         { type: "image_url", image_url: { url: "data:image/png;base64,..." } },
    //         { type: "text",      text: "..." }
    //       ]
    //     }
    //   ]
    let body: [String: Any] = [
      "model": modelName,
      "stream": false,
      "max_tokens": maxTokens,
      "messages": [
        [
          "role": "user",
          "content": [
            [
              "type": "image_url",
              "image_url": ["url": dataURL]
            ],
            [
              "type": "text",
              "text": text
            ]
          ]
        ]
      ]
    ]

    req.httpBody = try JSONSerialization.data(
      withJSONObject: body, options: [])
    return req
  }

  // MARK: - Helpers

  /// Encode an NSImage as a `data:image/png;base64,...` URL. Throws if the
  /// image has no rasterizable representation.
  private static func encodeImageAsDataURL(_ image: NSImage) throws -> String {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else {
      throw VisionLLMError.imageEncodingFailed
    }
    let b64 = png.base64EncodedString()
    return "data:image/png;base64,\(b64)"
  }

  private static func checkHTTPStatus(_ response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else {
      throw VisionLLMError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      let body = String(data: data.prefix(512), encoding: .utf8) ?? ""
      throw VisionLLMError.http(http.statusCode, body)
    }
  }
}

// MARK: - Wire types (private)

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
