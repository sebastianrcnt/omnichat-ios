import SwiftUI
import SwiftData

#if os(iOS)
@main
struct StrataApp: App {
    private let container: ModelContainer
    private let settings = SharedModels.settings
    private let connections = SharedModels.connections
    private let controller = SharedModels.controller

    init() {
        MemoryPurge.install()
        HighlightService.registerForPurge()
        DS.applyBarAppearance()
        do {
            container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self, CompactionRecord.self)
        } catch {
            fatalError("Could not create the SwiftData container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.appSettings, settings)
                .environment(\.connectionStore, connections)
                .environment(\.chatController, controller)
                .environment(\.theme, DSTheme(accent: settings.accent))
                .tint(settings.accent)
                // Text that names no font of its own is Pretendard too, with the UI line height.
                .font(DS.Typography.ui)
                .dsLeading(.ui)
                .modifier(TextSizeOverride(size: settings.dynamicTypeOverride))
                .modelContainer(container)
        }
    }
}
#endif
