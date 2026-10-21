import CryptoKit
import Foundation
import Security

// Private keys as the user or the model pastes them: what kind they are, whether they need a passphrase, and their
// public half (`authorized_keys` line) when it can be read without one. libssh2 does the real parsing when it signs;
// this is for the UI, the tools' answers and key generation.

/// What a pasted private key is.
struct SSHKeyInfo: Sendable, Equatable {
    enum Format: String, Sendable { case openSSH = "OpenSSH", pem = "PEM", pkcs8 = "PKCS#8", putty = "PuTTY" }
    var format: Format
    /// `ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-nistp256`…; nil when it can't be told without the passphrase.
    var type: String?
    var encrypted: Bool
    /// The `authorized_keys` line, when it can be read without the passphrase.
    var publicKey: String?
    /// RSA modulus size or curve size.
    var bits: Int?

    var summary: String {
        var parts = [type.map(SSHKeyFormat.shortName) ?? "Private key"]
        if let bits, type?.hasPrefix("ssh-rsa") == true { parts.append("\(bits)-bit") }
        parts.append(format.rawValue)
        if encrypted { parts.append("encrypted") }
        return parts.joined(separator: " · ")
    }
}

enum SSHKeyFormat {
    // MARK: Public keys

    /// The type string a key blob starts with.
    static func keyType(ofBlob blob: Data) -> String? {
        var reader = SSHWireReader(blob)
        return try? reader.string()
    }

    /// `SHA256:` + unpadded base64, like `ssh-keygen -l`.
    static func fingerprint(ofBlob blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
    }

    static func publicKeyLine(blob: Data, comment: String?) -> String {
        let type = keyType(ofBlob: blob) ?? "ssh-unknown"
        let line = type + " " + blob.base64EncodedString()
        guard let comment = comment?.trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty else { return line }
        return line + " " + comment
    }

    /// An `authorized_keys` line (or a `.pub` file, or a certificate): type, blob, comment. Options before the type are
    /// skipped.
    static func parsePublicKey(_ line: String) -> (type: String, blob: Data, comment: String)? {
        let fields = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        for i in fields.indices where i + 1 < fields.count {
            guard fields[i].hasPrefix("ssh-") || fields[i].hasPrefix("ecdsa-") || fields[i].hasPrefix("sk-") || fields[i].hasPrefix("rsa-"),
                  let blob = Data(base64Encoded: fields[i + 1]), keyType(ofBlob: blob) == fields[i] else { continue }
            return (fields[i], blob, fields[(i + 2)...].joined(separator: " "))
        }
        return nil
    }

    static func fingerprint(ofPublicKey line: String) -> String? {
        parsePublicKey(line).map { fingerprint(ofBlob: $0.blob) }
    }

    /// "ED25519", "RSA", "ECDSA".
    static func shortName(_ type: String) -> String {
        if type.contains("ed25519") { return "ED25519" }
        if type.contains("rsa") { return "RSA" }
        if type.contains("ecdsa") { return "ECDSA" }
        if type.contains("dss") { return "DSA" }
        return type
    }

    // MARK: Private keys

    /// Looks like a private key of any kind this app knows.
    static func isPrivateKey(_ text: String) -> Bool { inspect(text) != nil }

    static func inspect(_ raw: String) -> SSHKeyInfo? {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("PuTTY-User-Key-File") {
            let type = text.split(separator: "\n").first.flatMap { $0.split(separator: ":").last }.map { $0.trimmingCharacters(in: .whitespaces) }
            return SSHKeyInfo(format: .putty, type: type, encrypted: !text.contains("Encryption: none"), publicKey: nil)
        }
        guard let pem = PEMBlock(text) else { return nil }
        switch pem.label {
        case "OPENSSH PRIVATE KEY":
            return inspectOpenSSH(pem.body)
        case "RSA PRIVATE KEY":
            if pem.encrypted { return SSHKeyInfo(format: .pem, type: "ssh-rsa", encrypted: true, publicKey: nil) }
            let rsa = try? RSAKeyParts(pkcs1: pem.body)
            return SSHKeyInfo(format: .pem, type: "ssh-rsa", encrypted: false,
                              publicKey: rsa.map { publicKeyLine(blob: $0.publicBlob, comment: nil) }, bits: rsa?.bits)
        case "EC PRIVATE KEY":
            if pem.encrypted { return SSHKeyInfo(format: .pem, type: "ecdsa", encrypted: true, publicKey: nil) }
            let ec = try? ECKeyParts(sec1: pem.body, curve: nil)
            return SSHKeyInfo(format: .pem, type: ec?.type ?? "ecdsa", encrypted: false,
                              publicKey: ec.map { publicKeyLine(blob: $0.publicBlob, comment: nil) }, bits: ec?.bits)
        case "DSA PRIVATE KEY":
            return SSHKeyInfo(format: .pem, type: "ssh-dss", encrypted: pem.encrypted, publicKey: nil)
        case "PRIVATE KEY":
            return inspectPKCS8(pem.body)
        case "ENCRYPTED PRIVATE KEY":
            return SSHKeyInfo(format: .pkcs8, type: nil, encrypted: true, publicKey: nil)
        default:
            return nil
        }
    }

