import Foundation

/// A resolver turns a social-media page URL into a direct media URL.
///
/// Each platform ships its own implementation, since the tricks used to
/// find the actual .mp4 differ per site (meta tags, JSON-LD, JS-rendered
/// manifests, authenticated APIs…). Resolvers are async and throw
/// `DownloadError` on failure.
protocol MediaResolver {
    var platform: SocialPlatform { get }
    func resolve(_ url: URL) async throws -> ResolverResult
}

/// Shared HTML-scraping utilities used by the best-effort resolvers.
///
/// These helpers are intentionally small and dependency-free. They work
/// well for pages that embed media via OpenGraph or JSON-LD, and fall
/// back gracefully for pages that don't.
enum HTMLScraper {

    /// Fetch raw HTML for a URL. Sends a desktop User-Agent so that
    /// platforms don't serve us their mobile interstitial page.
    static func fetchHTML(_ url: URL) async throws -> String {
        var req = URLRequest(url: url)
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 " +
            "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw DownloadError.networkFailed("unexpected HTTP response")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw DownloadError.resolutionFailed("non-UTF8 response body")
        }
        return html
    }

    /// Pull the `content` attribute out of `<meta property="...">` tags.
    /// Returns the first match — good enough for og:video / og:image lookups.
    static func metaContent(_ html: String, property: String) -> String? {
        // Accept both `property` (OpenGraph) and `name` (Twitter cards etc.).
        let patterns = [
            #"<meta[^>]+property=["']\#(property)["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']\#(property)["']"#,
            #"<meta[^>]+name=["']\#(property)["'][^>]+content=["']([^"']+)["']"#
        ]
        for pattern in patterns {
            if let value = firstCaptureGroup(in: html, pattern: pattern) { return value }
        }
        return nil
    }

    /// Basic HTML-entity decoder for the tiny subset that shows up in
    /// meta tags. Extend as needed.
    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;", with: "'")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
    }

    static func firstCaptureGroup(in text: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = re.firstMatch(in: text, range: range), match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return decodeEntities(String(text[r]))
    }
}
