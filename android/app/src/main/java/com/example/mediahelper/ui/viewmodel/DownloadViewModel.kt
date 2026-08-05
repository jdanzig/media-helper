package com.example.mediahelper.ui.viewmodel

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.mediahelper.download.DownloadError
import com.example.mediahelper.download.GallerySaver
import com.example.mediahelper.download.MediaDownloader
import com.example.mediahelper.download.ResolverRegistry
import com.example.mediahelper.download.SocialPlatform
import com.example.mediahelper.download.SocialUrlParser
import kotlinx.coroutines.launch

/** Download tab state machine: idle → resolving → downloading → done/failed.
 *  Resolves all media in a post, downloads each, and saves to the gallery.
 *  Mirrors iOS DownloadViewModel (transcription pipeline is a later milestone). */
class DownloadViewModel(app: Application) : AndroidViewModel(app) {

    enum class Phase { IDLE, RESOLVING, DOWNLOADING, DONE, FAILED }

    var urlText by mutableStateOf("")
        private set
    var detectedPlatform by mutableStateOf(SocialPlatform.UNKNOWN)
        private set
    var phase by mutableStateOf(Phase.IDLE)
        private set
    var status by mutableStateOf("Paste a link above.")
        private set
    var progress by mutableStateOf(0.0)
        private set
    var resolvedCount by mutableStateOf(0)
        private set
    var downloadedCount by mutableStateOf(0)
        private set

    val isBusy get() = phase == Phase.RESOLVING || phase == Phase.DOWNLOADING

    fun onUrlChange(new: String) {
        urlText = new
        val uri = SocialUrlParser.uriFrom(new)
        if (uri == null) {
            detectedPlatform = SocialPlatform.UNKNOWN
            status = "Paste a link above."
            phase = Phase.IDLE
            return
        }
        // Reflect the tracking-stripped URL back to the field.
        val cleaned = uri.toString()
        if (cleaned != urlText) urlText = cleaned
        detectedPlatform = SocialUrlParser.detectPlatform(uri)
        status = if (detectedPlatform == SocialPlatform.UNKNOWN)
            "Not a recognized social URL." else "Detected ${detectedPlatform.displayName}."
        phase = Phase.IDLE
    }

    fun clear() {
        urlText = ""
        detectedPlatform = SocialPlatform.UNKNOWN
        phase = Phase.IDLE
        status = "Paste a link above."
        progress = 0.0
        resolvedCount = 0
        downloadedCount = 0
    }

    fun start() {
        val uri = SocialUrlParser.uriFrom(urlText) ?: run {
            phase = Phase.FAILED; status = "Invalid URL."; return
        }
        val platform = SocialUrlParser.detectPlatform(uri)
        detectedPlatform = platform
        val resolver = ResolverRegistry.resolverFor(platform) ?: run {
            phase = Phase.FAILED
            status = DownloadError.UnsupportedPlatform(platform).message ?: "Unsupported platform."
            return
        }

        viewModelScope.launch {
            try {
                phase = Phase.RESOLVING
                status = "Looking for media…"
                progress = 0.0
                downloadedCount = 0

                val results = resolver.resolveAll(uri.toString())
                if (results.isEmpty()) throw DownloadError.ResolutionFailed("no media found.")
                resolvedCount = results.size
                status = if (results.size == 1) {
                    if (results[0].isVideo) "Found video. Starting download…" else "Found image. Starting download…"
                } else "Found ${results.size} items. Starting download…"

                phase = Phase.DOWNLOADING
                val ctx = getApplication<Application>()
                results.forEachIndexed { index, result ->
                    if (results.size > 1) status = "Downloading ${index + 1} of ${results.size}…"
                    val base = index.toDouble() / results.size
                    val file = MediaDownloader.download(
                        context = ctx,
                        url = result.mediaUrl,
                        headers = result.requestHeaders,
                        isVideo = result.isVideo,
                        onProgress = { f -> progress = base + f / results.size },
                    )
                    if (result.isVideo) GallerySaver.saveVideo(ctx, file) else GallerySaver.saveImage(ctx, file)
                    downloadedCount = index + 1
                }
                progress = 1.0
                phase = Phase.DONE
                status = savedSummary(results.count { it.isVideo }, results.count { !it.isVideo })
            } catch (e: DownloadError) {
                phase = Phase.FAILED
                status = e.message ?: "Download failed."
            } catch (e: Exception) {
                phase = Phase.FAILED
                status = e.message ?: "Download failed."
            }
        }
    }

    private fun savedSummary(videos: Int, images: Int): String = when {
        videos == 0 -> "Saved $images photo${plural(images)} to your gallery."
        images == 0 -> "Saved $videos video${plural(videos)} to your gallery."
        else -> "Saved $videos video${plural(videos)} and $images photo${plural(images)} to your gallery."
    }

    private fun plural(n: Int) = if (n == 1) "" else "s"
}
