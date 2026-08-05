package com.example.mediahelper.ui.viewmodel

import android.app.Application
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.mediahelper.transcribe.AudioExtractor
import com.example.mediahelper.transcribe.SubtitleRenderer
import com.example.mediahelper.transcribe.TranscriptFormatter
import com.example.mediahelper.transcribe.TranscriptionBackend
import com.example.mediahelper.transcribe.TranscriptionError
import com.example.mediahelper.transcribe.TranscriptionOptions
import com.example.mediahelper.transcribe.TranscriptionServiceFactory
import kotlinx.coroutines.launch

/** Transcribe tab: pick a video, extract audio, transcribe via the chosen
 *  cloud backend, produce transcript + optional SRT text. Mirrors iOS
 *  TranscribeViewModel (burn-in / on-device omitted). */
class TranscribeViewModel(app: Application) : AndroidViewModel(app) {

    enum class Phase { IDLE, RUNNING, DONE, FAILED }

    var video by mutableStateOf<Uri?>(null)
        private set
    var backend by mutableStateOf(TranscriptionServiceFactory.defaultAvailableBackend())
    var translate by mutableStateOf(false)
    var speakerLabels by mutableStateOf(false)
    var makeSubtitles by mutableStateOf(false)

    var phase by mutableStateOf(Phase.IDLE)
        private set
    var status by mutableStateOf("Pick a video to transcribe.")
        private set
    var progress by mutableStateOf(0.0)
        private set
    var transcript by mutableStateOf<String?>(null)
        private set
    var srt by mutableStateOf<String?>(null)
        private set

    val backends = listOf(TranscriptionBackend.OPENAI_WHISPER, TranscriptionBackend.ASSEMBLY_AI)
    val isBusy get() = phase == Phase.RUNNING

    fun pickVideo(uri: Uri) {
        video = uri
        transcript = null; srt = null
        phase = Phase.IDLE
        status = "Video selected. Choose options and Start."
    }

    fun start() {
        val uri = video ?: run { status = "Pick a video first."; return }
        viewModelScope.launch {
            try {
                phase = Phase.RUNNING
                progress = 0.0
                status = "Extracting audio…"
                val ctx = getApplication<Application>()
                val audio = AudioExtractor.extractToM4a(ctx, uri)

                status = "Transcribing with ${backend.displayName}…"
                val service = TranscriptionServiceFactory.make(backend)
                val options = TranscriptionOptions(
                    writeTranscript = true,
                    writeSubtitles = makeSubtitles,
                    translateToEnglish = translate,
                    speakerLabels = speakerLabels,
                )
                val result = service.transcribe(audio, options) { f -> progress = f }

                transcript = TranscriptFormatter.render(result)
                srt = if (makeSubtitles) SubtitleRenderer.renderSrt(result.segments) else null
                phase = Phase.DONE
                status = "Done."
            } catch (e: TranscriptionError) {
                phase = Phase.FAILED; status = e.message ?: "Transcription failed."
            } catch (e: Exception) {
                phase = Phase.FAILED; status = e.message ?: "Transcription failed."
            }
        }
    }
}
