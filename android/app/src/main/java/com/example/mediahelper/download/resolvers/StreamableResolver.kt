package com.example.mediahelper.download.resolvers

import android.net.Uri
import com.example.mediahelper.download.*

/** Streamable — public JSON API at api.streamable.com/videos/<shortcode>. */
class StreamableResolver : MediaResolver {
    override val platform = SocialPlatform.STREAMABLE

    override suspend fun resolve(url: String): ResolverResult {
        val shortcode = Uri.parse(url).pathSegments.lastOrNull()?.takeIf { it.isNotEmpty() }
            ?: throw DownloadError.ResolutionFailed("Couldn't extract Streamable video ID from URL.")

        val json = Http.getJson("https://api.streamable.com/videos/$shortcode")
        val title = json.stringOrNull("title")
        val thumb = json.stringOrNull("thumbnail_url")?.let { absolute(it) }
        val files = json.objOrNull("files")
            ?: throw DownloadError.ResolutionFailed("Streamable API response contained no files.")

        for (key in listOf("mp4", "mp4-mobile")) {
            val raw = files.objOrNull(key)?.stringOrNull("url") ?: continue
            return ResolverResult(absolute(raw), title, thumb, isVideo = true, platform = platform)
        }
        throw DownloadError.ResolutionFailed("Streamable API returned no downloadable video URL.")
    }

    private fun absolute(raw: String) = if (raw.startsWith("//")) "https:$raw" else raw
}
