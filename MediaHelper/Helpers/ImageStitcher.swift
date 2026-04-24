import UIKit

/// Combines an ordered list of `UIImage`s into one big image, either
/// stacked vertically (one column) or placed side-by-side (one row).
///
/// Behavior:
///   - Vertical stitch matches image widths by scaling each image to the
///     width of the *narrowest* input, preserving aspect ratio.
///   - Horizontal stitch matches image heights to the *shortest* input.
///   - Output is drawn at device scale 1.0 so pixel dimensions match the
///     pixel math exactly (important when saving to Photos).
enum StitchAxis: String, CaseIterable, Identifiable {
    case vertical, horizontal
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum ImageStitcher {

    static func stitch(_ images: [UIImage], axis: StitchAxis) -> UIImage? {
        guard !images.isEmpty else { return nil }
        if images.count == 1 { return images[0] }

        switch axis {
        case .vertical:   return stitchVertical(images)
        case .horizontal: return stitchHorizontal(images)
        }
    }

    private static func stitchVertical(_ images: [UIImage]) -> UIImage? {
        let targetWidth = images.map(\.size.width).min() ?? 0
        guard targetWidth > 0 else { return nil }

        // Each image gets resized to `targetWidth`, preserving aspect ratio.
        let scaledSizes = images.map { img -> CGSize in
            let scale = targetWidth / img.size.width
            return CGSize(width: targetWidth, height: img.size.height * scale)
        }
        let totalHeight = scaledSizes.reduce(0) { $0 + $1.height }
        let canvas = CGSize(width: targetWidth, height: totalHeight)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        return renderer.image { _ in
            var y: CGFloat = 0
            for (img, size) in zip(images, scaledSizes) {
                img.draw(in: CGRect(origin: CGPoint(x: 0, y: y), size: size))
                y += size.height
            }
        }
    }

    private static func stitchHorizontal(_ images: [UIImage]) -> UIImage? {
        let targetHeight = images.map(\.size.height).min() ?? 0
        guard targetHeight > 0 else { return nil }

        let scaledSizes = images.map { img -> CGSize in
            let scale = targetHeight / img.size.height
            return CGSize(width: img.size.width * scale, height: targetHeight)
        }
        let totalWidth = scaledSizes.reduce(0) { $0 + $1.width }
        let canvas = CGSize(width: totalWidth, height: targetHeight)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        return renderer.image { _ in
            var x: CGFloat = 0
            for (img, size) in zip(images, scaledSizes) {
                img.draw(in: CGRect(origin: CGPoint(x: x, y: 0), size: size))
                x += size.width
            }
        }
    }
}
