import Foundation

/// YouTube resolver using the **InnerTube** private API.
///
/// Public downloaders (yt-dlp, cobalt, etc.) work by calling YouTube's
/// internal `youtubei/v1/player` endpoint with a client context that
/// mimics the first-party iOS / Android apps. Those clients receive
/// stream URLs directly in the response — no JavaScript "signature
/// cipher" to reverse, no WebView needed.
///
/// We pose as the iOS YouTube app here because that client historically
/// returns the widest set of progressive (muxed audio+video) MP4s. If
/// Google tightens this, swap `clientName` to `ANDROID` or
/// `WEB_EMBEDDED_PLAYER` — the rest of the code stays the same.
///
/// Known limits:
///  - Age-gated videos usually need the `TVHTML5_SIMPLY_EMBEDDED_PLAYER`
///    client. TODO: retry with that client when `playabilityStatus` is
///    `LOGIN_REQUIRED`.
///  - Live streams return HLS manifests (m3u8) rather than a single
///    progressive MP4. The downloader doesn't handle HLS assembly.
struct YouTubeResolver: MediaResolver {
    let platform: SocialPlatform = .youtube

    // Publicly known key the YouTube iOS app uses to authenticate
    // against the InnerTube gateway. Not a secret — it ships in every
    // `youtubei` request the app makes.
    private static let innertubeKey = "AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc"
    private static let clientVersion = "19.09.3"
    private static let userAgent = "com.google.ios.youtube/19.09.3 (iPhone14,3; U; CPU iOS 15_6 like Mac OS X)"

    func resolve(_ url: URL) async throws -> ResolverResult {
        guard let videoID = Self.extractVideoID(from: url) else {
            throw DownloadError.resolutionFailed("couldn't find a video ID in that URL.")
        }

        let endpoint = URL(string:
            "https://youtubei.googleapis.com/youtubei/v1/player?key=\(Self.innertubeKey)"
        )!

        // Matches what the iOS app sends. Keys are order-insensitive.
        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "IOS",
                    "clientVersion": Self.clientVersion,
                    "deviceModel": "iPhone14,3",
                    "hl": "en",
                    "timeZone": "UTC",
                    "utcOffsetMinutes": 0
                ]
            ],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        do {
            let (d, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw DownloadError.networkFailed("InnerTube HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            data = d
        } catch let e as DownloadError { throw e }
        catch { throw DownloadError.networkFailed(error.localizedDescription) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DownloadError.resolutionFailed("InnerTube returned a non-JSON response.")
        }

        // Surface Google's own error string if playback is blocked.
        if let playability = json["playabilityStatus"] as? [String: Any],
           let status = playability["status"] as? String,
           status != "OK" {
            let reason = (playability["reason"] as? String) ?? status
            throw DownloadError.resolutionFailed("YouTube says: \(reason)")
        }

        guard let streamingData = json["streamingData"] as? [String: Any] else {
            throw DownloadError.resolutionFailed("no streamingData in InnerTube response.")
        }

        // `formats` is the progressive (single-file) list; `adaptiveFormats`
        // are DASH (split audio+video). We prefer progressive so the
        // downloader can hand the file straight to Photos.
        let progressive = (streamingData["formats"] as? [[String: Any]]) ?? []

        guard let best = Self.pickBestProgressive(progressive) else {
            throw DownloadError.resolutionFailed(
                "no progressive MP4 available (this video may be adaptive-only — " +
                "merging audio+video DASH streams is a TODO)."
            )
        }
        guard let urlString = best["url"] as? String, let mediaURL = URL(string: urlString) else {
            throw DownloadError.resolutionFailed("chosen format had no direct URL.")
        }

        let details = json["videoDetails"] as? [String: Any]
        let title = details?["title"] as? String
        let thumbs = ((details?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]) ?? []
        let thumbURL = (thumbs.last?["url"] as? String).flatMap(URL.init(string:))

        return ResolverResult(
            mediaURL: mediaURL,
            title: title,
            thumbnailURL: thumbURL,
            isVideo: true,
            platform: .youtube
        )
    }

    // MARK: - Helpers

    /// Extract the 11-character video ID from any youtube URL form:
    /// `youtube.com/watch?v=…`, `youtu.be/…`, `/shorts/…`, `/embed/…`, `/live/…`.
    static func extractVideoID(from url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }

        // Short-link host: the first path component IS the ID.
        if host.hasSuffix("youtu.be") {
            let comp = url.path.split(separator: "/").first.map(String.init)
            return comp.flatMap(sanitizeID)
        }

        // /watch?v=ID
        if url.path == "/watch",
           let qi = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let id = qi.first(where: { $0.name == "v" })?.value {
            return sanitizeID(id)
        }

        // /shorts/ID, /embed/ID, /live/ID, /v/ID
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]) {
            return sanitizeID(parts[1])
        }

        return nil
    }

    private static func sanitizeID(_ raw: String) -> String? {
        // IDs are [A-Za-z0-9_-] and typically 11 chars. Strip anything after
        // a query-like char to tolerate share suffixes.
        let cleaned = raw.split(whereSeparator: { "?&#".contains($0) }).first.map(String.init) ?? raw
        guard cleaned.count >= 11,
              cleaned.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        return String(cleaned.prefix(11))
    }

    /// Pick the highest-quality progressive MP4 that isn't DRM-locked.
    /// Rough ranking: 720p > 360p > others; MP4 > WebM as a tiebreaker.
    private static func pickBestProgressive(_ formats: [[String: Any]]) -> [String: Any]? {
        let usable = formats.filter { f in
            guard let mime = f["mimeType"] as? String else { return false }
            // Progressive formats with both audio+video codecs listed.
            return mime.contains("video/") && mime.contains(",")
        }
        return usable.max { a, b in
            let ha = (a["height"] as? Int) ?? 0
            let hb = (b["height"] as? Int) ?? 0
            if ha != hb { return ha < hb }
            // Prefer mp4 when heights tie.
            let ma = ((a["mimeType"] as? String) ?? "").contains("mp4")
            let mb = ((b["mimeType"] as? String) ?? "").contains("mp4")
            return !ma && mb
        }
    }
}
