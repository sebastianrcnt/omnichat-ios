import SwiftUI
import ImageIO
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// The few places where iOS and macOS differ, in one file. Everything else in the app is shared source.

#if canImport(UIKit)
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#else
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    /// A decoded image no larger than `size` (aspect fit), without keeping the full-size bitmap around.
    nonisolated static func thumbnail(from data: Data, fitting size: CGSize) -> PlatformImage? {
        #if canImport(UIKit)
        UIImage(data: data)?.preparingThumbnail(of: size)
        #else
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        #endif
    }

    /// The pixels of the image at its natural size.
    var cgImageRepresentation: CGImage? {
        #if canImport(UIKit)
        cgImage
        #else
        cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }
}

extension PlatformColor {
    /// sRGB components, for the hex string of a color.
    var rgbaComponents: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        (usingColorSpace(.sRGB) ?? self).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        return (r, g, b, a)
    }
}

/// Copy to the general pasteboard.
@MainActor
enum Pasteboard {
    static func copy(_ string: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }

    static func copy(_ image: PlatformImage) {
        #if canImport(UIKit)
        UIPasteboard.general.image = image
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        #endif
    }
}

#if !STRATA_EXTENSION // UIApplication.shared: not in the share extension
/// App activation, as the platform reports it. iOS suspends an app that is not active; a Mac app keeps running.
enum AppLifecycle {
    #if canImport(UIKit)
    static let didBecomeActive = UIApplication.didBecomeActiveNotification
    /// Moments when the running turn's state should reach disk.
    static let checkpointTriggers = [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification]
    @MainActor static var isActive: Bool { UIApplication.shared.applicationState == .active }
    @MainActor static var isBackground: Bool { UIApplication.shared.applicationState == .background }
    #else
    static let didBecomeActive = NSApplication.didBecomeActiveNotification
    static let checkpointTriggers = [NSApplication.willResignActiveNotification, NSApplication.willTerminateNotification]
    @MainActor static var isActive: Bool { NSApplication.shared.isActive }
    /// A Mac app is never suspended, so nothing there counts as "in the background".
    @MainActor static var isBackground: Bool { false }
    #endif
}
#endif

// MARK: - Image encoding without UIKit

enum ImageEncoding {
    /// JPEG bytes of `image` through ImageIO, which exists on both platforms.
    static func jpegData(from image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

// MARK: - SwiftUI modifiers that exist on one platform only

/// Which software keyboard a field asks for. Only iOS has one.
enum KeyboardKind { case standard, number, url }

extension View {
    /// A field for identifiers and addresses: no capitalization, no autocorrection, and the keyboard layout asked for.
    func plainTextInput(keyboard: KeyboardKind = .standard) -> some View {
        #if canImport(UIKit)
        self.textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboard == .number ? .numberPad : keyboard == .url ? .URL : .default)
        #else
        self.autocorrectionDisabled()
        #endif
    }

    /// A Mac text field draws a bezel by default; the phone's does not. Fields in this app draw their own surface.
    func unbezeledField() -> some View {
        #if os(macOS)
        self.textFieldStyle(.plain)
        #else
        self
        #endif
    }

    /// A small title in the navigation bar. (A Mac window shows its title in the title bar.)
    func inlineNavigationTitle() -> some View {
        #if canImport(UIKit)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Full-screen on iPhone; a sheet on a Mac, which has no full-screen presentation.
    func fullScreenCoverOrSheet<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if canImport(UIKit)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented, content: content)
        #endif
    }

    /// `fullScreenCoverOrSheet(isPresented:)` for an item.
    func fullScreenCoverOrSheet<Item: Identifiable, Content: View>(item: Binding<Item?>,
                                                                 @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if canImport(UIKit)
        self.fullScreenCover(item: item, content: content)
        #else
        self.sheet(item: item, content: content)
        #endif
    }
}

extension ToolbarItemPlacement {
    /// The trailing end of the bar: top right on iOS, the confirmation spot on a Mac.
    static var trailingBar: ToolbarItemPlacement {
        #if canImport(UIKit)
        .topBarTrailing
        #else
        .confirmationAction
        #endif
    }
}
