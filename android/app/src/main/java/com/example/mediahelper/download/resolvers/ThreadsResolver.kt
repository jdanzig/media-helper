package com.example.mediahelper.download.resolvers

import android.net.Uri
import com.example.mediahelper.download.*

/** Threads (threads.net / .com) — Instagram-infra posts rendered server-side.
 *  Scrapes og:video / inline JSON / <source> / raw mp4 / images, filtering out
 *  Meta static assets and profile pics. Mirrors iOS ThreadsResolver. */
class ThreadsResolver : MediaResolver {
    override val platform = SocialPlatform.THREADS

    private val userAgents = listOf(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
    )

    override suspend fun resolve(url: String): ResolverResult {
        for (candidate in listOf(toThreadsNet(url), toThreadsCom(url))) {
            runCatching { resolveViaPage(candidate) }.getOrNull()?.let { return it }
        }
        extractShortcode(url)?.let { sc ->
            runCatching { resolveViaEmbed(sc) }.getOrNull()?.let { return it }
        }
        throw DownloadError.ResolutionFailed(
            "couldn't find a public media URL on that Threads post. Private posts require login, which isn't supported."
        )
    }

    private suspend fun resolveViaPage(url: String): ResolverResult {
        for (ua in userAgents) {
            val html = runCatching { fetchHtml(ua, url) }.getOrNull() ?: continue
            runCatching { extractMedia(html, url, ua) }.getOrNull()?.let { return it }
        }
        throw DownloadError.ResolutionFailed("no media found in page HTML.")
    }

    private suspend fun resolveViaEmbed(shortcode: String): ResolverResult {
        val embed = "https://www.threads.net/t/$shortcode/embed/"
        for (ua in userAgents) {
            val html = runCatching { fetchHtml(ua, embed) }.getOrNull() ?: continue
            runCatching { extractMedia(html, embed, ua) }.getOrNull()?.let { return it }
        }
        throw DownloadError.ResolutionFailed("no media found in embed page HTML.")
    }

    private fun extractMedia(html: String, referer: String, pageUA: String): ResolverResult {
        val cdnHeaders = mapOf(
            "Referer" to referer,
            "User-Agent" to pageUA,
            "Accept" to "video/mp4,video/webm,video/*;q=0.9,image/avif,image/webp,image/*;q=0.8,*/*;q=0.5",
            "Accept-Language" to "en-US,en;q=0.9",
            "Origin" to "https://www.threads.net",
        )
        val title = HtmlScraper.metaContent(html, "og:title")
        val thumb = HtmlScraper.metaContent(html, "og:image")

        fun video(u: String) = ResolverResult(u, title, thumb, isVideo = true, platform, cdnHeaders)
        fun image(u: String) = ResolverResult(u, title, u, isVideo = false, platform, cdnHeaders)

        (HtmlScraper.metaContent(html, "og:video")
            ?: HtmlScraper.metaContent(html, "og:video:secure_url")
            ?: HtmlScraper.metaContent(html, "og:video:url"))?.let { return video(it) }

        val videoKeys = listOf("video_url", "playable_url", "playable_url_quality_hd",
            "playback_url", "stream_url", "clip_playback_url", "videoUrl", "contentUrl", "browser_native_url")
        for (key in videoKeys) {
            allDecoded(html, "\"$key\":\"([^\"]+)\"").firstOrNull { !isNonMedia(it) }?.let { return video(it) }
        }

        allDecoded(html, "\"video_versions\"\\s*:\\s*\\[[^\\]]*?\"url\"\\s*:\\s*\"([^\"]+)\"")
            .firstOrNull { !isNonMedia(it) }?.let { return video(it) }

        val srcPatterns = listOf(
            "<source[^>]+src=[\"']([^\"']+\\.mp4[^\"']*)[\"']",
            "<video[^>]+src=[\"']([^\"']+\\.mp4[^\"']*)[\"']",
            "<source[^>]+src=[\"'](https?://[^\"']+)[\"'][^>]+type=[\"']video",
        )
        for (pat in srcPatterns) allDecoded(html, pat).firstOrNull()?.let { return video(it) }

        allDecoded(html, "(https?://[^\"'<\\s\\\\]+\\.mp4[^\"'<\\s\\\\]*)").firstOrNull()?.let { return video(it) }

        for (key in listOf("display_url", "image_url", "thumbnail_url")) {
            allDecoded(html, "\"$key\":\"([^\"]+)\"").firstOrNull { !isNonMedia(it) }?.let { return image(it) }
        }

        allDecoded(html, "(https?://scontent[^\"'<\\s\\\\]+\\.(?:jpg|jpeg|png|webp)[^\"'<\\s\\\\]*)")
            .firstOrNull { !isNonMedia(it) }?.let { return image(it) }

        if (thumb != null && !isNonMedia(thumb)) return image(thumb)

        throw DownloadError.ResolutionFailed("no media found in page HTML.")
    }

    private fun allDecoded(html: String, pattern: String): List<String> =
        HtmlScraper.allCaptureGroups(html, pattern).map { decodeJsonString(it) }

    private fun isNonMedia(url: String): Boolean =
        url.contains("static.cdninstagram.com") || url.contains("rsrc.php") ||
            url.contains("t51.2885-19") || url.contains("profile_pic") || url.contains("profile_pics") ||
            url.contains("/s150x150/") || url.contains("/s320x320/")

    private fun toThreadsNet(url: String) = if (url.contains("threads.net")) url else url.replace("threads.com", "threads.net")
    private fun toThreadsCom(url: String) = if (url.contains("threads.com")) url else url.replace("threads.net", "threads.com")

    private suspend fun fetchHtml(ua: String, url: String): String = Http.getString(url, mapOf(
        "User-Agent" to ua,
        "Accept" to "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
        "Accept-Language" to "en-US,en;q=0.9",
        "Upgrade-Insecure-Requests" to "1",
        "Cache-Control" to "no-cache",
    ))

    private fun extractShortcode(url: String): String? {
        val parts = Uri.parse(url).pathSegments
        val i = parts.indexOf("post")
        if (i >= 0 && i + 1 < parts.size) return parts[i + 1]
        if (parts.firstOrNull() == "t" && parts.size >= 2) return parts[1]
        return null
    }
}
