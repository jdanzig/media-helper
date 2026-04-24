import Foundation

/// Top-level "run the whole thing" coordinator used by both the Download
/// and Transcribe tabs. Given a local video file plus options and a
/// backend, returns a `TranscriptionOutputs` with whichever artifacts
/// were requested.
///
/// Phased progress reporting so callers can show a sensible progress UI:
///   - extractingAudio    (0.00 – 0.10)
///   - transcribing       (0.10 – 0.70)
///   - burningSubtitles   (0.70 – 0.95)
///   - savingFiles        (0.95 – 1.00)
enum TranscriptionPipeline {

    enum Phase: Equatable {
        case extractingAudio
        case transcribing
        case burningSubtitles
        case savingFiles
        case done

        var label: String {
            switch self {
            case .extractingAudio:  return "Extracting audio…"
            case .transcribing:     return "Transcribing…"
            case .burningSubtitles: return "Burning subtitles…"
            case .savingFiles:      return "Saving outputs…"
            case .done:             return "Done."
            }
        }
    }

    struct ProgressUpdate {
        var phase: Phase
        var fraction: Double   // 0…1 across the whole pipeline
    }

    /// Run the pipeline. `videoURL` must point at a local file.
    ///
    /// The function is `@MainActor`-agnostic — callers may want to
    /// bridge `onProgress` back to the main actor before updating UI.
    static func run(videoURL: URL,
                    backend: TranscriptionBackend,
                    options: TranscriptionOptions,
                    onProgress: @Sendable @escaping (ProgressUpdate) -> Void) async throws -> TranscriptionOutputs {
        var outputs = TranscriptionOutputs()
        outputs.videoURL = options.keepVideo ? videoURL : nil

        // Short-circuit: no text work requested, nothing else to do.
        if !options.needsTranscription {
            onProgress(.init(phase: .done, fraction: 1.0))
            return outputs
        }

        // 1. Audio
        onProgress(.init(phase: .extractingAudio, fraction: 0.01))
        let audioURL = try await AudioExtractor.extractM4A(from: videoURL)
        onProgress(.init(phase: .extractingAudio, fraction: 0.10))

        // 2. Transcribe
        let service = try TranscriptionServiceFactory.make(for: backend)
        let result = try await service.transcribe(
            audioFileURL: audioURL,
            options: options,
            progress: { inner in
                // Map backend's 0…1 progress into our 0.10…0.70 window.
                onProgress(.init(phase: .transcribing,
                                 fraction: 0.10 + min(max(inner, 0), 1) * 0.60))
            }
        )
        outputs.result = result

        // 3. Text outputs
        if options.writeTranscript {
            outputs.transcriptFileURL = try TranscriptFormatter.writeTranscriptFile(result)
        }
        if options.burnInSubtitles {
            outputs.subtitleFileURL = try SubtitleRenderer.writeSRTFile(result.segments)
        }

        // 4. Burn-in
        if options.burnInSubtitles {
            onProgress(.init(phase: .burningSubtitles, fraction: 0.72))
            let burnedURL = try await SubtitleBurner.burn(
                into: videoURL,
                segments: result.segments,
                progress: { inner in
                    onProgress(.init(phase: .burningSubtitles,
                                     fraction: 0.72 + min(max(inner, 0), 1) * 0.23))
                }
            )
            outputs.subtitledVideoURL = burnedURL
        }

        // 5. Saving (Photos writes happen here for videos).
        onProgress(.init(phase: .savingFiles, fraction: 0.96))
        if let videoOut = outputs.videoURL {
            try await PhotoLibrarySaver.saveVideo(at: videoOut)
        }
        if let burned = outputs.subtitledVideoURL {
            try await PhotoLibrarySaver.saveVideo(at: burned)
        }

        onProgress(.init(phase: .done, fraction: 1.0))
        return outputs
    }
}
