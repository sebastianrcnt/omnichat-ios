import SwiftUI

/// Hex-backed color preset.
struct AccentPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let hex: String

    static let all: [AccentPreset] = [
        .init(id: "purple", name: String(localized: "Purple"), hex: "#8B5CF6"),
        .init(id: "blue", name: String(localized: "Blue"), hex: "#3B82F6"),
        .init(id: "teal", name: String(localized: "Teal"), hex: "#14B8A6"),
        .init(id: "green", name: String(localized: "Green"), hex: "#22C55E"),
        .init(id: "orange", name: String(localized: "Orange"), hex: "#F97316"),
        .init(id: "pink", name: String(localized: "Pink"), hex: "#EC4899"),
        .init(id: "red", name: String(localized: "Red"), hex: "#EF4444"),
    ]
    static let defaultHex = "#8B5CF6"
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255, opacity: 1)
    }

    var hexString: String {
        let (r, g, b, _) = PlatformColor(self).rgbaComponents
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

/// The in-app text size: seven steps from xSmall to xxxLarge, or the system's own Dynamic Type setting.
enum TextSizeSetting {
    static let sizes: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge]
    /// `.large` is the system default size.
    static let defaultStep = 3

    static func clamped(_ step: Int) -> Int { min(max(step, 0), sizes.count - 1) }
    static func size(forStep step: Int) -> DynamicTypeSize { sizes[clamped(step)] }

    /// The size to force on the whole app, or nil to follow the system.
    static func override(useSystem: Bool, step: Int) -> DynamicTypeSize? { useSystem ? nil : size(forStep: step) }

    static func label(forStep step: Int) -> String {
        switch clamped(step) {
        case 0: String(localized: "Extra small")
        case 1: String(localized: "Small")
        case 2: String(localized: "Medium")
        case 3: String(localized: "Default")
        case 4: String(localized: "Large")
        case 5: String(localized: "Extra large")
        default: String(localized: "Largest")
        }
    }
}

