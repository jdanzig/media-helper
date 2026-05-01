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
            language: nil,
            usePrefillPrompt: true,
            beamSize: 5,        // beam search vs greedy — same model, better accuracy
            withoutTimestamps: false
        )

        // We avoid an explicit `[WhisperKit.TranscriptionResult]`
        // annotation: `WhisperKit` is both a module name and a class
        // name in that package, and Swift parses the qualifier as the
        // class — which has no nested `TranscriptionResult`. Letting
        // type inference do its thing sidesteps the collision.
        var flatSegments: [TranscriptSegment] = []
        var detectedLanguage: String?
        do {
            // `pipe.transcribe(...)` returns a non-optional array in
            // current WhisperKit versions, so no `?? []` is needed.
            let raw = try await pipe.transcribe(
                audioPath: audioFileURL.path,
                decodeOptions: decodeOptions
            )
            progress(0.9)
            for r in raw {
                if detectedLanguage == nil { detectedLanguage = r.language }
                for s in r.segments {
                    // WhisperKit can leave special tokens like
                    // <|startoftranscript|>, <|en|>, <|3.68|> etc. in the
                    // raw segment text. Strip them before storing.
                    let clean = s.text
                        .replacingOccurrences(of: #"<\|[^|]*\|>"#,
                                              with: "",
                                              options: .regularExpression)
                        .trimmingCharacters(in: .whitespaces)
                    guard !clean.isEmpty else { continue }
                    flatSegments.append(
                        TranscriptSegment(
                            start: TimeInterval(s.start),
                            end: TimeInterval(s.end),
                            text: clean,
                            speaker: nil
                        )
                    )
                }
            }
        } catch {
            throw TranscriptionError.backendRejected(
                "WhisperKit transcription failed: \(error.localizedDescription)"
            )
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
