import UIKit

enum ImageProcessor {
    static let maxLongSide: CGFloat = 1568
    static let jpegQuality: CGFloat = 0.8

    /// Downscale so the long side is at most `maxLongSide`, and encode as JPEG.
    static func jpegData(from image: UIImage, maxLongSide: CGFloat = maxLongSide, quality: CGFloat = jpegQuality) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxLongSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: quality)
    }

    static func jpegData(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return jpegData(from: image)
    }
}
