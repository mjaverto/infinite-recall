import Foundation

struct OnboardingWebSearchResult: Sendable {
  let query: String
  let title: String
  let url: String
  let snippet: String
}

actor OnboardingWebResearchService {
  static let shared = OnboardingWebResearchService()

  func search(queries: [String], maxResultsPerQuery: Int = 3) async -> [OnboardingWebSearchResult] {
    // Infinite Recall fork: local-only mode — no outbound network.
    log("[backend-stripped] OnboardingWebResearchService.search(queries:): no-op (queries=\(queries.count))")
    return []
  }

  private func search(query: String, maxResults: Int) async -> [OnboardingWebSearchResult] {
    // Infinite Recall fork: local-only mode — no outbound network.
    log("[backend-stripped] OnboardingWebResearchService.search(query:): no-op (query=\(query))")
    return []
  }

  private func parse(
    html: String,
    query: String,
    maxResults: Int
  ) -> [OnboardingWebSearchResult] {
    guard
      let titleRegex = try? NSRegularExpression(
        pattern: #"<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#,
        options: [.dotMatchesLineSeparators, .caseInsensitive]
      ),
      let snippetRegex = try? NSRegularExpression(
        pattern:
          #"<a[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</a>|<div[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</div>"#,
        options: [.dotMatchesLineSeparators, .caseInsensitive]
      )
    else {
      return []
    }

    let nsHTML = html as NSString
    let titleMatches = titleRegex.matches(
      in: html, range: NSRange(location: 0, length: nsHTML.length))
    let snippetMatches = snippetRegex.matches(
      in: html, range: NSRange(location: 0, length: nsHTML.length))

    var results: [OnboardingWebSearchResult] = []

    for (index, titleMatch) in titleMatches.prefix(maxResults).enumerated() {
      guard titleMatch.numberOfRanges >= 3 else { continue }

      let rawURL = nsHTML.substring(with: titleMatch.range(at: 1))
      let rawTitle = nsHTML.substring(with: titleMatch.range(at: 2))
      let rawSnippet: String
      if index < snippetMatches.count {
        let snippetMatch = snippetMatches[index]
        if snippetMatch.numberOfRanges > 2, snippetMatch.range(at: 1).location != NSNotFound {
          rawSnippet = nsHTML.substring(with: snippetMatch.range(at: 1))
        } else if snippetMatch.numberOfRanges > 2, snippetMatch.range(at: 2).location != NSNotFound
        {
          rawSnippet = nsHTML.substring(with: snippetMatch.range(at: 2))
        } else {
          rawSnippet = ""
        }
      } else {
        rawSnippet = ""
      }

      let resolvedURL = unwrapDuckDuckGoRedirect(rawURL) ?? rawURL
      let title = cleanHTML(rawTitle)
      let snippet = cleanHTML(rawSnippet)

      guard !title.isEmpty, !resolvedURL.isEmpty else { continue }

      results.append(
        OnboardingWebSearchResult(query: query, title: title, url: resolvedURL, snippet: snippet)
      )
    }

    return results
  }

  private func unwrapDuckDuckGoRedirect(_ rawURL: String) -> String? {
    guard let url = URL(string: rawURL) else { return rawURL }

    if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
      let decoded = target.removingPercentEncoding
    {
      return decoded
    }

    return rawURL
  }

  private func cleanHTML(_ text: String) -> String {
    let withoutTags = text.replacingOccurrences(
      of: #"<[^>]+>"#,
      with: " ",
      options: .regularExpression
    )

    let decoded =
      withoutTags
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&apos;", with: "'")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&nbsp;", with: " ")

    return decoded.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
