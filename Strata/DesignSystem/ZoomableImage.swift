import SwiftUI
#if canImport(UIKit)
import UIKit
import Photos
#else
import AppKit
#endif

/// An image that fits its space and zooms with a pinch (a trackpad pinch on a Mac), panning once it's larger than the
/// view. Smaller than the view, it stays centered.
#if canImport(UIKit)
struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomingScrollView { ZoomingScrollView(image: image) }
    func updateUIView(_ view: ZoomingScrollView, context: Context) { view.show(image) }
}

final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var fittedTo: CGSize = .zero

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        imageView.backgroundColor = .white // figures are drawn for a white page
        addSubview(imageView)
        show(image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        fittedTo = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedTo { fit() }
        centerImage()
    }

    /// Fits the image to the view; pinching goes up to five times that (or the image's own pixels, if more).
    private func fit() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        fittedTo = bounds.size
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        zoomScale = 1
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        minimumZoomScale = fit
        maximumZoomScale = max(fit * 5, 2)
        zoomScale = fit
    }

    private func centerImage() {
        let w = imageView.frame.width, h = imageView.frame.height
        let x = max(0, (bounds.width - w) / 2), y = max(0, (bounds.height - h) / 2)
        let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        if contentInset != inset { contentInset = inset }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }
}

/// Saves an image file to the photo library (add-only access, asked for on first use).
enum PhotoLibrarySaver {
    enum Failure: LocalizedError {
        case denied
        var errorDescription: String? { String(localized: "OpenChat isn't allowed to add photos. You can allow it in Settings.") }
    }

    static func save(fileURL: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.denied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: fileURL, options: nil)
        }
    }
}
#else
struct ZoomableImage: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> MagnifyingScrollView { MagnifyingScrollView(image: image) }
    func updateNSView(_ view: MagnifyingScrollView, context: Context) { view.show(image) }
}

final class MagnifyingScrollView: NSScrollView {
    private let imageView = NSImageView()
    private var fittedTo: CGSize = .zero

    init(image: NSImage) {
        super.init(frame: .zero)
        contentView = CenteringClipView()
        allowsMagnification = true
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.white.cgColor
        documentView = imageView
        show(image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ image: NSImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        fittedTo = .zero
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard bounds.size != fittedTo, let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
        let rep = image.representations.first
        let size = rep.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }.flatMap { $0.width > 0 ? $0 : nil } ?? image.size
        guard size.width > 0, size.height > 0 else { return }
        fittedTo = bounds.size
        imageView.frame = CGRect(origin: .zero, size: size)
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        minMagnification = fit
        maxMagnification = max(fit * 5, 2)
        magnification = fit
    }
}

/// Keeps a document smaller than the view in its middle.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}
#endif
