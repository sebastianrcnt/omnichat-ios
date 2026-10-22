import SwiftUI

/// Circular glass button used for header controls. Visual size is `diameter`; the hit target is at least 44pt.
struct GlassIconButton: View {
    let systemName: String
    let label: LocalizedStringKey
    var diameter: CGFloat = DS.IconSize.controlDiameter
    var iconSize: CGFloat = DS.IconSize.headerIcon
    var tint: Color?
    /// A flat filled circle instead of glass: for buttons that sit on glass already (the composer).
    var flat = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .frame(width: diameter, height: diameter)
                .modifier(ControlSurface(flat: flat, tint: tint))
                .contentShape(Circle().inset(by: -max(0, (DS.IconSize.minHitTarget - diameter) / 2)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// Glass, or (on glass already) a flat circle of `composerControl`, pressed darker.
struct ControlSurface: ViewModifier {
    @Environment(\.theme) private var theme
    let flat: Bool
    var tint: Color?

    func body(content: Content) -> some View {
        if flat {
            content.background(tint ?? theme.composerControl, in: Circle())
        } else {
            content.glassEffect(.regular.tint(tint).interactive(), in: Circle())
        }
    }
}

/// The animated accent mark shown while the model is working.
struct StreamingIndicator: View {
    @Environment(\.theme) private var theme
    var size: CGFloat = DS.IconSize.md
    @State private var animating = false

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(theme.accent)
            .scaleEffect(animating ? 1.0 : 0.72)
            .rotationEffect(.degrees(animating ? 90 : 0))
            .opacity(animating ? 1 : 0.6)
            .onAppear { withAnimation(DS.Motion.indicatorPulse) { animating = true } }
            .accessibilityHidden(true)
    }
}

/// Circular context-fill indicator: a visible track with a filled wedge from 12 o'clock inside it, a gauge that can't
/// be mistaken for a spinner (a short colored arc on a track reads as one). Neutral until the context gets full.
/// `fraction == nil` means no usage yet (track only, dimmed).
struct ContextRing: View {
    @Environment(\.theme) private var theme
    /// 0...1, or nil before the first reply.
    var fraction: Double?
    var diameter: CGFloat = DS.IconSize.ring
    var lineWidth: CGFloat = DS.IconSize.ringStroke

    /// Any non-zero usage shows at least this much arc.
    nonisolated static let minimumVisibleArc = 0.07

    nonisolated static func arc(for fraction: Double) -> Double {
        fraction <= 0 ? 0 : min(1, max(minimumVisibleArc, fraction))
    }

    private var color: Color {
        switch fraction ?? 0 {
        case ..<0.7: theme.textSecondary
        case ..<0.9: theme.warning
        default: theme.destructive
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(theme.textSecondary.opacity(fraction == nil ? 0.3 : 0.45), lineWidth: lineWidth) // a full, visible track reads as a gauge, not a spinner
            if let fraction, fraction > 0 {
                ContextWedge(fraction: Self.arc(for: fraction))
                    .fill(color)
                    .padding(lineWidth * 1.5)
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(DS.Motion.ease, value: fraction)
        .accessibilityElement()
        .accessibilityLabel(Text(fraction.map { "Context: \(Int(($0 * 100).rounded()))% used" } ?? "Context: no usage yet"))
    }
}

/// A pie slice from 12 o'clock, clockwise.
private struct ContextWedge: Shape {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2, startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * fraction), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// The ring inside a 44pt glass circle, tappable.
struct ContextRingButton: View {
    var fraction: Double?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ContextRing(fraction: fraction)
                .frame(width: DS.IconSize.controlDiameter, height: DS.IconSize.controlDiameter)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Thumbnail of an attached JPEG, optionally removable.
struct AttachmentThumbnail: View {
    @Environment(\.theme) private var theme
    let data: Data
    var size: CGFloat = DS.IconSize.thumbnail
    var onRemove: (() -> Void)?
    @Environment(\.displayScale) private var displayScale
    @State private var image: PlatformImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(platformImage: image).resizable().scaledToFill()
                } else {
                    theme.surfaceRaised
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.thumbnail))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.thumbnail)) // the clipped overflow still takes taps

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: DS.IconSize.md))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(theme.onAccent, theme.photoBadgeBackdrop)
                }
                .padding(DS.Spacing.xs)
                .accessibilityLabel(Text("Remove photo"))
            }
        }
        .task(id: data.count) {
            let scale = displayScale
            let d = data
            image = await Task.detached {
                PlatformImage.thumbnail(from: d, fitting: CGSize(width: size * scale * 2, height: size * scale * 2))
            }.value
        }
    }
}

