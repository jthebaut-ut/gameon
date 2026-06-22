import SwiftUI
import UIKit

enum FanGeoZoomableImageSource: Equatable {
    case asset(name: String)
    case uiImage(UIImage)
    case remoteURL(URL)

    static func == (lhs: FanGeoZoomableImageSource, rhs: FanGeoZoomableImageSource) -> Bool {
        switch (lhs, rhs) {
        case let (.asset(lhsName), .asset(rhsName)):
            return lhsName == rhsName
        case (.uiImage, .uiImage):
            return true
        case let (.remoteURL(lhsURL), .remoteURL(rhsURL)):
            return lhsURL == rhsURL
        default:
            return false
        }
    }
}

/// Full-screen read-only image viewer with pinch zoom, double-tap zoom, drag-down dismiss, and close control.
struct FanGeoZoomableImageFullscreenViewer: View {
    let source: FanGeoZoomableImageSource
    let onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var backdropOpacity: Double = 1
    @State private var isImageZoomed = false
    @State private var remoteUIImage: UIImage?

    private var resolvedUIImage: UIImage? {
        switch source {
        case .asset(let name):
            return UIImage(named: name)
        case .uiImage(let image):
            return image
        case .remoteURL:
            return remoteUIImage
        }
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backdropOpacity)
                .ignoresSafeArea()

            if let image = resolvedUIImage {
                FanGeoZoomableImageScrollView(image: image, isZoomed: $isImageZoomed)
                    .offset(y: dragOffset)
            } else if case .remoteURL = source {
                ProgressView()
                    .tint(.white)
            } else {
                ContentUnavailableView("Image Unavailable", systemImage: "photo")
                    .foregroundStyle(.white.opacity(0.8))
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.16))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer()
            }
        }
        .simultaneousGesture(isImageZoomed ? nil : dismissDragGesture)
        .statusBarHidden(true)
        .task(id: remoteImageTaskID) {
            await loadRemoteImageIfNeeded()
        }
    }

    private var remoteImageTaskID: String? {
        guard case .remoteURL(let url) = source else { return nil }
        return url.absoluteString
    }

    @MainActor
    private func loadRemoteImageIfNeeded() async {
        guard case .remoteURL(let url) = source else {
            remoteUIImage = nil
            return
        }
        remoteUIImage = nil
        if let cached = await DiscoverMapImageCache.shared.cachedImage(for: url) {
            guard !Task.isCancelled else { return }
            remoteUIImage = cached
            return
        }
        if let loaded = await DiscoverMapImageCache.shared.image(for: url) {
            guard !Task.isCancelled else { return }
            remoteUIImage = loaded
        }
    }

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                let vertical = value.translation.height
                guard vertical > 0 else {
                    dragOffset = 0
                    backdropOpacity = 1
                    return
                }
                dragOffset = vertical
                backdropOpacity = max(0.35, 1 - Double(vertical / 320))
            }
            .onEnded { value in
                if value.translation.height > 120 || value.predictedEndTranslation.height > 180 {
                    onDismiss()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        dragOffset = 0
                        backdropOpacity = 1
                    }
                }
            }
    }
}

private struct FanGeoZoomableImageScrollView: UIViewRepresentable {
    let image: UIImage
    @Binding var isZoomed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isZoomed: $isZoomed)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = .clear
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        context.coordinator.updateLayout()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        private var isZoomed: Binding<Bool>

        init(isZoomed: Binding<Bool>) {
            self.isZoomed = isZoomed
        }

        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            isZoomed.wrappedValue = scrollView.zoomScale > 1.01
            centerImage(in: scrollView)
        }

        func updateLayout() {
            guard let scrollView, let imageView, let image = imageView.image else { return }

            scrollView.zoomScale = 1
            let bounds = scrollView.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }

            let imageSize = image.size
            guard imageSize.width > 0, imageSize.height > 0 else { return }

            let widthScale = bounds.width / imageSize.width
            let heightScale = bounds.height / imageSize.height
            let scale = min(widthScale, heightScale)

            let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            imageView.frame = CGRect(
                x: (bounds.width - fittedSize.width) / 2,
                y: (bounds.height - fittedSize.height) / 2,
                width: fittedSize.width,
                height: fittedSize.height
            )
            scrollView.contentSize = bounds.size
            centerImage(in: scrollView)
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView, let imageView else { return }

            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
                isZoomed.wrappedValue = false
                return
            }

            let point = recognizer.location(in: imageView)
            let targetScale = min(scrollView.maximumZoomScale, 2.5)
            let width = scrollView.bounds.width / targetScale
            let height = scrollView.bounds.height / targetScale
            let rect = CGRect(
                x: point.x - (width / 2),
                y: point.y - (height / 2),
                width: width,
                height: height
            )
            scrollView.zoom(to: rect, animated: true)
        }

        private func centerImage(in scrollView: UIScrollView) {
            guard let imageView else { return }

            let boundsSize = scrollView.bounds.size
            var frameToCenter = imageView.frame

            if frameToCenter.width < boundsSize.width {
                frameToCenter.origin.x = (boundsSize.width - frameToCenter.width) / 2
            } else {
                frameToCenter.origin.x = 0
            }

            if frameToCenter.height < boundsSize.height {
                frameToCenter.origin.y = (boundsSize.height - frameToCenter.height) / 2
            } else {
                frameToCenter.origin.y = 0
            }

            imageView.frame = frameToCenter
        }
    }
}
