package com.example.mediahelper.download

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.io.File
import java.util.UUID

/** Streams a resolved media URL to a temp file, reporting 0..1 progress.
 *  `headers` are forwarded verbatim (some CDNs require the resolver's
 *  UA/Referer/Cookie). Mirrors iOS MediaDownloader. */
object MediaDownloader {

    /** Downloads to [context].cacheDir and returns the file. [onProgress] gets
     *  fractions in 0..1 (only when the server reports a content length). */
    suspend fun download(
        context: Context,
        url: String,
        headers: Map<String, String> = emptyMap(),
        isVideo: Boolean,
        onProgress: (Double) -> Unit = {},
    ): File = withContext(Dispatchers.IO) {
        val req = Request.Builder().url(url).apply {
            headers.forEach { (k, v) -> header(k, v) }
        }.build()

        Http.client.newCall(req).execute().use { resp ->
            if (resp.code !in 200..399) throw DownloadError.NetworkFailed("HTTP ${resp.code}")
            val body = resp.body ?: throw DownloadError.NetworkFailed("empty response")

            val ext = guessExtension(url, resp.header("Content-Type"), isVideo)
            val out = File(context.cacheDir, "${UUID.randomUUID()}.$ext")
            val total = body.contentLength()

            body.byteStream().use { input ->
                out.outputStream().use { output ->
                    val buf = ByteArray(64 * 1024)
                    var written = 0L
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        output.write(buf, 0, n)
                        written += n
                        if (total > 0) onProgress(written.toDouble() / total)
                    }
                }
            }
            onProgress(1.0)
            out
        }
    }

    private fun guessExtension(url: String, contentType: String?, isVideo: Boolean): String {
        val pathExt = url.substringBefore('?').substringAfterLast('.', "")
        if (pathExt.length in 2..4 && pathExt.all { it.isLetterOrDigit() }) return pathExt
        contentType?.let {
            when {
                it.contains("mp4") -> return "mp4"
                it.contains("quicktime") -> return "mov"
                it.contains("jpeg") -> return "jpg"
                it.contains("png") -> return "png"
                it.contains("webp") -> return "webp"
            }
        }
        return if (isVideo) "mp4" else "jpg"
    }
}
