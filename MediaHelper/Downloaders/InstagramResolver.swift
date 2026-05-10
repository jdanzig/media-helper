import Foundation

/// Instagram resolver.
///
/// Strategy (tried in order, first video result wins):
///
///  1. **Private GraphQL API** — POST to `instagram.com/api/graphql` with
///     a known `doc_id` query and `X-IG-App-ID` header. Returns structured
///     JSON with `xdt_shortcode_media.video_url` for public posts without
///     requiring a login cookie. This is the most reliable unauthenticated
///     surface as of 2026.
///     ⚠️  Instagram rotates `doc_id` every few weeks — update
///     `graphqlDocID` when this pass starts failing.
///
///  2. **Canonical page / desktop UA** — og:video meta + inline JSON sweep.
///
///  3. **Embed page** (`…/embed/captioned`) — older JSON shapes.
///
///  4. **Canonical page / iOS app UA** — different server rendering path.
///
/// Private/stories posts require login — surfaced as a clear error.
struct InstagramResolver: MediaResolver {
    let platform: SocialPlatform = .instagram

    /// GraphQL `doc_id` for the `xdt_shortcode_media` query.
    /// Instagram rotates this periodically — update it when pass 1 starts
    /// returning empty `data` objects. Cross-reference with:
    /// github.com/ahmedrangel/instagram-media-scraper
    private static let graphqlDocID = "10015901848480474"

    /// LSD token required by Instagram's GraphQL gateway.
    /// Same value used across all unauthenticated requests (static enough
    /// to hardcode; refresh alongside graphqlDocID if needed).
    private static let lsdToken = "AVqbxe3J_YA"

    /// Instagram's public web app ID. Present in every IG web request;
    /// not a secret — it's embedded in their public JavaScript bundle.
    private static let igAppID = "936619743392459"

    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// Instagram's iOS app User-Agent. Hitting the canonical reel URL
    /// with this UA sometimes nudges the server into rendering the
    /// inline media JSON we need (instead of the JS-only shell that
    /// modern desktop browsers get).
    private static let appUserAgent =
        "Instagram 250.0.0.21.109 (iPhone14,3; iOS 17_0; en_US; en; " +
        "scale=3.00; 1170x2532; 401047810) AppleWebKit/420+"

    /// Whether the URL is unambiguously a video post (`/reel/`, `/tv/`).
    /// `/p/` could be either a photo or a video post — only treat the
    /// reel/IGTV paths as "must be video, otherwise error".
    private static func pathImpliesVideo(_ url: URL) -> Bool {
        let first = url.path.split(separator: "/").first.map(String.init)?.lowercased()
        return first == "reel" || first == "reels" || first == "tv"
    }

    // MARK: - Public resolution entry points

    /// Resolve all media in the post. For carousel/album posts (`/p/`) this
    /// returns every image and video in the sidecar; for single-item posts it
    /// returns a one-element array. Falls back to `resolve()` if the
    /// carousel-aware GraphQL path fails.
    func resolveAll(_ url: URL) async throws -> [ResolverResult] {
        if let sc = Self.extractShortcode(from: url),
           let results = try? await resolveAllViaGraphQL(shortcode: sc),
           !results.isEmpty {
            return results
        }
        // Single-item fallback (also handles Reels / IGTV).
        return [try await resolve(url)]
    }

