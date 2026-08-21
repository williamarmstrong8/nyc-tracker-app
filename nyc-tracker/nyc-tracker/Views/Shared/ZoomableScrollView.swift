import SwiftUI
import UIKit

/// Hosts SwiftUI content inside a `UIScrollView` so pinch-to-zoom, double-tap-to-zoom,
/// and panning while zoomed behave exactly like the system Photos viewer.
///
/// A SwiftUI-only gesture stack (`MagnificationGesture` + `DragGesture`) fights a parent
/// `TabView(.page)` for the pan — `UIScrollView` doesn't, because it only claims the pan
/// when it actually has room to scroll (i.e. once zoomed past 1x). At 1x, content size
/// equals the frame, so the gesture falls through to the page swipe underneath it.
struct ZoomableScrollView<Content: View>: UIViewRepresentable {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(hostingController: UIHostingController(rootView: content))
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 4
        scrollView.minimumZoomScale = 1
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never

        let hosted = context.coordinator.hostingController
        hosted.view.backgroundColor = .clear
        hosted.view.translatesAutoresizingMaskIntoConstraints = true
        scrollView.addSubview(hosted.view)

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap)
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.hostingController.rootView = content

        let size = scrollView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if context.coordinator.hostingController.view.frame.size != size {
            context.coordinator.hostingController.view.frame = CGRect(origin: .zero, size: size)
            scrollView.contentSize = size
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let hostingController: UIHostingController<Content>

        init(hostingController: UIHostingController<Content>) {
            self.hostingController = hostingController
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            hostingController.view
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            let view = hostingController.view!
            let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) * 0.5, 0)
            let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) * 0.5, 0)
            view.center = CGPoint(
                x: scrollView.contentSize.width * 0.5 + offsetX,
                y: scrollView.contentSize.height * 0.5 + offsetY
            )
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let point = gesture.location(in: hostingController.view)
                let targetScale = scrollView.maximumZoomScale
                let width = scrollView.bounds.width / targetScale
                let height = scrollView.bounds.height / targetScale
                let zoomRect = CGRect(
                    x: point.x - width / 2,
                    y: point.y - height / 2,
                    width: width,
                    height: height
                )
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }
    }
}
