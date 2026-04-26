import Foundation

/// POSTs a pre-serialized memory payload to a user-supplied webhook URL.
///
/// Owns its own `URLSession` (not `.shared`) with a 30s request timeout so
/// a slow webhook can't tie up cookies/credentials/cache from the rest of
/// the app. Returns a `DispatchOutcome` so the drain service can branch
/// uniformly with the filesystem sender.
enum WebhookSender {
  /// Dedicated session for outbound webhook POSTs. 30s request timeout —
  /// the drain service runs every 60s, so we never want a single hung
  /// connection to block the queue past one tick.
  private static let session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    return URLSession(configuration: config)
  }()

  /// POSTs `payload` (already JSON-encoded by the caller via
  /// `MemoryPayload.encodedJSON()`) to `urlString`.
  ///
  /// - Bad URL (not http/https or unparseable) → `.permanentFailure`.
  /// - 2xx → `.success`.
  /// - 429 / 5xx → `.retry`.
  /// - Other 4xx → `.permanentFailure`.
  /// - URLError / non-HTTP response → `.retry`.
  static func send(payload: Data, to urlString: String) async -> DispatchOutcome {
    guard let url = URL(string: urlString),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https"
    else {
      return .permanentFailure(reason: "invalid URL: \(urlString)")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = payload

    do {
      let (_, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .retry(reason: "non-HTTP response")
      }
      let status = http.statusCode
      switch status {
      case 200...299:
        return .success
      case 429, 500...599:
        return .retry(reason: "HTTP \(status)")
      case 400...499:
        return .permanentFailure(reason: "HTTP \(status)")
      default:
        // URLSession follows 3xx automatically and consumes 1xx, so seeing
        // one here means the server is misbehaving. Treat as permanent so
        // we don't spin forever — the user sees lastError and can fix the URL.
        return .permanentFailure(reason: "unexpected HTTP \(status)")
      }
    } catch let urlError as URLError {
      return .retry(reason: urlError.localizedDescription)
    } catch {
      return .retry(reason: error.localizedDescription)
    }
  }
}
