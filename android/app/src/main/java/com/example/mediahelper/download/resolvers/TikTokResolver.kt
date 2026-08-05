package com.example.mediahelper.download.resolvers

import com.example.mediahelper.download.*
import com.example.mediahelper.store.SecureStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request

/** TikTok — scrapes the UNIVERSAL_DATA rehydration blob for playAddr. A stored
 *  sessionid unlocks age/sensitivity-gated posts; the cookies TikTok sets are
 *  re-attached to the CDN download. Mirrors iOS TikTokResolver. */
class TikTokResolver : MediaResolver {
    override val platform = SocialPlatform.TIKTOK

    private val ua = Http.DESKTOP_UA

    /** In-memory jar scoped to one resolve, seeded with the saved sessionid. */
    private class SimpleCookieJar : CookieJar {
        private val jar = mutableListOf<Cookie>()
        fun seed(cookie: Cookie) { jar.add(cookie) }
        override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) { jar.addAll(cookies) }
        override fun loadForRequest(url: HttpUrl): List<Cookie> = jar.filter { it.matches(url) }
        fun headerFor(url: HttpUrl): String =
            jar.filter { it.matches(url) }.joinToString("; ") { "${it.name}=${it.value}" }
    }

    override suspend fun resolve(url: String): ResolverResult = withContext(Dispatchers.IO) {
        val cookieJar = SimpleCookieJar()
        SecureStore.load(SecureStore.Item.TikTokSessionCookie)?.let { sid ->
            cookieJar.seed(Cookie.Builder().name("sessionid").value(sid).domain("tiktok.com").build())
        }
        val client: OkHttpClient = Http.client.newBuilder().cookieJar(cookieJar).build()

        val req = Request.Builder().url(url)
            .header("User-Agent", ua)
            .header("Accept-Language", "en-US,en;q=0.9")
            .build()
        val (landingUrl, html) = client.newCall(req).execute().use { resp ->
            if (resp.code !in 200..399) throw DownloadError.NetworkFailed("tiktok HTTP ${resp.code}")
            resp.request.url to (resp.body?.string() ?: throw DownloadError.ResolutionFailed("non-UTF8 response."))
        }

        val title = HtmlScraper.metaContent(html, "og:title")
        val thumb = HtmlScraper.metaContent(html, "og:image")
        val cookieHeader = cookieJar.headerFor(landingUrl)
        val headers = buildMap {
            put("User-Agent", ua)
            put("Referer", "https://www.tiktok.com/")
            put("Range", "bytes=0-")
            if (cookieHeader.isNotEmpty()) put("Cookie", cookieHeader)
        }

        for (key in listOf("playAddr_h264", "playAddr", "downloadAddr")) {
            val candidate = HtmlScraper.firstCaptureGroup(html, "\"$key\":\"([^\"]+)\"")?.let { decodeJsonString(it) }
            if (candidate != null) {
                return@withContext ResolverResult(candidate, title, thumb, isVideo = true, platform, headers)
            }
        }
        HtmlScraper.metaContent(html, "og:video")?.let {
            return@withContext ResolverResult(it, title, thumb, isVideo = true, platform, headers)
        }

        if (html.contains("AgeGate") || html.contains("not be comfortable")) {
            throw DownloadError.LoginRequired(SocialPlatform.TIKTOK)
        }
        throw DownloadError.ResolutionFailed("TikTok didn't expose playAddr/og:video — markup may have changed.")
    }
}
