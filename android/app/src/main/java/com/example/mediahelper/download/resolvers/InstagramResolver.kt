package com.example.mediahelper.download.resolvers

import android.net.Uri
import com.example.mediahelper.download.*
import com.example.mediahelper.store.SecureStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.FormBody
import okhttp3.Request
import org.json.JSONObject

/** Instagram. Order: GraphQL (currently dead) → OpenGraph → embed → OpenGraph
 *  (app UA) → authenticated private API (i.instagram.com) when a sessionid is
 *  stored. Carousels return every child. Mirrors iOS InstagramResolver. */
class InstagramResolver : MediaResolver {
    override val platform = SocialPlatform.INSTAGRAM

    private val desktopUA = Http.DESKTOP_UA
    private val appUA =
        "Instagram 250.0.0.21.109 (iPhone14,3; iOS 17_0; en_US; en; scale=3.00; 1170x2532; 401047810) AppleWebKit/420+"
    private val igAppId = "936619743392459"
    private val docId = "10015901848480474"   // ⚠️ currently broken; kept for when GraphQL returns
    private val lsd = "AdRajKE-dbL5DFDu4y87RHQZaXA"

    // MARK: entry points

    override suspend fun resolveAll(url: String): List<ResolverResult> {
        extractShortcode(url)?.let { sc ->
            runCatching { resolveAllViaGraphQL(sc) }.getOrNull()?.takeIf { it.isNotEmpty() }?.let { return it }
            SecureStore.load(SecureStore.Item.InstagramSessionCookie)?.let { sid ->
                runCatching { resolveAllViaPrivateAPI(sc, sid) }.getOrNull()?.takeIf { it.isNotEmpty() }?.let { return it }
            }
        }
        return listOf(resolve(url))
    }

    override suspend fun resolve(url: String): ResolverResult {
        val pathIsVideo = pathImpliesVideo(url)
        val shortcode = extractShortcode(url)

        shortcode?.let { sc ->
            runCatching { resolveViaGraphQL(sc) }.getOrNull()?.takeIf { it.isVideo }?.let { return it }
        }
        runCatching { resolveViaOpenGraph(url, desktopUA) }.getOrNull()?.takeIf { it.isVideo }?.let { return it }
        shortcode?.let { sc ->
            runCatching { resolveViaEmbed(sc) }.getOrNull()?.takeIf { it.isVideo }?.let { return it }
        }
        runCatching { resolveViaOpenGraph(url, appUA) }.getOrNull()?.takeIf { it.isVideo }?.let { return it }

        // Authenticated fallback — the only surface that honours the cookie.
        if (shortcode != null) {
            SecureStore.load(SecureStore.Item.InstagramSessionCookie)?.let { sid ->
                runCatching { resolveAllViaPrivateAPI(shortcode, sid).firstOrNull() }.getOrNull()
                    ?.takeIf { it.isVideo || !pathIsVideo }?.let { return it }
                throw DownloadError.LoginRequired(SocialPlatform.INSTAGRAM)
            }
        }
        if (pathIsVideo) throw DownloadError.LoginRequired(SocialPlatform.INSTAGRAM)

        shortcode?.let { sc -> runCatching { resolveViaGraphQL(sc) }.getOrNull()?.let { return it } }
        return resolveViaOpenGraph(url, desktopUA)
    }

    // MARK: GraphQL (pass 1 — currently broken upstream, kept for revival)

    private suspend fun fetchGraphQLMedia(shortcode: String): JSONObject = withContext(Dispatchers.IO) {
        val body = FormBody.Builder()
            .add("doc_id", docId).add("lsd", lsd).add("variables", "{\"shortcode\":\"$shortcode\"}")
            .build()
        val req = Request.Builder().url("https://www.instagram.com/api/graphql").post(body)
            .header("User-Agent", desktopUA)
            .header("X-IG-App-ID", igAppId)
            .header("X-FB-LSD", lsd)
            .header("X-ASBD-ID", "129477")
            .header("Origin", "https://www.instagram.com")
            .header("Referer", "https://www.instagram.com/")
            .build()
        Http.client.newCall(req).execute().use { resp ->
            if (resp.code !in 200..299) throw DownloadError.NetworkFailed("IG GraphQL HTTP ${resp.code}")
            val json = JSONObject(resp.body?.string() ?: throw DownloadError.ResolutionFailed("empty GraphQL"))
            json.objOrNull("data")?.objOrNull("xdt_shortcode_media")
                ?: throw DownloadError.ResolutionFailed("GraphQL: unexpected response shape.")
        }
    }

