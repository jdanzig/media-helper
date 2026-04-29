import Foundation

/// YouTube resolver using the **InnerTube** private API.
///
/// Public downloaders (yt-dlp, cobalt, etc.) work by calling YouTube's
/// internal `youtubei/v1/player` endpoint with a client context that
/// mimics the first-party iOS / Android / TV apps. Different clients
/// have different blocking patterns at any given moment — Google plays
/// whack-a-mole and keeps tightening, so we try several in order and
/// take the first one that returns playable streams.
///
/// Order picked to maximize success rate as of 2026:
///  1. **ANDROID_VR** — the Quest YouTube app. Largely ignored by anti-
///     bot measures and returns progressive MP4s.
///  2. **ANDROID** — most stable for non-age-gated content.
///  3. **TVHTML5_SIMPLY_EMBEDDED_PLAYER** — handles age-gated and works
///     when iOS/Android are challenged for a PoToken.
///  4. **IOS** — kept as a final fallback. Increasingly serves 400/403
///     to clients that don't carry a freshly minted PoToken.
///
/// Known limits:
///  - PoToken-gated videos (Google's anti-bot challenge) ultimately
///    return UI-friendly errors; a robust fix would need a JS engine.
///  - Live streams return HLS manifests (m3u8) rather than a single
///    progressive MP4. The downloader doesn't handle HLS assembly.
struct YouTubeResolver: MediaResolver {
    let platform: SocialPlatform = .youtube

    // Publicly known key the YouTube apps use to authenticate against
    // the InnerTube gateway. Not a secret — it ships in every
    // `youtubei` request from every client.
    private static let innertubeKey = "AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc"

    /// One row of the table of clients we'll try in order.
    private struct ClientProfile {
        let name: String
        let version: String
        let userAgent: String
        let extra: [String: Any]
    }

    private static let clients: [ClientProfile] = [
        // ANDROID_VR — quietest of the lot. Used by the Meta Quest app.
        ClientProfile(
            name: "ANDROID_VR",
            version: "1.60.19",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.60.19 " +
                       "(Linux; U; Android 12L; en_US; Quest 3) gzip",
            extra: ["deviceMake": "Oculus", "deviceModel": "Quest 3",
                    "androidSdkVersion": 32, "osName": "Android", "osVersion": "12L"]
        ),
        // MWEB — the mobile-web client. Lightweight, no PoToken in many
        // regions. Worth trying before the heavier mobile-app clients.
        ClientProfile(
            name: "MWEB",
            version: "2.20240814.07.00",
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
                       "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 " +
                       "Mobile/15E148 Safari/604.1",
            extra: [:]
        ),
        // ANDROID — main consumer client.
        ClientProfile(
            name: "ANDROID",
            version: "19.09.37",
            userAgent: "com.google.android.youtube/19.09.37 (Linux; U; Android 14; en_US) gzip",
            extra: ["androidSdkVersion": 34, "osName": "Android", "osVersion": "14"]
        ),
        // TV embedded player — handles age-gated videos.
        ClientProfile(
            name: "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
            version: "2.0",
            userAgent: "Mozilla/5.0 (PlayStation; PlayStation 4/8.03) AppleWebKit/605.1.15 " +
                       "(KHTML, like Gecko) Version/13.0 Safari/605.1.15",
            extra: [:]
        ),
        // WEB_EMBEDDED_PLAYER — what `youtube.com/embed/<id>` runs.
        // Sometimes returns playable streams when other clients are
        // PoToken-challenged because the embed surface is more permissive.
        ClientProfile(
            name: "WEB_EMBEDDED_PLAYER",
            version: "1.20240814.01.00",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 " +
                       "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            extra: [:]
        ),
        // IOS — historically reliable, increasingly PoToken-challenged.
        ClientProfile(
            name: "IOS",
            version: "19.09.3",
            userAgent: "com.google.ios.youtube/19.09.3 (iPhone14,3; U; CPU iOS 15_6 like Mac OS X)",
            extra: ["deviceModel": "iPhone14,3"]
        )
    ]

    func resolve(_ url: URL) async throws -> ResolverResult {
        guard let videoID = Self.extractVideoID(from: url) else {
            throw DownloadError.resolutionFailed("couldn't find a video ID in that URL.")
        }

        var lastError: Error?
        for client in Self.clients {
            do {
                return try await Self.resolveWithClient(client, videoID: videoID)
            } catch {
                lastError = error
                continue
            }
        }
        // No client worked. Surface the last error verbatim — usually it's
        // YouTube's own message ("Sign in to confirm you're not a bot",
        // "Video unavailable", etc.) which is more useful than a generic.
        throw lastError ?? DownloadError.resolutionFailed("all InnerTube clients failed.")
    }

    /// Single-client attempt. Returns a `ResolverResult` if the video is
    /// reachable, throws otherwise.
    private static func resolveWithClient(_ client: ClientProfile,
                                          videoID: String) async throws -> ResolverResult {
        let endpoint = URL(string:
            "https://youtubei.googleapis.com/youtubei/v1/player?key=\(innertubeKey)"
        )!

        var clientContext: [String: Any] = [
            "clientName": client.name,
            "clientVersion": client.version,
            "hl": "en",
            "timeZone": "UTC",
            "utcOffsetMinutes": 0
        ]
        for (k, v) in client.extra { clientContext[k] = v }

        let body: [String: Any] = [
            "context": ["client": clientContext],
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12   // surface failures fast — we have 4 clients to try
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloadError.networkFailed(
                "\(client.name) HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DownloadError.resolutionFailed("\(client.name): non-JSON response.")
        }

        if let playability = json["playabilityStatus"] as? [String: Any],
           let status = playability["status"] as? String,
           status != "OK" {
            let reason = (playability["reason"] as? String) ?? status
            throw DownloadError.resolutionFailed("YouTube says: \(reason)")
        }

        guard let streamingData = json["streamingData"] as? [String: Any] else {
            throw DownloadError.resolutionFailed("\(client.name): no streamingData.")
        }

        let progressive = (streamingData["formats"] as? [[String: Any]]) ?? []
        guard let best = pickBestProgressive(progressive) else {
            throw DownloadError.resolutionFailed(
                "\(client.name): no progressive MP4 available."
            )
        }
        guard let urlString = best["url"] as? String, let mediaURL = URL(string: urlString) else {
            throw DownloadError.resolutionFailed("\(client.name): chosen format had no direct URL.")
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
