import Foundation

/// The files produced by a full pipeline run. All URLs point at files in
/// the app's temporary directory unless the pipeline has already copied
/// them to Photos; the caller is responsible for moving / sharing them.
struct TranscriptionOutputs: Equatable {
    /// The original (or downloaded) video, if `keepVideo` was requested.
    var videoURL: URL?

    /// The subtitled video, rendered via `SubtitleBurner`.
    var subtitledVideoURL: URL?

    /// SRT file matching whichever language was transcribed/translated.
    var subtitleFileURL: URL?

    /// Human-readable `.txt` transcript, optionally with speaker labels.
    var transcriptFileURL: URL?

    /// The raw segments, in case the UI wants to render them inline.
    var result: TranscriptionResult?
}
