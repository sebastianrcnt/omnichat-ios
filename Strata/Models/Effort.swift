import Foundation

/// Reasoning effort levels understood by the gateway (`reasoning_effort`), and `off`: no thinking, on the models that
/// can answer without (`ModelInfo.effortLevels` puts it first then). Stored as "none", the value the title request sends.
enum Effort: String, CaseIterable, Codable, Sendable, Identifiable {
    case off = "none"
    case low, medium, high, xhigh, max

    /// The thinking levels. `off` is not one: a model offers it apart, and lists of what a model takes leave it out.
    static let allCases: [Effort] = [.low, .medium, .high, .xhigh, .max]

    var id: String { rawValue }

    /// Value sent on the wire.
    var apiValue: String { rawValue }

    static let `default`: Effort = .medium

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .low: String(localized: "Low")
        case .medium: String(localized: "Medium")
        case .high: String(localized: "High")
        case .xhigh: String(localized: "Extra")
        case .max: String(localized: "Max")
        }
    }

    /// Engine thinking-token cap, `nil` meaning uncapped.
    var thinkingTokenCap: Int? {
        switch self {
        case .off: 0
        case .low: 1024
        case .medium: 4096
        case .high: 8192
        case .xhigh: 16384
        case .max: nil
        }
    }

    /// The levels a connection offers. OpenAI's reasoning models stop at `xhigh` (Max would send the same).
    static func levels(_ style: EffortStyle) -> [Effort] {
        style == .tokenCaps ? allCases : [.low, .medium, .high, .xhigh]
    }

    /// This level as one of `levels`: a level that isn't offered (Max picked on another connection, or a model with
    /// fewer levels) reads as the highest offered level below it, else the lowest offered.
    /// Off on a model that can't answer without thinking reads as its lowest level.
    func resolved(in levels: [Effort]) -> Effort {
        guard !levels.isEmpty, !levels.contains(self) else { return self }
        let thinking = levels.filter { $0 != .off } // a level a model lacks reads as another level, never as Off
        return thinking.last { $0.rank < rank } ?? thinking.first ?? levels[0]
    }

    private var rank: Int { Effort.allCases.firstIndex(of: self) ?? -1 }

    func hint(_ style: EffortStyle) -> String {
        if self == .off { return String(localized: "Answers without thinking") }
        switch style {
        case .tokenCaps:
            if let cap = thinkingTokenCap { return String(localized: "Thinks up to \(cap.formatted()) tokens") }
            return String(localized: "No thinking limit")
        case .modelDecides, .openAI:
            switch self {
            case .off, .low: return String(localized: "Brief reasoning, faster answers")
            case .medium: return String(localized: "Balanced")
            case .high: return String(localized: "Reasons longer on hard problems")
            case .xhigh, .max: return String(localized: "Reasons as long as it takes")
            }
        }
    }

    var isRecommended: Bool { self == .medium }
}

/// How effort works on a connection: the Strata engine caps thinking tokens per level; OpenAI's models get the level
/// itself and decide how long to think. On OpenAI's own API each model takes its own levels
/// (`OpenAIPlatform.effortLevels`).
enum EffortStyle: Sendable {
    case tokenCaps, modelDecides, openAI
}
