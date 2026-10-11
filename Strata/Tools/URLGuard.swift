import Foundation
import Darwin

protocol HostResolving: Sendable {
    /// Numeric address strings for `host`, or empty when it does not resolve.
    func resolve(_ host: String) async -> [String]
}

/// Resolves with getaddrinfo, which also normalizes odd literal forms (`127.1`, `0x7f000001`, ...).
struct SystemHostResolver: HostResolving {
    func resolve(_ host: String) async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var res: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else {
                    cont.resume(returning: [])
                    return
                }
                defer { freeaddrinfo(first) }
                var out: [String] = []
                var cur: UnsafeMutablePointer<addrinfo>? = first
                while let ai = cur {
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                        out.append(String(decoding: bytes, as: UTF8.self))
                    }
                    cur = ai.pointee.ai_next
                }
                cont.resume(returning: out)
            }
        }
    }
}

enum URLGuardError: Error, LocalizedError, Equatable {
    case invalidURL
    case unsupportedScheme(String)
    case blockedHost(String)
    case unresolvable(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: String(localized: "The URL is not valid.")
        case .unsupportedScheme(let s): String(localized: "Only http and https URLs can be fetched (got \(s)).")
        case .blockedHost(let h): String(localized: "Blocked: \(h) is a private, local or loopback address.")
        case .unresolvable(let h): String(localized: "Could not resolve the host \(h).")
        }
    }
}

/// Keeps `web_fetch` away from private, LAN, loopback and link-local destinations.
enum URLGuard {
    static func isBlockedHostname(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if h.isEmpty { return true }
        if h == "localhost" { return true }
        for suffix in [".localhost", ".local", ".internal", ".lan", ".home.arpa", ".intranet", ".corp"] where h.hasSuffix(suffix) {
            return true
        }
        return false
    }

    /// True when the numeric address (v4 or v6 literal) is not publicly routable.
    static func isBlocked(address: String) -> Bool {
        var addr = address
        if let pct = addr.firstIndex(of: "%") { addr = String(addr[..<pct]) }
        var v4 = in_addr()
        if inet_pton(AF_INET, addr, &v4) == 1 {
            let b = withUnsafeBytes(of: &v4) { Array($0) }
            return isBlocked(ipv4: b)
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, addr, &v6) == 1 {
            let b = withUnsafeBytes(of: &v6) { Array($0) }
            return isBlocked(ipv6: b)
        }
        return true // not an IP literal: treat as unsafe
    }

    static func isBlocked(ipv4 b: [UInt8]) -> Bool {
        guard b.count == 4 else { return true }
        switch (b[0], b[1]) {
        case (0, _): return true                                  // 0.0.0.0/8
        case (10, _): return true                                 // 10/8
        case (100, 64...127): return true                         // 100.64/10 CGNAT
        case (127, _): return true                                // loopback
        case (169, 254): return true                              // link-local
        case (172, 16...31): return true                          // 172.16/12
        case (192, 0) where b[2] == 0: return true                // 192.0.0/24
        case (192, 168): return true                              // 192.168/16
        case (198, 18...19): return true                          // benchmarking
        case (224...255, _): return true                          // multicast, reserved, broadcast
        default: return false
        }
    }

    static func isBlocked(ipv6 b: [UInt8]) -> Bool {
        guard b.count == 16 else { return true }
        if b.allSatisfy({ $0 == 0 }) { return true }                                  // ::
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }            // ::1
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }                      // fe80::/10
        if (b[0] & 0xfe) == 0xfc { return true }                                      // fc00::/7
        if b[0] == 0xff { return true }                                               // multicast
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {      // ::ffff:a.b.c.d
            return isBlocked(ipv4: Array(b[12..<16]))
        }
        if b[0..<12].allSatisfy({ $0 == 0 }) { return isBlocked(ipv4: Array(b[12..<16])) } // v4-compatible
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b {             // 64:ff9b::/96 NAT64
            return isBlocked(ipv4: Array(b[12..<16]))
        }
        return false
    }

    /// Throws unless `url` is http(s) and its host resolves only to public addresses.
    static func validate(_ url: URL, resolver: any HostResolving = SystemHostResolver()) async throws {
        guard let scheme = url.scheme?.lowercased() else { throw URLGuardError.invalidURL }
        guard scheme == "http" || scheme == "https" else { throw URLGuardError.unsupportedScheme(scheme) }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { throw URLGuardError.invalidURL }
        if isBlockedHostname(host) { throw URLGuardError.blockedHost(host) }
        let addresses = await resolver.resolve(host)
        if addresses.isEmpty { throw URLGuardError.unresolvable(host) }
        if addresses.contains(where: { isBlocked(address: $0) }) { throw URLGuardError.blockedHost(host) }
    }
}

/// URL rewrites applied before fetching.
enum URLRewriter {
    static func rewrite(_ url: URL) -> URL {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return url }
        if host == "blog.naver.com" {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.host = "m.blog.naver.com"
            return comps?.url ?? url
        }
        return url
    }
}
