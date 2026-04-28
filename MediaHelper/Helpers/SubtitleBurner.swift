import Foundation
import AVFoundation
import CoreImage
import UIKit

/// Renders a new video file with subtitles burned into the pixels.
///
/// We use the standard AVFoundation recipe:
///   1. Build an `AVMutableComposition` carrying the source video+audio.
///   2. Build an `AVMutableVideoComposition` whose frame rule matches the
///      source, applying the source's `preferredTransform` so portrait
///      clips don't come out sideways.
///   3. Hand that composition a `CoreAnimationTool` whose animation layer
///      holds the video layer plus one `CATextLayer` per segment, each
///      with an opacity animation matching its timestamp window.
///   4. Export through `AVAssetExportSession` at `HighestQuality` to mp4.
///
/// Subtitles render at the bottom of the frame with a translucent black
/// background box (standard social-clip style). For longer segments we
/// rely on `SubtitleRenderer`'s wrapping logic — the layer is wide enough
/// to accommodate two lines.
enum SubtitleBurner {

    static func burn(into videoURL: URL,
                     segments: [TranscriptSegment],
                     progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)

        // Load tracks up front (async APIs on iOS 16+).
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideo = videoTracks.first else {
            throw TranscriptionError.audioExtractionFailed("video file had no video track")
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        let naturalSize = try await sourceVideo.load(.naturalSize)
        let preferredTransform = try await sourceVideo.load(.preferredTransform)
        let nominalFrameRate = try await sourceVideo.load(.nominalFrameRate)

        // 1. Composition — copy source tracks.
        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw TranscriptionError.audioExtractionFailed("couldn't build video composition track")
        }
        try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                      of: sourceVideo, at: .zero)

        if let sourceAudio = audioTracks.first,
           let compAudio = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? compAudio.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                           of: sourceAudio, at: .zero)
        }

        // 2. Video composition — render size respects preferred transform
        // so portrait clips render portrait.
        let renderSize = Self.renderSize(natural: naturalSize,
                                         transform: preferredTransform)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
        layerInstruction.setTransform(preferredTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(
            value: 1,
            timescale: nominalFrameRate > 0 ? CMTimeScale(nominalFrameRate) : 30
        )
        videoComposition.instructions = [instruction]

        // 3. Core animation layers. `videoLayer` is where the source
        // frames render; `overlayLayer` draws on top. AVFoundation
        // requires a flipped, non-retina coordinate space — layers
        // here are in logical pixels, not points.
        let parentLayer = CALayer()
        let videoLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        videoLayer.frame = parentLayer.frame
        parentLayer.addSublayer(videoLayer)

        Self.addSubtitleLayers(to: parentLayer,
                               renderSize: renderSize,
                               segments: segments,
                               totalDuration: duration.seconds)

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        // 4. Export
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: outputURL)

        guard let exporter = AVAssetExportSession(asset: composition,
                                                  presetName: AVAssetExportPresetHighestQuality) else {
            throw TranscriptionError.audioExtractionFailed("couldn't build exporter")
        }
        exporter.videoComposition = videoComposition
        exporter.outputFileType = .mp4
        exporter.outputURL = outputURL

        // `AVAssetExportSession` isn't Sendable; box it so we can capture
        // it inside the continuation's `@Sendable` body without warnings.
        // The session is owned exclusively by this call.
        let box = UncheckedSendable(exporter)

        // Poll for progress while exporting.
        let progressTask = Task {
            while !Task.isCancelled {
                let p = Double(box.value.progress)
                progress(p)
                if p >= 1 { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            box.value.exportAsynchronously {
                switch box.value.status {
                case .completed: cont.resume()
                case .failed, .cancelled:
                    cont.resume(throwing: TranscriptionError.audioExtractionFailed(
                        box.value.error?.localizedDescription ?? "export failed"
                    ))
                default:
                    cont.resume(throwing: TranscriptionError.audioExtractionFailed("unexpected state"))
                }
            }
        }
        progressTask.cancel()

        return outputURL
    }

    // MARK: - Layout

    /// Apply `transform` to `natural` to find the visible bounding box
    /// of a frame post-rotation. For a 1920x1080 video rotated 90° this
    /// comes out as 1080x1920, which is what the user sees.
    private static func renderSize(natural: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    private static func addSubtitleLayers(to parent: CALayer,
                                          renderSize: CGSize,
                                          segments: [TranscriptSegment],
                                          totalDuration: TimeInterval) {
        // Scale font / padding to the smaller dimension so portrait and
        // landscape clips look about the same.
        let shortSide = min(renderSize.width, renderSize.height)
        let fontSize = max(24, round(shortSide * 0.045))
        let horizontalPadding: CGFloat = shortSide * 0.04
        let layerWidth = renderSize.width - 2 * horizontalPadding
        let layerHeight = fontSize * 3.2
        let bottomMargin: CGFloat = shortSide * 0.06

        for seg in segments {
            guard seg.end > seg.start, !seg.text.isEmpty else { continue }

            let displayText: String = {
                if let speaker = seg.speaker, !speaker.isEmpty {
                    return "\(speaker):\n\(seg.text)"
                }
                return seg.text
            }()

            let textLayer = CATextLayer()
            textLayer.string = displayText
            textLayer.font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
            textLayer.fontSize = fontSize
            textLayer.foregroundColor = UIColor.white.cgColor
            textLayer.backgroundColor = UIColor.black.withAlphaComponent(0.55).cgColor
            textLayer.alignmentMode = .center
            textLayer.isWrapped = true
            textLayer.truncationMode = .end
            textLayer.contentsScale = 2
            textLayer.cornerRadius = 6
            textLayer.masksToBounds = true
            textLayer.frame = CGRect(
                x: horizontalPadding,
                y: bottomMargin,
                width: layerWidth,
                height: layerHeight
            )
            textLayer.opacity = 0

            // Hard on/off opacity animations matching the segment window.
            // AVFoundation interprets layer time via beginTime; zero is
            // special-cased to AVCoreAnimationBeginTimeAtZero.
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.beginTime = seg.start == 0 ? AVCoreAnimationBeginTimeAtZero : seg.start
            appear.duration = 0.0001 // step, not fade
            appear.isRemovedOnCompletion = false
            appear.fillMode = .forwards
            textLayer.add(appear, forKey: "appear")

            let disappear = CABasicAnimation(keyPath: "opacity")
            disappear.fromValue = 1
            disappear.toValue = 0
            disappear.beginTime = seg.end == 0 ? AVCoreAnimationBeginTimeAtZero : seg.end
            disappear.duration = 0.0001
            disappear.isRemovedOnCompletion = false
            disappear.fillMode = .forwards
            textLayer.add(disappear, forKey: "disappear")

            parent.addSublayer(textLayer)
        }
    }
}
