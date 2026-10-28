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
    nonisolated static let userPreferencesKey = "userPreferences"
    nonisolated static let browserEnabledKey = "browserTools"
    nonisolated static let locationEnabledKey = "locationTool"
    nonisolated static let sshEnabledKey = "sshEnabled"
    nonisolated static let webSearchEnabledKey = "webSearchTool"
    nonisolated static let videoTranscriptsEnabledKey = "videoTranscriptTool"
    nonisolated static let interactiveViewsEnabledKey = "interactiveViews"
    nonisolated static let healthEnabledKey = "healthTool"

    private let defaults: UserDefaults

    var accentHex: String { didSet { defaults.set(accentHex, forKey: "accentHex") } }
    /// Light, dark, or as the system is. This device only: each device has its own surroundings.
    var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
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
    /// Titles are asked of Apple's on-device model rather than the chat's own (`OnDevice.titleEndpoint`). Off by default.
    var nameChatsOnDevice: Bool { didSet { defaults.set(nameChatsOnDevice, forKey: "nameChatsOnDevice") } }
    /// Shows Settings > Developer > Diagnostics.
    var developerMode: Bool { didSet { defaults.set(developerMode, forKey: "developerMode") } }
    /// Follow the system's text size (default), or use `textSizeStep`.
    var useSystemTextSize: Bool { didSet { defaults.set(useSystemTextSize, forKey: "useSystemTextSize") } }
    /// 0...6, xSmall ... xxxLarge; 3 is the default size.
    var textSizeStep: Int { didSet { defaults.set(textSizeStep, forKey: "textSizeStep") } }
    var lastEffortRaw: String { didSet { defaults.set(lastEffortRaw, forKey: "lastEffort") } }
    /// Models picked in "Select model", newest first (`RecentModels`).
    var recentModels: [String] { didSet { defaults.set(recentModels, forKey: "recentModels") } }
    /// A notification when a reply finishes while the app is in the background (`ReplyBackgroundExecution` reads the key).
    var notifyReplies: Bool { didSet { defaults.set(notifyReplies, forKey: "notifyReplies") } }
    /// A Live Activity for running replies on the Lock Screen and in the Dynamic Island (`ReplyLiveActivities`). On by default.
    var liveActivities: Bool { didSet { defaults.set(liveActivities, forKey: Self.liveActivitiesKey) } }
    static let liveActivitiesKey = "liveActivities"
    /// How many lines a thought line may take (1...4, default 2).
    var thinkingLines: Int { didSet { defaults.set(thinkingLines, forKey: "thinkingLines") } }
    /// Translate English thinking into Korean on the device (`ThoughtTranslator`). Off by default.
    var translateThinking: Bool { didSet { defaults.set(translateThinking, forKey: "translateThinking") } }
    static let thinkingLineOptions = [1, 2, 3, 4]
    static let defaultThinkingLines = 2
    /// The language dictation listens for (`DictationLanguage.current` reads the same key).
    var dictationLanguage: String { didSet { defaults.set(dictationLanguage, forKey: DictationLanguage.defaultsKey) } }
    /// The dictation engine and, for the API one, its connection and model (`DictationSettings.load` reads the keys).
    var dictationEngine: DictationEngineKind { didSet { defaults.set(dictationEngine.rawValue, forKey: DictationSettings.engineKey) } }
    var dictationConnectionID: UUID? {
        didSet { defaults.set(dictationConnectionID?.uuidString, forKey: DictationSettings.connectionKey) }
    }
    var dictationModel: String { didSet { defaults.set(dictationModel, forKey: DictationSettings.modelKey) } }
    /// How the assistant should behave and respond (personality, tone, a name). Sent after the app prompt; a chat
    /// keeps the preferences it started with (`Conversation.frozenPreferences`).
    var userPreferences: String { didSet { defaults.set(userPreferences, forKey: Self.userPreferencesKey) } }
    /// Site plugins the model may run (all off until turned on).
    var enabledPlugins: Set<String> { didSet { defaults.set(enabledPlugins.sorted(), forKey: Self.enabledPluginsKey) } }
    /// The tool switches below are the defaults for new chats; each chat has its own (`ToolGroup`, the composer's "+"
    /// menu). Web search (`web_search`, `web_fetch`, plugins) on by default.
    var webSearchEnabled: Bool { didSet { defaults.set(webSearchEnabled, forKey: Self.webSearchEnabledKey) } }
    /// `run_python` in new chats (on by default).
    var pythonEnabled: Bool { didSet { defaults.set(pythonEnabled, forKey: PythonSettings.enabledKey) } }
    /// Seconds one Python run may take (`PythonSettings.timeLimitSeconds` reads the same key).
    var pythonTimeLimit: Int { didSet { defaults.set(pythonTimeLimit, forKey: PythonSettings.timeLimitKey) } }
    /// The browser tools (`browser_open`, `browser_eval`) and skills in new chats (on by default).
    var browserEnabled: Bool { didSet { defaults.set(browserEnabled, forKey: Self.browserEnabledKey) } }
    /// `current_location` in new chats, with the browser tools (on by default; the system asks for permission on first use).
    var locationEnabled: Bool { didSet { defaults.set(locationEnabled, forKey: Self.locationEnabledKey) } }
    /// The SSH tools in new chats (off by default: a chat turns them on from the + menu).
    var sshEnabled: Bool { didSet { defaults.set(sshEnabled, forKey: Self.sshEnabledKey) } }
    /// `video_transcript` in new chats (on by default).
    var videoTranscriptsEnabled: Bool { didSet { defaults.set(videoTranscriptsEnabled, forKey: Self.videoTranscriptsEnabledKey) } }
    /// Interactive views (OpenUI Lang blocks) in new chats (on by default).
    var interactiveViewsEnabled: Bool { didSet { defaults.set(interactiveViewsEnabled, forKey: Self.interactiveViewsEnabledKey) } }
    /// `health_query` in new chats (off by default: a chat turns Apple Health on from the + menu). iPhone only.
    var healthEnabled: Bool { didSet { defaults.set(healthEnabled, forKey: Self.healthEnabledKey) } }
    /// A page showing a robot check is handed to the user (`RobotCheck.asksUser` reads the key). On by default.
    var askRobotChecks: Bool { didSet { defaults.set(askRobotChecks, forKey: RobotCheck.askKey) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accentHex = defaults.string(forKey: "accentHex") ?? AccentPreset.defaultHex
        appearance = defaults.string(forKey: "appearance").flatMap(AppearanceMode.init(rawValue:)) ?? .system
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
        nameChatsOnDevice = defaults.bool(forKey: "nameChatsOnDevice")
        developerMode = defaults.bool(forKey: "developerMode")
        lastEffortRaw = defaults.string(forKey: "lastEffort") ?? Effort.default.rawValue
        recentModels = defaults.stringArray(forKey: "recentModels") ?? []
        userPreferences = defaults.string(forKey: Self.userPreferencesKey) ?? ""
        enabledPlugins = Set(defaults.stringArray(forKey: Self.enabledPluginsKey) ?? [])
        dictationLanguage = defaults.string(forKey: DictationLanguage.defaultsKey) ?? DictationLanguage.defaultID()
        let dictation = DictationSettings.load(defaults)
        dictationEngine = dictation.engine
        dictationConnectionID = dictation.connectionID
        dictationModel = dictation.model
        let lines = defaults.integer(forKey: "thinkingLines")
        thinkingLines = Self.thinkingLineOptions.contains(lines) ? lines : Self.defaultThinkingLines
        translateThinking = defaults.bool(forKey: "translateThinking")
        notifyReplies = defaults.object(forKey: "notifyReplies") as? Bool ?? true
        liveActivities = defaults.object(forKey: Self.liveActivitiesKey) as? Bool ?? true
        webSearchEnabled = defaults.object(forKey: Self.webSearchEnabledKey) == nil ? true : defaults.bool(forKey: Self.webSearchEnabledKey)
        pythonEnabled = defaults.object(forKey: PythonSettings.enabledKey) == nil ? true : defaults.bool(forKey: PythonSettings.enabledKey)
        let limit = defaults.integer(forKey: PythonSettings.timeLimitKey)
        pythonTimeLimit = PythonSettings.timeLimitOptions.contains(limit) ? limit : PythonSettings.defaultTimeLimit
        browserEnabled = defaults.object(forKey: Self.browserEnabledKey) == nil ? true : defaults.bool(forKey: Self.browserEnabledKey)
        locationEnabled = defaults.object(forKey: Self.locationEnabledKey) == nil ? true : defaults.bool(forKey: Self.locationEnabledKey)
        sshEnabled = defaults.bool(forKey: Self.sshEnabledKey)
        videoTranscriptsEnabled = defaults.object(forKey: Self.videoTranscriptsEnabledKey) == nil
            ? true : defaults.bool(forKey: Self.videoTranscriptsEnabledKey)
        interactiveViewsEnabled = defaults.object(forKey: Self.interactiveViewsEnabledKey) == nil
            ? true : defaults.bool(forKey: Self.interactiveViewsEnabledKey)
        healthEnabled = defaults.bool(forKey: Self.healthEnabledKey)
        askRobotChecks = defaults.object(forKey: RobotCheck.askKey) == nil ? true : defaults.bool(forKey: RobotCheck.askKey)
        // `bool` and `integer` also read launch-argument strings ("NO", "0"), which `as? Bool` would not.
        useSystemTextSize = defaults.object(forKey: "useSystemTextSize") == nil ? true : defaults.bool(forKey: "useSystemTextSize")
        textSizeStep = defaults.object(forKey: "textSizeStep") == nil
            ? TextSizeSetting.defaultStep : TextSizeSetting.clamped(defaults.integer(forKey: "textSizeStep"))
    }

    /// Reads the values again after another device changed them in `defaults` (`SettingsSync`). Only what differs is
    /// set, so views that read the rest don't redraw.
    func reload(from defaults: UserDefaults) {
        let fresh = AppSettings(defaults: defaults)
        for field in Self.fields { field.take(fresh, self) }
    }

    /// Every stored setting: its key, whether it follows the user to their other devices (`SettingsSync` syncs those),
    /// and how `reload` takes it. A new setting goes here too; a test fails while one is missing.
    static let fields: [SettingField] = [
        SettingField(\.accentHex, key: "accentHex", .synced),
        SettingField(\.appearance, key: "appearance", .thisDevice),
        SettingField(\.defaultContextLength, key: "defaultContextLength", .synced),
        SettingField(\.lastConnectionID, key: "lastConnectionID", .thisDevice),
        SettingField(\.lastModelID, key: "lastModelID", .thisDevice),
        SettingField(\.fetchLength, key: "fetchLength", .synced),
        SettingField(\.fetchPatience, key: FetchPatience.defaultsKey, .synced),
        SettingField(\.searchEngine, key: "searchEngine", .synced),
        SettingField(\.smoothStreaming, key: "smoothStreaming", .synced),
        SettingField(\.continueOnEmptyAnswer, key: "continueOnEmptyAnswer", .synced),
        SettingField(\.generateTitles, key: "generateTitles", .synced),
        SettingField(\.nameChatsOnDevice, key: "nameChatsOnDevice", .synced),
        SettingField(\.developerMode, key: "developerMode", .thisDevice),
        SettingField(\.useSystemTextSize, key: "useSystemTextSize", .thisDevice),
        SettingField(\.textSizeStep, key: "textSizeStep", .thisDevice),
        SettingField(\.lastEffortRaw, key: "lastEffort", .thisDevice),
        SettingField(\.recentModels, key: "recentModels", .synced),
        SettingField(\.notifyReplies, key: "notifyReplies", .thisDevice),
        SettingField(\.liveActivities, key: AppSettings.liveActivitiesKey, .thisDevice),
        SettingField(\.thinkingLines, key: "thinkingLines", .synced),
        SettingField(\.translateThinking, key: "translateThinking", .synced),
        SettingField(\.dictationLanguage, key: DictationLanguage.defaultsKey, .thisDevice),
        SettingField(\.dictationEngine, key: DictationSettings.engineKey, .thisDevice),
        SettingField(\.dictationConnectionID, key: DictationSettings.connectionKey, .thisDevice),
        SettingField(\.dictationModel, key: DictationSettings.modelKey, .thisDevice),
        SettingField(\.userPreferences, key: AppSettings.userPreferencesKey, .synced),
        SettingField(\.enabledPlugins, key: AppSettings.enabledPluginsKey, .synced),
        SettingField(\.webSearchEnabled, key: AppSettings.webSearchEnabledKey, .synced),
        SettingField(\.pythonEnabled, key: PythonSettings.enabledKey, .synced),
        SettingField(\.pythonTimeLimit, key: PythonSettings.timeLimitKey, .synced),
        SettingField(\.browserEnabled, key: AppSettings.browserEnabledKey, .synced),
        SettingField(\.locationEnabled, key: AppSettings.locationEnabledKey, .synced),
        SettingField(\.sshEnabled, key: AppSettings.sshEnabledKey, .synced),
        SettingField(\.videoTranscriptsEnabled, key: AppSettings.videoTranscriptsEnabledKey, .synced),
        SettingField(\.interactiveViewsEnabled, key: AppSettings.interactiveViewsEnabledKey, .synced),
        SettingField(\.healthEnabled, key: AppSettings.healthEnabledKey, .thisDevice),
        SettingField(\.askRobotChecks, key: RobotCheck.askKey, .synced),
    ]

    /// Applied at the root; nil leaves Dynamic Type to the system (accessibility sizes included).
    var dynamicTypeOverride: DynamicTypeSize? { TextSizeSetting.override(useSystem: useSystemTextSize, step: textSizeStep) }

    var accent: Color {
        get { Color(hex: accentHex) }
        set { accentHex = newValue.hexString }
    }

    /// The tool switches a new chat starts with. Location comes with the browser, as Settings shows it.
    var defaultToolGroups: Set<ToolGroup> {
        var groups: Set<ToolGroup> = []
        if webSearchEnabled { groups.insert(.web) }
        if pythonEnabled { groups.insert(.python) }
        if browserEnabled { groups.insert(.browser) }
        if browserEnabled && locationEnabled { groups.insert(.location) }
        if sshEnabled { groups.insert(.ssh) }
        if videoTranscriptsEnabled { groups.insert(.video) }
        if interactiveViewsEnabled { groups.insert(.views) }
        if healthEnabled && ToolGroup.health.isSupported { groups.insert(.health) }
        return groups
    }

    var lastEffort: Effort {
        get { Effort(rawValue: lastEffortRaw) ?? .default }
        set { lastEffortRaw = newValue.rawValue }
    }
}

/// One stored setting of `AppSettings`, for the code that handles them all: sync and reload.
@MainActor
struct SettingField {
    enum Scope { case synced, thisDevice }

    let key: String
    let scope: Scope
    /// Sets the value from one settings object on another, only when it differs (views that read it redraw then).
    let take: (_ from: AppSettings, _ to: AppSettings) -> Void
    /// Assigns the value to itself, which writes it under `key` (tests check the key is the one the property uses).
    let rewrite: (AppSettings) -> Void

    init<T: Equatable>(_ path: ReferenceWritableKeyPath<AppSettings, T>, key: String, _ scope: Scope) {
        self.key = key
        self.scope = scope
        take = { from, to in if to[keyPath: path] != from[keyPath: path] { to[keyPath: path] = from[keyPath: path] } }
        rewrite = { s in s[keyPath: path] = s[keyPath: path] }
    }
}
