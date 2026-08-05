import SwiftUI
import UIKit

/// A `UIScrollView`-backed view that displays a `UIImage` with native
/// pinch-to-zoom and one-finger pan. The image is initially scaled to
/// aspect-fit the view; the user can zoom up to 6× from there.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = .clear
        // zoom range + initial fit are configured in fitToView()

        let imageView = UIImageView(image: image)
        scrollView.addSubview(imageView)
        context.coordinator.imageView  = imageView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    /// Only reset the scroll view when the image *identity* changes.
    /// Calling fitToView() on every SwiftUI render (status updates, axis
    /// toggles before the new render lands, …) used to leave minimumZoomScale
    /// keyed to the wrong image size and clobber the user's zoom level.
    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let c = context.coordinator
        guard c.currentImage !== image else { return }
        c.currentImage        = image
        c.imageView?.image    = image
        // Defer until SwiftUI's layout pass is committed so bounds are final.
        DispatchQueue.main.async { [weak c] in c?.fitToView() }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView:  UIImageView?
        /// Tracks the image instance currently fitted to the scroll view.
        var currentImage: UIImage?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) { recenterContent() }

        // MARK: Fit

        /// Scale the image to aspect-fit the scroll view's bounds, then centre it.
        /// Retries on the next run-loop tick if bounds are not yet available.
        func fitToView() {
            guard let scrollView, let imageView, let image = imageView.image else { return }
            let bounds = scrollView.bounds.size
            guard bounds.width > 0, bounds.height > 0 else {
                DispatchQueue.main.async { [weak self] in self?.fitToView() }
                return
            }

            // ── Reset zoom to 1 before touching imageView.frame ─────────────
            // UIScrollView applies a CGAffineTransform to the zoom view.
            // Setting .frame on a view with a non-identity transform is
            // undefined UIKit behaviour and corrupts the scroll view's internal
            // zoom tracking (causing snap-back on zoom-out).  Resetting to 1
            // first makes the transform identity so the frame assignment is safe.
            scrollView.minimumZoomScale = 1
            scrollView.maximumZoomScale = 1
            scrollView.zoomScale        = 1          // transform → identity
            scrollView.contentInset     = .zero

            // ── Size the content view to the image's natural dimensions ──────
            imageView.frame        = CGRect(origin: .zero, size: image.size)
            scrollView.contentSize = image.size

            // ── Install the correct zoom range and start at fit scale ─────────
            let fitScale = min(bounds.width  / image.size.width,
                               bounds.height / image.size.height)
            scrollView.minimumZoomScale = fitScale
            scrollView.maximumZoomScale = fitScale * 6
            scrollView.setZoomScale(fitScale, animated: false)

            // Ensure the image is centred (scrollViewDidZoom fires for the
            // setZoomScale call above but an explicit call here is belt-and-
            // suspenders for the case where the scale didn't actually change).
            recenterContent()
        }

        // MARK: Centering

        /// Keep the image centred in the viewport when it is smaller than the
        /// scroll view (i.e. at or near the minimum zoom level).
        ///
        /// Uses contentInset — the correct UIKit mechanism for this.  The old
        /// approach of adjusting imageView.frame directly caused corruption
        /// because UIScrollView had already applied a scale transform to it.
        private func recenterContent() {
            guard let scrollView else { return }
            let bw = scrollView.bounds.size.width
            let bh = scrollView.bounds.size.height
            let cw = scrollView.contentSize.width
            let ch = scrollView.contentSize.height
            let ox = max((bw - cw) / 2, 0)
            let oy = max((bh - ch) / 2, 0)
            scrollView.contentInset = UIEdgeInsets(top: oy, left: ox,
                                                   bottom: oy, right: ox)
        }
    }
}
