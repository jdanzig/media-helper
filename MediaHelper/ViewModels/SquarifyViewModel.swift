import SwiftUI
import PhotosUI

/// State for the Squarify tab.
///
/// Loading a new image immediately makes the source and background colour
/// available so the interactive canvas can render straight away. No output
/// image is pre-computed — the final render only runs at save time, using
/// the scale / offset the user has dialled in via pinch and drag.
@MainActor
final class SquarifyViewModel: ObservableObject {

    @Published var pickerItem: PhotosPickerItem? {
        didSet { Task { await loadImage() } }
    }
    @Published private(set) var source: UIImage?
    /// Fill colour for the canvas background — the top-left pixel of the
    /// source image, matching `ImageSquarifier`'s padding colour.
    @Published private(set) var backgroundColor: UIColor = .black
    @Published private(set) var status: String = "Pick one image."
    @Published var isSaving = false

    private func loadImage() async {
        guard let pickerItem else {
            source = nil
            status = "Pick one image."
            return
        }
        status = "Loading image…"
        guard let data = try? await pickerItem.loadTransferable(type: Data.self),
              let img  = UIImage(data: data) else {
            status = "Couldn't load that image."
            return
        }
        // Compute background colour off the main thread — pixel read on a
        // potentially large image.
        let bg = await Task.detached(priority: .userInitiated) {
            ImageSquarifier.topLeftPixelColor(of: img) ?? .black
        }.value

        source          = img
        backgroundColor = bg

        let side = Int(max(img.size.width, img.size.height))
        status = "Output: \(side) × \(side). Pinch to zoom, drag to reposition."
    }

    /// Render and save a square image using the current user-chosen transform.
    ///
    /// - Parameters:
    ///   - scale:      Total zoom multiplier (confirmed + in-progress gesture).
    ///   - offset:     Translation in canvas **display** points.
    ///   - canvasSize: The square canvas width in display points (from
    ///                 `GeometryReader`). Used to map display-space offsets to
    ///                 output-pixel offsets.
    func save(scale: CGFloat, offset: CGSize, canvasSize: CGFloat) async {
        guard let source else { return }
        isSaving = true
        defer { isSaving = false }

        let outputSide = max(source.size.width, source.size.height)
        let bg         = backgroundColor

        let rendered = await Task.detached(priority: .userInitiated) {
            Self.renderSquare(
                source:     source,
                background: bg,
                scale:      scale,
                offset:     offset,
                canvasSize: canvasSize,
                outputSide: outputSide
            )
        }.value

        guard let rendered else {
            status = "Couldn't render image."
            return
        }
        do {
            try await PhotoLibrarySaver.saveImage(rendered)
            status = "Saved to Photos."
        } catch {
            status = error.localizedDescription
        }
    }

    /// Reset to the initial empty state.
    func clear() {
        pickerItem      = nil   // triggers loadImage() → resets source & status
        backgroundColor = .black
    }

    // MARK: - Rendering

    /// Produce an `outputSide × outputSide` UIImage by applying the given
    /// display-space transform to `source` and filling the canvas with
    /// `background`.
    ///
    /// This mirrors the SwiftUI layout exactly:
    ///  - The image is initially scaled with `.scaledToFit()` into the
    ///    `canvasSize × canvasSize` display canvas.
    ///  - The user's `scale` multiplier and `offset` are then applied.
    ///  - Everything is scaled up by `outputSide / canvasSize` for the final
    ///    high-resolution render.
    private static func renderSquare(
        source:     UIImage,
        background: UIColor,
        scale:      CGFloat,
        offset:     CGSize,
        canvasSize: CGFloat,
        outputSide: CGFloat
    ) -> UIImage? {
        guard canvasSize > 0, outputSide > 0 else { return nil }

        let renderRatio = outputSide / canvasSize

        // Fit dimensions: match SwiftUI's .scaledToFit() in the square canvas.
        let srcW     = source.size.width
        let srcH     = source.size.height
        let fitScale = min(canvasSize / srcW, canvasSize / srcH)
        let fitW     = srcW * fitScale
        let fitH     = srcH * fitScale

        // Apply user scale and convert from display points to output pixels.
        let drawW = fitW * scale * renderRatio
        let drawH = fitH * scale * renderRatio

        // Canvas centre + user offset (scaled to output pixels).
        let cx = outputSide / 2 + offset.width  * renderRatio
        let cy = outputSide / 2 + offset.height * renderRatio

        let drawRect   = CGRect(x: cx - drawW / 2, y: cy - drawH / 2,
                                width: drawW,       height: drawH)
        let canvasRect = CGRect(origin: .zero,
                                size:   CGSize(width: outputSide, height: outputSide))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: canvasRect.size, format: format).image { ctx in
            background.setFill()
            ctx.fill(canvasRect)
            source.draw(in: drawRect)
        }
    }
}
