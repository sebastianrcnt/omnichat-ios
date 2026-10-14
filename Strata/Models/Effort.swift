import Foundation

/// Reasoning effort levels understood by the gateway (`reasoning_effort`).
enum Effort: String, CaseIterable, Codable, Sendable, Identifiable {
    case low, medium, high, xhigh, max

    var id: String { rawValue }

    /// Value sent on the wire.
    var apiValue: String { rawValue }

    static let `default`: Effort = .medium

    var title: String {
        switch self {
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
    func resolved(in levels: [Effort]) -> Effort {
        guard !levels.isEmpty, !levels.contains(self) else { return self }
        let rank = Effort.allCases.firstIndex(of: self) ?? 0
        return levels.last { (Effort.allCases.firstIndex(of: $0) ?? 0) < rank } ?? levels[0]
    }

    func hint(_ style: EffortStyle) -> String {
        switch style {
        case .tokenCaps:
            if let cap = thinkingTokenCap { return String(localized: "Thinks up to \(cap.formatted()) tokens") }
            return String(localized: "No thinking limit")
        case .modelDecides:
            switch self {
            case .low: return String(localized: "Brief reasoning, faster answers")
            case .medium: return String(localized: "Balanced")
            case .high: return String(localized: "Reasons longer on hard problems")
            case .xhigh, .max: return String(localized: "Reasons as long as it takes")
            }
        }
    }

    var isRecommended: Bool { self == .medium }
}

/// How effort works on a connection: the Strata engine caps thinking tokens per level; OpenAI's models get the level
/// itself and decide how long to think.
enum EffortStyle: Sendable {
    case tokenCaps, modelDecides
}
