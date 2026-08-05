import Foundation

/// Streamable resolver (streamable.com).
///
/// Streamable exposes a public JSON API at:
///   https://api.streamable.com/videos/<shortcode>
///
/// The response includes a `files` object with quality variants (`mp4`,
/// `mp4-mobile`). URLs are protocol-relative (`//cdn…`) and need `https:` prepended.
///
/// URL forms handled:
///   https://streamable.com/abc123
struct StreamableResolver: MediaResolver {
    let platform: SocialPlatform = .streamable

    func resolve(_ url: URL) async throws -> ResolverResult {
        let components = url.pathComponents.filter { $0 != "/" }
        guard let shortcode = components.last, !shortcode.isEmpty else {
            throw DownloadError.resolutionFailed("Couldn't extract Streamable video ID from URL.")
        }

        guard let apiURL = URL(string: "https://api.streamable.com/videos/\(shortcode)") else {
            throw DownloadError.resolutionFailed("Couldn't build Streamable API URL.")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: apiURL)
        } catch {
            throw DownloadError.networkFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw DownloadError.networkFailed("Streamable API HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DownloadError.resolutionFailed("Unexpected response from Streamable API.")
        }

        let title = json["title"] as? String
        let thumbRaw = json["thumbnail_url"] as? String
        let thumb = thumbRaw.flatMap { URL(string: Self.absoluteURL($0)) }

        guard let files = json["files"] as? [String: Any] else {
            throw DownloadError.resolutionFailed("Streamable API response contained no files.")
        }

        // Prefer full quality mp4; fall back to mobile variant.
        for key in ["mp4", "mp4-mobile"] {
            if let file = files[key] as? [String: Any],
               let rawURL = file["url"] as? String,
               let videoURL = URL(string: Self.absoluteURL(rawURL)) {
                return ResolverResult(
                    mediaURL: videoURL,
                    title: title,
                    thumbnailURL: thumb,
                    isVideo: true,
                    platform: .streamable,
                    requestHeaders: [:]
                )
            }
        }

        throw DownloadError.resolutionFailed("Streamable API returned no downloadable video URL.")
    }

    /// Convert a protocol-relative URL (`//cdn.example.com/…`) to `https:`.
    private static func absoluteURL(_ raw: String) -> String {
        raw.hasPrefix("//") ? "https:" + raw : raw
    }
}
