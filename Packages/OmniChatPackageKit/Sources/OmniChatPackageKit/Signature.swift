import Foundation
import CryptoKit

// CHECKSUMS and SIGNATURE (docs/PACKAGES.md 3.13). CHECKSUMS lists "sha256  path" for every file but SIGNATURE, sorted
// by path, LF; SIGNATURE is Ed25519 over the bytes of CHECKSUMS, optionally with a key-rotation chain.

public enum PackageChecksums {
    public static let fileName = "CHECKSUMS"

    /// The CHECKSUMS text for `files` (every file but SIGNATURE and CHECKSUMS itself).
    public static func make(_ files: [String: Data]) -> String {
        files.keys.filter { $0 != fileName && $0 != PackageSignature.fileName }
            .sorted(by: JSONValue.byteOrder)
            .map { "\(sha256Hex(files[$0]!))  \($0)\n" }
            .joined()
    }

    /// Path → hex digest. Throws on a malformed line.
    public static func parse(_ text: String) throws -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].count == 64, parts[1].hasPrefix(" ") else {
                throw PackageError.signature("CHECKSUMS has a malformed line: \(line.prefix(80))")
            }
            out[String(parts[1].dropFirst())] = String(parts[0]).lowercased()
        }
        return out
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Checks that CHECKSUMS lists exactly the package's files (SIGNATURE aside) with their digests.
    public static func verify(_ text: String, files: [String: Data]) throws {
        let listed = try parse(text)
        let present = Set(files.keys).subtracting([fileName, PackageSignature.fileName])
        if let missing = present.sorted().first(where: { listed[$0] == nil }) {
            throw PackageError.signature("CHECKSUMS doesn't list \(missing). Pack the package again with omnichat-pkg pack.")
        }
        if let extra = listed.keys.sorted().first(where: { !present.contains($0) }) {
            throw PackageError.signature("CHECKSUMS lists \(extra), which isn't in the package.")
        }
        for path in present.sorted() where listed[path] != sha256Hex(files[path]!) {
            throw PackageError.signature("\(path) doesn't match CHECKSUMS: the package was changed after it was packed.")
        }
    }
}

/// An Ed25519 public key as packages write it: `ed25519:<base64url of the 32 raw bytes>`.
public struct PackageKey: Sendable, Hashable {
    public let raw: Data

    public init(raw: Data) { self.raw = raw }

    public init(_ string: String) throws {
        guard string.hasPrefix("ed25519:"), let data = Base64URL.decode(String(string.dropFirst(8))), data.count == 32 else {
            throw PackageError.signature("\(string.prefix(24))… is not an ed25519 key (expected ed25519:<base64url>).")
        }
        raw = data
    }

    public var string: String { "ed25519:" + Base64URL.encode(raw) }

    /// A short, readable fingerprint for the review sheet: the first 16 bytes of its SHA-256 in groups of four hex digits.
    public var fingerprint: String {
        let hex = SHA256.hash(data: raw).prefix(16).map { String(format: "%02x", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { i in
            String(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 4)])
        }.joined(separator: " ")
    }

    func publicKey() throws -> Curve25519.Signing.PublicKey {
        do { return try Curve25519.Signing.PublicKey(rawRepresentation: raw) }
        catch { throw PackageError.signature("The key is not a valid Ed25519 public key.") }
    }
}

/// The SIGNATURE file.
public struct PackageSignature: Codable, Sendable, Equatable {
    public static let fileName = "SIGNATURE"
    /// Signed by the old key to vouch for the next one in a rotation chain.
    public static let rotationPrefix = "omnichat-key-rotation:v1\n"
    /// The prefix links signed before the rename to OmniChat carry: still verified, never written.
    public static let legacyRotationPrefixes = ["openchat-key-rotation:v1\n"]

    public var alg: String
    /// The original key.
    public var key: String
    /// Base64url signature over CHECKSUMS by the newest key (the last of `chain`, or `key`).
    public var sig: String
    public var chain: [Link]?

    public struct Link: Codable, Sendable, Equatable {
        /// The next key.
        public var key: String
        /// The previous key's signature over `rotationPrefix + key` (or a legacy prefix + key).
        public var sig: String
        public init(key: String, sig: String) { self.key = key; self.sig = sig }
    }

    public init(alg: String = "ed25519", key: String, sig: String, chain: [Link]? = nil) {
        self.alg = alg; self.key = key; self.sig = sig; self.chain = chain
    }

    /// Signs CHECKSUMS with `privateKey`; `chain` (from an earlier rotation) is kept, and its last key must be this one.
    public static func sign(checksums: Data, with privateKey: Curve25519.Signing.PrivateKey, original: String? = nil,
                            chain: [Link]? = nil) throws -> PackageSignature {
        let own = PackageKey(raw: privateKey.publicKey.rawRepresentation).string
        let sig = try privateKey.signature(for: checksums)
        return PackageSignature(key: original ?? own, sig: Base64URL.encode(sig), chain: chain)
    }

    /// A link handing over from `old` to `new`.
    public static func rotate(from old: Curve25519.Signing.PrivateKey, to new: String) throws -> Link {
        Link(key: new, sig: Base64URL.encode(try old.signature(for: Data((rotationPrefix + new).utf8))))
    }

    /// Every key from the original to the newest, each vouched for by the one before.
    public func verifiedKeys() throws -> [PackageKey] {
        guard alg == "ed25519" else { throw PackageError.signature("SIGNATURE uses \(alg); only ed25519 is supported.") }
        var keys = [try PackageKey(key)]
        for link in chain ?? [] {
            let next = try PackageKey(link.key)
            let previous = try keys.last!.publicKey()
            guard let sig = Base64URL.decode(link.sig),
                  ([Self.rotationPrefix] + Self.legacyRotationPrefixes).contains(where: {
                      previous.isValidSignature(sig, for: Data(($0 + next.string).utf8))
                  }) else {
                throw PackageError.signature("The key rotation chain in SIGNATURE is broken at \(next.fingerprint).")
            }
            keys.append(next)
        }
        return keys
    }

    /// Verifies the signature over `checksums`; returns the chain of keys, newest last.
    public func verify(checksums: Data) throws -> [PackageKey] {
        let keys = try verifiedKeys()
        guard let sig = Base64URL.decode(self.sig), try keys.last!.publicKey().isValidSignature(sig, for: checksums) else {
            throw PackageError.signature("SIGNATURE doesn't match CHECKSUMS: the package was changed after it was signed, or signed with another key.")
        }
        return keys
    }

    public static func decode(_ data: Data) throws -> PackageSignature {
        do { return try JSONDecoder().decode(PackageSignature.self, from: data) }
        catch { throw PackageError.signature("SIGNATURE is not valid JSON of the form {\"alg\", \"key\", \"sig\"}.") }
    }

    public func encoded() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return (try? e.encode(self)) ?? Data()
    }
}

public enum PackageKeys {
    /// A new signing key, as the raw private key in base64url (keep it secret) and the public key string.
    public static func generate() -> (privateKey: String, publicKey: String) {
        let key = Curve25519.Signing.PrivateKey()
        return (Base64URL.encode(key.rawRepresentation), PackageKey(raw: key.publicKey.rawRepresentation).string)
    }

    public static func privateKey(_ text: String) throws -> Curve25519.Signing.PrivateKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Base64URL.decode(trimmed.hasPrefix("ed25519:") ? String(trimmed.dropFirst(8)) : trimmed),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else {
            throw PackageError.signature("The private key file doesn't hold an Ed25519 key from omnichat-pkg keygen.")
        }
        return key
    }
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}
