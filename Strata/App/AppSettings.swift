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
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
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

    private let defaults: UserDefaults

    var accentHex: String { didSet { defaults.set(accentHex, forKey: "accentHex") } }
    var defaultContextLength: Int { didSet { defaults.set(defaultContextLength, forKey: "defaultContextLength") } }
    var lastConnectionID: UUID? { didSet { defaults.set(lastConnectionID?.uuidString, forKey: "lastConnectionID") } }
    var lastModelID: String? { didSet { defaults.set(lastModelID, forKey: "lastModelID") } }
    var fetchLength: Int { didSet { defaults.set(fetchLength, forKey: "fetchLength") } }
    var smoothStreaming: Bool { didSet { defaults.set(smoothStreaming, forKey: "smoothStreaming") } }
    var lastEffortRaw: String { didSet { defaults.set(lastEffortRaw, forKey: "lastEffort") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accentHex = defaults.string(forKey: "accentHex") ?? AccentPreset.defaultHex
        let ctx = defaults.integer(forKey: "defaultContextLength")
        defaultContextLength = ctx > 0 ? ctx : Self.defaultContextLength
        lastConnectionID = defaults.string(forKey: "lastConnectionID").flatMap(UUID.init(uuidString:))
        lastModelID = defaults.string(forKey: "lastModelID")
        let fl = defaults.integer(forKey: "fetchLength")
        fetchLength = Self.fetchLengthOptions.contains(fl) ? fl : Self.defaultFetchLength
        smoothStreaming = defaults.object(forKey: "smoothStreaming") as? Bool ?? true
        lastEffortRaw = defaults.string(forKey: "lastEffort") ?? Effort.default.rawValue
    }

    var accent: Color {
        get { Color(hex: accentHex) }
        set { accentHex = newValue.hexString }
    }

    var lastEffort: Effort {
        get { Effort(rawValue: lastEffortRaw) ?? .default }
        set { lastEffortRaw = newValue.rawValue }
    }
}
