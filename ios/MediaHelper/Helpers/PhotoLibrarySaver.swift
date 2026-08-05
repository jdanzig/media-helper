import Foundation
import Photos
import UIKit

/// Thin wrapper around PHPhotoLibrary for the "add to Photos" flow.
///
/// We request `.addOnly` authorization — the least-privilege option that
/// lets us save new assets without reading existing ones. Callers should
/// funnel both video and image saves through this type so permission
/// handling lives in one place.
enum PhotoLibrarySaver {

    /// Ensure the app has write access to Photos. Safe to call repeatedly.
    static func requestAddOnlyAccess() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current == .authorized || current == .limited { return true }

        let granted = await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                cont.resume(returning: status == .authorized || status == .limited)
            }
        }
        return granted
    }

    /// Save a video file (at a local URL, e.g. from `MediaDownloader`) to
    /// the camera roll. Throws `DownloadError.saveFailed` on any failure.
    static func saveVideo(at fileURL: URL) async throws {
        guard await requestAddOnlyAccess() else {
            throw DownloadError.saveFailed("Photos access was denied.")
        }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            // Override the file's embedded creation date so the asset appears
            // under "today" in Photos rather than whenever the video was filmed.
            request?.creationDate = Date()
        }
    }

    /// Save an in-memory `UIImage`. Used by Stitch/Squarify and by the
    /// Download tab when the resolved media is a still image.
    static func saveImage(_ image: UIImage) async throws {
        guard await requestAddOnlyAccess() else {
            throw DownloadError.saveFailed("Photos access was denied.")
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAsset(from: image)
        }
    }

    /// Save an image that's already on disk (matches how downloads arrive).
    ///
    /// Prefers adding the file resource directly (same path as `saveVideo`) so
    /// that original format, quality, and EXIF are preserved. Falls back to a
    /// UIImage round-trip if Photos rejects the raw file (e.g. a format Photos
    /// doesn't recognise, which UIImage can still decode and re-encode to JPEG).
    static func saveImage(at fileURL: URL) async throws {
        guard await requestAddOnlyAccess() else {
            throw DownloadError.saveFailed("Photos access was denied.")
        }

        // Attempt 1: add the file directly — preserves original data.
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, fileURL: fileURL, options: nil)
            }
            return
        } catch { /* fall through to UIImage path */ }

        // Attempt 2: decode → UIImage → JPEG in Photos.
        // Handles CDN image formats (WebP, AVIF, …) that Photos won't ingest
        // raw but UIImage can decode, and catches colour-space issues too.
        guard let image = UIImage(contentsOfFile: fileURL.path) else {
            throw DownloadError.saveFailed("Downloaded file isn't a readable image.")
        }
        try await saveImage(image)
    }
}
