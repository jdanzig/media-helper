import Foundation

/// User-selected outputs for a transcription run.
///
/// Maps the "A–E" choices from the Download tab UI onto concrete flags:
///   A — keepVideo
///   B — keepVideo + burnInSubtitles
///   C — keepVideo + burnInSubtitles + translateToEnglish
///   D — writeTranscript
///   E — all of the above
///
/// The Transcribe tab reuses the same struct for user-picked videos.
struct TranscriptionOptions: Equatable {
    /// Keep the original (or freshly downloaded) video file in Photos.
    var keepVideo: Bool = true

    /// Render a hardcoded-subtitles copy of the video and save that too.
    var burnInSubtitles: Bool = false

    /// Run Whisper's `translate` task (source → English) instead of pure
    /// transcription. Only meaningful when at least one text output is on.
    var translateToEnglish: Bool = false

    /// Emit a `.txt` transcript via the share sheet.
    var writeTranscript: Bool = false

    /// Ask the backend for speaker labels (AssemblyAI only — other
    /// backends ignore this flag).
    var speakerLabels: Bool = false

    /// True if any text-producing path is requested.
    var needsTranscription: Bool {
        burnInSubtitles || writeTranscript
    }

    /// Convenience constructors matching the Download tab's five presets.
    static let videoOnly                = TranscriptionOptions(keepVideo: true)
    static let videoWithSubs            = TranscriptionOptions(keepVideo: true, burnInSubtitles: true)
    static let videoWithTranslatedSubs  = TranscriptionOptions(keepVideo: true, burnInSubtitles: true, translateToEnglish: true)
    static let transcriptOnly           = TranscriptionOptions(keepVideo: false, writeTranscript: true)
    static let everything               = TranscriptionOptions(keepVideo: true, burnInSubtitles: true, translateToEnglish: true, writeTranscript: true, speakerLabels: true)
}

/// Multi-select output configuration for Download and Transcribe tabs.
///
/// `subtitles` and `transcript` are each single-value enums so that
/// "original" and "translated" are naturally mutually exclusive within
/// each group — tapping one automatically deselects the other.
struct OutputSelections: Equatable {
    /// Save the unmodified video to Photos.
    var saveOriginalVideo: Bool = true

    /// Which subtitle variant (if any) to burn into a video copy.
    var subtitles: SubtitleOption = .none

    /// Which transcript variant (if any) to produce.
    var transcript: TranscriptOption = .none

    enum SubtitleOption: Equatable { case none, original, translated }
    enum TranscriptOption: Equatable { case none, original, translated }

    /// True when at least one output is requested.
    var hasAnyOutput: Bool {
        saveOriginalVideo || subtitles != .none || transcript != .none
    }

    /// Translation is needed when either the subtitle or transcript
    /// variant is "translated". Note: mixing translated-subtitles with
    /// original-transcript (or vice-versa) uses a single translation pass,
    /// so both outputs come out in English in that edge case.
    var needsTranslation: Bool {
        subtitles == .translated || transcript == .translated
    }

    func toTranscriptionOptions(speakerLabels: Bool = false) -> TranscriptionOptions {
        TranscriptionOptions(
            keepVideo: saveOriginalVideo,
            burnInSubtitles: subtitles != .none,
            translateToEnglish: needsTranslation,
            writeTranscript: transcript != .none,
            speakerLabels: speakerLabels
        )
    }
}