    private static func inspectOpenSSH(_ body: Data) -> SSHKeyInfo? {
        let magic = Data("openssh-key-v1\0".utf8)
        guard body.starts(with: magic) else { return nil }
        var r = SSHWireReader(body.dropFirst(magic.count))
        guard let cipher = try? r.string(), let _ = try? r.string(), let _ = try? r.bytes(),
              let count = try? r.uint32(), count >= 1, let blob = try? r.bytes() else { return nil }
        let encrypted = cipher != "none"
        var comment: String?
        if !encrypted, let section = try? r.bytes() {
            // check, check, then the key: its type and fields, and the comment last.
            var p = SSHWireReader(section)
            if (try? p.uint32()) != nil, (try? p.uint32()) != nil, let type = try? p.string() {
                let fields = switch type {
                case "ssh-ed25519": 2
                case "ssh-rsa": 6
                case _ where type.hasPrefix("ecdsa-"): 3
                case "ssh-dss": 5
                default: -1
                }
                if fields > 0 {
                    for _ in 0..<fields { _ = try? p.bytes() }
                    comment = try? p.string()
                }
            }
        }
        let type = keyType(ofBlob: blob)
        var bits: Int?
        if type == "ssh-rsa" {
            var b = SSHWireReader(blob)
            _ = try? b.string(); _ = try? b.bytes()
            if let n = try? b.bytes() { bits = (n.drop { $0 == 0 }.count) * 8 }
        } else if let type, type.hasPrefix("ecdsa-sha2-nistp") {
            bits = Int(type.dropFirst("ecdsa-sha2-nistp".count))
        }
        return SSHKeyInfo(format: .openSSH, type: type, encrypted: encrypted, publicKey: publicKeyLine(blob: blob, comment: comment), bits: bits)
    }

    private static func inspectPKCS8(_ body: Data) -> SSHKeyInfo? {
        guard let outer = try? DER(body).sequence(), outer.count >= 3,
              let algorithm = try? outer[1].sequence(), let oid = algorithm.first?.oid,
              let inner = outer[2].octets else { return nil }
        switch oid {
        case "1.2.840.113549.1.1.1":
            let rsa = try? RSAKeyParts(pkcs1: inner)
            return SSHKeyInfo(format: .pkcs8, type: "ssh-rsa", encrypted: false,
                              publicKey: rsa.map { publicKeyLine(blob: $0.publicBlob, comment: nil) }, bits: rsa?.bits)
        case "1.2.840.10045.2.1":
            let curve = algorithm.count > 1 ? algorithm[1].oid : nil
            let ec = try? ECKeyParts(sec1: inner, curve: curve)
            return SSHKeyInfo(format: .pkcs8, type: ec?.type ?? "ecdsa", encrypted: false,
                              publicKey: ec.map { publicKeyLine(blob: $0.publicBlob, comment: nil) }, bits: ec?.bits)
        case "1.3.101.112":
            guard let seed = try? DER(inner).node().octets, seed.count == 32,
                  let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
                return SSHKeyInfo(format: .pkcs8, type: "ssh-ed25519", encrypted: false, publicKey: nil)
            }
            return SSHKeyInfo(format: .pkcs8, type: "ssh-ed25519", encrypted: false,
                              publicKey: publicKeyLine(blob: ed25519Blob(key.publicKey.rawRepresentation), comment: nil), bits: 256)
        default:
            return SSHKeyInfo(format: .pkcs8, type: nil, encrypted: false, publicKey: nil)
        }
    }

    static func ed25519Blob(_ publicKey: Data) -> Data {
        var w = SSHWireWriter()
        w.string("ssh-ed25519")
        w.bytes(publicKey)
        return w.data
    }
}

// MARK: - Generation

/// A new key pair: the private key in OpenSSH format (unencrypted; it is kept in the Keychain) and its
/// `authorized_keys` line.
struct SSHGeneratedKey: Sendable, Equatable {
    var privateKey: String
    var publicKey: String
}

enum SSHKeyGenerator {
    enum KeyType: String, Sendable, CaseIterable { case ed25519, rsa }

