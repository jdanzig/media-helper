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
/// **Endpoint choice matters.** `youtubei.googleapis.com/youtubei/v1/player`
/// (with `?key=…`) applies PoToken enforcement to most clients. The
/// `www.youtube.com/youtubei/v1/player` path does not require a key and
/// is what yt-dlp uses for its ANDROID_TESTSUITE bypass. We try the
/// www-subdomain endpoint first and fall back to the googleapis one.
///
/// Order picked to maximize success rate as of 2026:
///  1. **ANDROID_TESTSUITE** — Google's internal test harness client (ID 30).
///     Exempt from PoToken enforcement; yt-dlp uses this as its primary
///     bypass. Must be called against www.youtube.com, not the googleapis
///     gateway.
///  2. **ANDROID_VR** — Quest YouTube app. Also largely PoToken-exempt.
///  3. **MWEB** — lightweight mobile-web client.
///  4. **ANDROID** — main consumer client.
///  5. **TVHTML5_SIMPLY_EMBEDDED_PLAYER** — handles age-gated content.
///  6. **WEB_EMBEDDED_PLAYER** — embed-surface, sometimes more permissive.
///  7. **IOS** — final fallback; increasingly PoToken-challenged.
///
/// Known limits:
///  - PoToken-gated videos that block all clients ultimately need a JS
///    engine to solve the challenge — out of scope here.
///  - Live streams return HLS manifests (m3u8) rather than a single
///    progressive MP4. The downloader doesn't handle HLS assembly.
struct YouTubeResolver: MediaResolver {
    let platform: SocialPlatform = .youtube

    /// InnerTube endpoint on the www subdomain. Does **not** require an
    /// API key; client identity is established via the User-Agent and the
    /// `X-Youtube-Client-Name` / `X-Youtube-Client-Version` headers.
    private static let wwwEndpoint =
        URL(string: "https://www.youtube.com/youtubei/v1/player")!

    /// Fallback InnerTube endpoint on the googleapis subdomain. Requires
    /// a key and is subject to stricter PoToken enforcement, but still
    /// occasionally works when the www endpoint returns a 404 or empty
    /// streamingData.
    private static let apiEndpoint =
        URL(string: "https://youtubei.googleapis.com/youtubei/v1/player" +
                    "?key=AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w")!

    /// One row of the table of clients we'll try in order.
    private struct ClientProfile {
        /// Name sent in the `clientName` body field.
        let name: String
        /// Integer sent in `X-Youtube-Client-Name`.
        /// Reference: https://github.com/yt-dlp/yt-dlp (innertubeClientMap)
        let clientID: Int
        let version: String
        let userAgent: String
        let extra: [String: Any]
    }