#Preview("Light · Purple") { buttonsPreview.previewStyle(.light) }
#Preview("Dark · Purple") { buttonsPreview.previewStyle(.dark) }
#Preview("Dark · Orange") { buttonsPreview.previewStyle(.dark, accent: Color(hex: "#F97316")) }

@MainActor private var buttonsPreview: some View {
    VStack(spacing: DS.Spacing.lg) {
        HStack(spacing: DS.Spacing.md) {
            GlassIconButton(systemName: "line.3.horizontal", label: "Sidebar") {}
            GlassIconButton(systemName: "ellipsis", label: "More") {}
            StreamingIndicator()
        }
        HStack(spacing: DS.Spacing.md) {
            ForEach([nil, 0.0, 0.03, 0.37, 0.8, 0.95] as [Double?], id: \.self) { f in
                ContextRingButton(fraction: f) {}
            }
        }
        HStack(spacing: DS.Spacing.md) {
            GlassIconMenu(systemName: "ellipsis", label: "More") { Button("New chat") {}; Button("Rename") {} }
            GlassIconMenuPlain(systemName: "ellipsis", label: "More") { Button("Copy") {} }
            AttachmentThumbnail(data: previewJPEG(.systemTeal)) {}
            AttachmentThumbnail(data: previewJPEG(.systemOrange), size: DS.IconSize.cameraTile / 2)
        }
    }
    .padding()
}

@MainActor private func previewJPEG(_ color: PlatformColor) -> Data {
    let context = CGContext(data: nil, width: 96, height: 96, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    let (r, g, b, _) = color.rgbaComponents
    context?.setFillColor(red: r, green: g, blue: b, alpha: 1)
    context?.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
    return context?.makeImage().flatMap { ImageEncoding.jpegData(from: $0, quality: 0.8) } ?? Data()
}

/// Circular glass button that opens a menu.
struct GlassIconMenu<Content: View>: View {
    let systemName: String
    let label: LocalizedStringKey
    var diameter: CGFloat = DS.IconSize.controlDiameter
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: systemName)
                .font(.system(size: DS.IconSize.headerIcon, weight: .medium))
                .frame(width: diameter, height: diameter)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// Menu button without its own glass, for use inside a shared glass capsule.
struct GlassIconMenuPlain<Content: View>: View {
    let systemName: String
    let label: LocalizedStringKey
    var diameter: CGFloat = DS.IconSize.controlDiameter
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: systemName)
                .font(.system(size: DS.IconSize.headerIcon, weight: .medium))
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - Text links

/// A plain text link for actions inside content (the activity feed's "Watch", "Open page", "Skip"): no background or
/// border, the feed's link font, an optional SF Symbol in a fixed slot so stacked links line up, and a hit target at
/// least 44 pt tall without any visible chrome. Pressed, it dims.
struct QuietLinkButtonStyle: ButtonStyle {
    enum Tone { case primary, secondary, accent }
    var tone: Tone = .primary
    /// A small "›" after the title, for links that open something ("Open this page ›").
    var chevron = false

    func makeBody(configuration: Configuration) -> some View {
        QuietLinkBody(configuration: configuration, tone: tone, chevron: chevron)
    }
}

private struct QuietLinkBody: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyleConfiguration
    let tone: QuietLinkButtonStyle.Tone
    let chevron: Bool

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            configuration.label.labelStyle(QuietLinkLabelStyle())
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: DS.Feed.mark, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .font(tone == .accent ? DS.Typography.feedLinkEmphasis : DS.Typography.feedLink)
        .foregroundStyle(color)
        .opacity(configuration.isPressed ? 0.45 : isEnabled ? 1 : 0.4)
        .frame(minHeight: DS.IconSize.minHitTarget)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: DS.Motion.fast), value: configuration.isPressed)
    }

    private var color: Color {
        switch tone {
        case .primary: theme.textPrimary
        case .secondary: theme.textSecondary
        case .accent: theme.accent
        }
    }
}

/// Icon in a fixed slot, then the title: links stacked in a column share one text edge.
struct QuietLinkLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: DS.Spacing.xs + DS.Spacing.xxs) {
            configuration.icon
                .font(.system(size: DS.Feed.icon, weight: .medium))
                .frame(width: DS.Feed.iconColumn)
            configuration.title
        }
    }
}

extension ButtonStyle where Self == QuietLinkButtonStyle {
    static var quietLink: QuietLinkButtonStyle { QuietLinkButtonStyle() }
    static func quietLink(_ tone: QuietLinkButtonStyle.Tone, chevron: Bool = false) -> QuietLinkButtonStyle {
        QuietLinkButtonStyle(tone: tone, chevron: chevron)
    }
}
