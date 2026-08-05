import Foundation

/// Facebook resolver — public videos only.
///
/// Facebook's web player embeds the media URL into the page HTML for
/// logged-out visitors as long as the post is public. Our strategy
/// mirrors the other scrape-style resolvers, with a few FB-specific tricks:
///
///   1. Fetch the canonical desktop page (richest og: tags + inlined JSON).
///   2. Fetch the mobile page (`m.facebook.com`), which uses simpler markup.
///   3. Try the lightweight `/video/embed?video_id=<id>` iframe page —
///      this is what third-party embeds load, and FB keeps it scrape-
///      friendly because it can't require login from embedding sites.
///   4. Brute-force scan for any `.mp4` URL across all collected HTML blobs.
///
/// Each pass tries og:video meta, then an inline JSON key sweep, then a
/// raw .mp4 scan. We stop as soon as we find a video.
///
/// TODO: Authenticated/private content would require capturing the
///       user's `c_user` + `xs` cookies via an in-app WebView and
///       passing them to the video CDN. Out of scope — we fail cleanly.
struct FacebookResolver: MediaResolver {
    let platform: SocialPlatform = .facebook

    func resolve(_ url: URL) async throws -> ResolverResult {
        // 1. Desktop UA on the canonical URL.
        if let result = try? await scrape(url, mobile: false), result.isVideo {
            return result
        }
        // 2. Mobile UA on m.facebook.com — simpler server-side markup.
        if let mobileURL = Self.mobileVariant(of: url),
           let result = try? await scrape(mobileURL, mobile: true), result.isVideo {
            return result
        }
        // 3. Lightweight iframe embed page. Works for fb.watch + /watch/?v=
        //    + /username/videos/<id>/ because FB can't require auth there.
        if let videoID = try? await Self.resolveVideoID(from: url),
           let embedURL = URL(string: "https://www.facebook.com/video/embed?video_id=\(videoID)"),
           let result = try? await scrape(embedURL, mobile: false), result.isVideo {
            return result
        }
        // Last resort: desktop again, accepting image fallback if present.
        return try await scrape(url, mobile: false)
    }

    // MARK: - Core scrape

    private func scrape(_ url: URL, mobile: Bool) async throws -> ResolverResult {
        let html = try await Self.fetchHTML(url, mobile: mobile)

        let title = HTMLScraper.metaContent(html, property: "og:title")
        let thumb = HTMLScraper.metaContent(html, property: "og:image").flatMap(URL.init(string:))

        // 1. OpenGraph video.
        if let videoString = HTMLScraper.metaContent(html, property: "og:video:secure_url")
            ?? HTMLScraper.metaContent(html, property: "og:video")
            ?? HTMLScraper.metaContent(html, property: "og:video:url"),
           let videoURL = URL(string: videoString) {
            return ResolverResult(
                mediaURL: videoURL, title: title, thumbnailURL: thumb,
                isVideo: true, platform: .facebook
            )
        }

        // 2. Inline-JSON sweep. Facebook inlines things like
        //    `"hd_src":"https:\/\/..."` for public videos. Preference:
        //    HD > SD > native HD/SD > playable > generic.
        let keys = [
            "hd_src", "sd_src",
            "browser_native_hd_url", "browser_native_sd_url",
            "playable_url_quality_hd", "playable_url",
            "videoUrl", "video_url",
            "hd_src_no_ratelimit", "sd_src_no_ratelimit",
            "dash_manifest"          // rarely a direct URL but worth a try
        ]
        for key in keys {
            if let raw = HTMLScraper.firstCaptureGroup(
                in: html, pattern: "\"\(key)\":\"([^\"]+)\""
            ) {
                let cleaned = Self.decodeJSONString(raw)
                // Skip manifest playlists — we only want direct .mp4 / CDN URLs.
                guard !cleaned.contains(".mpd"), !cleaned.contains("<MPD"),
                      let videoURL = URL(string: cleaned) else { continue }
                return ResolverResult(
                    mediaURL: videoURL, title: title, thumbnailURL: thumb,
                    isVideo: true, platform: .facebook
                )
            }
        }

        // 3. Brute-force scan for any `https://…mp4` URL in the HTML.
        if let mp4 = HTMLScraper.firstCaptureGroup(
            in: html,
            pattern: #"(https?://[^"'<\s\\]+\.mp4[^"'<\s\\]*)"#
        ).flatMap({ URL(string: Self.decodeJSONString($0)) }) {
            return ResolverResult(
                mediaURL: mp4, title: title, thumbnailURL: thumb,
                isVideo: true, platform: .facebook
            )
        }

        // 4. Image fallback for photo posts (only when there's zero hint of
        //    a video on the page).
        if let img = thumb,
           html.range(of: "og:image", options: .caseInsensitive) != nil,
           html.range(of: "og:video", options: .caseInsensitive) == nil,
           html.range(of: "mp4", options: .caseInsensitive) == nil {
            return ResolverResult(
                mediaURL: img, title: title, thumbnailURL: img,
                isVideo: false, platform: .facebook
            )
        }

        throw DownloadError.resolutionFailed(
            "couldn't find a public video on that page. Private or login-gated posts aren't supported."
        )
    }

