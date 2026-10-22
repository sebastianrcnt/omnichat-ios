import Foundation

/// SemVer 2.0 versions, compared by precedence (build metadata ignored).
public struct SemVer: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var prerelease: [String]

    public init(_ major: Int, _ minor: Int, _ patch: Int, prerelease: [String] = []) {
        self.major = major; self.minor = minor; self.patch = patch; self.prerelease = prerelease
    }

    /// Strict: `1.4.0`, `2.0.0-beta.1`, `1.0.0+build.5`. Loose (for ranges): `1`, `1.4` fill in zeros.
    /// Pre-release and build identifiers must be `[0-9A-Za-z-]+` (SemVer 2.0 rules 9 and 10): an installed package's
    /// version names its folder, so `1.0.0+x/../..` must not parse.
    public init?(_ text: String, loose: Bool = false) {
        var core = text.trimmingCharacters(in: .whitespaces)
        if let plus = core.firstIndex(of: "+") {
            let build = core[core.index(after: plus)...].split(separator: ".", omittingEmptySubsequences: false)
            guard build.allSatisfy(Self.isIdentifier) else { return nil }
            core = String(core[..<plus])
        }
        var pre: [String] = []
        if let dash = core.firstIndex(of: "-") {
            pre = core[core.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            core = String(core[..<dash])
            guard pre.allSatisfy({ Self.isIdentifier($0[...]) }) else { return nil }
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 || (loose && (1...3).contains(parts.count)) else { return nil }
        var nums: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), let n = Int(p), n >= 0, !(p.count > 1 && p.hasPrefix("0")) else { return nil }
            nums.append(n)
        }
        while nums.count < 3 { nums.append(0) }
        self.init(nums[0], nums[1], nums[2], prerelease: pre)
    }

    /// A non-empty run of ASCII letters, digits and `-`.
    private static func isIdentifier(_ id: Substring) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."z").contains($0) || ("A"..."Z").contains($0) || $0 == "-" }
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) { return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
        if a.prerelease.isEmpty != b.prerelease.isEmpty { return !a.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (.some, nil): return true
            case (nil, .some): return false
            default: return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }

    /// Whether the version satisfies a range: space-separated comparators, `>=1.3.0`, `<2`, `^1.2`, `~1.2.3`, `=1.0.0`
    /// or a bare version (exact). Nil when the range can't be read.
    public func satisfies(_ range: String) -> Bool? {
        for token in range.split(separator: " ") where !token.isEmpty {
            let t = String(token)
            let ops = [">=", "<=", ">", "<", "^", "~", "="]
            let op = ops.first { t.hasPrefix($0) } ?? ""
            guard let v = SemVer(String(t.dropFirst(op.count)), loose: true) else { return nil }
            let ok: Bool
            switch op {
            case ">=": ok = self >= v
            case "<=": ok = self <= v
            case ">": ok = self > v
            case "<": ok = self < v
            case "^": ok = self >= v && (v.major > 0 ? major == v.major : minor == v.minor && major == 0)
            case "~": ok = self >= v && major == v.major && minor == v.minor
            default: ok = (major, minor, patch) == (v.major, v.minor, v.patch)
            }
            if !ok { return false }
        }
        return true
    }
}
