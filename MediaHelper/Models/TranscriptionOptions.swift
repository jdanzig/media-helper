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

/// Presets that map 1:1 to the radio buttons on the Download tab.
enum TranscriptionPreset: String, CaseIterable, Identifiable {
    case videoOnly
    case videoWithSubs
    case videoWithTranslatedSubs
    case transcriptOnly
    case everything

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videoOnly:               return "Video only"
        case .videoWithSubs:           return "Video + subtitles"
        case .videoWithTranslatedSubs: return "Video + translated (EN) subtitles"
        case .transcriptOnly:          return "Transcript only"
        case .everything:              return "Everything"
        }
    }

    func options(withSpeakerLabels labels: Bool) -> TranscriptionOptions {
        switch self {
        case .videoOnly:               return .videoOnly
        case .videoWithSubs:           var o: TranscriptionOptions = .videoWithSubs; o.speakerLabels = labels; return o
        case .videoWithTranslatedSubs: var o: TranscriptionOptions = .videoWithTranslatedSubs; o.speakerLabels = labels; return o
        case .transcriptOnly:          var o: TranscriptionOptions = .transcriptOnly; o.speakerLabels = labels; return o
        case .everything:              var o: TranscriptionOptions = .everything; o.speakerLabels = labels; return o
        }
    }
}