    func resolve(_ url: URL) async throws -> ResolverResult {
        let pathIsVideo = Self.pathImpliesVideo(url)
        let shortcode = Self.extractShortcode(from: url)

        // 1. Private GraphQL API — structured JSON, no login needed for
        //    public posts. Most reliable as of 2026; try this first.
        if let sc = shortcode,
           let result = try? await resolveViaGraphQL(shortcode: sc),
           result.isVideo {
            return result
        }

        // 2. Canonical page with desktop UA.
        if let result = try? await resolveViaOpenGraph(url, userAgent: Self.desktopUserAgent),
           result.isVideo {
            return result
        }

        // 3. Embed endpoint (`…/embed/captioned`).
        if let sc = shortcode,
           let result = try? await resolveViaEmbed(shortcode: sc),
           result.isVideo {
            return result
        }

        // 4. Canonical page with the IG iOS app UA.
        if let result = try? await resolveViaOpenGraph(url, userAgent: Self.appUserAgent),
           result.isVideo {
            return result
        }

        // 5. Give up. Refuse to silently hand back the thumbnail when
        //    the user pasted a URL whose path means "video" — they
        //    expect a video. Photo-only paths (/p/) get the image.
        if pathIsVideo {
            throw DownloadError.resolutionFailed(
                "couldn't find a public video URL on the Reel page. Instagram may " +
                "be requiring login for this post, or the markup just shifted again."
            )
        }

        // For /p/ paths, try GraphQL for the image too before falling back.
        if let sc = shortcode,
           let result = try? await resolveViaGraphQL(shortcode: sc) {
            return result
        }
        return try await resolveViaOpenGraph(url, userAgent: Self.desktopUserAgent)
    }

    // MARK: - GraphQL API (pass 1)

