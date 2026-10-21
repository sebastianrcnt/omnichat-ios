import SwiftUI

// The pieces of the Artifacts gallery: a page thumbnail, the grid card and the list row. The screen itself is
// `ArtifactsView` (UI/).

/// The top of an artifact's page as a 4:3 picture, in the current appearance. A quiet placeholder shows until the
/// thumbnail is ready; it is rendered once and cached (`ArtifactThumbnails`).
struct ArtifactThumbnail: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    let entry: ArtifactStore.Entry
    var cornerRadius: CGFloat = DS.Radius.thumbnail
    var thumbnails: ArtifactThumbnails = .shared

    @State private var image: PlatformImage?
    @State private var shownKey: ArtifactThumbnailKey?

    private var key: ArtifactThumbnailKey { ArtifactThumbnailKey(entry: entry, dark: colorScheme == .dark) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Color.clear
            .aspectRatio(ArtifactThumbnails.imageSize.width / ArtifactThumbnails.imageSize.height, contentMode: .fit)
            .overlay {
                if let image, shownKey == key {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                } else {
                    ZStack {
                        theme.surface
                        Image(systemName: ArtifactFeedCard.icon)
                            .font(.system(size: DS.IconSize.md, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(theme.separator, lineWidth: 1) }
            .accessibilityHidden(true)
            .task(id: key) {
                let key = key
                if let cached = thumbnails.cached(key) {
                    image = cached
                    shownKey = key
                    return
                }
                let rendered = await thumbnails.image(for: key)
                guard !Task.isCancelled, let rendered else { return }
                withAnimation(.easeOut(duration: DS.Motion.fast)) {
                    image = rendered
                    shownKey = key
                }
            }
    }
}

/// A grid card: the thumbnail, the title, and "Chat · Oct 15" under it.
struct ArtifactGridCard: View {
    @Environment(\.theme) private var theme
    let entry: ArtifactStore.Entry
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            ArtifactThumbnail(entry: entry)
                .padding(.bottom, DS.Spacing.xxs)
            Text(verbatim: entry.artifact.title)
                .font(DS.Typography.uiSmall.weight(.semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Text(verbatim: subtitle)
                .font(DS.Typography.uiCaption)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A list row: a small thumbnail, the title, and "Chat · Oct 15".
struct ArtifactListRow: View {
    @Environment(\.theme) private var theme
    let entry: ArtifactStore.Entry
    let subtitle: String

    var body: some View {
        HStack(spacing: DS.Spacing.md) {
            ArtifactThumbnail(entry: entry, cornerRadius: DS.Radius.sm)
                .frame(width: DS.IconSize.thumbnail)
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(verbatim: entry.artifact.title)
                    .font(DS.Typography.ui)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(DS.Typography.uiSmall)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.Spacing.sm)
            Image(systemName: "chevron.right")
                .font(.system(size: DS.IconSize.sm, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md - DS.Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Previews

#Preview("Dark · Purple") { artifactGalleryPreview.previewStyle(.dark) }
#Preview("Light · Purple") { artifactGalleryPreview.previewStyle(.light) }

@MainActor private var artifactGalleryPreview: some View {
    let entry = ArtifactStore.Entry(conversationID: UUID(),
                                    artifact: Artifact(id: "a1", title: "Mortgage calculator", version: 2, created: .now, updated: .now))
    return VStack(spacing: DS.Spacing.lg) {
        HStack(alignment: .top, spacing: DS.Spacing.md) {
            ArtifactGridCard(entry: entry, subtitle: "Home loan · Oct 15")
            ArtifactGridCard(entry: entry, subtitle: "Home loan · Oct 15")
        }
        ArtifactListRow(entry: entry, subtitle: "Home loan · Oct 15")
    }
    .padding()
}
