package com.example.mediahelper.download.resolvers

import android.net.Uri
import com.example.mediahelper.download.*
import org.json.JSONObject

/** YouTube via the private InnerTube youtubei/v1/player API. Tries several
 *  client profiles (ANDROID_VR, ANDROID, MWEB, …) since Google blocks them
 *  unevenly. Mirrors iOS YouTubeResolver. */
class YouTubeResolver : MediaResolver {
    override val platform = SocialPlatform.YOUTUBE

    private data class Client(
        val name: String, val id: Int, val version: String,
        val userAgent: String, val extra: Map<String, Any>,
    )

    private val wwwEndpoint = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"
    private val apiEndpoint =
        "https://youtubei.googleapis.com/youtubei/v1/player?key=AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w&prettyPrint=false"

    private val clients = listOf(
        Client("ANDROID_VR", 28, "1.65.10",
            "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; en_US; Quest 3) gzip",
            mapOf("deviceMake" to "Oculus", "deviceModel" to "Quest 3", "androidSdkVersion" to 32, "osName" to "Android", "osVersion" to "12L")),
        Client("ANDROID", 3, "20.10.38",
            "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip",
            mapOf("androidSdkVersion" to 30, "osName" to "Android", "osVersion" to "11")),
        Client("MWEB", 2, "2.20250925.01.00",
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3.2 Mobile/15E148 Safari/604.1",
            emptyMap()),
        Client("WEB_EMBEDDED_PLAYER", 56, "1.20260115.01.00",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36",
            emptyMap()),
        Client("TVHTML5_SIMPLY_EMBEDDED_PLAYER", 85, "2.0",
            "Mozilla/5.0 (PlayStation; PlayStation 4/8.03) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/13.0 Safari/605.1.15",
            emptyMap()),
        Client("IOS", 5, "20.10.4",
            "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
            mapOf("deviceModel" to "iPhone16,2", "osName" to "iPhone OS", "osVersion" to "18.3.2", "userInterfaceIdiom" to "handset")),
    )

    override suspend fun resolve(url: String): ResolverResult {
        val videoId = extractVideoId(url)
            ?: throw DownloadError.ResolutionFailed("couldn't find a video ID in that URL.")

        var lastError: Throwable? = null
        for (client in clients) {
            runCatching { resolveWithClient(client, videoId, wwwEndpoint) }.getOrNull()?.let { return it }
            try {
                return resolveWithClient(client, videoId, apiEndpoint)
            } catch (e: Throwable) {
                lastError = e
            }
        }
        throw (lastError ?: DownloadError.ResolutionFailed("all InnerTube clients failed."))
    }

    private suspend fun resolveWithClient(client: Client, videoId: String, endpoint: String): ResolverResult {
        val ctx = JSONObject().apply {
            put("clientName", client.name); put("clientVersion", client.version)
            put("hl", "en"); put("gl", "US"); put("timeZone", "UTC"); put("utcOffsetMinutes", 0)
            client.extra.forEach { (k, v) -> put(k, v) }
        }
        val body = JSONObject().apply {
            put("context", JSONObject().put("client", ctx))
            put("videoId", videoId); put("contentCheckOk", true); put("racyCheckOk", true)
        }.toString()

        val json = Http.postJson(endpoint, body, mapOf(
            "Content-Type" to "application/json",
            "User-Agent" to client.userAgent,
            "Accept-Language" to "en-US,en;q=0.9",
            "X-Youtube-Client-Name" to client.id.toString(),
            "X-Youtube-Client-Version" to client.version,
            "Origin" to "https://www.youtube.com",
            "Referer" to "https://www.youtube.com/",
        ))

        json.objOrNull("playabilityStatus")?.let { p ->
            val status = p.stringOrNull("status")
            if (status != null && status != "OK") {
                throw DownloadError.ResolutionFailed("YouTube says: ${p.stringOrNull("reason") ?: status}")
            }
        }

        val streaming = json.objOrNull("streamingData")
            ?: throw DownloadError.ResolutionFailed("${client.name}: no streamingData.")
        val formats = streaming.arrOrNull("formats")?.objects().orEmpty()
        val best = pickBestProgressive(formats)
            ?: throw DownloadError.ResolutionFailed("${client.name}: no progressive MP4 in formats array.")
        val mediaUrl = best.stringOrNull("url")
            ?: throw DownloadError.ResolutionFailed("${client.name}: chosen format had no direct URL.")

        val details = json.objOrNull("videoDetails")
        val title = details?.stringOrNull("title")
        val thumbs = details?.objOrNull("thumbnail")?.arrOrNull("thumbnails")?.objects().orEmpty()
        val thumb = thumbs.lastOrNull()?.stringOrNull("url")

        return ResolverResult(mediaUrl, title, thumb, isVideo = true, platform = platform)
    }

    private fun extractVideoId(url: String): String? {
        val uri = Uri.parse(url)
        val host = uri.host?.lowercase() ?: return null
        if (host.endsWith("youtu.be")) return sanitizeId(uri.pathSegments.firstOrNull() ?: return null)
        if (uri.path == "/watch") uri.getQueryParameter("v")?.let { return sanitizeId(it) }
        val parts = uri.pathSegments
        if (parts.size >= 2 && parts[0] in listOf("shorts", "embed", "live", "v")) return sanitizeId(parts[1])
        return null
    }

    private fun sanitizeId(raw: String): String? {
        val cleaned = raw.split('?', '&', '#').firstOrNull() ?: raw
        if (cleaned.length < 11 || !cleaned.all { it.isLetterOrDigit() || it == '_' || it == '-' }) return null
        return cleaned.take(11)
    }

    private fun pickBestProgressive(formats: List<JSONObject>): JSONObject? {
        val usable = formats.filter { f ->
            val mime = f.stringOrNull("mimeType") ?: return@filter false
            mime.contains("video/") && mime.contains(",")
        }
        return usable.maxWithOrNull(compareBy(
            { it.optInt("height", 0) },
            { if ((it.stringOrNull("mimeType") ?: "").contains("mp4")) 1 else 0 },
        ))
    }
}
