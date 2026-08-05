package com.example.mediahelper.download.resolvers

import android.net.Uri
import com.example.mediahelper.download.*

/** Vimeo — player.vimeo.com/video/<id>/config JSON with progressive MP4s. */
class VimeoResolver : MediaResolver {
    override val platform = SocialPlatform.VIMEO

    override suspend fun resolve(url: String): ResolverResult {
        val uri = Uri.parse(url)
        val videoId = extractVideoId(uri)
            ?: throw DownloadError.ResolutionFailed("Couldn't extract Vimeo video ID from URL.")
        val hash = extractHash(uri, videoId)

        var configUrl = "https://player.vimeo.com/video/$videoId/config"
        if (hash != null) configUrl += "?h=$hash"

        val json = try {
            Http.getJson(configUrl, mapOf("User-Agent" to Http.DESKTOP_UA, "Referer" to "https://vimeo.com/"))
        } catch (e: DownloadError.NetworkFailed) {
            // 401/403 land here via HTTP-code check; surface as private.
            throw DownloadError.ResolutionFailed("This Vimeo video is private or requires a password.")
        }

        val video = json.objOrNull("video")
        val title = video?.stringOrNull("title")
        val thumb = video?.objOrNull("thumbs")?.stringOrNull("base")

        val progressive = json.objOrNull("files")?.arrOrNull("progressive")?.objects().orEmpty()
        if (progressive.isEmpty()) {
            throw DownloadError.ResolutionFailed(
                "Vimeo returned no progressive download files. The video may be private or restricted."
            )
        }
        val best = progressive
            .mapNotNull { f -> f.stringOrNull("url")?.let { (f.optInt("width", 0)) to it } }
            .maxByOrNull { it.first }
            ?: throw DownloadError.ResolutionFailed("Couldn't parse a download URL from Vimeo's response.")

        return ResolverResult(best.second, title, thumb, isVideo = true, platform = platform)
    }

    private fun extractVideoId(uri: Uri): String? =
        uri.pathSegments.firstOrNull { it.all(Char::isDigit) && it.length >= 5 }

    private fun extractHash(uri: Uri, videoId: String): String? {
        val parts = uri.pathSegments
        val idx = parts.indexOf(videoId)
        if (idx < 0 || idx + 1 >= parts.size) return null
        val c = parts[idx + 1]
        val isHex = c.isNotEmpty() && c.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }
        val allDigits = c.all(Char::isDigit)
        return if (isHex && !allDigits) c else null
    }
}