    static func generate(_ type: KeyType, comment: String) throws -> SSHGeneratedKey {
        switch type {
        case .ed25519: ed25519(comment: comment)
        case .rsa: try rsa(bits: 4096, comment: comment)
        }
    }

    static func ed25519(comment: String) -> SSHGeneratedKey {
        let key = Curve25519.Signing.PrivateKey()
        let pub = key.publicKey.rawRepresentation
        var fields = SSHWireWriter()
        fields.bytes(pub)
        fields.bytes(key.rawRepresentation + pub)
        return openSSH(type: "ssh-ed25519", publicBlob: SSHKeyFormat.ed25519Blob(pub), privateFields: fields.data, comment: comment)
    }

    static func rsa(bits: Int, comment: String) throws -> SSHGeneratedKey {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: bits]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let der = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw SSHError.key("Couldn't generate an RSA key: \(error?.takeRetainedValue().localizedDescription ?? "unknown error").")
        }
        let parts = try RSAKeyParts(pkcs1: der)
        var fields = SSHWireWriter()
        fields.mpint(parts.n); fields.mpint(parts.e); fields.mpint(parts.d)
        fields.mpint(parts.iqmp); fields.mpint(parts.p); fields.mpint(parts.q)
        return openSSH(type: "ssh-rsa", publicBlob: parts.publicBlob, privateFields: fields.data, comment: comment)
    }

    /// The `openssh-key-v1` container, unencrypted.
    private static func openSSH(type: String, publicBlob: Data, privateFields: Data, comment: String) -> SSHGeneratedKey {
        var section = SSHWireWriter()
        let check = UInt32.random(in: .min ... .max)
        section.uint32(check); section.uint32(check)
        section.string(type)
        section.raw(privateFields)
        section.string(comment)
        var pad: UInt8 = 1
        while section.data.count % 8 != 0 { section.raw(Data([pad])); pad += 1 }
        var w = SSHWireWriter()
        w.raw(Data("openssh-key-v1\0".utf8))
        w.string("none"); w.string("none"); w.bytes(Data())
        w.uint32(1)
        w.bytes(publicBlob)
        w.bytes(section.data)
        let body = w.data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n\(body)\n-----END OPENSSH PRIVATE KEY-----\n"
        return SSHGeneratedKey(privateKey: pem, publicKey: SSHKeyFormat.publicKeyLine(blob: publicBlob, comment: comment))
    }
}

// MARK: - Key parts

private struct RSAKeyParts {
    var n, e, d, p, q, iqmp: Data

    /// PKCS#1 `RSAPrivateKey`: version, n, e, d, p, q, dp, dq, qinv.
    init(pkcs1: Data) throws {
        let items = try DER(pkcs1).sequence()
        guard items.count >= 9 else { throw SSHError.key("Not an RSA private key.") }
        n = items[1].body; e = items[2].body; d = items[3].body
        p = items[4].body; q = items[5].body; iqmp = items[8].body
    }

    var bits: Int { n.drop { $0 == 0 }.count * 8 }

    var publicBlob: Data {
        var w = SSHWireWriter()
        w.string("ssh-rsa"); w.mpint(e); w.mpint(n)
        return w.data
    }
}

private struct ECKeyParts {
    var curve: String
    var point: Data

    static let curves = ["1.2.840.10045.3.1.7": "nistp256", "1.3.132.0.34": "nistp384", "1.3.132.0.35": "nistp521"]

    /// SEC1 `ECPrivateKey`: version, the private key, [0] the curve, [1] the public point.
    init(sec1: Data, curve outerCurve: String?) throws {
        let items = try DER(sec1).sequence()
        guard items.count >= 2, let scalar = items[1].octets else { throw SSHError.key("Not an EC private key.") }
        var curveOID = outerCurve
        var point: Data?
        for item in items.dropFirst(2) {
            if item.tag == 0xA0 { curveOID = (try? DER(item.body).node())?.oid ?? curveOID }
            if item.tag == 0xA1, let bits = try? DER(item.body).node(), bits.tag == 0x03 { point = Data(bits.body.dropFirst()) }
        }
        // A key written with explicit curve parameters names no curve: its sizes tell.
        let bySize = [32: "nistp256", 48: "nistp384", 66: "nistp521"][scalar.count]
            ?? point.flatMap { [65: "nistp256", 97: "nistp384", 133: "nistp521"][$0.count] }
        guard let curve = curveOID.flatMap({ Self.curves[$0] }) ?? bySize else { throw SSHError.key("Unsupported EC curve.") }
        self.curve = curve
        if let point {
            self.point = point
        } else {
            switch curve {
            case "nistp256": self.point = try P256.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation
            case "nistp384": self.point = try P384.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation
            default: self.point = try P521.Signing.PrivateKey(rawRepresentation: scalar).publicKey.x963Representation
            }
        }
    }

