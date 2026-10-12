#if os(macOS)
import SwiftUI
import SwiftData
import CoreText

@main
struct StrataMacApp: App {
    private let container: ModelContainer
    private let settings = SharedModels.settings

    init() {
        MacFonts.register()
        #if DEBUG
        DebugHooks.runKeychainSelfTest()
        DebugHooks.runWebSelfTest()
        MacKeyTest.runIfRequested()
        #endif
        MemoryPurge.install()
        HighlightService.registerForPurge()
        do {
            container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self, CompactionRecord.self)
        } catch {
            fatalError("Could not create the SwiftData container: \(error)")
        }
    }

    var body: some Scene {
        // One window: the controller runs one reply at a time, so a second window would only show the same state twice.
        Window("Strata", id: "main") {
            MacRootView()
                .strataEnvironment(settings: settings, container: container)
        }
        .defaultSize(width: 1120, height: 800)
        .commands { StrataCommands() }

        Settings {
            SettingsView()
                .frame(width: 560, height: 680)
                .strataEnvironment(settings: settings, container: container)
        }
    }
}

/// The app-wide environment of every Mac scene, the same values the iPhone root sets.
private struct StrataEnvironment: ViewModifier {
    let settings: AppSettings
    let container: ModelContainer

    func body(content: Content) -> some View {
        content
            .environment(\.appSettings, settings)
            .environment(\.connectionStore, SharedModels.connections)
            .environment(\.chatController, SharedModels.controller)
            .environment(\.theme, DSTheme(accent: settings.accent))
            .tint(settings.accent)
            // Text that names no font of its own is Pretendard too, with the UI line height.
            .font(DS.Typography.ui)
            .dsLeading(.ui)
            .modifier(TextSizeOverride(size: settings.dynamicTypeOverride))
            .modelContainer(container)
    }
}

private extension View {
    func strataEnvironment(settings: AppSettings, container: ModelContainer) -> some View {
        modifier(StrataEnvironment(settings: settings, container: container))
    }
}

/// An iOS app lists its fonts in `UIAppFonts`; a Mac app registers them with the font manager for this process.
@MainActor
enum MacFonts {
    static let files = ["PretendardVariable.ttf", "Pretendard-Regular.otf", "Pretendard-Medium.otf",
                        "Pretendard-SemiBold.otf", "Pretendard-Bold.otf"]

    static func register() {
        for file in files {
            let url = URL(filePath: file)
            guard let bundled = Bundle.main.url(forResource: url.deletingPathExtension().lastPathComponent,
                                                withExtension: url.pathExtension) else { continue }
            CTFontManagerRegisterFontsForURL(bundled as CFURL, .process, nil)
        }
    }
}
#endif
