import Foundation

/// Threads resolver (threads.net / threads.com).
///
/// Threads is built on Instagram's infrastructure and renders its posts
/// server-side for logged-out visitors **on threads.net**. The threads.com
/// domain may serve a client-side-only shell that embeds no media data in
/// the initial HTML, so all URLs are normalised to threads.net before fetching.
///
/// The page HTML embeds a React state blob with Instagram-style media fields.
/// Strategy (tried in order):
///
///  1. **threads.net main page** — `og:video`, then JSON key sweep for video
///     (`video_url`, `playable_url`, …), `<source src>` / `<video src>` tags,
///     brute-force `.mp4` scan, JSON key sweep for images (`display_url`, …),
///     brute-force CDN image scan, `og:image` (only if not a static asset or
///     profile picture).
///
///  2. **Embed page** (`/t/<shortcode>/embed/`) — a lighter server render that
///     sometimes exposes the video URL when the main page JS blob hides it.
///
/// Non-media CDN URLs are filtered throughout:
///   - `static.cdninstagram.com` — Meta's static UI assets (logos, icons)
///   - `rsrc.php` — Facebook's static resource CDN
///   - Instagram profile-picture asset type `t51.2885-19`
///   - Small fixed-size avatars (`/s150x150/`, `/s320x320/`)
///
/// Private posts require login — surfaced as a clear error.
///
/// URL forms handled:
///   https://www.threads.net/@user/post/SHORTCODE
///   https://www.threads.com/@user/post/SHORTCODE
///   https://threads.net/t/SHORTCODE
struct ThreadsResolver: MediaResolver {
    let platform: SocialPlatform = .threads

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    func resolve(_ url: URL) async throws -> ResolverResult {
        // Always fetch from threads.net — threads.com may be client-side only
        // and not embed media data in the initial HTML response.
        let netURL = Self.toThreadsNet(url)

        // 1. Main page (threads.net).
        if let result = try? await resolveViaPage(netURL) { return result }

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

        // 1. OpenGraph video — Threads populates this for some public video posts.
        if let s = HTMLScraper.metaContent(html, property: "og:video")
                ?? HTMLScraper.metaContent(html, property: "og:video:secure_url")
                ?? HTMLScraper.metaContent(html, property: "og:video:url"),
           let videoURL = URL(string: s) {
            return ResolverResult(mediaURL: videoURL, title: title,
                                  thumbnailURL: thumb, isVideo: true, platform: .threads)
        }

        // 2. JSON key sweep for video — Threads embeds Instagram-style React
        //    state containing `video_url` / `playable_url` for video posts.
        let videoKeys = ["video_url", "playable_url", "playable_url_quality_hd",
                         "videoUrl", "contentUrl"]
        for key in videoKeys {
            let hits = allDecoded(in: html, pattern: "\"\(key)\":\"([^\"]+)\"")
            if let urlStr = hits.first, let videoURL = URL(string: urlStr) {
                return ResolverResult(mediaURL: videoURL, title: title,
                                      thumbnailURL: thumb, isVideo: true, platform: .threads)
            }
        }

        // 3. <source src> and <video src> tags — some renders put the URL
        //    directly in HTML video elements rather than React state.
        let srcPatterns = [
            #"<source[^>]+src=["']([^"']+\.mp4[^"']*)["']"#,
            #"<video[^>]+src=["']([^"']+\.mp4[^"']*)["']"#,
            #"<source[^>]+src=["'](https?://[^"']+)["'][^>]+type=["']video"#,
        ]
        for pattern in srcPatterns {
            let hits = allDecoded(in: html, pattern: pattern)
            if let urlStr = hits.first, let videoURL = URL(string: urlStr) {
                return ResolverResult(mediaURL: videoURL, title: title,
                                      thumbnailURL: thumb, isVideo: true, platform: .threads)
            }
        }

        // 4. Brute-force .mp4 scan — catches markup changes where key names shift.
        let mp4Hits = allDecoded(in: html,
                                 pattern: #"(https?://[^"'<\s\\]+\.mp4[^"'<\s\\]*)"#)
        if let urlStr = mp4Hits.first, let videoURL = URL(string: urlStr) {
            return ResolverResult(mediaURL: videoURL, title: title,
                                  thumbnailURL: thumb, isVideo: true, platform: .threads)
        }

        // 5. JSON key sweep for post images. We scan ALL occurrences of each
        //    key and skip any URL that looks like a static asset or profile pic.
        let imageKeys = ["display_url", "image_url", "thumbnail_url"]
        for key in imageKeys {
            let hits = allDecoded(in: html, pattern: "\"\(key)\":\"([^\"]+)\"")
            if let urlStr = hits.first(where: { !isNonMediaURL($0) }),
               let imageURL = URL(string: urlStr) {
                return ResolverResult(mediaURL: imageURL, title: title,
                                      thumbnailURL: imageURL, isVideo: false, platform: .threads)
            }
        }

        // 6. Brute-force CDN image scan — user-content CDN only, non-static assets.
        //    Restricts to scontent* hosts (user uploads) to avoid logos/icons.
        let imgHits = allDecoded(
            in: html,
            pattern: #"(https?://scontent[^"'<\s\\]+\.(?:jpg|jpeg|png|webp)[^"'<\s\\]*)"#
        )
        if let urlStr = imgHits.first(where: { !isNonMediaURL($0) }),
           let imageURL = URL(string: urlStr) {
            return ResolverResult(mediaURL: imageURL, title: title,
                                  thumbnailURL: imageURL, isVideo: false, platform: .threads)
        }

        // 7. og:image fallback — only if it looks like user content, not a logo.
        if let imageURL = thumb, !isNonMediaURL(imageURL.absoluteString) {
            return ResolverResult(mediaURL: imageURL, title: title,
                                  thumbnailURL: imageURL, isVideo: false, platform: .threads)
        }

        throw DownloadError.resolutionFailed("no media found in page HTML.")
    }

    // MARK: - Extraction helpers

    /// Return the decoded value of every occurrence of the first capture group
    /// across all regex matches in `html`, with JSON-string decoding applied.
    private static func allDecoded(in html: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern,
                                                options: .caseInsensitive) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return re.matches(in: html, range: range).compactMap { match -> String? in
            guard match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: html) else { return nil }
            return decodeJSONString(String(html[r]))
        }
    }

    /// True for CDN URLs that are static UI assets or profile pictures rather
    /// than user-uploaded post media.
    ///
    /// - `static.cdninstagram.com` — Meta's static CDN for logos, icons, and
    ///   other UI assets. User content lives on `scontent*.cdninstagram.com`.
    /// - `rsrc.php` — Facebook's static resource CDN path (JS, CSS, images).
    /// - `t51.2885-19` — Instagram/Threads CDN asset type for profile pictures.
    /// - Small fixed-size paths — avatars are typically served at `/s150x150/`
    ///   or `/s320x320/`; post media is served at full resolution.
    private static func isNonMediaURL(_ url: String) -> Bool {
        url.contains("static.cdninstagram.com")   // UI logos / icons
        || url.contains("rsrc.php")               // Facebook static resources
        || url.contains("t51.2885-19")            // profile-picture asset type
        || url.contains("profile_pic")
        || url.contains("profile_pics")
        || url.contains("/s150x150/")
        || url.contains("/s320x320/")
    }

    // MARK: - Helpers

    /// Rewrite a threads.com URL to its threads.net equivalent.
    /// threads.com may render client-side only (no media data in initial HTML);
    /// threads.net SSR-renders the React state blob that contains media URLs.
    private static func toThreadsNet(_ url: URL) -> URL {
        let s = url.absoluteString
        guard s.contains("threads.com") else { return url }
        return URL(string: s.replacingOccurrences(of: "threads.com", with: "threads.net")) ?? url
    }

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