    var type: String { "ecdsa-sha2-" + curve }
    var bits: Int { Int(curve.dropFirst(5)) ?? 0 }

    var publicBlob: Data {
        var w = SSHWireWriter()
        w.string(type); w.string(curve); w.bytes(point)
        return w.data
    }
}

/// `-----BEGIN X-----` … `-----END X-----`, with RFC 1421 headers (`Proc-Type: 4,ENCRYPTED`).
private struct PEMBlock {
    var label: String
    var encrypted: Bool
    var body: Data

    init?(_ text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN ") && $0.hasSuffix("-----") }) else { return nil }
        let label = String(lines[start].dropFirst("-----BEGIN ".count).dropLast(5))
        guard let end = lines[start...].firstIndex(of: "-----END \(label)-----") else { return nil }
        var base64 = ""
        var encrypted = false
        for line in lines[(start + 1)..<end] {
            if line.contains(":") {
                if line.hasPrefix("Proc-Type:") && line.contains("ENCRYPTED") { encrypted = true }
                continue
            }
            base64 += line
        }
        guard let body = Data(base64Encoded: base64) else { return nil }
        self.label = label
        self.encrypted = encrypted
        self.body = body
    }
}

// MARK: - Wire formats

/// RFC 4251 data: uint32, string, mpint.
struct SSHWireReader {
    private var data: Data
    init<D: DataProtocol>(_ data: D) { self.data = Data(data) }

    struct Truncated: Error {}

    mutating func uint32() throws -> UInt32 {
        guard data.count >= 4 else { throw Truncated() }
        let v = data.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        data = Data(data.dropFirst(4))
        return v
    }

    mutating func bytes() throws -> Data {
        let n = Int(try uint32())
        guard data.count >= n else { throw Truncated() }
        let out = Data(data.prefix(n))
        data = Data(data.dropFirst(n))
        return out
    }

    mutating func string() throws -> String { String(decoding: try bytes(), as: UTF8.self) }
}

struct SSHWireWriter {
    private(set) var data = Data()

    mutating func raw(_ d: Data) { data.append(d) }
    mutating func uint32(_ v: UInt32) { data.append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
    mutating func bytes(_ d: Data) { uint32(UInt32(d.count)); data.append(d) }
    mutating func string(_ s: String) { bytes(Data(s.utf8)) }

    /// A positive integer from big-endian bytes: no leading zeros, one zero byte when the top bit is set.
    mutating func mpint(_ d: Data) {
        var v = Data(d.drop { $0 == 0 })
        if let first = v.first, first & 0x80 != 0 { v.insert(0, at: 0) }
        bytes(v)
    }
}

/// Just enough DER for private keys: tag, length, body.
private struct DER {
    struct Node {
        var tag: UInt8
        var body: Data
        var octets: Data? { tag == 0x04 ? body : nil }
        var oid: String? {
            guard tag == 0x06, let first = body.first else { return nil }
            var parts = [Int(first) / 40, Int(first) % 40]
            var value = 0
            for byte in body.dropFirst() {
                value = value << 7 | Int(byte & 0x7F)
                if byte & 0x80 == 0 { parts.append(value); value = 0 }
            }
            return parts.map(String.init).joined(separator: ".")
        }
        func sequence() throws -> [Node] {
            guard tag == 0x30 else { throw SSHError.key("Unexpected key structure.") }
            return try DER(body).all()
        }
    }

    private var data: Data
    init(_ data: Data) { self.data = Data(data) }

    mutating func next() throws -> Node {
        guard data.count >= 2 else { throw SSHError.key("Truncated key.") }
        let tag = data[data.startIndex]
        var index = data.startIndex + 1
        var length = Int(data[index]); index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count <= 4, data.endIndex - index >= count else { throw SSHError.key("Truncated key.") }
            length = data[index..<(index + count)].reduce(0) { $0 << 8 | Int($1) }
            index += count
        }
        guard data.endIndex - index >= length else { throw SSHError.key("Truncated key.") }
        let node = Node(tag: tag, body: Data(data[index..<(index + length)]))
        data = Data(data[(index + length)...])
        return node
    }

    func node() throws -> Node { var copy = self; return try copy.next() }
    func sequence() throws -> [Node] { try node().sequence() }

    func all() throws -> [Node] {
        var copy = self
        var out: [Node] = []
        while !copy.data.isEmpty { out.append(try copy.next()) }
        return out
    }
}