    private suspend fun resolveAllViaGraphQL(shortcode: String): List<ResolverResult> {
        val media = fetchGraphQLMedia(shortcode)
        val title = media.objOrNull("owner")?.stringOrNull("username")?.let { "@$it" }
        media.objOrNull("edge_sidecar_to_children")?.arrOrNull("edges")?.objects()?.let { edges ->
            val results = edges.mapNotNull { edge ->
                val node = edge.objOrNull("node") ?: return@mapNotNull null
                graphNodeToResult(node, title)
            }
            if (results.isNotEmpty()) return results
        }
        return listOf(graphNodeToResult(media, title)
            ?: throw DownloadError.ResolutionFailed("GraphQL: media found but no URL extracted."))
    }

    private fun graphNodeToResult(node: JSONObject, title: String?): ResolverResult? {
        val thumb = node.stringOrNull("display_url")
        if (node.optBoolean("is_video")) {
            node.stringOrNull("video_url")?.let {
                return ResolverResult(it, title, thumb, isVideo = true, platform = platform)
            }
        }
        return thumb?.let { ResolverResult(it, title, it, isVideo = false, platform = platform) }
    }

    private suspend fun resolveViaGraphQL(shortcode: String): ResolverResult =
        resolveAllViaGraphQL(shortcode).firstOrNull()
            ?: throw DownloadError.ResolutionFailed("GraphQL: media found but no URL extracted.")

    // MARK: embed

    private suspend fun resolveViaEmbed(shortcode: String): ResolverResult {
        val html = Http.getString(
            "https://www.instagram.com/p/$shortcode/embed/captioned/",
            mapOf("User-Agent" to desktopUA, "Accept-Language" to "en-US,en;q=0.9"),
        )
        val title = HtmlScraper.firstCaptureGroup(html, "<div class=\"CaptionUsername\"[^>]*>([^<]+)</div>")
            ?: HtmlScraper.metaContent(html, "og:title")

        for (key in listOf("video_url", "videoUrl", "contentUrl")) {
            extractEscaped(html, key)?.let { v ->
                return ResolverResult(v, title, extractEscaped(html, "display_url"), isVideo = true, platform = platform)
            }
        }
        (HtmlScraper.metaContent(html, "og:video") ?: HtmlScraper.metaContent(html, "og:video:secure_url"))?.let {
            return ResolverResult(it, title, extractEscaped(html, "display_url"), isVideo = true, platform = platform)
        }
        extractEscaped(html, "display_url")?.let {
            return ResolverResult(it, title, it, isVideo = false, platform = platform)
        }
        throw DownloadError.ResolutionFailed("embed page had no media fields.")
    }

    // MARK: authenticated private API

    private suspend fun resolveAllViaPrivateAPI(shortcode: String, sessionId: String): List<ResolverResult> =
        withContext(Dispatchers.IO) {
            val mediaId = mediaId(shortcode)
                ?: throw DownloadError.ResolutionFailed("couldn't derive media id from shortcode.")
            val req = Request.Builder().url("https://i.instagram.com/api/v1/media/$mediaId/info/")
                .header("User-Agent", appUA)
                .header("X-IG-App-ID", igAppId)
                .header("X-IG-Capabilities", "3brTvw==")
                .header("Cookie", "sessionid=$sessionId")
                .build()
            Http.client.newCall(req).execute().use { resp ->
                if (resp.code !in 200..299) throw DownloadError.LoginRequired(SocialPlatform.INSTAGRAM)
                val json = JSONObject(resp.body?.string() ?: throw DownloadError.ResolutionFailed("empty API body"))
                val item = json.arrOrNull("items")?.objects()?.firstOrNull()
                    ?: throw DownloadError.ResolutionFailed("private API: unexpected response shape.")
                resultsFromMediaItem(item)
            }
        }

    private fun resultsFromMediaItem(item: JSONObject): List<ResolverResult> {
        val title = item.objOrNull("user")?.stringOrNull("username")?.let { "@$it" }
        item.arrOrNull("carousel_media")?.objects()?.takeIf { it.isNotEmpty() }?.let { carousel ->
            val children = carousel.mapNotNull { nodeToResult(it, title) }
            if (children.isNotEmpty()) return children
        }
        nodeToResult(item, title)?.let { return listOf(it) }
        throw DownloadError.ResolutionFailed("private API: media item had no URL.")
    }

