#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

extension DS {
    enum Layout {
        /// Widest the conversation and composer grow in a big window.
        static let readingWidth: CGFloat = 760
    }
}

extension View {
    /// Centers the view in a column of comfortable reading width.
    func readingColumn() -> some View {
        frame(maxWidth: DS.Layout.readingWidth).frame(maxWidth: .infinity)
    }
}

/// Image attachments on a Mac: a file panel (the composer's plus button), and images dropped onto the chat.
/// Files are resized to JPEG exactly as photos are on the phone.
struct MacImageAttaching: ViewModifier {
    @Binding var isPresented: Bool
    let onPick: ([Data]) -> Void

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                Task { await attach(urls) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let images = urls.filter { url in
                    (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) ?? false
                }
                guard !images.isEmpty else { return false }
                Task { await attach(images) }
                return true
            }
    }

    private func attach(_ urls: [URL]) async {
        var out: [Data] = []
        for url in urls {
            let jpeg = await Task.detached(priority: .userInitiated) { () -> Data? in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return nil }
                return ImageProcessor.jpegData(from: data)
            }.value
            if let jpeg { out.append(jpeg) }
        }
        if !out.isEmpty { onPick(out) }
    }
}

/// The window furniture the chat adds on a Mac: title, model subtitle, a toolbar with context usage and the chat's
/// menu, and image attaching. (On the phone these are the header and the attach sheet.)
struct MacChatChrome<MenuContent: View>: ViewModifier {
    @Environment(\.theme) private var theme
    let title: String
    let contextFraction: Double?
    @Binding var showUsage: Bool
    @Binding var showAttach: Bool
    @Binding var showNoImageSupport: Bool
    let onPickImages: ([Data]) -> Void
    let onEnableImages: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            // The chat scrolls under the title bar: give it a surface so answer text never shows through the title.
            .toolbarBackground(theme.background, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showUsage = true } label: { ContextRing(fraction: contextFraction) }
                        .help("Context usage")
                    Menu(content: menu) { Label("More", systemImage: "ellipsis") }
                        .menuIndicator(.hidden)
                        .help("More")
                }
            }
            .modifier(MacImageAttaching(isPresented: $showAttach, onPick: onPickImages))
            .alert("This model can't read images", isPresented: $showNoImageSupport) {
                Button("Turn on image support") { onEnableImages(); showAttach = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Turn on \"Supports images\" for it in Settings > Connections, or choose another model.")
            }
    }
}
#endif
