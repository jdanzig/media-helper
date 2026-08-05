package com.example.mediahelper.transcribe

/** One timestamped chunk. Times are seconds from the start. Mirrors iOS
 *  TranscriptSegment. */
data class TranscriptSegment(
    val start: Double,
    val end: Double,
    val text: String,
    val speaker: String? = null,
)

data class TranscriptionResult(
    val language: String?,
    val isTranslation: Boolean,
    val segments: List<TranscriptSegment>,
)

sealed class TranscriptionError(message: String) : Exception(message) {
    class AudioExtractionFailed(why: String) : TranscriptionError("Audio extraction failed: $why")
    class MissingApiKey(backend: TranscriptionBackend) :
        TranscriptionError("Add your ${backend.displayName} API key in Settings.")
    class FileTooLarge(bytes: Long, limit: Long) :
        TranscriptionError("Audio is ${bytes / 1_048_576} MB; the limit is ${limit / 1_048_576} MB.")
    object OnDeviceUnavailable :
        TranscriptionError("On-device transcription isn't available on Android yet — pick a cloud backend.")
    class Network(why: String) : TranscriptionError("Network problem: $why")
    class Decoding(why: String) : TranscriptionError("Couldn't read the response: $why")
    class BackendRejected(why: String) : TranscriptionError(why)
}

/** Which engine produces transcripts. Mirrors iOS TranscriptionBackend. */
enum class TranscriptionBackend(
    val displayName: String,
    val tagline: String,
    val supportsTranslation: Boolean,
    val supportsDiarization: Boolean,
    val requiresApiKey: Boolean,
) {
    ON_DEVICE("On-device", "Not available on Android yet.", true, false, false),
    OPENAI_WHISPER("OpenAI Whisper", "Cloud. 25 MB cap. No speaker labels.", true, false, true),
    ASSEMBLY_AI("AssemblyAI", "Cloud. Speaker labels supported.", false, true, true),
}

/** User-selected outputs for a run. Mirrors the meaningful bits of iOS
 *  TranscriptionOptions (burn-in is a later milestone). */
data class TranscriptionOptions(
    val writeTranscript: Boolean = true,
    val writeSubtitles: Boolean = false,
    val translateToEnglish: Boolean = false,
    val speakerLabels: Boolean = false,
) {
    val needsTranscription get() = writeTranscript || writeSubtitles
}
