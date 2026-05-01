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
    static func saveImage(at fileURL: URL) async throws {
        guard let image = UIImage(contentsOfFile: fileURL.path) else {
            throw DownloadError.saveFailed("Downloaded file wasn't a readable image.")
        }
        try await saveImage(image)
    }
}
