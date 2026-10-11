import SwiftUI

/// Circular glass button used for header controls. Visual size is `diameter`; the hit target is at least 44pt.
struct GlassIconButton: View {
    let systemName: String
    let label: LocalizedStringKey
    var diameter: CGFloat = DS.IconSize.controlDiameter
    var iconSize: CGFloat = DS.IconSize.headerIcon
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .frame(width: diameter, height: diameter)
                .glassEffect(.regular.tint(tint).interactive(), in: Circle())
                .contentShape(Circle().inset(by: -max(0, (DS.IconSize.minHitTarget - diameter) / 2)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
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

/// Circular context-fill indicator: a visible track plus an accent arc from 12 o'clock.
/// `fraction == nil` means no usage yet (track only, dimmed).
struct ContextRing: View {
    @Environment(\.theme) private var theme
    /// 0...1, or nil before the first reply.
    var fraction: Double?
    var diameter: CGFloat = DS.IconSize.ring
    var lineWidth: CGFloat = DS.IconSize.ringStroke

    /// Any non-zero usage shows at least this much arc.
    nonisolated static let minimumVisibleArc = 0.04

    nonisolated static func arc(for fraction: Double) -> Double {
        fraction <= 0 ? 0 : min(1, max(minimumVisibleArc, fraction))
    }

    private var color: Color {
        switch fraction ?? 0 {
        case ..<0.7: theme.accent
        case ..<0.9: theme.warning
        default: theme.destructive
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(theme.textTertiary.opacity(fraction == nil ? 0.35 : 0.55), lineWidth: lineWidth)
            if let fraction, fraction > 0 {
                Circle()
                    .trim(from: 0, to: Self.arc(for: fraction))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(DS.Motion.ease, value: fraction)
        .accessibilityElement()
        .accessibilityLabel(Text(fraction.map { "Context: \(Int(($0 * 100).rounded()))% used" } ?? "Context: no usage yet"))
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
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    theme.surfaceRaised
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.thumbnail))

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
                UIImage(data: d)?.preparingThumbnail(of: CGSize(width: size * scale * 2, height: size * scale * 2))
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

@MainActor private func previewJPEG(_ color: UIColor) -> Data {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96))
    return renderer.jpegData(withCompressionQuality: 0.8) { ctx in
        color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
    }
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
