import Foundation

/// Facebook resolver — public videos only.
///
/// Facebook's web player embeds the media URL into the page HTML for
/// logged-out visitors as long as the post is public. Our strategy
/// mirrors the other scrape-style resolvers:
///
///   1. Fetch the page (desktop UA so we get the full markup rather than
///      the skinny mobile "log in to continue" interstitial).
///   2. Try the standard OpenGraph tags (`og:video:secure_url` / `og:video`
///      / `og:image`). These are populated for public Reels, fb.watch
///      shortlinks, and most public Pages videos.
///   3. Fall back to a regex sweep for the `hd_src` / `sd_src` keys that
///      Facebook inlines into their bootstrap JSON for public videos.
///   4. If we get nothing, surface a clear message: it's almost
///      certainly a private or login-gated post.
///
/// TODO: Authenticated/private content would require capturing the
///       user's `c_user` + `xs` cookies via an in-app WebView and
///       passing them to the video CDN. Out of scope — we fail cleanly.
struct FacebookResolver: MediaResolver {
    let platform: SocialPlatform = .facebook

    func resolve(_ url: URL) async throws -> ResolverResult {
        // Try the desktop site first (richer og: tags), then the mobile
        // site if that fails. The desktop React shell often omits inline
        // video URLs for logged-out viewers, while m.facebook.com still
        // serves them in a more scrape-friendly markup.
        if let result = try? await scrape(url, mobile: false), result.isVideo {
            return result
        }
        if let mobileURL = Self.mobileVariant(of: url),
           let result = try? await scrape(mobileURL, mobile: true), result.isVideo {
            return result
        }

        // Last resort — desktop again, accepting an image / image fallback
        // if that's all there is. (Most likely path to the "couldn't find"
        // error message.)
        return try await scrape(url, mobile: false)
    }

    // MARK: -

    private func scrape(_ url: URL, mobile: Bool) async throws -> ResolverResult {
        let html = try await Self.fetchHTML(url, mobile: mobile)

        let title = HTMLScraper.metaContent(html, property: "og:title")
        let thumb = HTMLScraper.metaContent(html, property: "og:image").flatMap(URL.init(string:))

        // 1. OpenGraph video
        if let videoString = HTMLScraper.metaContent(html, property: "og:video:secure_url")
            ?? HTMLScraper.metaContent(html, property: "og:video")
            ?? HTMLScraper.metaContent(html, property: "og:video:url"),
           let videoURL = URL(string: videoString) {
            return ResolverResult(
                mediaURL: videoURL, title: title, thumbnailURL: thumb,
                isVideo: true, platform: .facebook
            )
        }

        // 2. Inline-JSON sweep. FB inlines things like `"hd_src":"https:\/\/..."`
        // for public videos; preference order: HD > SD > native > playable.
        let keys = [
            "hd_src", "sd_src",
            "browser_native_hd_url", "browser_native_sd_url",
            "playable_url_quality_hd", "playable_url",
            "videoUrl", "video_url"
        ]
        for key in keys {
            if let raw = HTMLScraper.firstCaptureGroup(
                in: html, pattern: "\"\(key)\":\"([^\"]+)\""
            ) {
                let cleaned = Self.decodeJSONString(raw)
                if let videoURL = URL(string: cleaned) {
                    return ResolverResult(
                        mediaURL: videoURL, title: title, thumbnailURL: thumb,
                        isVideo: true, platform: .facebook
                    )
                }
            }
        }

        // 3. Brute-force scan for any `https://…mp4` URL in the HTML —
        // catches CDN-direct links that aren't behind a known JSON key.
        if let mp4 = HTMLScraper.firstCaptureGroup(
            in: html,
            pattern: #"(https?://[^"\\]+\.mp4[^"\\]*)"#
        ).flatMap({ URL(string: Self.decodeJSONString($0)) }) {
            return ResolverResult(
                mediaURL: mp4, title: title, thumbnailURL: thumb,
                isVideo: true, platform: .facebook
            )
        }

        // 4. Image fallback for FB photo posts.
        if let img = thumb,
           html.range(of: "og:image", options: .caseInsensitive) != nil,
           html.range(of: "og:video", options: .caseInsensitive) == nil {
            return ResolverResult(
                mediaURL: img, title: title, thumbnailURL: img,
                isVideo: false, platform: .facebook
            )
        }

        throw DownloadError.resolutionFailed(
            "couldn't find a public video on that page. Private or login-gated posts aren't supported."
        )
    }

    /// Fetch a Facebook page using either a desktop or a mobile UA.
    private static func fetchHTML(_ url: URL, mobile: Bool) async throws -> String {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(mobile ? mobileUserAgent : desktopUserAgent,
                     forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw DownloadError.networkFailed("FB HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw DownloadError.resolutionFailed("non-UTF8 response.")
        }
        return html
    }

    /// Rewrite `www.facebook.com` → `m.facebook.com` for the mobile retry.
    /// `fb.watch` short links are returned as-is; the mobile UA on those
    /// already gets the simpler markup.
    private static func mobileVariant(of url: URL) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let host = comps.host?.lowercased() else { return nil }
        switch host {
        case "facebook.com", "www.facebook.com":
            comps.host = "m.facebook.com"
            return comps.url
        case "m.facebook.com":
            return nil // already mobile
        default:
            return url // fb.watch / other hosts: don't rewrite, just retry with mobile UA
        }
    }

    /// JSON string-escape decoder — `\uXXXX` plus the bare backslash
    /// forms. Same logic as TikTokResolver; kept local to avoid a
    /// utility dependency.
    private static func decodeJSONString(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\\" {
                let next = s.index(after: i)
                guard next < s.endIndex else { out.append(c); break }
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

    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
}
