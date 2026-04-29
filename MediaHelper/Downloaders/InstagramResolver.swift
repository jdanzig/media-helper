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
        // Instagram's embed endpoint started obfuscating `video_url` for
        // some Reels in 2024-2025 — the JSON field is sometimes missing
        // even though the post is a video, so we'd fall through to
        // `display_url` and silently return the thumbnail. Try og:video
        // on the canonical page first; it's set for public Reels and
        // is the source of truth.
        if let result = try? await resolveViaOpenGraph(url), result.isVideo {
            return result
        }

        // Embed fallback for posts where og:video isn't populated.
        if let shortcode = Self.extractShortcode(from: url),
           let result = try? await resolveViaEmbed(shortcode: shortcode), result.isVideo {
            return result
        }

        // Last resort: rerun og:video parse and accept whatever it gives
        // (image fallback). At this point we know it's not a video, so
        // returning an image is the best we can do.
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

        // Videos: try several keys in order. Instagram has shipped at
        // least three shapes in the last few years:
        //   "video_url":"…"          (older)
        //   "videoUrl":"…"           (newer GraphQL passthrough)
        //   inside JSON-LD: "contentUrl":"…"
        let videoKeys = ["video_url", "videoUrl", "contentUrl"]
        for key in videoKeys {
            if let s = Self.extractEscapedString(html: html, key: key),
               let videoURL = URL(string: s) {
                let thumb = Self.extractEscapedString(html: html, key: "display_url")
                    .flatMap(URL.init(string:))
                return ResolverResult(
                    mediaURL: videoURL, title: title, thumbnailURL: thumb,
                    isVideo: true, platform: .instagram
                )
            }
        }

        // og:video on the embed page (Instagram populates this for some
        // posts even when the inlined JSON has been gutted).
        if let videoString = HTMLScraper.metaContent(html, property: "og:video")
            ?? HTMLScraper.metaContent(html, property: "og:video:secure_url"),
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

        // 1. og:video meta — works for some public posts.
        if let videoString = HTMLScraper.metaContent(html, property: "og:video")
            ?? HTMLScraper.metaContent(html, property: "og:video:secure_url"),
           let videoURL = URL(string: videoString) {
            return ResolverResult(mediaURL: videoURL, title: title, thumbnailURL: thumb,
                                  isVideo: true, platform: .instagram)
        }

        // 2. Modern Reels inline the video URL inside script JSON. Try
        // every shape we know about, in roughly preferred order.
        let inlineKeys = ["playable_url_quality_hd", "playable_url",
                          "video_url", "videoUrl", "contentUrl"]
        for key in inlineKeys {
            if let candidate = Self.extractEscapedString(html: html, key: key),
               let videoURL = URL(string: candidate) {
                return ResolverResult(mediaURL: videoURL, title: title, thumbnailURL: thumb,
                                      isVideo: true, platform: .instagram)
            }
        }

        // 3. `video_versions` array. Modern shape:
        //    "video_versions":[{"type":101,"width":720,"height":1280,
        //    "url":"https:\/\/scontent.cdninstagram.com\/...\.mp4..."}, ...]
        // First `"url":"…"` after the array opens is good enough.
        if let candidate = Self.extractFirstURLAfter(
            anchor: "\"video_versions\":[",
            in: html
        ), let videoURL = URL(string: candidate) {
            return ResolverResult(mediaURL: videoURL, title: title, thumbnailURL: thumb,
                                  isVideo: true, platform: .instagram)
        }

        // 4. Brute force: any `https://...mp4` URL anywhere in the HTML.
        //    Catches future markup shifts where the key changes again.
        if let candidate = Self.extractFirstMP4(in: html),
           let videoURL = URL(string: candidate) {
            return ResolverResult(mediaURL: videoURL, title: title, thumbnailURL: thumb,
                                  isVideo: true, platform: .instagram)
        }

        // 5. As a last resort, hand back the still image. The app's
        //    caller can decide whether that's what the user wanted.
        if let imageURL = thumb {
            return ResolverResult(mediaURL: imageURL, title: title, thumbnailURL: imageURL,
                                  isVideo: false, platform: .instagram)
        }

        throw DownloadError.resolutionFailed(
            "post likely requires login; sign-in flow not implemented."
        )
    }

    /// Find the first `"url":"…"` value occurring after a given anchor
    /// substring, decoding JSON escapes. Used to pluck the first entry
    /// out of `"video_versions":[ {…"url":"…"…}, … ]`.
    private static func extractFirstURLAfter(anchor: String, in html: String) -> String? {
        guard let anchorRange = html.range(of: anchor) else { return nil }
        let tail = String(html[anchorRange.upperBound...])
        guard let value = HTMLScraper.firstCaptureGroup(
            in: tail, pattern: "\"url\":\"([^\"]+)\""
        ) else { return nil }
        return decodeJSONString(value)
    }

    /// Brute-force scan for any `https://…mp4` URL in the HTML. We let
    /// the JSON unescape pass run over the captured string in case the
    /// match crossed an encoded slash (`\/`).
    private static func extractFirstMP4(in html: String) -> String? {
        guard let raw = HTMLScraper.firstCaptureGroup(
            in: html,
            pattern: #"(https?:[^"\\]+?\.mp4[^"\\]*)"#
        ) else { return nil }
        return decodeJSONString(raw)
    }

    /// Decode the subset of JSON string escapes Instagram uses:
    /// `\uXXXX`, `\/`, `\\`, `\"`. Mirrors the helpers in
    /// `TikTokResolver` / `FacebookResolver`.
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
        return decodeJSONString(raw)
    }
}
