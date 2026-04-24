import Foundation

/// X / Twitter resolver using the public **syndication** endpoint.
///
/// `cdn.syndication.twimg.com/tweet-result` is the JSON feed that powers
/// Twitter's embeddable tweet widgets. It doesn't require login or an
/// auth bearer, returns the full video variant list, and ignores the
/// x.com rebrand. This is the same path most "download tweet video"
/// sites take.
///
/// Variants look like:
///   { content_type: "video/mp4", bitrate: 2176000, url: "https://…/vid/…" }
///   { content_type: "application/x-mpegURL", url: "https://…/m3u8" }
///
/// We pick the highest-bitrate MP4, skipping HLS (the downloader
/// doesn't stitch m3u8 chunks — see MediaDownloader for why).
///
/// Fallback chain:
///   1. Syndication JSON (primary — works for public tweets)
///   2. og:video / og:image scrape (our original best-effort path)
///
/// TODO: For protected or age-gated tweets, the syndication endpoint
///       returns `tombstone` instead of media. A guest-token GraphQL
///       call could handle those — left as follow-up work.
struct TwitterResolver: MediaResolver {
    let platform: SocialPlatform = .twitter

    func resolve(_ url: URL) async throws -> ResolverResult {
        // First try the syndication path. It's fast, auth-free, and
        // handles both twitter.com and x.com URLs the same way.
        if let tweetID = Self.extractTweetID(from: url),
           let result = try? await resolveViaSyndication(tweetID: tweetID) {
            return result
        }

        // Fall back to meta-tag scraping.
        return try await resolveViaOpenGraph(url)
    }

    // MARK: - Syndication

    private func resolveViaSyndication(tweetID: String) async throws -> ResolverResult {
        let token = Self.syndicationToken(for: tweetID)
        var comps = URLComponents(string: "https://cdn.syndication.twimg.com/tweet-result")!
        comps.queryItems = [
            URLQueryItem(name: "id", value: tweetID),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "lang", value: "en")
        ]
        guard let endpoint = comps.url else {
            throw DownloadError.resolutionFailed("bad syndication URL.")
        }

        var req = URLRequest(url: endpoint)
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 " +
            "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("https://platform.twitter.com", forHTTPHeaderField: "Referer")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloadError.networkFailed("syndication HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DownloadError.resolutionFailed("syndication returned non-JSON.")
        }

        // `mediaDetails` is an array; videos have `video_info.variants`.
        let mediaDetails = json["mediaDetails"] as? [[String: Any]] ?? []
        let title = (json["text"] as? String)
            ?? ((json["user"] as? [String: Any])?["name"] as? String)

        // Prefer the first media entry that has video; fall back to the
        // first with a photo.
        if let videoEntry = mediaDetails.first(where: { ($0["type"] as? String) == "video"
                                                      || ($0["type"] as? String) == "animated_gif" }),
           let videoInfo = videoEntry["video_info"] as? [String: Any],
           let variants = videoInfo["variants"] as? [[String: Any]],
           let best = Self.pickBestVariant(variants),
           let urlStr = best["url"] as? String,
           let mediaURL = URL(string: urlStr) {

            let thumb = (videoEntry["media_url_https"] as? String).flatMap(URL.init(string:))
            return ResolverResult(
                mediaURL: mediaURL,
                title: title,
                thumbnailURL: thumb,
                isVideo: true,
                platform: .twitter
            )
        }

        if let photo = mediaDetails.first(where: { ($0["type"] as? String) == "photo" }),
           let urlStr = photo["media_url_https"] as? String,
           let mediaURL = URL(string: urlStr) {
            return ResolverResult(
                mediaURL: mediaURL,
                title: title,
                thumbnailURL: mediaURL,
                isVideo: false,
                platform: .twitter
            )
        }

        throw DownloadError.resolutionFailed("syndication returned no media.")
    }

    /// Pick the highest-bitrate MP4 variant; skip HLS (m3u8).
    private static func pickBestVariant(_ variants: [[String: Any]]) -> [String: Any]? {
        let mp4s = variants.filter { ($0["content_type"] as? String) == "video/mp4" }
        return mp4s.max { a, b in
            ((a["bitrate"] as? Int) ?? 0) < ((b["bitrate"] as? Int) ?? 0)
        }
    }

    // MARK: - OpenGraph fallback

    private func resolveViaOpenGraph(_ url: URL) async throws -> ResolverResult {
        let normalized: URL = {
            guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
            if c.host?.hasSuffix("x.com") == true { c.host = "twitter.com" }
            return c.url ?? url
        }()

        let html: String
        do { html = try await HTMLScraper.fetchHTML(normalized) }
        catch { throw DownloadError.networkFailed(error.localizedDescription) }

        let title = HTMLScraper.metaContent(html, property: "og:title")
        let thumb = HTMLScraper.metaContent(html, property: "og:image").flatMap(URL.init(string:))

        if let videoString = HTMLScraper.metaContent(html, property: "og:video")
            ?? HTMLScraper.metaContent(html, property: "og:video:url"),
           let videoURL = URL(string: videoString) {
            return ResolverResult(mediaURL: videoURL, title: title, thumbnailURL: thumb,
                                  isVideo: true, platform: .twitter)
        }
        if let imageURL = thumb {
            return ResolverResult(mediaURL: imageURL, title: title, thumbnailURL: imageURL,
                                  isVideo: false, platform: .twitter)
        }

        throw DownloadError.resolutionFailed(
            "the tweet may require login, or Twitter stopped emitting og tags."
        )
    }

    // MARK: - URL parsing + token derivation

    /// Tweet ID is the trailing numeric path component after `/status/`.
    static func extractTweetID(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: "status"), i + 1 < parts.count else { return nil }
        let candidate = parts[i + 1]
        return candidate.allSatisfy(\.isNumber) ? candidate : nil
    }

    /// Replicates the JS snippet Twitter's widget loader uses:
    ///   ((Number(id) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, "")
    ///
    /// Big tweet IDs exceed Double precision, but we only need the leading
    /// digits — the server accepts any token derived from this formula.
    static func syndicationToken(for tweetID: String) -> String {
        guard let n = Double(tweetID) else { return "a" }
        let v = (n / 1e15) * .pi
        var base36 = radix36(v)
        base36 = base36.replacingOccurrences(of: "0", with: "")
                       .replacingOccurrences(of: ".", with: "")
        return base36.isEmpty ? "a" : base36
    }

    /// Produce a base-36 string approximation of a Double, mirroring JS
    /// `Number#toString(36)` closely enough for the syndication token.
    private static func radix36(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        var whole = Int64(value)
        var frac = value - Double(whole)

        let digits = "0123456789abcdefghijklmnopqrstuvwxyz"
        let d = Array(digits)

        func intToBase36(_ x: Int64) -> String {
            if x == 0 { return "0" }
            var n = x
            var out: [Character] = []
            while n > 0 {
                out.append(d[Int(n % 36)])
                n /= 36
            }
            return String(out.reversed())
        }

        var result = intToBase36(whole)
        if frac > 0 {
            result += "."
            for _ in 0..<11 {
                frac *= 36
                let k = Int(frac)
                result.append(d[k])
                frac -= Double(k)
                if frac <= 0 { break }
            }
        }
        return result
    }
}