    private static let clients: [ClientProfile] = [
        // ANDROID_TESTSUITE (30) — Google's own QA client. PoToken-exempt.
        // yt-dlp uses this as its primary bypass against the bot gate.
        ClientProfile(
            name: "ANDROID_TESTSUITE",
            clientID: 30,
            version: "1.9",
            userAgent: "com.google.android.youtube/1.9 (Linux; U; Android 11) gzip",
            extra: ["androidSdkVersion": 30, "osName": "Android", "osVersion": "11"]
        ),
        // ANDROID_VR (28) — Meta Quest YouTube app. Also largely exempt.
        ClientProfile(
            name: "ANDROID_VR",
            clientID: 28,
            version: "1.60.19",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.60.19 " +
                       "(Linux; U; Android 12L; en_US; Quest 3) gzip",
            extra: ["deviceMake": "Oculus", "deviceModel": "Quest 3",
                    "androidSdkVersion": 32, "osName": "Android", "osVersion": "12L"]
        ),
        // MWEB (2) — mobile-web client, lightweight and often PoToken-free.
        ClientProfile(
            name: "MWEB",
            clientID: 2,
            version: "2.20240814.07.00",
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " +
                       "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 " +
                       "Mobile/15E148 Safari/604.1",
            extra: [:]
        ),
        // ANDROID (3) — main consumer client.
        ClientProfile(
            name: "ANDROID",
            clientID: 3,
            version: "19.09.37",
            userAgent: "com.google.android.youtube/19.09.37 (Linux; U; Android 14; en_US) gzip",
            extra: ["androidSdkVersion": 34, "osName": "Android", "osVersion": "14"]
        ),
        // TVHTML5_SIMPLY_EMBEDDED_PLAYER (85) — handles age-gated videos.
        ClientProfile(
            name: "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
            clientID: 85,
            version: "2.0",
            userAgent: "Mozilla/5.0 (PlayStation; PlayStation 4/8.03) AppleWebKit/605.1.15 " +
                       "(KHTML, like Gecko) Version/13.0 Safari/605.1.15",
            extra: [:]
        ),
        // WEB_EMBEDDED_PLAYER (56) — embed surface, sometimes more permissive.
        ClientProfile(
            name: "WEB_EMBEDDED_PLAYER",
            clientID: 56,
            version: "1.20240814.01.00",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 " +
                       "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            extra: [:]
        ),
        // IOS (5) — final fallback; increasingly requires PoToken.
        ClientProfile(
            name: "IOS",
            clientID: 5,
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
            // Try the www endpoint first (no key, PoToken-exempt path).
            if let result = try? await Self.resolveWithClient(
                client, videoID: videoID, endpoint: Self.wwwEndpoint
            ) {
                return result
            }
            // Fall back to the googleapis endpoint with key.
            do {
                return try await Self.resolveWithClient(
                    client, videoID: videoID, endpoint: Self.apiEndpoint
                )
            } catch {
                lastError = error
                continue
            }
        }
        // No client / endpoint combo worked. Surface the last error verbatim —
        // usually YouTube's own message ("Sign in to confirm you're not a bot",
        // "Video unavailable", etc.) which is more useful than a generic.
        throw lastError ?? DownloadError.resolutionFailed("all InnerTube clients failed.")
    }

    /// Single-client + single-endpoint attempt.
    private static func resolveWithClient(_ client: ClientProfile,
                                          videoID: String,
                                          endpoint: URL) async throws -> ResolverResult {
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
        request.timeoutInterval = 12   // fast failure so we can try the next client
        request.setValue("application/json",        forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent,           forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9",          forHTTPHeaderField: "Accept-Language")
        // These headers identify the client on the www-subdomain endpoint
        // (which doesn't use a key). They're harmless on the googleapis endpoint.
        request.setValue("\(client.clientID)",       forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(client.version,             forHTTPHeaderField: "X-Youtube-Client-Version")
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

    /// Extract the 11-character video ID from any YouTube URL form:
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
        // a query-like character to tolerate share suffixes.
        let cleaned = raw.split(whereSeparator: { "?&#".contains($0) }).first.map(String.init) ?? raw
        guard cleaned.count >= 11,
              cleaned.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        return String(cleaned.prefix(11))
    }

    /// Pick the highest-quality progressive MP4 (audio+video muxed).
    /// Rough ranking: 720p > 360p > others; MP4 > WebM as a tiebreaker.
    private static func pickBestProgressive(_ formats: [[String: Any]]) -> [String: Any]? {
        let usable = formats.filter { f in
            guard let mime = f["mimeType"] as? String else { return false }
            // Progressive formats list two codecs (video + audio) separated by ", ".
            return mime.contains("video/") && mime.contains(",")
        }
        return usable.max { a, b in
            let ha = (a["height"] as? Int) ?? 0
            let hb = (b["height"] as? Int) ?? 0
            if ha != hb { return ha < hb }
            // Prefer mp4 over webm when heights are equal.
            let ma = ((a["mimeType"] as? String) ?? "").contains("mp4")
            let mb = ((b["mimeType"] as? String) ?? "").contains("mp4")
            return !ma && mb
        }
    }
}
