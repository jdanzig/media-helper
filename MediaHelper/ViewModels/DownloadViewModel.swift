import Foundation
import SwiftUI

/// Orchestrates the Download tab's state machine:
///
///   idle → detecting → resolving → downloading → (transcribing/burning) → done
///
/// The view observes `phase`, `statusMessage`, `progress`, `resolved`, and
/// `outputs`. All network / pipeline logic lives here.
@MainActor
final class DownloadViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case detecting
        case resolving
        case downloading
        case postProcessing(TranscriptionPipeline.Phase)
        case done
        case failed(String)
    }

    // MARK: Published UI state

    @Published var urlText: String = ""
    @Published private(set) var detectedPlatform: SocialPlatform = .unknown
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statusMessage: String = "Paste a link above."
    @Published private(set) var progress: Double = 0
    @Published private(set) var resolved: ResolverResult?
    @Published private(set) var outputs: TranscriptionOutputs?

    // User-chosen post-processing options (mirrored from `TranscriptionOptionsView`).
    @Published var preset: TranscriptionPreset = .videoOnly
    @Published var backend: TranscriptionBackend = TranscriptionServiceFactory.defaultAvailableBackend()
    @Published var speakerLabels: Bool = false

    // MARK: Dependencies

    /// Map of platform → resolver. Swap entries in here to add a new
    /// backend (e.g. a server-assisted YouTube resolver).
    private let resolvers: [SocialPlatform: any MediaResolver] = [
        .youtube:   YouTubeResolver(),
        .twitter:   TwitterResolver(),
        .tiktok:    TikTokResolver(),
        .instagram: InstagramResolver(),
        .facebook:  FacebookResolver()
    ]
    private let downloader = MediaDownloader()

    // MARK: Actions

    /// Called as the user types. Runs URL parsing only — no network yet.
    func urlDidChange() {
        resolved = nil
        outputs = nil
        progress = 0
        if let url = SocialURLParser.url(from: urlText) {
            detectedPlatform = SocialURLParser.detectPlatform(url)
            if detectedPlatform == .unknown {
                statusMessage = "Not a recognized social URL."
                phase = .idle
            } else {
                statusMessage = "Detected \(detectedPlatform.displayName)."
                phase = .detecting
            }
        } else {
            detectedPlatform = .unknown
            statusMessage = "Paste a link above."
            phase = .idle
        }
    }

    /// Resolve, download, and (for videos) optionally transcribe / burn
    /// subtitles / save a transcript. Runs the whole pipeline in one
    /// `Task` so cancellation is straightforward.
    func start() async {
        guard let url = SocialURLParser.url(from: urlText) else {
            phase = .failed("Invalid URL")
            statusMessage = "Invalid URL."
            return
        }
        let platform = SocialURLParser.detectPlatform(url)
        detectedPlatform = platform
        guard let resolver = resolvers[platform] else {
            phase = .failed("Unsupported platform")
            statusMessage = DownloadError.unsupportedPlatform(platform).localizedDescription
            return
        }

        do {
            // 1. Resolve
            phase = .resolving
            statusMessage = "Looking for a media URL…"
            progress = 0
            let result = try await resolver.resolve(url)
            resolved = result
            statusMessage = result.isVideo ? "Found video. Starting download…"
                                           : "Found image. Starting download…"

            // 2. Download (with progress stream)
            phase = .downloading
            let (progressStream, task) = downloader.download(
                from: result.mediaURL,
                headers: result.requestHeaders
            )
            let observeTask = Task { [weak self] in
                for await fraction in progressStream {
                    await MainActor.run { self?.progress = fraction }
                }
            }
            let fileURL = try await task.value
            observeTask.cancel()
            progress = 1.0

            // 3. Images: old behavior — save and done. No transcription
            //    makes sense for a still image.
            if !result.isVideo {
                statusMessage = "Saving to Photos…"
                try await PhotoLibrarySaver.saveImage(at: fileURL)
                phase = .done
                statusMessage = "Saved to Photos."
                return
            }

            // 4. Videos: run the transcription pipeline with whatever
            //    options the user picked. `TranscriptionPipeline` also
            //    handles saving the final videos to Photos.
            let options = preset.options(withSpeakerLabels: speakerLabels)

            // If the user only wants the video (no text work), the
            // pipeline still short-circuits nicely — it'll just save
            // the video to Photos.
            if options == .videoOnly {
                statusMessage = "Saving to Photos…"
                try await PhotoLibrarySaver.saveVideo(at: fileURL)
                phase = .done
                statusMessage = "Saved to Photos."
                return
            }

            let outputs = try await TranscriptionPipeline.run(
                videoURL: fileURL,
                backend: backend,
                options: options,
                onProgress: { [weak self] update in
                    Task { @MainActor [weak self] in
                        self?.phase = .postProcessing(update.phase)
                        self?.progress = update.fraction
                        self?.statusMessage = update.phase.label
                    }
                }
            )
            self.outputs = outputs
            phase = .done
            statusMessage = "Done. Outputs saved."
        } catch let e as DownloadError {
            phase = .failed(e.localizedDescription)
            statusMessage = e.localizedDescription
        } catch let e as TranscriptionError {
            phase = .failed(e.localizedDescription)
            statusMessage = e.localizedDescription
        } catch {
            phase = .failed(error.localizedDescription)
            statusMessage = error.localizedDescription
        }
    }

    /// Reset back to the initial state (used by the "clear" button).
    func reset() {
        urlText = ""
        detectedPlatform = .unknown
        phase = .idle
        statusMessage = "Paste a link above."
        progress = 0
        resolved = nil
        outputs = nil
    }
}
