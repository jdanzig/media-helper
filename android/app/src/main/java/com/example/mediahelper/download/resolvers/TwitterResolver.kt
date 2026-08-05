package com.example.mediahelper.download.resolvers

import android.net.Uri
import com.example.mediahelper.download.*
import org.json.JSONObject
import kotlin.math.PI

/** X / Twitter — public syndication endpoint (cdn.syndication.twimg.com),
 *  with an og: scrape fallback. Handles up to 4 media items per tweet. */
class TwitterResolver : MediaResolver {
    override val platform = SocialPlatform.TWITTER

    override suspend fun resolve(url: String): ResolverResult {
        extractTweetId(url)?.let { id ->
            runCatching { resolveViaSyndication(id) }.getOrNull()?.let { return it }
        }
        return resolveViaOpenGraph(url)
    }

    override suspend fun resolveAll(url: String): List<ResolverResult> {
        extractTweetId(url)?.let { id ->
            runCatching { allItemsViaSyndication(id) }.getOrNull()?.takeIf { it.isNotEmpty() }?.let { return it }
        }
        return listOf(resolveViaOpenGraph(url))
    }

    private suspend fun allItemsViaSyndication(tweetId: String): List<ResolverResult> {
        val (title, mediaDetails) = fetchSyndicationMedia(tweetId)
        val results = mutableListOf<ResolverResult>()
        for (entry in mediaDetails) {
            val type = entry.stringOrNull("type")
            val thumb = entry.stringOrNull("media_url_https")
            when (type) {
                "video", "animated_gif" -> {
                    val variants = entry.objOrNull("video_info")?.arrOrNull("variants")?.objects().orEmpty()
                    val best = pickBestVariant(variants) ?: continue
                    val u = best.stringOrNull("url") ?: continue
                    results += ResolverResult(u, title, thumb, isVideo = true, platform = platform)
                }
                "photo" -> if (thumb != null)
                    results += ResolverResult(thumb, title, thumb, isVideo = false, platform = platform)
            }
        }
        return results
    }

    private suspend fun resolveViaSyndication(tweetId: String): ResolverResult {
        val all = allItemsViaSyndication(tweetId)
        return all.firstOrNull { it.isVideo } ?: all.firstOrNull()
            ?: throw DownloadError.ResolutionFailed("syndication returned no media.")
    }

    private suspend fun fetchSyndicationMedia(tweetId: String): Pair<String?, List<JSONObject>> {
        val token = syndicationToken(tweetId)
        val endpoint = Uri.parse("https://cdn.syndication.twimg.com/tweet-result").buildUpon()
            .appendQueryParameter("id", tweetId)
            .appendQueryParameter("token", token)
            .appendQueryParameter("lang", "en")
            .build().toString()
        val json = Http.getJson(endpoint, mapOf(
            "User-Agent" to Http.DESKTOP_UA,
            "Referer" to "https://platform.twitter.com",
        ))
        val title = json.stringOrNull("text") ?: json.objOrNull("user")?.stringOrNull("name")
        val media = json.arrOrNull("mediaDetails")?.objects().orEmpty()
        return title to media
    }

    private fun pickBestVariant(variants: List<JSONObject>): JSONObject? =
        variants.filter { it.stringOrNull("content_type") == "video/mp4" }
            .maxByOrNull { it.optInt("bitrate", 0) }

    private suspend fun resolveViaOpenGraph(url: String): ResolverResult {
        val normalized = url.replace("//x.com", "//twitter.com").replace("//www.x.com", "//www.twitter.com")
        val html = Http.getString(normalized)
        val title = HtmlScraper.metaContent(html, "og:title")
        val thumb = HtmlScraper.metaContent(html, "og:image")
        val video = HtmlScraper.metaContent(html, "og:video") ?: HtmlScraper.metaContent(html, "og:video:url")
        if (video != null) return ResolverResult(video, title, thumb, isVideo = true, platform = platform)
        if (thumb != null) return ResolverResult(thumb, title, thumb, isVideo = false, platform = platform)
        throw DownloadError.ResolutionFailed("the tweet may require login, or Twitter stopped emitting og tags.")
    }

    private fun extractTweetId(url: String): String? {
        val parts = Uri.parse(url).pathSegments
        val i = parts.indexOf("status")
        if (i < 0 || i + 1 >= parts.size) return null
        val c = parts[i + 1]
        return if (c.all(Char::isDigit)) c else null
    }

    /** ((Number(id)/1e15)*Math.PI).toString(36).replace(/(0+|\.)/g,"") */
    private fun syndicationToken(tweetId: String): String {
        val n = tweetId.toDoubleOrNull() ?: return "a"
        val v = (n / 1e15) * PI
        val base36 = radix36(v).replace("0", "").replace(".", "")
        return base36.ifEmpty { "a" }
    }

    private fun radix36(value: Double): String {
        if (!value.isFinite()) return "0"
        val whole = value.toLong()
        var frac = value - whole.toDouble()
        val d = "0123456789abcdefghijklmnopqrstuvwxyz"

        fun intToBase36(x: Long): String {
            if (x == 0L) return "0"
            var n = x
            val out = StringBuilder()
            while (n > 0) { out.append(d[(n % 36).toInt()]); n /= 36 }
            return out.reverse().toString()
        }

        val result = StringBuilder(intToBase36(whole))
        if (frac > 0) {
            result.append('.')
            for (unused in 0 until 11) {
                frac *= 36
                val k = frac.toInt()
                result.append(d[k])
                frac -= k.toDouble()
                if (frac <= 0) break
            }
        }
        return result.toString()
    }
}
