package com.example.mediahelper.download

/** The set of social platforms the app attempts to download from.
 *  Mirrors iOS SocialPlatform. */
enum class SocialPlatform(val displayName: String) {
    YOUTUBE("YouTube"),
    TWITTER("X / Twitter"),
    TIKTOK("TikTok"),
    INSTAGRAM("Instagram"),
    FACEBOOK("Facebook"),
    THREADS("Threads"),
    STREAMABLE("Streamable"),
    VIMEO("Vimeo"),
    UNKNOWN("Unknown"),
}

/** Metadata a resolver returns after turning a page URL into a direct media URL.
 *  `requestHeaders` are extra headers the downloader must attach to the media
 *  fetch (TikTok's CDN validates the same cookie/UA/Referer from the resolve). */
data class ResolverResult(
    val mediaUrl: String,
    val title: String? = null,
    val thumbnailUrl: String? = null,
    val isVideo: Boolean,
    val platform: SocialPlatform,
    val requestHeaders: Map<String, String> = emptyMap(),
)

/** Errors a resolver or downloader surfaces to the UI. Mirrors iOS DownloadError. */
sealed class DownloadError(message: String) : Exception(message) {
    object InvalidUrl : DownloadError("That doesn't look like a valid URL.")
    class UnsupportedPlatform(p: SocialPlatform) :
        DownloadError("${p.displayName} downloads aren't supported in this build.")
    class ResolutionFailed(why: String) :
        DownloadError("Couldn't find a media file on that page: $why")
    class NetworkFailed(why: String) : DownloadError("Network problem: $why")
    class SaveFailed(why: String) : DownloadError("Couldn't save to your library: $why")
    class LoginRequired(val platform: SocialPlatform) :
        DownloadError("${platform.displayName} requires login for this post. Add your session cookie in Settings → ${platform.displayName}.")
}
