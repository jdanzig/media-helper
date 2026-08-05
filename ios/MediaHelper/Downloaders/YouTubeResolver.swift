import Foundation

/// YouTube resolver using the **InnerTube** private API.
///
/// Public downloaders (yt-dlp, cobalt, YouTubeKit, etc.) work by calling
/// YouTube's internal `youtubei/v1/player` endpoint with a client context
/// that mimics the first-party apps. Different clients have different
/// blocking patterns — Google plays whack-a-mole, so we try several.
///
/// **Two-endpoint strategy per client:**
///  1. `www.youtube.com/youtubei/v1/player?prettyPrint=false` — no key
///     required; identified via `X-Youtube-Client-Name/Version` headers.
///  2. `youtubei.googleapis.com/…?key=<android_key>` — fallback.
///
/// **Client order (as of April 2026, matching YouTubeKit's active list):**
///  1. ANDROID_VR   — Quest app; PoToken-exempt per yt-dlp wiki
///  2. ANDROID       — main consumer client; very stable
///  3. MWEB          — lightweight; often bypasses enforcement
///  4. WEB_EMBEDDED  — embed surface; sometimes more permissive
///  5. TVHTML5_SIMPLY_EMBEDDED_PLAYER — handles age-gated
///  6. IOS           — final fallback
///
/// Known limits:
///  - PoToken-gated videos that block every client need a JS engine to
///    solve BotGuard/DroidGuard — out of scope for this app.
///  - Live streams return HLS manifests (m3u8), not a single MP4.
struct YouTubeResolver: MediaResolver {
    let platform: SocialPlatform = .youtube

    /// Primary endpoint — no API key, client identified by headers.
    /// Equivalent to what the YouTube web app itself calls.
    private static let wwwEndpoint =
        URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!

    /// Fallback endpoint with Android API key.
    private static let apiEndpoint =
        URL(string: "https://youtubei.googleapis.com/youtubei/v1/player" +
                    "?key=AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w&prettyPrint=false")!

    private struct ClientProfile {
        let name: String
        let clientID: Int   // sent as X-Youtube-Client-Name integer
        let version: String
        let userAgent: String
        let extra: [String: Any]
        /// Some clients need Origin for the www endpoint.
        var needsOrigin: Bool { return false }
    }

    /// Versions current as of April 2026, cross-referenced with
    /// alexeichhorn/YouTubeKit (actively maintained Swift library).
    private static let clients: [ClientProfile] = [
        // ANDROID_VR (28) — Meta Quest app. PoToken-exempt per yt-dlp wiki.
        ClientProfile(
            name: "ANDROID_VR",
            clientID: 28,
            version: "1.65.10",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 " +
                       "(Linux; U; Android 12L; en_US; Quest 3) gzip",
            extra: ["deviceMake": "Oculus", "deviceModel": "Quest 3",
                    "androidSdkVersion": 32, "osName": "Android", "osVersion": "12L"]
        ),
        // ANDROID (3) — main consumer client; most stable for public videos.
        ClientProfile(
            name: "ANDROID",
            clientID: 3,
            version: "20.10.38",
            userAgent: "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip",
            extra: ["androidSdkVersion": 30, "osName": "Android", "osVersion": "11"]
        ),
        // MWEB (2) — mobile-web client; lightweight, often PoToken-free.
        ClientProfile(
            name: "MWEB",
            clientID: 2,
            version: "2.20250925.01.00",
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3_2 like Mac OS X) " +
                       "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3.2 " +
                       "Mobile/15E148 Safari/604.1",
            extra: [:]
        ),
        // WEB_EMBEDDED_PLAYER (56) — embed surface, sometimes more permissive.
        ClientProfile(
            name: "WEB_EMBEDDED_PLAYER",
            clientID: 56,
            version: "1.20260115.01.00",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                       "AppleWebKit/537.36 (KHTML, like Gecko) " +
                       "Chrome/123.0.0.0 Safari/537.36",
            extra: [:]
        ),
        // TVHTML5_SIMPLY_EMBEDDED_PLAYER (85) — handles age-gated content.
        ClientProfile(
            name: "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
            clientID: 85,
            version: "2.0",
            userAgent: "Mozilla/5.0 (PlayStation; PlayStation 4/8.03) AppleWebKit/605.1.15 " +
                       "(KHTML, like Gecko) Version/13.0 Safari/605.1.15",
            extra: [:]
        ),
        // IOS (5) — final fallback; increasingly requires PoToken.
        ClientProfile(
            name: "IOS",
            clientID: 5,
            version: "20.10.4",
            userAgent: "com.google.ios.youtube/20.10.4 " +
                       "(iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
            extra: ["deviceModel": "iPhone16,2", "osName": "iPhone OS",
                    "osVersion": "18.3.2", "userInterfaceIdiom": "handset"]
        )
    ]

    func resolve(_ url: URL) async throws -> ResolverResult {
        guard let videoID = Self.extractVideoID(from: url) else {
            throw DownloadError.resolutionFailed("couldn't find a video ID in that URL.")
        }

        var lastError: Error?
        for client in Self.clients {
            // Try the www endpoint first (no key required).
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
            }
        }

        // All clients failed. Surface the last error — usually YouTube's own
        // message ("Sign in to confirm you're not a bot", "Video unavailable").
        throw lastError ?? DownloadError.resolutionFailed("all InnerTube clients failed.")
    }

    private static func resolveWithClient(_ client: ClientProfile,
                                          videoID: String,
                                          endpoint: URL) async throws -> ResolverResult {
        var clientContext: [String: Any] = [
            "clientName": client.name,
            "clientVersion": client.version,
            "hl": "en",
            "gl": "US",
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
        request.timeoutInterval = 12
        request.setValue("application/json",         forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent,            forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9",           forHTTPHeaderField: "Accept-Language")
        request.setValue("\(client.clientID)",        forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(client.version,              forHTTPHeaderField: "X-Youtube-Client-Version")
        request.setValue("https://www.youtube.com",   forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/",  forHTTPHeaderField: "Referer")
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
                "\(client.name): no progressive MP4 in formats array."
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

        if host.hasSuffix("youtu.be") {
            let comp = url.path.split(separator: "/").first.map(String.init)
            return comp.flatMap(sanitizeID)
        }

        if url.path == "/watch",
           let qi = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let id = qi.first(where: { $0.name == "v" })?.value {
            return sanitizeID(id)
        }

        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]) {
            return sanitizeID(parts[1])
        }

        return nil
    }

    private static func sanitizeID(_ raw: String) -> String? {
        let cleaned = raw.split(whereSeparator: { "?&#".contains($0) }).first.map(String.init) ?? raw
        guard cleaned.count >= 11,
              cleaned.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        return String(cleaned.prefix(11))
    }

    /// Pick the highest-quality progressive MP4 (audio+video muxed, directly playable).
    private static func pickBestProgressive(_ formats: [[String: Any]]) -> [String: Any]? {
        let usable = formats.filter { f in
            guard let mime = f["mimeType"] as? String else { return false }
            return mime.contains("video/") && mime.contains(",")
        }
        return usable.max { a, b in
            let ha = (a["height"] as? Int) ?? 0
            let hb = (b["height"] as? Int) ?? 0
            if ha != hb { return ha < hb }
            let ma = ((a["mimeType"] as? String) ?? "").contains("mp4")
            let mb = ((b["mimeType"] as? String) ?? "").contains("mp4")
            return !ma && mb
        }
    }
}
