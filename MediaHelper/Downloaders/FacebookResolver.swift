import Foundation

/// Facebook resolver — public videos only.
///
/// Facebook's web player embeds the media URL into the page HTML for
/// logged-out visitors as long as the post is public. Our strategy
/// mirrors the other scrape-style resolvers:
///
///   1. Fetch the page (desktop UA so we get the full markup rather than
///      the skinny mobile "log in to continue" interstitial).
///   2. Try the standard OpenGraph tags (`og:video:secure_url` / `og:video`
///      / `og:image`). These are populated for public Reels, fb.watch
///      shortlinks, and most public Pages videos.
///   3. Fall back to a regex sweep for the `hd_src` / `sd_src` keys that
///      Facebook inlines into their bootstrap JSON for public videos.
///   4. If we get nothing, surface a clear message: it's almost
///      certainly a private or login-gated post.
///
/// TODO: Authenticated/private content would require capturing the
///       user's `c_user` + `xs` cookies via an in-app WebView and
///       passing them to the video CDN. Out of scope — we fail cleanly.
struct FacebookResolver: MediaResolver {
    let platform: SocialPlatform = .facebook

    func resolve(_ url: URL) async throws -> ResolverResult {
        let html = try await HTMLScraper.fetchHTML(url)

        let title = HTMLScraper.metaContent(html, property: "og:title")
        let thumb = HTMLScraper.metaContent(html, property: "og:image").flatMap(URL.init(string:))

        // 1. OpenGraph video
        if let videoString = HTMLScraper.metaContent(html, property: "og:video:secure_url")
            ?? HTMLScraper.metaContent(html, property: "og:video")
            ?? HTMLScraper.metaContent(html, property: "og:video:url"),
           let videoURL = URL(string: videoString) {
            return ResolverResult(
                mediaURL: videoURL, title: title, thumbnailURL: thumb,
                isVideo: true, platform: .facebook
            )
        }

        // 2. Inline-JSON sweep. FB inlines things like `"hd_src":"https:\/\/..."`
        // for public videos; hd_src > sd_src > browser_native_hd_url.
        for key in ["hd_src", "sd_src", "browser_native_hd_url", "browser_native_sd_url", "playable_url"] {
            if let raw = HTMLScraper.firstCaptureGroup(
                in: html, pattern: "\"\(key)\":\"([^\"]+)\""
            ) {
                let cleaned = raw
                    .replacingOccurrences(of: "\\u0026", with: "&")
                    .replacingOccurrences(of: "\\u0025", with: "%")
                    .replacingOccurrences(of: "\\/", with: "/")
                if let videoURL = URL(string: cleaned) {
                    return ResolverResult(
                        mediaURL: videoURL, title: title, thumbnailURL: thumb,
                        isVideo: true, platform: .facebook
                    )
                }
            }
        }

        // 3. Image fallback (og:image only) — Facebook photo posts.
        if let img = thumb,
           html.range(of: "og:image", options: .caseInsensitive) != nil,
           html.range(of: "og:video", options: .caseInsensitive) == nil {
            return ResolverResult(
                mediaURL: img, title: title, thumbnailURL: img,
                isVideo: false, platform: .facebook
            )
        }

        throw DownloadError.resolutionFailed(
            "couldn't find a public video on that page. Private or login-gated posts aren't supported."
        )
    }
}
