import Foundation

/// Threads resolver (threads.net).
///
/// Threads is built on Instagram's infrastructure and renders its posts
/// server-side for logged-out visitors. The page HTML embeds React state
/// that contains Instagram-style media fields. Strategy (tried in order):
///
///  1. **Main page** — `og:video` meta tags, then a sweep of known JSON
///     key names (`video_url`, `playable_url`, …), then a brute-force
///     scan for any CDN `.mp4` URL in the HTML.
///
///  2. **Embed page** (`/t/<shortcode>/embed/`) — a lighter render that
///     sometimes exposes the video URL when the main page JS blob hides it.
///
/// Private posts require login — surfaced as a clear error.
///
/// URL forms handled:
///   https://www.threads.net/@user/post/SHORTCODE
///   https://threads.net/t/SHORTCODE
struct ThreadsResolver: MediaResolver {
    let platform: SocialPlatform = .threads

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    func resolve(_ url: URL) async throws -> ResolverResult {
        // 1. Main page scrape.
        if let result = try? await resolveViaPage(url) { return result }

        // 2. Embed page.
        if let sc = Self.extractShortcode(from: url),
           let result = try? await resolveViaEmbed(shortcode: sc) { return result }

        throw DownloadError.resolutionFailed(
            "couldn't find a public media URL on that Threads post. " +
            "Private posts require login, which isn't supported."
        )
    }

    // MARK: - Page scrape

    private func resolveViaPage(_ url: URL) async throws -> ResolverResult {
        let html = try await Self.fetchHTML(url)
        return try Self.extractMedia(from: html)
    }

    // MARK: - Embed page

    private func resolveViaEmbed(shortcode: String) async throws -> ResolverResult {
        // Threads embed pages are lighter renders and sometimes expose
        // the video URL when the main page's JS bundle obscures it.
        guard let embedURL = URL(string: "https://www.threads.net/t/\(shortcode)/embed/") else {
            throw DownloadError.resolutionFailed("couldn't build embed URL.")
        }
        let html = try await Self.fetchHTML(embedURL)
        return try Self.extractMedia(from: html)
    }

    // MARK: - Shared extraction

    /// Try every signal we know about, in order of reliability.
    private static func extractMedia(from html: String) throws -> ResolverResult {
        let title = HTMLScraper.metaContent(html, property: "og:title")
        let thumb = HTMLScraper.metaContent(html, property: "og:image")
                        .flatMap(URL.init(string:))

        // 1. OpenGraph video — the simplest case; Threads populates this
        //    for some public video posts.
        if let s = HTMLScraper.metaContent(html, property: "og:video")
                ?? HTMLScraper.metaContent(html, property: "og:video:secure_url")
                ?? HTMLScraper.metaContent(html, property: "og:video:url"),
           let videoURL = URL(string: s) {
            return ResolverResult(mediaURL: videoURL, title: title,
                                  thumbnailURL: thumb, isVideo: true, platform: .threads)
        }

        // 2. JSON key sweep — Threads embeds Instagram-style React state
        //    that includes `video_url` / `playable_url` for video posts.
        let videoKeys = ["video_url", "playable_url", "playable_url_quality_hd",
                         "videoUrl", "contentUrl"]
        for key in videoKeys {
            if let raw = HTMLScraper.firstCaptureGroup(
                in: html, pattern: "\"\(key)\":\"([^\"]+)\""
            ),
               let decoded = decodeJSONString(raw),
               let videoURL = URL(string: decoded) {
                return ResolverResult(mediaURL: videoURL, title: title,
                                      thumbnailURL: thumb, isVideo: true, platform: .threads)
            }
        }

        // 3. Brute-force: any CDN `.mp4` URL anywhere in the HTML.
        //    Catches future markup changes where the key name shifts again.
        if let raw = HTMLScraper.firstCaptureGroup(
            in: html, pattern: #"(https?://[^"'<\s\\]+\.mp4[^"'<\s\\]*)"#
        ),
           let decoded = decodeJSONString(raw),
           let videoURL = URL(string: decoded) {
            return ResolverResult(mediaURL: videoURL, title: title,
                                  thumbnailURL: thumb, isVideo: true, platform: .threads)
        }

        // 4. Image fallback — photo-only posts or when all video passes fail.
        if let imageURL = thumb {
            return ResolverResult(mediaURL: imageURL, title: title,
                                  thumbnailURL: imageURL, isVideo: false, platform: .threads)
        }

        throw DownloadError.resolutionFailed("no media found in page HTML.")
    }

    // MARK: - Helpers

    private static func fetchHTML(_ url: URL) async throws -> String {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<400).contains(http.statusCode) else {
            throw DownloadError.networkFailed(
                "Threads HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            )
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw DownloadError.resolutionFailed("non-UTF8 response.")
        }
        return html
    }

    /// Extract the post shortcode from a Threads URL.
    ///   https://www.threads.net/@user/post/SHORTCODE  →  SHORTCODE
    ///   https://threads.net/t/SHORTCODE               →  SHORTCODE
    static func extractShortcode(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        if let i = parts.firstIndex(of: "post"), i + 1 < parts.count {
            return parts[i + 1]
        }
        if parts.first == "t", parts.count >= 2 { return parts[1] }
        return nil
    }

    /// Decode the JSON string escapes Threads/Meta CDN URLs use (`\/`, `\uXXXX`).
    private static func decodeJSONString(_ s: String) -> String? {
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\\" {
                let next = s.index(after: i)
                guard next < s.endIndex else { break }
                switch s[next] {
                case "/":  out.append("/");  i = s.index(after: next)
                case "\\": out.append("\\"); i = s.index(after: next)
                case "\"": out.append("\""); i = s.index(after: next)
                case "u":
                    let hexStart = s.index(after: next)
                    guard let hexEnd = s.index(hexStart, offsetBy: 4, limitedBy: s.endIndex),
                          let scalar = UInt32(s[hexStart..<hexEnd], radix: 16),
                          let unicode = Unicode.Scalar(scalar)
                    else { out.append(c); i = s.index(after: i); continue }
                    out.append(Character(unicode))
                    i = hexEnd
                default:
                    out.append(c); i = s.index(after: i)
                }
            } else {
                out.append(c)
                i = s.index(after: i)
            }
        }
        return out
    }
}
