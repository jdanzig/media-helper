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
    /// First resolved item — used by the UI to show title / host / type.
    @Published private(set) var resolved: ResolverResult?
    /// Total number of media items found in the post (≥ 1 when resolved ≠ nil).
    @Published private(set) var resolvedCount: Int = 0
    /// Number of items whose download has completed. Updated after each file
    /// lands so the view can show "2 of 4 downloaded" during multi-item jobs.
    @Published private(set) var downloadedCount: Int = 0
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
        .facebook:    FacebookResolver(),
        .threads:     ThreadsResolver(),
        .streamable:  StreamableResolver()
    ]
    private let downloader = MediaDownloader()

    // MARK: Actions

    /// Called as the user types or pastes. Runs URL parsing only — no network yet.
    /// Also rewrites `urlText` with the tracking-stripped URL so the user
    /// sees the clean version in the text field immediately.
    func urlDidChange() {
        resolved = nil
        resolvedCount = 0
        downloadedCount = 0
        outputs = nil
        progress = 0
        if let url = SocialURLParser.url(from: urlText) {
            // Strip tracking params and reflect the clean URL back to the
            // text field. Guard against equality so we don't recurse.
            // Also write it back to the clipboard so the clean URL is what
            // gets shared if the user copies it from somewhere else.
            let cleaned = url.absoluteString
            if cleaned != urlText {
                urlText = cleaned
                UIPasteboard.general.string = cleaned
            }

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

        // Prefer the raw string over UIPasteboard.url?.absoluteString.
        // The .url property re-serializes via a URL object whose parser can
        // misinterpret `@` in a URL path (e.g. Threads /@username/post/ID)
        // as a userinfo separator, corrupting the host in the output string.
        // The plain string is always what the user (or source app) actually copied.
        let raw = UIPasteboard.general.string
                ?? UIPasteboard.general.url?.absoluteString
                ?? ""
        guard !raw.isEmpty, raw != lastOfferedClipboard else { return }

        guard let url = SocialURLParser.url(from: raw) else { return }
        let platform = SocialURLParser.detectPlatform(url)
        guard platform != .unknown else { return }

        lastOfferedClipboard = raw
        clipboardSuggestion = (url: url.absoluteString, platform: platform)
    }

    /// Accept the clipboard suggestion: paste the cleaned URL into the field,
    /// write it back to the clipboard (the original clipboard content is still
    /// the dirty tracking URL at this point), then run the normal URL-changed
    /// pipeline.
    func acceptClipboardSuggestion() {
        guard let suggestion = clipboardSuggestion else { return }
        urlText = suggestion.url
        UIPasteboard.general.string = suggestion.url
        urlDidChange()
    }

    /// Dismiss the clipboard suggestion without pasting (e.g. user taps ✕).
    func dismissClipboardSuggestion() {
        clipboardSuggestion = nil
    }

    /// Resolve, download, and optionally transcribe / burn subtitles.
    /// For posts with multiple media items (e.g. a tweet with 4 attachments)
    /// all items are downloaded and saved to Photos; transcription only runs
    /// when there is exactly one video.
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
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "MediaHelper.download") {}
        defer { UIApplication.shared.endBackgroundTask(bgTask) }

        do {
            // 1. Resolve all media items in the post.
            phase = .resolving
            statusMessage = "Looking for media…"
            progress = 0
            let results = try await resolver.resolveAll(url)
            guard !results.isEmpty else {
                throw DownloadError.resolutionFailed("no media found.")
            }
            resolved = results.first
            resolvedCount = results.count

            if results.count == 1 {
                statusMessage = results[0].isVideo ? "Found video. Starting download…"
                                                   : "Found image. Starting download…"
            } else {
                statusMessage = "Found \(results.count) items. Starting download…"
            }

            // 2. Download all items, reporting aggregate progress.
            phase = .downloading
            var downloadedFiles: [(fileURL: URL, isVideo: Bool)] = []
            let total = Double(results.count)

            for (index, result) in results.enumerated() {
                if results.count > 1 {
                    statusMessage = "Downloading \(index + 1) of \(results.count)…"
                }
                let (progressStream, task) = downloader.download(
                    from: result.mediaURL,
                    headers: result.requestHeaders
                )
                let base = Double(index) / total
                let observeTask = Task { [weak self] in
                    for await fraction in progressStream {
                        await MainActor.run { self?.progress = base + fraction / total }
                    }
                }
                let fileURL = try await task.value
                observeTask.cancel()
                downloadedFiles.append((fileURL, result.isVideo))
                downloadedCount = downloadedFiles.count
            }
            progress = 1.0

            // 3a. Multiple items: save each to Photos and we're done.
            //     Transcription is skipped — it doesn't make sense to
            //     run a pipeline over multiple independent attachments.
            if results.count > 1 {
                statusMessage = "Saving to Photos…"
                for (fileURL, isVideo) in downloadedFiles {
                    if isVideo {
                        try await PhotoLibrarySaver.saveVideo(at: fileURL)
                    } else {
                        try await PhotoLibrarySaver.saveImage(at: fileURL)
                    }
                }
                downloadedFileURL = makeShareCopy(of: downloadedFiles[0].fileURL)
                phase = .done
                statusMessage = savedSummary(downloadedFiles)
                DownloadNotifier.shared.notifyIfBackgrounded(title: results.first?.title)
                return
            }

            // 3b. Single item: existing pipeline (image / video / transcription).
            let result  = results[0]
            let fileURL = downloadedFiles[0].fileURL

            if !result.isVideo {
                statusMessage = "Saving to Photos…"
                try await PhotoLibrarySaver.saveImage(at: fileURL)
                downloadedFileURL = makeShareCopy(of: fileURL)
                phase = .done
                statusMessage = "Saved to Photos."
                DownloadNotifier.shared.notifyIfBackgrounded(title: result.title)
                return
            }

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
        resolvedCount = 0
        downloadedCount = 0
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

    /// Human-readable summary of a multi-item save.
    private func savedSummary(_ files: [(fileURL: URL, isVideo: Bool)]) -> String {
        let videos = files.filter(\.isVideo).count
        let images = files.filter { !$0.isVideo }.count
        switch (videos, images) {
        case (0, let n): return "Saved \(n) photo\(n == 1 ? "" : "s") to Photos."
        case (let n, 0): return "Saved \(n) video\(n == 1 ? "" : "s") to Photos."
        default:         return "Saved \(videos) video\(videos == 1 ? "" : "s") and \(images) photo\(images == 1 ? "" : "s") to Photos."
        }
    }

    /// Copies `url` to Caches for reliable share-sheet access.
    /// Temp-dir URLs can be inaccessible to share-sheet extensions.
    /// Falls back to the original URL if the copy fails.
    private func makeShareCopy(of url: URL) -> URL {
        guard let caches = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask).first else { return url }
        let dest = caches.appendingPathComponent("MediaHelper_share.\(url.pathExtension)")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
        return FileManager.default.fileExists(atPath: dest.path) ? dest : url
    }
}
