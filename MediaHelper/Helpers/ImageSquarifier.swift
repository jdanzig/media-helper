import UIKit

/// Pads a non-square image to a square canvas, filling the new area with
/// the color of the top-left pixel of the original. The original is drawn
/// centered on the square canvas.
///
/// Short side of the output = max(width, height) of the input, so no
/// information is lost.
enum ImageSquarifier {

    static func squarify(_ image: UIImage) -> UIImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        if abs(size.width - size.height) < 0.5 { return image } // already square

        let side = max(size.width, size.height)
        let canvas = CGSize(width: side, height: side)
        let bg = topLeftPixelColor(of: image) ?? .black

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        return renderer.image { ctx in
            bg.setFill()
            ctx.fill(CGRect(origin: .zero, size: canvas))

            let origin = CGPoint(
                x: (side - size.width) / 2,
                y: (side - size.height) / 2
            )
            image.draw(in: CGRect(origin: origin, size: size))
        }
    }

    /// Read the top-left pixel by drawing the image into a 1×1 context.
    /// This naturally box-filters the corner, which is both fast and
    /// matches what the eye expects for solid-color borders.
    ///
    /// For a strict top-left pixel read, switch to CGImage + CFData below.
    private static func topLeftPixelColor(of image: UIImage) -> UIColor? {
        guard let cg = image.cgImage else { return nil }

        var pixel: [UInt8] = [0, 0, 0, 0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: &pixel,
            width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        // Draw the image into a 1-pixel-wide context positioned so the
        // (0,0) pixel of the source lands at (0,0) of the destination.
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(
            x: 0,
            y: -CGFloat(cg.height) + 1,
            width: CGFloat(cg.width),
            height: CGFloat(cg.height)
        ))

        let r = CGFloat(pixel[0]) / 255
        let g = CGFloat(pixel[1]) / 255
        let b = CGFloat(pixel[2]) / 255
        let a = CGFloat(pixel[3]) / 255
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }
}
