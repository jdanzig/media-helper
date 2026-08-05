import Foundation

/// A single timestamped chunk from whichever backend produced the
/// transcript. Times are in seconds from the start of the audio.
struct TranscriptSegment: Equatable, Hashable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    /// Only populated when the backend supports speaker diarization
    /// (currently AssemblyAI with `speaker_labels: true`).
    var speaker: String?
}

/// What a `TranscriptionService` returns.
struct TranscriptionResult: Equatable {
    /// Detected or requested BCP-47-ish language code (e.g. "en").
    var language: String?

    /// True if the text is a translation to English (i.e. Whisper's
    /// `translate` task was used rather than `transcribe`).
    var isTranslation: Bool

    /// Ordered, non-overlapping segments.
    var segments: [TranscriptSegment]

    /// Full flat text. Convenience; always equal to the segments joined
    /// by a space, so callers can use whichever shape is easier.
    var fullText: String {
        segments.map(\.text).joined(separator: " ")
    }
}

/// Errors surfaced by the transcription pipeline.
enum TranscriptionError: LocalizedError {
    case audioExtractionFailed(String)
    case missingAPIKey(TranscriptionBackend)
    case fileTooLarge(bytes: Int64, limit: Int64)
    case whisperKitUnavailable
    case network(String)
    case decoding(String)
    case backendRejected(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .audioExtractionFailed(let why):
            return "Couldn't pull audio out of the video: \(why)"
        case .missingAPIKey(let backend):
            return "Add a \(backend.displayName) API key in Settings to use this backend."
        case .fileTooLarge(let bytes, let limit):
            return "Audio is \(bytes / 1_000_000) MB, limit is \(limit / 1_000_000) MB for this backend."
        case .whisperKitUnavailable:
            return "WhisperKit isn't linked into this build. Add the Swift Package in Xcode to enable on-device transcription."
        case .network(let why):
            return "Network problem: \(why)"
        case .decoding(let why):
            return "Couldn't parse the backend's response: \(why)"
        case .backendRejected(let why):
            return "The transcription service refused: \(why)"
        case .cancelled:
            return "Cancelled."
        }
    }
}
