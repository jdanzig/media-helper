import Foundation
import SwiftUI
import UIKit

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
    /// Local file URL of the most recently downloaded media. Persists after
    /// save so the share sheet can offer the file to other apps / Photos.
    @Published private(set) var downloadedFileURL: URL?

    /// Non-nil when the clipboard contains a recognized social URL that
    /// the user hasn't been prompted about yet. Drives the suggestion banner.
    @Published private(set) var clipboardSuggestion: (url: String, platform: SocialPlatform)?

    /// Last raw clipboard string we already surfaced as a suggestion,
    /// so we don't re-prompt every time the app comes to the foreground.
    private var lastOfferedClipboard: String = ""

    // User-chosen post-processing options (mirrored from `TranscriptionOptionsView`).
    @Published var selections: OutputSelections = OutputSelections()
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

    /// Called as the user types or pastes. Runs URL parsing only — no network yet.
    /// Also rewrites `urlText` with the tracking-stripped URL so the user
    /// sees the clean version in the text field immediately.
    func urlDidChange() {
        resolved = nil
        outputs = nil
        progress = 0
        if let url = SocialURLParser.url(from: urlText) {
            // Strip tracking params and reflect the clean URL back to the
            // text field. Guard against equality so we don't recurse.
            let cleaned = url.absoluteString
            if cleaned != urlText { urlText = cleaned }

            // Hide the clipboard suggestion once the user has something in the field.
            clipboardSuggestion = nil

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
            // If the field just became empty (e.g. user tapped the inline ×),
            // re-check the clipboard so the suggestion banner can reappear.
            if urlText.isEmpty { checkClipboard() }
        }
    }

    /// Check the clipboard for a recognized social URL and surface it as
    /// a suggestion banner. Called when the app comes to the foreground.
    /// No-ops if the text field already has content, or if the clipboard
    /// hasn't changed since the last time we offered a suggestion.
    func checkClipboard() {
        guard urlText.isEmpty else { return }

        let raw = UIPasteboard.general.url?.absoluteString
                ?? UIPasteboard.general.string
                ?? ""
        guard !raw.isEmpty, raw != lastOfferedClipboard else { return }

        guard let url = SocialURLParser.url(from: raw) else { return }
        let platform = SocialURLParser.detectPlatform(url)
        guard platform != .unknown else { return }

        lastOfferedClipboard = raw
        clipboardSuggestion = (url: url.absoluteString, platform: platform)
    }

    /// Dismiss the clipboard suggestion without pasting (e.g. user taps ✕).
    func dismissClipboardSuggestion() {
        clipboardSuggestion = nil
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

        // Ask for notification permission once (no-op on subsequent calls).
        DownloadNotifier.shared.requestPermission()

        // Request background execution time so the download continues if
        // the user switches to another app. iOS typically grants ~3 minutes.
        // The expiration handler fires if we run out of time; the download
        // will be cut short, but there's nothing more we can do gracefully.
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "MediaHelper.download") {}
        defer { UIApplication.shared.endBackgroundTask(bgTask) }

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

            // 3. Images — save and done.
            if !result.isVideo {
                statusMessage = "Saving to Photos…"
                try await PhotoLibrarySaver.saveImage(at: fileURL)
                downloadedFileURL = makeShareCopy(of: fileURL)
                phase = .done
                statusMessage = "Saved to Photos."
                DownloadNotifier.shared.notifyIfBackgrounded(title: result.title)
                return
            }

            // 4. Videos: run the transcription pipeline.
            let options = selections.toTranscriptionOptions(speakerLabels: speakerLabels)

            if !options.needsTranscription {
                statusMessage = "Saving to Photos…"
                try await PhotoLibrarySaver.saveVideo(at: fileURL)
                downloadedFileURL = makeShareCopy(of: fileURL)
                phase = .done
                statusMessage = "Saved to Photos."
                DownloadNotifier.shared.notifyIfBackgrounded(title: result.title)
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
            downloadedFileURL = makeShareCopy(of: fileURL)
            phase = .done
            statusMessage = "Done. Outputs saved."
            DownloadNotifier.shared.notifyIfBackgrounded(title: result.title)
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

    /// Clear just the URL field and reset URL-related state, then immediately
    /// re-check the clipboard so the suggestion banner can reappear.
    /// Unlike `reset()` this leaves download outputs (phase, resolved, outputs)
    /// intact so the user can still share / open results after clearing the field.
    func clearURL() {
        urlText = ""
        detectedPlatform = .unknown
        statusMessage = "Paste a link above."
        phase = .idle
        lastOfferedClipboard = ""   // must clear so checkClipboard() isn't blocked
        checkClipboard()
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
        downloadedFileURL = nil
        selections = OutputSelections()
        clipboardSuggestion = nil
        lastOfferedClipboard = ""
        // Re-check the clipboard immediately so the suggestion banner
        // reappears right after clearing, without needing to re-foreground.
        checkClipboard()
    }

    // MARK: - Private helpers

    /// Copy `url` into the app's Caches directory so `UIActivityViewController`
    /// always gets a stable, process-accessible path. The temp directory can be
    /// inaccessible to share-sheet extensions, causing a blank sheet on first
    /// presentation. Overwrites any previous share copy; falls back to the
    /// original URL if the copy fails.
    private func makeShareCopy(of url: URL) -> URL {
        guard let caches = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask).first else { return url }
        let dest = caches.appendingPathComponent("MediaHelper_share.\(url.pathExtension)")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return url
        }
    }
}
