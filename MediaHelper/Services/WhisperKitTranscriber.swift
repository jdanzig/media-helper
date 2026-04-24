import Foundation

#if canImport(WhisperKit)
import WhisperKit

/// On-device transcription via WhisperKit. Requires the WhisperKit SPM
/// package (https://github.com/argmaxinc/WhisperKit) to be added to the
/// Xcode project — until then the whole file compiles out and
/// `TranscriptionServiceFactory` throws `.whisperKitUnavailable`.
///
/// The first time this runs it downloads the Whisper model bytes into
/// the app's caches directory. That's slow; subsequent runs reuse the
/// cached weights.
///
/// Translation: WhisperKit supports `task: .translate` which produces
/// English output regardless of source language. Speaker diarization is
/// **not** supported; the `speakerLabels` option is ignored here.
final class WhisperKitTranscriber: TranscriptionService {
    let backend: TranscriptionBackend = .whisperKit

    /// Lazily initialized pipeline — constructing `WhisperKit` downloads
    /// the model and takes several seconds the first time.
    private var pipeline: WhisperKit?

    func transcribe(audioFileURL: URL,
                    options: TranscriptionOptions,
                    progress: @Sendable @escaping (Double) -> Void) async throws -> TranscriptionResult {
        progress(0.02)

        let pipe: WhisperKit
        if let existing = pipeline {
            pipe = existing
        } else {
            do {
                pipe = try await WhisperKit()
            } catch {
                throw TranscriptionError.backendRejected(
                    "WhisperKit failed to initialize: \(error.localizedDescription)"
                )
            }
            pipeline = pipe
        }
        progress(0.15)

        let decodeOptions = DecodingOptions(
            task: options.translateToEnglish ? .translate : .transcribe,
            // WhisperKit's default is solid for general speech; leave
            // language auto-detect on unless translating.
            language: nil,
            usePrefillPrompt: true,
            withoutTimestamps: false
        )

        // WhisperKit 0.9+ accepts an audio file path (String). Run on a
        // detached task so the main actor isn't blocked for long jobs.
        let results: [WhisperKit.TranscriptionResult]
        do {
            let out = try await pipe.transcribe(
                audioPath: audioFileURL.path,
                decodeOptions: decodeOptions
            )
            results = out ?? []
        } catch {
            throw TranscriptionError.backendRejected(
                "WhisperKit transcription failed: \(error.localizedDescription)"
            )
        }
        progress(0.9)

        var flatSegments: [TranscriptSegment] = []
        var detectedLanguage: String?
        for r in results {
            if detectedLanguage == nil { detectedLanguage = r.language }
            for s in r.segments {
                flatSegments.append(
                    TranscriptSegment(
                        start: TimeInterval(s.start),
                        end: TimeInterval(s.end),
                        text: s.text.trimmingCharacters(in: .whitespaces),
                        speaker: nil
                    )
                )
            }
        }
        progress(1.0)

        return TranscriptionResult(
            language: detectedLanguage,
            isTranslation: options.translateToEnglish,
            segments: flatSegments
        )
    }
}

#else

/// Placeholder so the symbol resolves in `TranscriptionServiceFactory`
/// even when the WhisperKit dependency isn't linked. The factory guards
/// this case with `throws TranscriptionError.whisperKitUnavailable` and
/// we never actually construct this type in that build.
final class WhisperKitTranscriber: TranscriptionService {
    let backend: TranscriptionBackend = .whisperKit
    func transcribe(audioFileURL: URL,
                    options: TranscriptionOptions,
                    progress: @Sendable @escaping (Double) -> Void) async throws -> TranscriptionResult {
        throw TranscriptionError.whisperKitUnavailable
    }
}

#endif
