package com.example.mediahelper.download.resolvers

import android.net.Uri
import com.example.mediahelper.download.*

/** Facebook — public videos only. Scrapes desktop, then mobile, then the
 *  lightweight /video/embed page; og:video → inline-JSON keys → raw .mp4 scan. */
class FacebookResolver : MediaResolver {
    override val platform = SocialPlatform.FACEBOOK

    private val desktopUA = Http.DESKTOP_UA
    private val mobileUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    override suspend fun resolve(url: String): ResolverResult {
        runCatching { scrape(url, mobile = false) }.getOrNull()?.takeIf { it.isVideo }?.let { return it }
        mobileVariant(url)?.let { m ->
            runCatching { scrape(m, mobile = true) }.getOrNull()?.takeIf { it.isVideo }?.let { return it }
        }
        runCatching { resolveVideoId(url) }.getOrNull()?.let { id ->
            val embed = "https://www.facebook.com/video/embed?video_id=$id"
            runCatching { scrape(embed, mobile = false) }.getOrNull()?.takeIf { it.isVideo }?.let { return it }
        }
        return scrape(url, mobile = false)
    }

    private suspend fun scrape(url: String, mobile: Boolean): ResolverResult {
        val html = Http.getString(url, mapOf(
            "User-Agent" to if (mobile) mobileUA else desktopUA,
            "Accept-Language" to "en-US,en;q=0.9",
        ))
        val title = HtmlScraper.metaContent(html, "og:title")
        val thumb = HtmlScraper.metaContent(html, "og:image")

        val ogVideo = HtmlScraper.metaContent(html, "og:video:secure_url")
            ?: HtmlScraper.metaContent(html, "og:video")
            ?: HtmlScraper.metaContent(html, "og:video:url")
        if (ogVideo != null) return ResolverResult(ogVideo, title, thumb, isVideo = true, platform = platform)

        val keys = listOf(
            "hd_src", "sd_src", "browser_native_hd_url", "browser_native_sd_url",
            "playable_url_quality_hd", "playable_url", "videoUrl", "video_url",
            "hd_src_no_ratelimit", "sd_src_no_ratelimit", "dash_manifest",
        )
        for (key in keys) {
            val raw = HtmlScraper.firstCaptureGroup(html, "\"$key\":\"([^\"]+)\"") ?: continue
            val cleaned = decodeJsonString(raw)
            if (cleaned.contains(".mpd") || cleaned.contains("<MPD")) continue
            return ResolverResult(cleaned, title, thumb, isVideo = true, platform = platform)
        }

        HtmlScraper.firstCaptureGroup(html, "(https?://[^\"'<\\s\\\\]+\\.mp4[^\"'<\\s\\\\]*)")?.let {
            return ResolverResult(decodeJsonString(it), title, thumb, isVideo = true, platform = platform)
        }

        if (thumb != null &&
            html.contains("og:image", ignoreCase = true) &&
            !html.contains("og:video", ignoreCase = true) &&
            !html.contains("mp4", ignoreCase = true)
        ) {
            return ResolverResult(thumb, title, thumb, isVideo = false, platform = platform)
        }

        throw DownloadError.ResolutionFailed(
            "couldn't find a public video on that page. Private or login-gated posts aren't supported."
        )
    }

    private suspend fun resolveVideoId(url: String): String {
        val uri = Uri.parse(url)
        val canonical = if (uri.host?.lowercase()?.contains("fb.watch") == true) {
            Http.redirectLocation(url, desktopUA)?.let { Uri.parse(it) } ?: uri
        } else uri
        return extractVideoId(canonical)
            ?: throw DownloadError.ResolutionFailed("can't extract FB video ID")
    }

    private fun extractVideoId(uri: Uri): String? {
        uri.getQueryParameter("v")?.takeIf { it.all(Char::isDigit) }?.let { return it }
        val parts = uri.pathSegments
        for ((i, part) in parts.withIndex()) {
            val lower = part.lowercase()
            if ((lower == "videos" || lower == "reel" || lower == "reels") &&
                i + 1 < parts.size && parts[i + 1].all(Char::isDigit)
            ) return parts[i + 1]
        }
        if (parts.firstOrNull()?.lowercase() == "video" && parts.size >= 2 && parts[1].all(Char::isDigit))
            return parts[1]
        return null
    }

    private fun mobileVariant(url: String): String? {
        val uri = Uri.parse(url)
        return when (uri.host?.lowercase()) {
            "facebook.com", "www.facebook.com" ->
                uri.buildUpon().authority("m.facebook.com").build().toString()
            "m.facebook.com" -> null
            else -> url
        }
    }
}
