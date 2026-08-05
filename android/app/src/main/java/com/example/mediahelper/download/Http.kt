package com.example.mediahelper.download

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/** Shared HTTP + scraping utilities. Mirrors iOS HTMLScraper + the per-resolver
 *  networking. OkHttp calls run on Dispatchers.IO. */
object Http {

    const val DESKTOP_UA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605.1.15 " +
            "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /** No auto-redirect client (for HEAD redirect inspection, TikTok/FB). */
    val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    /** Client that does NOT follow redirects — used to read Location headers. */
    val noRedirectClient: OkHttpClient = client.newBuilder()
        .followRedirects(false)
        .followSslRedirects(false)
        .build()

    suspend fun getString(
        url: String,
        headers: Map<String, String> = mapOf(
            "User-Agent" to DESKTOP_UA,
            "Accept-Language" to "en-US,en;q=0.9",
        ),
    ): String = withContext(Dispatchers.IO) {
        val req = Request.Builder().url(url).apply {
            headers.forEach { (k, v) -> header(k, v) }
        }.build()
        client.newCall(req).execute().use { resp ->
            if (resp.code !in 200..399) {
                throw DownloadError.NetworkFailed("HTTP ${resp.code}")
            }
            resp.body?.string() ?: throw DownloadError.ResolutionFailed("empty response body")
        }
    }

    suspend fun getJson(url: String, headers: Map<String, String> = mapOf("User-Agent" to DESKTOP_UA)): JSONObject =
        JSONObject(getString(url, headers))

    suspend fun postJson(
        url: String,
        bodyJson: String,
        headers: Map<String, String>,
    ): JSONObject = withContext(Dispatchers.IO) {
        val body = bodyJson.toRequestBody("application/json".toMediaType())
        val req = Request.Builder().url(url).post(body).apply {
            headers.forEach { (k, v) -> header(k, v) }
        }.build()
        client.newCall(req).execute().use { resp ->
            if (resp.code !in 200..299) throw DownloadError.NetworkFailed("HTTP ${resp.code}")
            JSONObject(resp.body?.string() ?: throw DownloadError.ResolutionFailed("empty JSON"))
        }
    }

    /** GET the Location header of a single redirect hop (null if none). */
    suspend fun redirectLocation(url: String, userAgent: String = DESKTOP_UA): String? =
        withContext(Dispatchers.IO) {
            val req = Request.Builder().url(url).head().header("User-Agent", userAgent).build()
            noRedirectClient.newCall(req).execute().use { resp ->
                if (resp.code in 300..399) resp.header("Location") else null
            }
        }
}

/** Shared HTML scraping — meta tags, capture groups, entity decode. */
object HtmlScraper {
    fun metaContent(html: String, property: String): String? {
        val p = Regex.escape(property)
        val patterns = listOf(
            "<meta[^>]+property=[\"']$p[\"'][^>]+content=[\"']([^\"']+)[\"']",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+property=[\"']$p[\"']",
            "<meta[^>]+name=[\"']$p[\"'][^>]+content=[\"']([^\"']+)[\"']",
        )
        for (pat in patterns) firstCaptureGroup(html, pat)?.let { return it }
        return null
    }

    fun firstCaptureGroup(text: String, pattern: String): String? {
        val re = runCatching { Regex(pattern, RegexOption.IGNORE_CASE) }.getOrNull() ?: return null
        val m = re.find(text) ?: return null
        val g = m.groupValues.getOrNull(1) ?: return null
        return decodeEntities(g)
    }

    /** Every first-capture-group across all matches (no entity decode — the
     *  caller applies JSON-string decoding). Used by the Threads resolver. */
    fun allCaptureGroups(text: String, pattern: String): List<String> {
        val re = runCatching { Regex(pattern, RegexOption.IGNORE_CASE) }.getOrNull() ?: return emptyList()
        return re.findAll(text).mapNotNull { it.groupValues.getOrNull(1) }.toList()
    }

    fun decodeEntities(s: String): String = s
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

/** Decode the subset of JSON string escapes the resolvers rely on:
 *  \uXXXX, \/, \\, \", \n, \r, \t. Mirrors the per-resolver Swift decoders. */
fun decodeJsonString(s: String): String {
    val out = StringBuilder(s.length)
    var i = 0
    while (i < s.length) {
        val c = s[i]
        if (c == '\\' && i + 1 < s.length) {
            when (s[i + 1]) {
                '/' -> { out.append('/'); i += 2 }
                '\\' -> { out.append('\\'); i += 2 }
                '"' -> { out.append('"'); i += 2 }
                'n' -> { out.append('\n'); i += 2 }
                'r' -> { out.append('\r'); i += 2 }
                't' -> { out.append('\t'); i += 2 }
                'u' -> {
                    if (i + 6 <= s.length) {
                        val hex = s.substring(i + 2, i + 6)
                        val code = hex.toIntOrNull(16)
                        if (code != null) { out.append(code.toChar()); i += 6 } else { out.append(c); i++ }
                    } else { out.append(c); i++ }
                }
                else -> { out.append(c); i++ }
            }
        } else {
            out.append(c); i++
        }
    }
    return out.toString()
}
