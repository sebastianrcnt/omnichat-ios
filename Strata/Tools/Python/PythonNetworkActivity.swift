import Foundation
import Observation

/// What a running Python call is doing on the network ("Network: TCP db.local:5432, …; listening on TCP port 8000"),
/// for its card while it runs. The finished run's output carries the same line.
@MainActor
@Observable
final class PythonNetworkActivity {
    static let shared = PythonNetworkActivity()

    private var summaries: [String: String] = [:]

    private static func key(_ conversation: UUID?, _ callID: String?) -> String {
        "\(conversation?.uuidString ?? "-")|\(callID ?? "-")"
    }

    func summary(conversation: UUID?, callID: String?) -> String? { summaries[Self.key(conversation, callID)] }

    func update(conversation: UUID?, callID: String?, summary: String?) {
        summaries[Self.key(conversation, callID)] = summary
    }

    func clear(conversation: UUID?, callID: String?) {
        summaries[Self.key(conversation, callID)] = nil
    }
}

/// The device's own addresses, for "listening on TCP port 8000 (192.168.1.23)".
enum LocalAddress {
    /// The IPv4 address on Wi-Fi or Ethernet, if there is one.
    static func wifi() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: String?
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: entry.pointee.ifa_name)
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  name.hasPrefix("en"), entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name == "en0" { return text }
            found = found ?? text
        }
        return found
    }
}
