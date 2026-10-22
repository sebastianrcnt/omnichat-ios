import SwiftUI
import CoreText

// The share extension compiles the design system's `Tokens.swift` and `Platform.swift` from the app. These are the few
// app symbols those files (and the share sheet) use that live in app-only files; keep them in step with the originals.

/// `AppSettings.swift`.
enum AccentPreset {
    static let defaultHex = "#8B5CF6"
}

/// `AppSettings.swift`.
extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255, opacity: 1)
    }
}

/// `Engine/ContextGrid.swift` (only `DSTheme.contextCategory` names it here).
enum ContextCategory: Int, CaseIterable, Sendable {
    case system, tools, messages, web, reasoning, images
}

/// `DesignSystem/Activity.swift`.
struct FlowLayout: Layout {
    var spacing: CGFloat = DS.Spacing.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (i, origin) in result.origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

/// Pretendard, read from the containing app's bundle (the extension sits in its `PlugIns` folder) instead of a second
/// copy in the extension.
enum ShareFonts {
    static let files = ["PretendardVariable.ttf", "Pretendard-Regular.otf", "Pretendard-Medium.otf",
                        "Pretendard-SemiBold.otf", "Pretendard-Bold.otf"]

    static func register() {
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let urls = files.map { app.appending(path: $0) }.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        guard !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }
}
