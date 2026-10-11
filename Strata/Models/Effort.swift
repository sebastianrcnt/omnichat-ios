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

    var hint: String {
        if let cap = thinkingTokenCap {
            return String(localized: "Thinks up to \(cap.formatted()) tokens")
        }
        return String(localized: "No thinking limit")
    }

    var isRecommended: Bool { self == .medium }
}
