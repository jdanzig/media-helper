import Foundation

/// Vimeo resolver (vimeo.com / player.vimeo.com).
///
/// Uses Vimeo's player config endpoint:
///   https://player.vimeo.com/video/<id>/config
///
/// The response JSON contains a `files.progressive` array of direct MP4
/// download URLs at various qualities. We pick the highest-resolution one.
///
/// URL forms handled:
///   https://vimeo.com/123456789
///   https://vimeo.com/channels/channelname/123456789
///   https://vimeo.com/groups/groupname/videos/123456789
///   https://player.vimeo.com/video/123456789
struct VimeoResolver: MediaResolver {
    let platform: SocialPlatform = .vimeo

    func resolve(_ url: URL) async throws -> ResolverResult {
        guard let videoID = Self.extractVideoID(from: url) else {
            throw DownloadError.resolutionFailed("Couldn't extract Vimeo video ID from URL.")
        }

        guard let configURL = URL(string: "https://player.vimeo.com/video/\(videoID)/config") else {
            throw DownloadError.resolutionFailed("Couldn't build Vimeo config URL.")
        }

        var request = URLRequest(url: configURL)
        request.timeoutInterval = 15
        request.setValue("https://vimeo.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 " +
            "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DownloadError.networkFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.networkFailed("No HTTP response from Vimeo.")
        }
        if http.statusCode == 403 || http.statusCode == 401 {
            throw DownloadError.resolutionFailed("This Vimeo video is private or requires a password.")
        }
        guard (200..<400).contains(http.statusCode) else {
            throw DownloadError.networkFailed("Vimeo config HTTP \(http.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DownloadError.resolutionFailed("Unexpected response from Vimeo.")
        }

        let title = (json["video"] as? [String: Any])?["title"] as? String
        let thumbBase = ((json["video"] as? [String: Any])?["thumbs"] as? [String: Any])?["base"] as? String
        let thumb = thumbBase.flatMap { URL(string: $0) }

        guard let files = json["files"] as? [String: Any],
              let progressive = files["progressive"] as? [[String: Any]],
              !progressive.isEmpty else {
            throw DownloadError.resolutionFailed(
                "Vimeo returned no progressive download files. " +
                "The video may be private or restricted."
            )
        }

        // Pick the highest-resolution variant by width.
        let best = progressive
            .compactMap { file -> (width: Int, url: String)? in
                guard let urlStr = file["url"] as? String else { return nil }
                let width = file["width"] as? Int ?? 0
                return (width, urlStr)
            }
            .sorted { $0.width > $1.width }
            .first

        guard let best, let videoURL = URL(string: best.url) else {
            throw DownloadError.resolutionFailed("Couldn't parse a download URL from Vimeo's response.")
        }

        return ResolverResult(
            mediaURL: videoURL,
            title: title,
            thumbnailURL: thumb,
            isVideo: true,
            platform: .vimeo,
            requestHeaders: [:]
        )
    }

    /// Extract the numeric video ID from any standard Vimeo URL.
    /// The ID is always an all-digit path component.
    static func extractVideoID(from url: URL) -> String? {
        url.pathComponents.first(where: { $0.allSatisfy(\.isNumber) && $0.count >= 5 })
    }
}