/// User preferences persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let defaultContextLength = 262_144
    nonisolated static let fetchLengthOptions = [12_000, 24_000, 48_000, 96_000]
    nonisolated static let defaultFetchLength = 24_000

    /// Read by the tools off the main actor.
    nonisolated static var currentFetchLength: Int {
        let v = UserDefaults.standard.integer(forKey: "fetchLength")
        return fetchLengthOptions.contains(v) ? v : defaultFetchLength
    }

    /// Read by the search tool off the main actor.
    nonisolated static var currentSearchEngine: SearchEnginePreference {
        UserDefaults.standard.string(forKey: "searchEngine").flatMap(SearchEnginePreference.init(rawValue:)) ?? .auto
    }

    /// The plugins turned on in Settings. Read by the plugin tool and the system prompt off the main actor.
    nonisolated static var currentEnabledPlugins: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: enabledPluginsKey) ?? [])
    }
    nonisolated static let enabledPluginsKey = "enabledPlugins"

    private let defaults: UserDefaults

    var accentHex: String { didSet { defaults.set(accentHex, forKey: "accentHex") } }
    var defaultContextLength: Int { didSet { defaults.set(defaultContextLength, forKey: "defaultContextLength") } }
    var lastConnectionID: UUID? { didSet { defaults.set(lastConnectionID?.uuidString, forKey: "lastConnectionID") } }
    var lastModelID: String? { didSet { defaults.set(lastModelID, forKey: "lastModelID") } }
    var fetchLength: Int { didSet { defaults.set(fetchLength, forKey: "fetchLength") } }
    /// How long the hidden browser waits for a page (`FetchPatience.current` reads the same key).
    var fetchPatience: FetchPatience { didSet { defaults.set(fetchPatience.rawValue, forKey: FetchPatience.defaultsKey) } }
    var searchEngine: SearchEnginePreference { didSet { defaults.set(searchEngine.rawValue, forKey: "searchEngine") } }
    var smoothStreaming: Bool { didSet { defaults.set(smoothStreaming, forKey: "smoothStreaming") } }
    /// After tools, an empty answer gets one more request asking for it (`EmptyAnswerRetry`). Off by default.
    var continueOnEmptyAnswer: Bool { didSet { defaults.set(continueOnEmptyAnswer, forKey: "continueOnEmptyAnswer") } }
    /// After the first answer, a short side request names the chat (`AutoRename`). On by default.
    var generateTitles: Bool { didSet { defaults.set(generateTitles, forKey: "generateTitles") } }
    /// Shows Settings > Developer > Diagnostics.
    var developerMode: Bool { didSet { defaults.set(developerMode, forKey: "developerMode") } }
    /// Follow the system's text size (default), or use `textSizeStep`.
    var useSystemTextSize: Bool { didSet { defaults.set(useSystemTextSize, forKey: "useSystemTextSize") } }
    /// 0...6, xSmall ... xxxLarge; 3 is the default size.
    var textSizeStep: Int { didSet { defaults.set(textSizeStep, forKey: "textSizeStep") } }
    var lastEffortRaw: String { didSet { defaults.set(lastEffortRaw, forKey: "lastEffort") } }
    /// The language dictation listens for (`DictationLanguage.current` reads the same key).
    var dictationLanguage: String { didSet { defaults.set(dictationLanguage, forKey: DictationLanguage.defaultsKey) } }
    /// Site plugins the model may run (all off until turned on).
    var enabledPlugins: Set<String> { didSet { defaults.set(enabledPlugins.sorted(), forKey: Self.enabledPluginsKey) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accentHex = defaults.string(forKey: "accentHex") ?? AccentPreset.defaultHex
        let ctx = defaults.integer(forKey: "defaultContextLength")
        defaultContextLength = ctx > 0 ? ctx : Self.defaultContextLength
        lastConnectionID = defaults.string(forKey: "lastConnectionID").flatMap(UUID.init(uuidString:))
        lastModelID = defaults.string(forKey: "lastModelID")
        let fl = defaults.integer(forKey: "fetchLength")
        fetchLength = Self.fetchLengthOptions.contains(fl) ? fl : Self.defaultFetchLength
        fetchPatience = defaults.string(forKey: FetchPatience.defaultsKey).flatMap(FetchPatience.init(rawValue:)) ?? .standard
        searchEngine = defaults.string(forKey: "searchEngine").flatMap(SearchEnginePreference.init(rawValue:)) ?? .auto
        smoothStreaming = defaults.object(forKey: "smoothStreaming") as? Bool ?? true
        continueOnEmptyAnswer = defaults.bool(forKey: "continueOnEmptyAnswer")
        generateTitles = defaults.object(forKey: "generateTitles") == nil ? true : defaults.bool(forKey: "generateTitles")
        developerMode = defaults.bool(forKey: "developerMode")
        lastEffortRaw = defaults.string(forKey: "lastEffort") ?? Effort.default.rawValue
        enabledPlugins = Set(defaults.stringArray(forKey: Self.enabledPluginsKey) ?? [])
        dictationLanguage = defaults.string(forKey: DictationLanguage.defaultsKey) ?? DictationLanguage.defaultID()
        // `bool` and `integer` also read launch-argument strings ("NO", "0"), which `as? Bool` would not.
        useSystemTextSize = defaults.object(forKey: "useSystemTextSize") == nil ? true : defaults.bool(forKey: "useSystemTextSize")
        textSizeStep = defaults.object(forKey: "textSizeStep") == nil
            ? TextSizeSetting.defaultStep : TextSizeSetting.clamped(defaults.integer(forKey: "textSizeStep"))
    }

    /// Applied at the root; nil leaves Dynamic Type to the system (accessibility sizes included).
    var dynamicTypeOverride: DynamicTypeSize? { TextSizeSetting.override(useSystem: useSystemTextSize, step: textSizeStep) }

    var accent: Color {
        get { Color(hex: accentHex) }
        set { accentHex = newValue.hexString }
    }

    var lastEffort: Effort {
        get { Effort(rawValue: lastEffortRaw) ?? .default }
        set { lastEffortRaw = newValue.rawValue }
    }
}
