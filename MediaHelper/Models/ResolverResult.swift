import Foundation

/// Metadata returned by a `MediaResolver` after inspecting a social URL.
///
/// A resolver's job is to turn a user-pasted page URL into a direct media URL
/// (plus whatever display metadata we can cheaply extract). The downloader
/// then consumes `mediaURL` to fetch bytes.
struct ResolverResult: Equatable {
    /// The direct URL of the video/image file to download.
    let mediaURL: URL

    /// Optional title (e.g. video title or tweet text) shown in the UI.
    let title: String?

    /// Optional thumbnail URL, typically from `og:image`.
    let thumbnailURL: URL?

    /// True if the resolved media is a video, false for images.
    let isVideo: Bool

    /// The platform this result was produced by — used for analytics/UI.
    let platform: SocialPlatform

    /// Extra request headers the downloader must attach when fetching
    /// `mediaURL`. Required for platforms whose CDNs enforce a matching
    /// User-Agent, Referer, or cookie from the original resolve step
    /// (TikTok, some Instagram CDNs). Default is empty.
    var requestHeaders: [String: String] = [:]
}

/// Errors a resolver or downloader can surface to the UI layer.
enum DownloadError: LocalizedError {
    case invalidURL
    case unsupportedPlatform(SocialPlatform)
    case resolutionFailed(String)
    case networkFailed(String)
    case saveFailed(String)
    /// The platform requires a login session to serve this post's media.
    case loginRequired(SocialPlatform)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "That doesn't look like a valid URL."
        case .unsupportedPlatform(let p):
            return "\(p.displayName) downloads aren't supported in this build."
        case .resolutionFailed(let why):
            return "Couldn't find a media file on that page: \(why)"
        case .networkFailed(let why):
            return "Network problem: \(why)"
        case .saveFailed(let why):
            return "Couldn't save to Photos: \(why)"
        case .loginRequired(let p):
            return "\(p.displayName) requires login for this post. Add your session cookie in Settings → Instagram."
        }
    }
}
