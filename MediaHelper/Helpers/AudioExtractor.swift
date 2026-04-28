import Foundation
import AVFoundation

/// Pulls the audio track out of a video file and writes it to an .m4a.
///
/// Used by the transcription pipeline as the first step: Whisper and
/// AssemblyAI both want a plain audio file, not a video container.
/// The `AVAssetExportPresetAppleM4A` preset reencodes to AAC — small
/// enough to stay under OpenAI's 25 MB cap for most clips under ~30 min.
enum AudioExtractor {

    /// Extract audio from `videoURL` and write an .m4a next to it.
    /// Returns the URL of the new audio file.
    static func extractM4A(from videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)

        // Must have at least one audio track.
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw TranscriptionError.audioExtractionFailed("video has no audio track")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try? FileManager.default.removeItem(at: outputURL)

        guard let exporter = AVAssetExportSession(asset: asset,
                                                  presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.audioExtractionFailed("couldn't create export session")
        }
        exporter.outputFileType = .m4a
        exporter.outputURL = outputURL

        // iOS 18 adds an async `export(to:as:)`; older SDKs use the
        // callback-based `exportAsynchronously`. Stick with the wrapper
        // below so we compile against iOS 17.
        //
        // `AVAssetExportSession` isn't Sendable, but `withCheckedThrowing
        // Continuation`'s body parameter is `@Sendable` under strict
        // concurrency. The exporter is genuinely owned by this single
        // call (we created it locally, no one else has a reference), so
        // we wrap it in an `@unchecked Sendable` box to silence the
        // checker without changing runtime behavior.
        let box = UncheckedSendable(exporter)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            box.value.exportAsynchronously {
                switch box.value.status {
                case .completed:
                    cont.resume()
                case .failed, .cancelled:
                    cont.resume(throwing: TranscriptionError.audioExtractionFailed(
                        box.value.error?.localizedDescription ?? "export failed"
                    ))
                default:
                    // .waiting / .exporting shouldn't ever land here —
                    // the completion handler only fires on terminal states.
                    cont.resume(throwing: TranscriptionError.audioExtractionFailed("unexpected state"))
                }
            }
        }

        return outputURL
    }
}
