package com.example.mediahelper.transcribe

import com.example.mediahelper.download.Http
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.MultipartBody
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import org.json.JSONObject
import java.io.File

/** OpenAI Whisper (whisper-1) — /v1/audio/transcriptions or /translations,
 *  verbose_json for segment timestamps. Mirrors iOS OpenAIWhisperTranscriber. */
class OpenAiWhisperTranscriber(private val apiKey: String) : TranscriptionService {
    override val backend = TranscriptionBackend.OPENAI_WHISPER
    private val sizeLimit = 25L * 1024 * 1024

    override suspend fun transcribe(
        audioFile: File,
        options: TranscriptionOptions,
        onProgress: (Double) -> Unit,
    ): TranscriptionResult = withContext(Dispatchers.IO) {
        onProgress(0.02)
        if (audioFile.length() > sizeLimit) throw TranscriptionError.FileTooLarge(audioFile.length(), sizeLimit)

        val endpoint = if (options.translateToEnglish)
            "https://api.openai.com/v1/audio/translations"
        else
            "https://api.openai.com/v1/audio/transcriptions"

        val mime = mimeFor(audioFile).toMediaTypeOrNull()
        val body = MultipartBody.Builder().setType(MultipartBody.FORM)
            .addFormDataPart("model", "whisper-1")
            .addFormDataPart("response_format", "verbose_json")
            .addFormDataPart("timestamp_granularities[]", "segment")
            .addFormDataPart("file", audioFile.name, audioFile.asRequestBody(mime))
            .build()

        val req = Request.Builder().url(endpoint)
            .header("Authorization", "Bearer $apiKey")
            .post(body).build()

        onProgress(0.3)
        Http.client.newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (resp.code !in 200..299) throw TranscriptionError.BackendRejected(text.ifEmpty { "HTTP ${resp.code}" })
            onProgress(0.85)
            val json = runCatching { JSONObject(text) }.getOrElse { throw TranscriptionError.Decoding(it.message ?: "bad JSON") }
            val segs = json.optJSONArray("segments")?.let { arr ->
                (0 until arr.length()).mapNotNull { i ->
                    val o = arr.optJSONObject(i) ?: return@mapNotNull null
                    TranscriptSegment(o.optDouble("start", 0.0), o.optDouble("end", 0.0),
                        o.optString("text").trim(), null)
                }
            } ?: emptyList()
            onProgress(1.0)
            TranscriptionResult(
                language = if (options.translateToEnglish) "en" else json.optString("language").ifEmpty { null },
                isTranslation = options.translateToEnglish,
                segments = segs,
            )
        }
    }

    private fun mimeFor(file: File): String = when (file.extension.lowercase()) {
        "m4a", "mp4" -> "audio/mp4"
        "mp3" -> "audio/mpeg"
        "wav" -> "audio/wav"
        "flac" -> "audio/flac"
        "ogg" -> "audio/ogg"
        else -> "application/octet-stream"
    }
}
