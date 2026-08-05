package com.example.mediahelper.transcribe

import com.example.mediahelper.download.Http
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.File

/** AssemblyAI v2: upload → create job (optional speaker_labels) → poll.
 *  Utterances become speaker-labelled segments. Mirrors iOS AssemblyAITranscriber. */
class AssemblyAiTranscriber(private val apiKey: String) : TranscriptionService {
    override val backend = TranscriptionBackend.ASSEMBLY_AI

    override suspend fun transcribe(
        audioFile: File,
        options: TranscriptionOptions,
        onProgress: (Double) -> Unit,
    ): TranscriptionResult = withContext(Dispatchers.IO) {
        if (options.translateToEnglish) throw TranscriptionError.BackendRejected(
            "AssemblyAI doesn't support translation in this build. Pick OpenAI Whisper for translated subtitles."
        )
        onProgress(0.02)
        val uploadUrl = upload(audioFile); onProgress(0.25)
        val jobId = createJob(uploadUrl, options.speakerLabels); onProgress(0.35)
        pollJob(jobId, onProgress)
    }

    private fun upload(file: File): String {
        val body = file.asRequestBody("application/octet-stream".toMediaTypeOrNull())
        val req = Request.Builder().url("https://api.assemblyai.com/v2/upload")
            .header("Authorization", apiKey).post(body).build()
        Http.client.newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (resp.code !in 200..299) throw TranscriptionError.BackendRejected(text.ifEmpty { "HTTP ${resp.code}" })
            return JSONObject(text).optString("upload_url").ifEmpty {
                throw TranscriptionError.Decoding("no upload_url")
            }
        }
    }

    private fun createJob(audioUrl: String, speakerLabels: Boolean): String {
        val json = JSONObject().apply {
            put("audio_url", audioUrl)
            put("speaker_labels", speakerLabels)
            put("language_detection", true)
            put("punctuate", true)
            put("format_text", true)
        }.toString()
        val req = Request.Builder().url("https://api.assemblyai.com/v2/transcript")
            .header("Authorization", apiKey)
            .post(json.toRequestBody("application/json".toMediaTypeOrNull())).build()
        Http.client.newCall(req).execute().use { resp ->
            val text = resp.body?.string().orEmpty()
            if (resp.code !in 200..299) throw TranscriptionError.BackendRejected(text.ifEmpty { "HTTP ${resp.code}" })
            return JSONObject(text).optString("id").ifEmpty { throw TranscriptionError.Decoding("no job id") }
        }
    }

    private suspend fun pollJob(id: String, onProgress: (Double) -> Unit): TranscriptionResult {
        val endpoint = "https://api.assemblyai.com/v2/transcript/$id"
        var ticks = 0
        val deadline = 200 // 200 * 3s = 10 min
        while (ticks < deadline) {
            delay(3000)
            ticks++
            onProgress(minOf(0.95, 0.35 + ticks * 0.02))
            val req = Request.Builder().url(endpoint).header("Authorization", apiKey).build()
            val json = Http.client.newCall(req).execute().use { resp ->
                if (resp.code !in 200..299) return@use null
                runCatching { JSONObject(resp.body?.string().orEmpty()) }.getOrNull()
            } ?: continue
            when (json.optString("status")) {
                "completed" -> return decodeResult(json)
                "error" -> throw TranscriptionError.BackendRejected(json.optString("error", "AssemblyAI error"))
                else -> Unit // queued / processing
            }
        }
        throw TranscriptionError.BackendRejected("Timed out waiting for AssemblyAI job.")
    }

    private fun decodeResult(json: JSONObject): TranscriptionResult {
        val language = json.optString("language_code").ifEmpty { null }

        json.optJSONArray("utterances")?.takeIf { it.length() > 0 }?.let { arr ->
            val segs = (0 until arr.length()).mapNotNull { i ->
                val u = arr.optJSONObject(i) ?: return@mapNotNull null
                val text = u.optString("text").ifEmpty { return@mapNotNull null }
                TranscriptSegment(
                    start = u.optDouble("start", 0.0) / 1000.0,
                    end = u.optDouble("end", 0.0) / 1000.0,
                    text = text.trim(),
                    speaker = u.optString("speaker").ifEmpty { null }?.let { "Speaker $it" },
                )
            }
            return TranscriptionResult(language, false, segs)
        }

        json.optJSONArray("words")?.takeIf { it.length() > 0 }?.let { words ->
            return TranscriptionResult(language, false, groupWords(words))
        }

        val text = json.optString("text")
        val duration = json.optDouble("audio_duration", 0.0)
        return TranscriptionResult(language, false, listOf(TranscriptSegment(0.0, duration, text, null)))
    }

    private fun groupWords(words: org.json.JSONArray, targetSeconds: Double = 8.0): List<TranscriptSegment> {
        val out = mutableListOf<TranscriptSegment>()
        val buffer = mutableListOf<String>()
        var bufStart = Double.NaN
        var bufEnd = 0.0
        fun flush() {
            if (buffer.isEmpty() || bufStart.isNaN()) return
            out.add(TranscriptSegment(bufStart / 1000.0, bufEnd / 1000.0, buffer.joinToString(" "), null))
            buffer.clear(); bufStart = Double.NaN; bufEnd = 0.0
        }
        for (i in 0 until words.length()) {
            val w = words.optJSONObject(i) ?: continue
            val text = w.optString("text").ifEmpty { continue }
            val start = w.optDouble("start", 0.0)
            val end = w.optDouble("end", 0.0)
            if (bufStart.isNaN()) bufStart = start
            buffer.add(text); bufEnd = end
            if ((bufEnd - bufStart) / 1000.0 >= targetSeconds) flush()
        }
        flush()
        return out
    }
}
