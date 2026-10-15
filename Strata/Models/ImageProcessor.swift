import Foundation
import CoreGraphics
import ImageIO
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum ImageProcessor {
    static let maxLongSide: CGFloat = 1568
    static let jpegQuality: CGFloat = 0.8

    /// Downscale so the long side is at most `maxLongSide`, and encode as JPEG.
    static func jpegData(from image: PlatformImage, maxLongSide: CGFloat = maxLongSide, quality: CGFloat = jpegQuality) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxLongSide / max(size.width, size.height))
        // At least a pixel each way: a 1×10,000 image would otherwise round its short side to 0.
        let target = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: quality)
        #else
        guard let cg = image.cgImageRepresentation,
              let context = CGContext(data: nil, width: Int(target.width), height: Int(target.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(origin: .zero, size: target))
        context.draw(cg, in: CGRect(origin: .zero, size: target))
        return context.makeImage().flatMap { ImageEncoding.jpegData(from: $0, quality: quality) }
        #endif
    }

    static func jpegData(from data: Data) -> Data? {
        // Downsampled by ImageIO first: a small file can hold a 30,000-pixel image whose full decode would take
        // gigabytes. The thumbnail is already at most `maxLongSide`, so the resize below only re-encodes it.
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceShouldCacheImmediately: true,
               kCGImageSourceThumbnailMaxPixelSize: maxLongSide,
           ] as CFDictionary) {
            #if canImport(UIKit)
            return jpegData(from: UIImage(cgImage: cg))
            #else
            return jpegData(from: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
            #endif
        }
        guard let image = PlatformImage(data: data) else { return nil }
        return jpegData(from: image)
    }

    /// Long side of a stored preview: about twice the largest size a bubble draws, on a 3x screen.
    static let thumbnailLongSide: CGFloat = 240

    /// A small JPEG preview made with ImageIO, which never decodes the full-size image.
    static func thumbnailData(from jpeg: Data, longSide: CGFloat = thumbnailLongSide, quality: CGFloat = 0.7) -> Data? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        #if canImport(UIKit)
        return UIImage(cgImage: cg).jpegData(compressionQuality: quality)
        #else
        return ImageEncoding.jpegData(from: cg, quality: quality)
        #endif
    }
}
