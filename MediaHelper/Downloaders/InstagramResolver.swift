import Foundation

/// Instagram resolver.
///
/// Instagram walled off its public GraphQL endpoints, but the public
/// **embed page** (`instagram.com/{reel|p|tv}/{shortcode}/embed/captioned`)
/// still renders a non-auth HTML page with the full media payload
/// embedded as a JSON literal inside a `<script>`. Most "download
/// Instagram video" sites use exactly this endpoint — it's the last
/// unauthenticated surface that still exposes media URLs reliably.
///
/// Strategy:
///  1. Normalize the URL → extract shortcode → hit `…/embed/captioned`.
///  2. Scan the HTML for the inlined JSON containing `video_url` /
///     `display_url`.
///  3. Unicode-unescape and return. For carousels, the embed shows only
///     the first slide — that's the common case and matches what
///     public sites deliver.
///  4. Fall back to the classic og:video / og:image scrape.
///
/// TODO: Private posts and most stories now require login. A production
///       implementation would wrap an in-app WebView to collect the
///       user's session cookies, then POST to `i.instagram.com/api/v1/
///       media/{id}/info/`. Out of scope here; error surfaced clearly.
struct InstagramResolver: MediaResolver {
    let platform: SocialPlatform = .instagram

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    func resolve(_ url: URL) async throws -> ResolverResult {
        // 1. Try the embed endpoint.
        if let shortcode = Self.extractShortcode(from: url),
           let result = try? await resolveViaEmbed(shortcode: shortcode) {
            return result
        }

        // 2. Fall back to scraping og:video on the regular page.
        return try await resolveViaOpenGraph(url)
    }

    // MARK: - Embed path

    private func resolveViaEmbed(shortcode: String) async throws -> ResolverResult {
        guard let embedURL = URL(string: "https://www.instagram.com/p/\(shortcode)/embed/captioned/") else {
            throw DownloadError.resolutionFailed("couldn't build embed URL.")
        }

        var req = URLRequest(url: embedURL)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw DownloadError.networkFailed("embed HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw DownloadError.resolutionFailed("non-UTF8 embed response.")
        }

        let title = HTMLScraper.firstCaptureGroup(
            in: html, pattern: #"<div class="CaptionUsername"[^>]*>([^<]+)</div>"#
        ) ?? HTMLScraper.metaContent(html, property: "og:title")

        // Videos: the inlined JSON uses the key `"video_url":"…"`.
        if let videoString = Self.extractEscapedString(html: html, key: "video_url"),
           let videoURL = URL(string: videoString) {
            let thumb = Self.extractEscapedString(html: html, key: "display_url")
                .flatMap(URL.init(string:))
            return ResolverResult(
                mediaURL: videoURL, title: title, thumbnailURL: thumb,
                isVideo: true, platform: .instagram
            )
        }

        // Photos: `display_url` is the full-res image.
        if let imageString = Self.extractEscapedString(html: html, key: "display_url"),
           let imageURL = URL(string: imageString) {
            return ResolverResult(
                mediaURL: imageURL, title: title, thumbnailURL: imageURL,
                isVideo: false, platform: .instagram
            )
        }

        throw DownloadError.resolutionFailed("embed page had no media fields.")
    }

    // MARK: - OpenGraph fallback

    private func resolveViaOpenGraph(_ url: URL) async throws -> ResolverResult {
        let html = try await HTMLScraper.fetchHTML(url)
        let title = HTMLScraper.metaContent(html, property: "og:title")
        let thumb = HTMLScraper.metaContent(html, property: "og:image").flatMap(URL.init(string:))

        if let videoString = HTMLScraper.metaContent(html, property: "og:video")
            ?? HTMLScraper.metaContent(html, property: "og:video:secure_url"),
           let videoURL = URL(string: videoString) {
            return ResolverResult(mediaURL: videoURL, title: title, thumbnailURL: thumb,
                                  isVideo: true, platform: .instagram)
        }
        if let imageURL = thumb {
            return ResolverResult(mediaURL: imageURL, title: title, thumbnailURL: imageURL,
                                  isVideo: false, platform: .instagram)
        }

        throw DownloadError.resolutionFailed(
            "post likely requires login; sign-in flow not implemented."
        )
    }

    // MARK: - Parsing helpers

    /// Find the 11-ish-char shortcode in `/p/…`, `/reel/…`, `/reels/…`, `/tv/…`.
    static func extractShortcode(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2,
              ["p", "reel", "reels", "tv"].contains(parts[0].lowercased()) else { return nil }
        let candidate = parts[1]
        // Shortcodes are [A-Za-z0-9_-].
        return candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
            ? candidate : nil
    }

    /// Scan for `"key":"…"` in a JSON-in-HTML blob, decoding the common
    /// Instagram escape sequences: `\u0026` (ampersand), `\/`, `\u0022`.
    private static func extractEscapedString(html: String, key: String) -> String? {
        guard let raw = HTMLScraper.firstCaptureGroup(
            in: html, pattern: "\"\(key)\":\"([^\"]+)\""
        ) else { return nil }
        return raw
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\u0025", with: "%")
            .replacingOccurrences(of: "\\u0022", with: "\"")
            .replacingOccurrences(of: "\\/", with: "/")
    }
}