    private fun nodeToResult(node: JSONObject, title: String?): ResolverResult? {
        val thumb = node.objOrNull("image_versions2")?.arrOrNull("candidates")?.objects()
            ?.firstOrNull()?.stringOrNull("url")
        node.arrOrNull("video_versions")?.objects()?.firstOrNull()?.stringOrNull("url")?.let {
            return ResolverResult(it, title, thumb, isVideo = true, platform = platform)
        }
        return thumb?.let { ResolverResult(it, title, it, isVideo = false, platform = platform) }
    }

    // MARK: OpenGraph / inline JSON

    private suspend fun resolveViaOpenGraph(url: String, userAgent: String): ResolverResult {
        val html = Http.getString(url, mapOf("User-Agent" to userAgent, "Accept-Language" to "en-US,en;q=0.9"))
        val title = HtmlScraper.metaContent(html, "og:title")
        val thumb = HtmlScraper.metaContent(html, "og:image")

        (HtmlScraper.metaContent(html, "og:video") ?: HtmlScraper.metaContent(html, "og:video:secure_url"))?.let {
            return ResolverResult(it, title, thumb, isVideo = true, platform = platform)
        }
        for (key in listOf("playable_url_quality_hd", "playable_url", "video_url", "videoUrl", "contentUrl")) {
            extractEscaped(html, key)?.let {
                return ResolverResult(it, title, thumb, isVideo = true, platform = platform)
            }
        }
        extractFirstUrlAfter("\"video_versions\":[", html)?.let {
            return ResolverResult(it, title, thumb, isVideo = true, platform = platform)
        }
        extractFirstMp4(html)?.let {
            return ResolverResult(it, title, thumb, isVideo = true, platform = platform)
        }
        thumb?.let { return ResolverResult(it, title, it, isVideo = false, platform = platform) }
        throw DownloadError.ResolutionFailed("post likely requires login; sign-in flow not implemented.")
    }

    // MARK: parsing helpers

    private fun pathImpliesVideo(url: String): Boolean {
        val first = Uri.parse(url).pathSegments.firstOrNull()?.lowercase()
        return first == "reel" || first == "reels" || first == "tv"
    }

    private fun extractShortcode(url: String): String? {
        val parts = Uri.parse(url).pathSegments
        if (parts.size < 2 || parts[0].lowercase() !in listOf("p", "reel", "reels", "tv")) return null
        val c = parts[1]
        return if (c.all { it.isLetterOrDigit() || it == '_' || it == '-' }) c else null
    }

    /** "key":"value" (Form 1) or \"key\":\"value\" (Form 2, doubly-escaped). */
    private fun extractEscaped(html: String, key: String): String? {
        HtmlScraper.firstCaptureGroup(html, "\"$key\":\"([^\"]+)\"")?.let { return decodeJsonString(it) }
        val p2 = "\\\\\"$key\\\\\":\\\\\"([^\"]+?)\\\\\""
        HtmlScraper.firstCaptureGroup(html, p2)?.let { return decodeJsonString(decodeJsonString(it)) }
        return null
    }

    private fun extractFirstUrlAfter(anchor: String, html: String): String? {
        val idx = html.indexOf(anchor)
        if (idx < 0) return null
        val tail = html.substring(idx + anchor.length)
        return HtmlScraper.firstCaptureGroup(tail, "\"url\":\"([^\"]+)\"")?.let { decodeJsonString(it) }
    }

    private fun extractFirstMp4(html: String): String? =
        HtmlScraper.firstCaptureGroup(html, "(https?:[^\"\\\\]+?\\.mp4[^\"\\\\]*)")?.let { decodeJsonString(it) }

    /** Shortcode → numeric media id (base64 URL-safe alphabet).
     *  ponytail: ULong, no overflow guard; current IDs fit, revisit if IG's PKs ever exceed 64 bits. */
    private fun mediaId(shortcode: String): String? {
        val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        var id = 0uL
        for (ch in shortcode) {
            val v = alphabet.indexOf(ch)
            if (v < 0) return null
            id = id * 64uL + v.toULong()
        }
        return id.toString()
    }
}