    /// POST to Instagram's private GraphQL gateway and return the raw
    /// `xdt_shortcode_media` dictionary. Both single-item and carousel-aware
    /// callers share this network path to avoid duplicating request logic.
    ///
    /// Response shape (simplified):
    /// ```json
    /// { "data": { "xdt_shortcode_media": {
    ///     "__typename": "XDTGraphSidecar" | "XDTGraphImage" | "XDTGraphVideo",
    ///     "is_video": true,
    ///     "video_url": "https://…cdn….mp4",
    ///     "display_url": "https://…cdn….jpg",
    ///     "owner": { "username": "…" },
    ///     "edge_sidecar_to_children": { "edges": [ { "node": {…} }, … ] }
    /// }}}
    /// ```
    private func fetchGraphQLMedia(shortcode: String) async throws -> [String: Any] {
        guard let endpoint = URL(string: "https://www.instagram.com/api/graphql") else {
            throw DownloadError.resolutionFailed("couldn't build GraphQL URL.")
        }

        let variables = "{\"shortcode\":\"\(shortcode)\"}"

        // Form-encoded body — Instagram's GraphQL gateway expects
        // application/x-www-form-urlencoded, not application/json.
        var bodyComps = URLComponents()
        bodyComps.queryItems = [
            URLQueryItem(name: "doc_id",    value: Self.graphqlDocID),
            URLQueryItem(name: "lsd",       value: Self.lsdToken),
            URLQueryItem(name: "variables", value: variables)
        ]
        guard let body = bodyComps.percentEncodedQuery?.data(using: .utf8) else {
            throw DownloadError.resolutionFailed("couldn't encode GraphQL body.")
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.httpBody = body
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.desktopUserAgent,                forHTTPHeaderField: "User-Agent")
        req.setValue(Self.igAppID,                         forHTTPHeaderField: "X-IG-App-ID")
        req.setValue(Self.lsdToken,                        forHTTPHeaderField: "X-FB-LSD")
        req.setValue("129477",                             forHTTPHeaderField: "X-ASBD-ID")
        req.setValue("same-origin",                        forHTTPHeaderField: "Sec-Fetch-Site")
        req.setValue("https://www.instagram.com",          forHTTPHeaderField: "Origin")
        req.setValue("https://www.instagram.com/",         forHTTPHeaderField: "Referer")
        req.setValue("en-US,en;q=0.9",                     forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloadError.networkFailed(
                "IG GraphQL HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            )
        }

        guard let json    = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jsonData = json["data"]                    as? [String: Any],
              let media    = jsonData["xdt_shortcode_media"] as? [String: Any] else {
            throw DownloadError.resolutionFailed("GraphQL: unexpected response shape.")
        }
        return media
    }

    /// Carousel-aware resolver. Returns all images/videos in a sidecar post,
    /// or a single-element array for plain photo/video posts.
    private func resolveAllViaGraphQL(shortcode: String) async throws -> [ResolverResult] {
        let media    = try await fetchGraphQLMedia(shortcode: shortcode)
        let username = (media["owner"] as? [String: Any])?["username"] as? String
        let title    = username.map { "@\($0)" }

        // Carousel/sidecar post — extract every child node.
        if let sidecar = media["edge_sidecar_to_children"] as? [String: Any],
           let edges   = sidecar["edges"]                  as? [[String: Any]] {
            var results: [ResolverResult] = []
            for edge in edges {
                guard let node = edge["node"] as? [String: Any] else { continue }
                let isVideo  = node["is_video"] as? Bool ?? false
                let thumbURL = (node["display_url"] as? String).flatMap(URL.init(string:))
                if isVideo,
                   let urlStr   = node["video_url"] as? String,
                   let videoURL = URL(string: urlStr) {
                    results.append(ResolverResult(mediaURL: videoURL, title: title,
                                                  thumbnailURL: thumbURL,
                                                  isVideo: true, platform: .instagram))
                } else if let imageURL = thumbURL {
                    results.append(ResolverResult(mediaURL: imageURL, title: title,
                                                  thumbnailURL: imageURL,
                                                  isVideo: false, platform: .instagram))
                }
            }
            if !results.isEmpty { return results }
        }

        // Single image or video.
        let thumbURL = (media["display_url"] as? String).flatMap(URL.init(string:))
        let isVideo  = media["is_video"] as? Bool ?? false
        if isVideo,
           let urlStr   = media["video_url"] as? String,
           let videoURL = URL(string: urlStr) {
            return [ResolverResult(mediaURL: videoURL, title: title,
                                   thumbnailURL: thumbURL, isVideo: true, platform: .instagram)]
        }
        if let imageURL = thumbURL {
            return [ResolverResult(mediaURL: imageURL, title: title,
                                   thumbnailURL: imageURL, isVideo: false, platform: .instagram)]
        }
        throw DownloadError.resolutionFailed("GraphQL: media found but no URL extracted.")
    }

    /// Single-item resolver (used by `resolve()`). Delegates to
    /// `fetchGraphQLMedia` and returns the first / only result.
    private func resolveViaGraphQL(shortcode: String) async throws -> ResolverResult {
        let media    = try await fetchGraphQLMedia(shortcode: shortcode)
        let username = (media["owner"] as? [String: Any])?["username"] as? String
        let title    = username.map { "@\($0)" }
        let thumbURL = (media["display_url"] as? String).flatMap(URL.init(string:))
        let isVideo  = media["is_video"] as? Bool ?? false

        if isVideo,
           let urlStr   = media["video_url"] as? String,
           let videoURL = URL(string: urlStr) {
            return ResolverResult(mediaURL: videoURL, title: title, thumbnailURL: thumbURL,
                                  isVideo: true, platform: .instagram)
        }
        if let imageURL = thumbURL {
            return ResolverResult(mediaURL: imageURL, title: title, thumbnailURL: imageURL,
                                  isVideo: false, platform: .instagram)
        }
        throw DownloadError.resolutionFailed("GraphQL: media found but no URL extracted.")
    }

    // MARK: - Embed path

    private func resolveViaEmbed(shortcode: String) async throws -> ResolverResult {
        guard let embedURL = URL(string: "https://www.instagram.com/p/\(shortcode)/embed/captioned/") else {
            throw DownloadError.resolutionFailed("couldn't build embed URL.")
        }

        var req = URLRequest(url: embedURL)
        req.timeoutInterval = 15
        req.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
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

    private func resolveViaOpenGraph(_ url: URL,
                                     userAgent: String) async throws -> ResolverResult {
        let html = try await Self.fetchHTML(url, userAgent: userAgent)
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

    /// Fetch a page using a configurable User-Agent. Different UAs get
    /// served different markup by Instagram's edge — desktop returns a
    /// JS shell with no media data for logged-out viewers, while the
    /// in-app UA sometimes inlines the video URL we need.
    private static func fetchHTML(_ url: URL, userAgent: String) async throws -> String {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw DownloadError.networkFailed("IG HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw DownloadError.resolutionFailed("non-UTF8 response.")
        }
        return html
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
