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

/// Circular context-fill indicator.
struct ContextRing: View {
    @Environment(\.theme) private var theme
    /// 0...1
    var fraction: Double
    var diameter: CGFloat = DS.IconSize.ring

    private var color: Color {
        switch fraction {
        case ..<0.8: theme.accent
        case ..<0.95: theme.warning
        default: theme.destructive
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(theme.separator, lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
        .animation(DS.Motion.ease, value: fraction)
    }
}

/// Small pill showing a source host.
struct SourceChip: View {
    @Environment(\.theme) private var theme
    let title: String
    var url: URL?

    var body: some View {
        let chip = Text(title)
            .font(DS.Typography.uiCaption)
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .background(theme.surfaceRaised, in: Capsule())
        if let url { Link(destination: url) { chip } } else { chip }
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
                        .foregroundStyle(.white, .black.opacity(0.6))
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
            ContextRing(fraction: 0.37)
            ContextRing(fraction: 0.85)
            ContextRing(fraction: 0.97)
            StreamingIndicator()
        }
        HStack {
            SourceChip(title: "github.com")
            SourceChip(title: "developer.apple.com")
        }
    }
    .padding()
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
