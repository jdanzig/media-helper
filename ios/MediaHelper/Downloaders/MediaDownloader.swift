import Foundation

/// Downloads bytes from a resolved media URL to a local temp file,
/// reporting progress via an async stream of 0…1 fractions.
///
/// Progress is exposed as an `AsyncStream<Double>` so it composes
/// cleanly with the `async/await` view model. The download itself
/// runs in a `Task` whose result is the local file URL.
final class MediaDownloader {

    /// Kick off a download. Caller gets a progress stream plus the
    /// result task that will ultimately yield the on-disk file URL.
    ///
    /// `headers` is forwarded verbatim to the download request. Some CDNs
    /// (TikTok especially) reject requests that don't carry the exact
    /// User-Agent / Referer / Cookie the resolver used on the landing page.
    func download(from url: URL,
                  headers: [String: String] = [:]) -> (progress: AsyncStream<Double>,
                                                       result: Task<URL, Error>) {

        let (progressStream, progressCont) = AsyncStream<Double>.makeStream()

        let task = Task<URL, Error> {
            defer { progressCont.finish() }

            let delegate = ProgressDelegate { fraction in
                progressCont.yield(fraction)
            }

            // `URLSession.download(for:delegate:)` accepts a *task* delegate
            // — cleaner than installing a session-wide delegate because the
            // object stays tied to this single download. We use the
            // request-based overload so we can attach custom headers.
            var request = URLRequest(url: url)
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

            let session = URLSession.shared
            let tempURL: URL
            let response: URLResponse
            do {
                (tempURL, response) = try await session.download(
                    for: request,
                    delegate: delegate
                )
            } catch {
                throw DownloadError.networkFailed(error.localizedDescription)
            }

            guard let http = response as? HTTPURLResponse,
                  (200..<400).contains(http.statusCode) else {
                throw DownloadError.networkFailed(
                    "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
                )
            }

            // URLSession removes the temp file soon after we return, so
            // move it somewhere we control first.
            let finalURL = Self.uniqueTempURL(for: url, response: http)
            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
            progressCont.yield(1.0)
            return finalURL
        }

        return (progressStream, task)
    }

    /// Pick a filename + extension from the response, defaulting to .mp4
    /// for video and .jpg for images when we can't tell from the URL.
    private static func uniqueTempURL(for url: URL, response: HTTPURLResponse) -> URL {
        let guessedExt: String = {
            let pathExt = url.pathExtension
            if !pathExt.isEmpty { return pathExt }
            if let mime = response.mimeType {
                if mime.contains("mp4") { return "mp4" }
                if mime.contains("quicktime") { return "mov" }
                if mime.contains("jpeg") { return "jpg" }
                if mime.contains("png") { return "png" }
            }
            return "mp4"
        }()

        return FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(guessedExt)
    }

    /// Per-task delegate that forwards download progress to a closure.
    private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
        let onProgress: (Double) -> Void
        init(onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }

        func urlSession(_ s: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didWriteData _: Int64,
                        totalBytesWritten written: Int64,
                        totalBytesExpectedToWrite total: Int64) {
            guard total > 0 else { return }
            onProgress(Double(written) / Double(total))
        }

        func urlSession(_ s: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            // No-op; the async `download(from:delegate:)` returns us the
            // same URL so we move the file out from the task continuation.
        }
    }
}
