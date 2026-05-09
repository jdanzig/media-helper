import SwiftUI
import UIKit

/// A `UIScrollView`-backed view that displays a `UIImage` with native
/// pinch-to-zoom and one-finger pan. The image is initially scaled to
/// fill the view (aspect-fit); the user can zoom up to 6× from there.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 6
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        context.coordinator.fitToView()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImageView() }

        /// Scale the image to fit the scroll view's bounds (aspect-fit), then
        /// centre it. Retries on the next run-loop tick when bounds haven't
        /// been set yet (initial layout).
        func fitToView() {
            guard let scrollView, let imageView, let image = imageView.image else { return }
            let bounds = scrollView.bounds.size
            guard bounds.width > 0, bounds.height > 0 else {
                DispatchQueue.main.async { [weak self] in self?.fitToView() }
                return
            }

            let fitScale = min(bounds.width  / image.size.width,
                               bounds.height / image.size.height)
            imageView.frame    = CGRect(origin: .zero, size: image.size)
            scrollView.contentSize    = image.size
            scrollView.minimumZoomScale = fitScale
            scrollView.maximumZoomScale = fitScale * 6
            scrollView.zoomScale        = fitScale
            centerImageView()
        }

        private func centerImageView() {
            guard let scrollView, let imageView else { return }
            let sv = scrollView.bounds.size
            var f  = imageView.frame
            f.origin.x = f.width  < sv.width  ? (sv.width  - f.width)  / 2 : 0
            f.origin.y = f.height < sv.height ? (sv.height - f.height) / 2 : 0
            imageView.frame = f
        }
    }
}
