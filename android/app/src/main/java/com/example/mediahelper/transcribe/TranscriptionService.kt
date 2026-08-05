package com.example.mediahelper.transcribe

import com.example.mediahelper.store.SecureStore
import java.io.File

/** Turns an audio/video file into a timestamped transcript. Mirrors iOS
 *  TranscriptionService. */
interface TranscriptionService {
    val backend: TranscriptionBackend
    suspend fun transcribe(
        audioFile: File,
        options: TranscriptionOptions,
        onProgress: (Double) -> Unit,
    ): TranscriptionResult
}

object TranscriptionServiceFactory {
    /** First backend usable given which API keys are configured. */
    fun defaultAvailableBackend(): TranscriptionBackend = when {
        SecureStore.has(SecureStore.Item.OpenAIApiKey) -> TranscriptionBackend.OPENAI_WHISPER
        SecureStore.has(SecureStore.Item.AssemblyAIApiKey) -> TranscriptionBackend.ASSEMBLY_AI
        else -> TranscriptionBackend.OPENAI_WHISPER
    }

    fun make(backend: TranscriptionBackend): TranscriptionService = when (backend) {
        TranscriptionBackend.ON_DEVICE -> OnDeviceTranscriber()
        TranscriptionBackend.OPENAI_WHISPER -> {
            val key = SecureStore.load(SecureStore.Item.OpenAIApiKey)
                ?: throw TranscriptionError.MissingApiKey(backend)
            OpenAiWhisperTranscriber(key)
        }
        TranscriptionBackend.ASSEMBLY_AI -> {
            val key = SecureStore.load(SecureStore.Item.AssemblyAIApiKey)
                ?: throw TranscriptionError.MissingApiKey(backend)
            AssemblyAiTranscriber(key)
        }
    }
}

/** ponytail: on-device Whisper isn't ported yet (needs a bundled whisper.cpp /
 *  GGML model + JNI). Fails cleanly; add when someone wants offline mode. */
class OnDeviceTranscriber : TranscriptionService {
    override val backend = TranscriptionBackend.ON_DEVICE
    override suspend fun transcribe(audioFile: File, options: TranscriptionOptions, onProgress: (Double) -> Unit): TranscriptionResult =
        throw TranscriptionError.OnDeviceUnavailable
}