    // MARK: - Video ID helpers

    /// Resolve a Facebook URL to a numeric video ID. For `fb.watch` and
    /// `/watch/?v=<id>` patterns this is trivial; for deep page URLs we
    /// follow the redirect chain to reach the canonical form.
    private static func resolveVideoID(from url: URL) async throws -> String {
        // fb.watch short links redirect to the canonical /video/... URL.
        let canonical: URL
        if let host = url.host?.lowercased(), host.contains("fb.watch") {
            canonical = try await Self.followRedirect(from: url)
        } else {
            canonical = url
        }
        guard let id = extractVideoID(from: canonical) else {
            throw DownloadError.resolutionFailed("can't extract FB video ID")
        }
        return id
    }

    /// Extract a numeric video ID from a canonical Facebook URL:
    ///  - `/watch/?v=<id>` or `/video.php?v=<id>`
    ///  - `/<username>/videos/<id>/`
    ///  - `/reel/<id>/` or `/reels/<id>/`
    ///  - `?story_fbid=<id>` (story embeds)
    static func extractVideoID(from url: URL) -> String? {
        // Query param "v" — most common for /watch and /video.php URLs.
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = comps.queryItems?.first(where: { $0.name == "v" })?.value,
           v.allSatisfy(\.isNumber) {
            return v
        }
        let parts = url.path.split(separator: "/").map(String.init)
        // /videos/<id> or /reel/<id> or /reels/<id>
        for (i, part) in parts.enumerated() {
            let lower = part.lowercased()
            if (lower == "videos" || lower == "reel" || lower == "reels"),
               i + 1 < parts.count,
               parts[i + 1].allSatisfy(\.isNumber) {
                return parts[i + 1]
            }
        }
        // /video/<id>/
        if parts.first?.lowercased() == "video", parts.count >= 2,
           parts[1].allSatisfy(\.isNumber) {
            return parts[1]
        }
        return nil
    }

    /// Follow a single redirect (used for fb.watch short links).
    /// Stops after one hop to keep things simple — fb.watch always
    /// redirects directly to the canonical facebook.com URL.
    private static func followRedirect(from url: URL) async throws -> URL {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 8
        req.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        // Disable automatic redirect following so we can read Location.
        let delegate = NoFollowDelegate()
        let (_, resp) = try await URLSession.shared.data(for: req, delegate: delegate)
        if let http = resp as? HTTPURLResponse,
           (300..<400).contains(http.statusCode),
           let loc = http.value(forHTTPHeaderField: "Location"),
           let next = URL(string: loc, relativeTo: url)?.absoluteURL {
            return next
        }
        return url
    }

    private final class NoFollowDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    // MARK: - Networking

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

    // MARK: - JSON escape decoder

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
                case "n":  out.append("\n"); i = s.index(after: next)
                case "r":  out.append("\r"); i = s.index(after: next)
                case "t":  out.append("\t"); i = s.index(after: next)
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

    // MARK: - User Agents

    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
}
