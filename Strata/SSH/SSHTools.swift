import Foundation

// The model's SSH tools: run commands, move files, and keep the credentials and servers it is given. The model handles
// secrets directly (the user's choice); the UI masks them (`SSHMask`).

enum SSHToolNames {
    static let exec = "ssh_exec"
    static let output = "ssh_output"
    static let upload = "ssh_upload"
    static let download = "ssh_download"
    static let credentialSave = "ssh_credential_save"
    static let credentialList = "ssh_credential_list"
    static let credentialGet = "ssh_credential_get"
    static let credentialDelete = "ssh_credential_delete"
    static let serverSave = "ssh_server_save"
    static let serverList = "ssh_server_list"
    static let serverDelete = "ssh_server_delete"
    static let keygen = "ssh_keygen"

    static let all = [exec, output, upload, download, credentialSave, credentialList, credentialGet, credentialDelete,
                      serverSave, serverList, serverDelete, keygen]

    static func covers(_ name: String) -> Bool { name.hasPrefix("ssh_") && all.contains(name) }

    /// Tools that reach a server (and show their target in the feed).
    static func connects(_ name: String) -> Bool { [exec, upload, download].contains(name) }
}

extension ToolDefinition {
    private typealias P = ToolDefinition.Function.Parameters.Property

    private static let targetProperties: [String: P] = [
        "server": .init(description: "A saved server's name (see ssh_server_list). Or leave it out and give host and user."),
        "host": .init(description: "Host name or IP address, when not using a saved server."),
        "user": .init(description: "User name, when not using a saved server (or to override its user)."),
        "port": .init(type: "integer", description: "Port. Defaults to 22 (or the saved server's)."),
        "credential": .init(description: "Optional. A saved credential's name; defaults to the saved server's."),
        "password": .init(description: "Optional. A password to sign in with (also answers a password prompt)."),
        "private_key": .init(description: "Optional. A private key to sign in with: the whole OpenSSH or PEM text."),
        "passphrase": .init(description: "Optional. The private key's passphrase."),
        "jump": .init(description: "Optional. Jump hosts, comma-separated, first to last: saved server names or user@host[:port] (like ProxyJump). Defaults to the saved server's."),
    ]

    static let sshExec = ToolDefinition(function: .init(
        name: SSHToolNames.exec,
        description: "Run a shell command on a server over SSH and return its stdout, stderr and exit code. Each call is a new connection: cd and variables don't carry over, so chain steps with && in one command. Long output is cut in the middle; read the rest with ssh_output. The user may be asked to approve the command first.",
        parameters: .init(properties: targetProperties.merging([
            "command": .init(description: "The command, run by the user's login shell."),
            "stdin": .init(description: "Optional. Text sent to the command's standard input, for example a password for sudo -S."),
            "timeout": .init(type: "integer", description: "Optional. Seconds to wait for the command, 1 to 3600. Defaults to 60. At the deadline the connection is closed and the output so far returned."),
        ]) { a, _ in a }, required: ["command"])))

    static let sshOutput = ToolDefinition(function: .init(
        name: SSHToolNames.output,
        description: "Read more of a long ssh_exec or ssh_download output this chat already got, by its id, from a character offset.",
        parameters: .init(properties: [
            "id": .init(description: "The output id from the earlier result, like o3."),
            "stream": .init(description: "stdout (default) or stderr.", choices: ["stdout", "stderr"]),
            "offset": .init(type: "integer", description: "Character offset to start from. Defaults to 0."),
        ], required: ["id"])))

    static let sshUpload = ToolDefinition(function: .init(
        name: SSHToolNames.upload,
        description: "Write a file on a server over SFTP, replacing it if it exists. For text, pass content; for binary, content_base64. At most 10 MB. The user may be asked to approve it first.",
        parameters: .init(properties: targetProperties.merging([
            "path": .init(description: "The remote path. Relative paths start in the user's home directory."),
            "content": .init(description: "The file's text."),
            "content_base64": .init(description: "The file's bytes, base64, instead of content."),
            "mode": .init(description: "Optional. Permissions in octal, like 644 or 755. Defaults to 644."),
        ]) { a, _ in a }, required: ["path"])))

    static let sshDownload = ToolDefinition(function: .init(
        name: SSHToolNames.download,
        description: "Read a file from a server over SFTP. Text is returned (long files in slices, continued with ssh_output); small binary files as base64. At most 1 MB.",
        parameters: .init(properties: targetProperties.merging([
            "path": .init(description: "The remote path. Relative paths start in the user's home directory."),
        ]) { a, _ in a }, required: ["path"])))

    static let sshCredentialSave = ToolDefinition(function: .init(
        name: SSHToolNames.credentialSave,
        description: "Save a credential by name in the device's Keychain, to sign in with later (also in other chats). Give a password, a private key (with its passphrase, if any), or keyboard-interactive answers. The same name replaces a saved credential.",
        parameters: .init(properties: [
            "name": .init(description: "A short name: letters, digits, dots, dashes, underscores, like nas-admin or id_ed25519."),
            "password": .init(description: "Optional. A password."),
            "private_key": .init(description: "Optional. A private key: the whole OpenSSH or PEM text."),
            "passphrase": .init(description: "Optional. The private key's passphrase."),
            "certificate": .init(description: "Optional. An OpenSSH certificate line (…-cert-v01@openssh.com) to present with the key."),
            "answers": .init(description: "Optional. Keyboard-interactive answers, one per line, in the order the server asks."),
            "username": .init(description: "Optional. The user name it belongs to."),
            "note": .init(description: "Optional. What it is for."),
        ], required: ["name"])))

    static let sshCredentialList = ToolDefinition(function: .init(
        name: SSHToolNames.credentialList,
        description: "List the saved credentials: names, kinds, user names and public keys (no secrets).",
        parameters: .init(properties: [:], required: [])))

    static let sshCredentialGet = ToolDefinition(function: .init(
        name: SSHToolNames.credentialGet,
        description: "Get a saved credential with its secrets (password, private key, passphrase, answers).",
        parameters: .init(properties: ["name": .init(description: "The credential's name.")], required: ["name"])))

    static let sshCredentialDelete = ToolDefinition(function: .init(
        name: SSHToolNames.credentialDelete,
        description: "Delete a saved credential.",
        parameters: .init(properties: ["name": .init(description: "The credential's name.")], required: ["name"])))

    static let sshServerSave = ToolDefinition(function: .init(
        name: SSHToolNames.serverSave,
        description: "Save a server by name, to use with the other ssh_ tools (also in other chats). Either give name, host, user (and optionally port, credential, jump), or paste an ssh_config text to save each Host in it; its IdentityFile names a saved credential with the file's name (like id_ed25519). The same name replaces a saved server.",
        parameters: .init(properties: [
            "name": .init(description: "A short name, like nas or web-prod."),
            "host": .init(description: "Host name or IP address."),
            "user": .init(description: "User name."),
            "port": .init(type: "integer", description: "Optional. Defaults to 22."),
            "credential": .init(description: "Optional. The saved credential to sign in with."),
            "jump": .init(description: "Optional. Jump hosts, comma-separated, first to last: saved server names or user@host[:port]."),
            "note": .init(description: "Optional. What the server is."),
            "ssh_config": .init(description: "Optional. ssh_config text (Host blocks with HostName, User, Port, ProxyJump, IdentityFile) to import instead."),
        ], required: [])))

    static let sshServerList = ToolDefinition(function: .init(
        name: SSHToolNames.serverList,
        description: "List the saved servers: names, addresses, credentials and jump hosts.",
        parameters: .init(properties: [:], required: [])))

    static let sshServerDelete = ToolDefinition(function: .init(
        name: SSHToolNames.serverDelete,
        description: "Delete a saved server.",
        parameters: .init(properties: ["name": .init(description: "The server's name.")], required: ["name"])))

    static let sshKeygen = ToolDefinition(function: .init(
        name: SSHToolNames.keygen,
        description: "Generate a new key pair on this device and save the private key as a credential. Returns the public key line to add to ~/.ssh/authorized_keys on a server.",
        parameters: .init(properties: [
            "name": .init(description: "The credential's name, like phone-ed25519."),
            "type": .init(description: "ed25519 (default) or rsa (4096-bit).", choices: ["ed25519", "rsa"]),
            "comment": .init(description: "Optional. The key's comment. Defaults to the name."),
        ], required: ["name"])))

    /// The SSH group's tools, in a fixed order (part of the cached prefix).
    static let ssh: [ToolDefinition] = [sshExec, sshOutput, sshUpload, sshDownload, sshCredentialSave, sshCredentialList,
                                        sshCredentialGet, sshCredentialDelete, sshServerSave, sshServerList, sshServerDelete, sshKeygen]
}

// MARK: - Arguments

/// A call's arguments, read leniently (numbers as strings, lists as arrays or text).
struct SSHArguments: Sendable, Equatable {
    var values: [String: String] = [:]

    init(json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for (key, value) in obj {
            switch value {
            case let s as String: values[key] = s
            case let n as NSNumber: values[key] = CFGetTypeID(n) == CFBooleanGetTypeID() ? (n.boolValue ? "true" : "false") : n.stringValue
            case let a as [Any]: values[key] = a.map { "\($0)" }.joined(separator: "\n")
            default: break
            }
        }
    }

    init(_ values: [String: String]) { self.values = values }

    /// A non-empty value, trimmed (secrets and file contents are not trimmed: `raw`).
    func string(_ key: String) -> String? {
        guard let v = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }

    func raw(_ key: String) -> String? {
        guard let v = values[key], !v.isEmpty else { return nil }
        return v
    }

    func int(_ key: String) -> Int? {
        guard let s = string(key) else { return nil }
        // `Int(exactly:)`: a number too big for Int ("1e100") is no number, not a crash.
        return Int(s) ?? Double(s).flatMap { Int(exactly: $0.rounded(.towardZero)) }
    }

    /// A list given as an array, or comma- or newline-separated text.
    func list(_ key: String, separators: CharacterSet = CharacterSet(charactersIn: ",\n")) -> [String] {
        (values[key] ?? "").components(separatedBy: separators).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Lines, kept as typed (answers can have spaces).
    func lines(_ key: String) -> [String] {
        (values[key] ?? "").components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }.filter { !$0.isEmpty }
    }
}

/// Where a call connects, and how it names it.
struct SSHTarget: Sendable, Equatable {
    var hops: [SSHHop]
    /// The approval key: the saved server's name, or `user@host:port`.
    var key: String
    /// The feed's name for it: the server's name, or `user@host`.
    var label: String
}

enum SSHTargetResolver {
    /// `user@host[:port]`.
    static func parseAddress(_ text: String) -> (user: String?, host: String, port: Int?)? {
        var rest = text.trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("ssh://") { rest.removeFirst(6) }
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
        }
        var port: Int?
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") { // [v6]:port
            let host = String(rest[rest.index(after: rest.startIndex)..<close])
            let tail = rest[rest.index(after: close)...]
            if tail.hasPrefix(":") { port = Int(tail.dropFirst()) }
            return host.isEmpty ? nil : (user, host, port)
        }
        if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            port = Int(rest[rest.index(after: colon)...])
            rest = String(rest[..<colon])
        }
        guard !rest.isEmpty, !rest.contains(" ") else { return nil }
        return (user, rest, port)
    }

    /// The hops of a call: its jump hosts, then the target, each with its credentials.
    static func resolve(_ args: SSHArguments, store: SSHStore) throws -> SSHTarget {
        var server: SSHServer?
        if let name = args.string("server") {
            if let saved = store.server(named: name) {
                server = saved
            } else if args.string("host") == nil, let address = parseAddress(name), address.user != nil {
                server = SSHServer(name: "", host: address.host, port: address.port ?? 22, user: address.user ?? "")
            } else {
                let names = store.servers.map(\.name)
                throw SSHStoreError.missing("No saved server is named \"\(name)\". "
                    + (names.isEmpty ? "None are saved yet; pass host and user instead, or save one with ssh_server_save."
                       : "Saved servers: \(names.joined(separator: ", ")).") )
            }
        }
        func savedCredential(_ name: String) throws -> SSHCredential {
            guard let saved = store.credential(named: name) else {
                let names = store.credentials.map(\.name)
                throw SSHStoreError.missing("No saved credential is named \"\(name)\". "
                    + (names.isEmpty ? "None are saved yet." : "Saved credentials: \(names.joined(separator: ", ")).") )
            }
            return saved
        }
        let named = try args.string("credential").map(savedCredential)
        guard let host = args.string("host") ?? server?.host else {
            throw SSHStoreError.missing("Say where to connect: a saved server's name (server), or host and user.")
        }
        if args.values["port"] != nil, args.int("port") == nil { throw SSHStoreError.invalid("The port must be a number between 1 and 65535.") }
        let port = args.int("port") ?? server?.port ?? 22
        guard (1...65535).contains(port) else { throw SSHStoreError.invalid("The port must be between 1 and 65535.") }
        let jumpsGiven = args.values["jump"] != nil ? args.list("jump") : nil
        // A saved server's name stands for its address, user and jump hosts. A call that names the server but changes
        // any of them goes somewhere else: it is not that server (not its approvals, not its saved credential), so its
        // key and label are the real address and it is asked about anew.
        if let saved = server, !saved.name.isEmpty {
            let user = args.string("user") ?? saved.user
            if host.lowercased() != saved.host.lowercased() || port != saved.port || user != saved.user
                || (jumpsGiven.map { $0 != saved.jump } ?? false) {
                server = SSHServer(name: "", host: host, port: port, user: user)
            }
        }
        var credential = named
        if credential == nil, let name = server?.credential { credential = try savedCredential(name) }
        guard let user = args.string("user") ?? server?.user ?? credential?.username else {
            throw SSHStoreError.missing("Say which user to sign in as (user).")
        }

        var auths: [SSHAuth] = []
        if let key = args.raw("private_key") {
            guard SSHKeyFormat.isPrivateKey(key) else {
                throw SSHStoreError.invalid("private_key isn't a private key OmniChat can read: pass the whole text, from -----BEGIN to -----END.")
            }
            auths.append(.privateKey(key, passphrase: args.raw("passphrase")))
        }
        if let password = args.raw("password") { auths.append(.password(password)) }
        if var credential {
            if let passphrase = args.raw("passphrase"), args.raw("private_key") == nil { credential.passphrase = passphrase }
            auths += credential.auths
        }

        let jumps = jumpsGiven ?? server?.jump ?? []
        var hops: [SSHHop] = []
        for jump in jumps {
            if let saved = store.server(named: jump) {
                let jumpAuths = saved.credential.flatMap(store.credential(named:))?.auths ?? auths
                hops.append(SSHHop(host: saved.host, port: saved.port, user: saved.user, auths: jumpAuths))
            } else if let address = parseAddress(jump) {
                hops.append(SSHHop(host: address.host, port: address.port ?? 22, user: address.user ?? user, auths: auths))
            } else {
                throw SSHStoreError.invalid("The jump host \"\(jump)\" is neither a saved server nor user@host[:port].")
            }
        }
        let target = SSHHop(host: host, port: port, user: user, auths: auths)
        hops.append(target)
        if let server, !server.name.isEmpty {
            return SSHTarget(hops: hops, key: server.name, label: server.name)
        }
        // Unsaved: the key names every hop, so an approval for one route never covers another through other jump hosts.
        let via = hops.dropLast().map { "\($0.user)@\($0.host.lowercased()):\($0.port)" }
        let key = (via + ["\(user)@\(host.lowercased()):\(port)"]).joined(separator: " > ")
        let address = port == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(port)"
        return SSHTarget(hops: hops, key: key, label: via.isEmpty ? address : String(localized: "\(address) via \(jumps.joined(separator: ", "))"))
    }
}

// MARK: - ssh_config

/// The Host blocks of a pasted `ssh_config`, as servers. Patterns (`*`, `?`, `!`) are skipped.
enum SSHConfigImport {
    struct Entry: Equatable {
        var server: SSHServer
        /// `IdentityFile`'s file name, the credential it is expected under.
        var identity: String?
    }

    static func parse(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        var current: [(alias: String, fields: [String: String])] = []
        var defaults: [String: String] = [:]
        func flush() {
            for block in current {
                let f = block.fields.merging(defaults) { mine, _ in mine }
                let jump = (f["proxyjump"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.lowercased() != "none" && !$0.isEmpty }
                var identity = f["identityfile"].map { ($0 as NSString).lastPathComponent }
                if identity?.isEmpty == true { identity = nil }
                let server = SSHServer(name: block.alias, host: f["hostname"] ?? block.alias, port: Int(f["port"] ?? "") ?? 22,
                                       user: f["user"] ?? "", credential: identity, jump: jump)
                entries.append(Entry(server: server, identity: identity))
            }
            current = []
        }
        var inWildcard = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "=\""))).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if key == "host" {
                flush()
                let aliases = value.split(separator: " ").map(String.init)
                inWildcard = aliases.allSatisfy { $0.contains("*") || $0.contains("?") || $0.hasPrefix("!") }
                current = aliases.filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }.map { ($0, [:]) }
            } else if key == "match" {
                flush()
                inWildcard = false
            } else if current.isEmpty {
                if inWildcard || entries.isEmpty, defaults[key] == nil { defaults[key] = value } // Host * and lines before any Host
            } else {
                for i in current.indices where current[i].fields[key] == nil { current[i].fields[key] = value } // first value wins
            }
        }
        flush()
        return entries
    }
}

// MARK: - Masking

/// Secret values in SSH calls and results: shown masked in the UI (a tap reveals), sent to the model as they are.
enum SSHMask {
    static let secretKeys: Set<String> = ["password", "private_key", "passphrase", "answers", "stdin", "certificate"]
    static let dots = "••••••"

    static func isSecret(_ key: String) -> Bool { secretKeys.contains(key) }

    /// The arguments with secret values replaced (for lines the UI shows before the call finishes).
    static func sanitized(_ arguments: String) -> String {
        var args = SSHArguments(json: arguments)
        for key in args.values.keys where isSecret(key) { args.values[key] = dots }
        let sorted = args.values.sorted { $0.key < $1.key }
        guard let data = try? JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: sorted), options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A tool's result is a secret as a whole (`ssh_credential_get`).
    static func resultIsSecret(_ tool: String) -> Bool { tool == SSHToolNames.credentialGet }

    /// `ssh_credential_save`'s line with the secret fields named, not shown.
    static func describe(_ args: SSHArguments) -> [String] {
        args.values.keys.filter(isSecret).sorted()
    }
}

// MARK: - Outputs kept for paging

/// Long outputs of this session, for `ssh_output`. In memory only, the last few per chat.
final class SSHOutputStore: @unchecked Sendable {
    static let shared = SSHOutputStore()
    private let lock = NSLock()
    private var items: [(id: String, conversation: UUID?, stdout: String, stderr: String)] = []
    private var counter = 0
    static let keep = 40

    func add(conversation: UUID?, stdout: String, stderr: String) -> String {
        lock.withLock {
            counter += 1
            let id = "o\(counter)"
            items.append((id, conversation, stdout, stderr))
            if items.count > Self.keep { items.removeFirst(items.count - Self.keep) }
            return id
        }
    }

    func get(_ id: String, conversation: UUID?) -> (stdout: String, stderr: String)? {
        lock.withLock { items.last { $0.id == id && $0.conversation == conversation }.map { ($0.stdout, $0.stderr) } }
    }
}

/// How the model reads a stream: whole when it fits, else its start and end with the middle to read with ssh_output.
enum SSHOutputFormat {
    static func clip(_ text: String, limit: Int, id: String, stream: String) -> (text: String, clipped: Bool) {
        guard text.count > limit else { return (text, false) }
        let headCount = limit / 4
        let tailCount = limit - headCount
        let left = text.count - headCount - tailCount
        let note = "\n[… \(left) characters left out (\(headCount) to \(headCount + left) of \(text.count)). Read them with ssh_output id=\(id) stream=\(stream) offset=\(headCount). …]\n"
        return (String(text.prefix(headCount)) + note + String(text.suffix(tailCount)), true)
    }

    /// A slice from `offset`, with a footer like web_fetch's.
    static func slice(_ text: String, offset: Int, limit: Int, id: String, stream: String) -> String {
        let total = text.count
        let start = min(max(0, offset), total)
        let end = min(total, start + limit)
        let from = text.index(text.startIndex, offsetBy: start)
        let to = text.index(from, offsetBy: end - start)
        let footer = end >= total
            ? "[End of output, \(total) characters total.]"
            : "[Showing characters \(start)\u{2013}\(end) of \(total). Call ssh_output with id=\(id) stream=\(stream) offset=\(end) to read more.]"
        return String(text[from..<to]) + "\n\n" + footer
    }

    /// The result of `ssh_exec` as the model reads it. The first line is fixed (`SSHResultLine` reads it back).
    static func exec(_ result: SSHExecResult, target: SSHTarget, limit: Int, outputs: SSHOutputStore, conversation: UUID?) -> String {
        var head = result.timedOut ? "Timed out after \(SSHDurations.text(result.duration)) (the command may still be running)"
            : result.exitSignal.map { "Killed by signal \($0)" } ?? "Exit code \(result.exitStatus ?? -1)"
        head += " · \(target.label) · \(String(format: "%.1f", result.duration.seconds))s"
        // One trailing newline is the end of the last line, not an empty line.
        func trimmed(_ s: String) -> String { s.hasSuffix("\n") ? String(s.dropLast()) : s }
        let stdout = trimmed(result.stdout.text), stderr = trimmed(result.stderr.text)
        var id: String?
        func outputID() -> String {
            if let id { return id }
            let new = outputs.add(conversation: conversation, stdout: stdout, stderr: stderr)
            id = new
            return new
        }
        var out = head + "\n"
        let errLimit = max(2000, limit / 4)
        if stdout.count > limit || stderr.count > errLimit { _ = outputID() }
        let o = clip(stdout, limit: limit, id: id ?? "", stream: "stdout")
        let e = clip(stderr, limit: errLimit, id: id ?? "", stream: "stderr")
        out += stdout.isEmpty ? "<stdout></stdout>" : "<stdout>\n\(o.text)\n</stdout>"
        if !stderr.isEmpty { out += "\n<stderr>\n\(e.text)\n</stderr>" }
        if result.stdout.omitted > 0 || result.stderr.omitted > 0 {
            out += "\n[The output was over 1 MB; its middle was not kept. Redirect long output to a file and read parts of it.]"
        }
        return out
    }
}

/// The first line of an `ssh_exec` result, read back for the feed.
struct SSHResultLine: Equatable {
    var exitCode: Int?
    var timedOut: Bool
    var signal: String?

    init?(_ result: String) {
        let first = result.prefix { $0 != "\n" }
        if first.hasPrefix("Exit code ") {
            exitCode = Int(first.dropFirst(10).prefix { $0 == "-" || $0.isNumber })
            timedOut = false
        } else if first.hasPrefix("Timed out after ") {
            timedOut = true
        } else if first.hasPrefix("Killed by signal ") {
            timedOut = false
            signal = String(first.dropFirst(17).prefix { $0 != " " })
        } else {
            return nil
        }
    }

    /// The streams between the tags.
    static func streams(_ result: String) -> (stdout: String, stderr: String) {
        func between(_ open: String, _ close: String) -> String {
            guard let a = result.range(of: open), let b = result.range(of: close, options: .backwards), a.upperBound <= b.lowerBound else { return "" }
            return String(result[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .newlines)
        }
        return (between("<stdout>", "</stdout>"), between("<stderr>", "</stderr>"))
    }
}

// MARK: - Running the tools

struct SSHTool: Sendable {
    var store: SSHStore = .shared
    var outputs: SSHOutputStore = .shared
    /// Test seam: runs the operation; nil uses `SSHClient`.
    var client: SSHClient?
    /// Asks the user to approve a command; nil uses the chat's card (`SSHRequests`).
    var ask: (@Sendable (SSHApproval) async -> SSHApprovalAnswer)?
    var asks: Bool = SSHApprovalPolicy.asks
    var limit: Int = AppSettings.currentFetchLength

    static let maxUpload = 10 * 1024 * 1024
    static let maxDownload = 1024 * 1024
    static let maxTimeout = 3600

    func run(name: String, arguments: String, conversation: UUID?, callID: String?) async -> ToolOutput {
        let args = SSHArguments(json: arguments)
        do {
            switch name {
            case SSHToolNames.exec: return try await exec(args, conversation: conversation, callID: callID)
            case SSHToolNames.output: return try output(args, conversation: conversation)
            case SSHToolNames.upload: return try await upload(args, conversation: conversation, callID: callID)
            case SSHToolNames.download: return try await download(args, conversation: conversation, callID: callID)
            case SSHToolNames.credentialSave: return try saveCredential(args)
            case SSHToolNames.credentialList: return listCredentials()
            case SSHToolNames.credentialGet: return try getCredential(args)
            case SSHToolNames.credentialDelete: return try deleteCredential(args)
            case SSHToolNames.serverSave: return try saveServer(args)
            case SSHToolNames.serverList: return listServers()
            case SSHToolNames.serverDelete: return try deleteServer(args)
            case SSHToolNames.keygen: return try await keygen(args)
            default: return ToolOutput(text: "Error: unknown tool \"\(name)\".", isError: true)
            }
        } catch let error as SSHError {
            return ToolOutput(text: "Error: " + (error.errorDescription ?? "\(error)"), isError: true)
        } catch {
            return ToolOutput(text: "Error: " + error.localizedDescription, isError: true)
        }
    }

    private func client(conversation: UUID?, callID: String?) -> SSHClient {
        if let client { return client }
        let store = store
        return SSHClient(checkHostKey: { try store.check($0) },
                         prompt: { request in await SSHRequests.shared.askPrompt(request, conversation: conversation, callID: callID) })
    }

    private func approve(_ approval: SSHApproval, conversation: UUID?, callID: String?) async -> Bool {
        let ask = ask ?? { approval in await SSHRequests.shared.askApproval(approval, conversation: conversation, callID: callID) }
        return await SSHApprovalPolicy.approve(approval, asks: asks, store: store, ask: ask)
    }

    private static let declined = "Error: the user declined to run this. Don't try it again unless they ask; say what you wanted to do instead."

    /// Runs `body` with a background task held on iOS; a failure after the app went to the background says so.
    private func guarded<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        let guardian = await SSHBackgroundGuard()
        await guardian.begin()
        do {
            let value = try await body()
            await guardian.end()
            return value
        } catch {
            let backgrounded = await guardian.wentToBackground
            await guardian.end()
            if backgrounded, !(error is CancellationError), (error as? SSHError) != .cancelled {
                throw SSHError.disconnected("OmniChat went to the background, and iOS stops its network connections soon after (\((error as? SSHError)?.errorDescription ?? error.localizedDescription)). Run long jobs with nohup or in tmux and check on them later")
            }
            throw error
        }
    }

    private func exec(_ args: SSHArguments, conversation: UUID?, callID: String?) async throws -> ToolOutput {
        guard let command = args.raw("command"), !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolOutput(text: "Error: missing required argument \"command\".", isError: true)
        }
        let target = try SSHTargetResolver.resolve(args, store: store)
        guard await approve(SSHApproval(target: target.key, server: target.label, action: .exec(command: command)),
                            conversation: conversation, callID: callID) else {
            return ToolOutput(text: Self.declined, isError: true)
        }
        let seconds = min(Self.maxTimeout, max(1, args.int("timeout") ?? 60))
        let stdin = args.raw("stdin").map { Data(($0.hasSuffix("\n") ? $0 : $0 + "\n").utf8) }
        let client = client(conversation: conversation, callID: callID)
        let result = try await guarded { try await client.exec(target.hops, command: command, stdin: stdin, timeout: .seconds(seconds)) }
        return ToolOutput(text: SSHOutputFormat.exec(result, target: target, limit: limit, outputs: outputs, conversation: conversation))
    }

    private func output(_ args: SSHArguments, conversation: UUID?) throws -> ToolOutput {
        guard let id = args.string("id") else { return ToolOutput(text: "Error: missing required argument \"id\".", isError: true) }
        guard let kept = outputs.get(id, conversation: conversation) else {
            return ToolOutput(text: "Error: no output \"\(id)\" is kept (outputs are kept while the app runs). Run the command again, or redirect its output to a file and read parts of it.", isError: true)
        }
        let stream = args.string("stream")?.lowercased() == "stderr" ? "stderr" : "stdout"
        return ToolOutput(text: SSHOutputFormat.slice(stream == "stderr" ? kept.stderr : kept.stdout, offset: args.int("offset") ?? 0,
                                                      limit: limit, id: id, stream: stream))
    }

    private func upload(_ args: SSHArguments, conversation: UUID?, callID: String?) async throws -> ToolOutput {
        guard let path = args.string("path") else { return ToolOutput(text: "Error: missing required argument \"path\".", isError: true) }
        let data: Data
        if let b64 = args.string("content_base64") {
            guard let d = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                return ToolOutput(text: "Error: content_base64 isn't valid base64.", isError: true)
            }
            data = d
        } else {
            data = Data((args.values["content"] ?? "").utf8)
        }
        guard data.count <= Self.maxUpload else { return ToolOutput(text: "Error: the file is over 10 MB.", isError: true) }
        let modeText = args.string("mode") ?? "644"
        guard let mode = Int(modeText, radix: 8), (0...0o7777).contains(mode) else {
            return ToolOutput(text: "Error: mode must be octal, like 644 or 755.", isError: true)
        }
        let target = try SSHTargetResolver.resolve(args, store: store)
        guard await approve(SSHApproval(target: target.key, server: target.label, action: .upload(path: path, bytes: data.count)),
                            conversation: conversation, callID: callID) else {
            return ToolOutput(text: Self.declined, isError: true)
        }
        let client = client(conversation: conversation, callID: callID)
        let written = try await guarded { try await client.upload(target.hops, data: data, to: path, mode: mode, timeout: .seconds(300)) }
        return ToolOutput(text: "Wrote \(written) bytes to \(path) on \(target.label) (mode \(modeText)).")
    }

    private func download(_ args: SSHArguments, conversation: UUID?, callID: String?) async throws -> ToolOutput {
        guard let path = args.string("path") else { return ToolOutput(text: "Error: missing required argument \"path\".", isError: true) }
        let target = try SSHTargetResolver.resolve(args, store: store)
        let client = client(conversation: conversation, callID: callID)
        let (data, truncated) = try await guarded { try await client.download(target.hops, from: path, limit: Self.maxDownload, timeout: .seconds(300)) }
        let more = truncated ? " The file is longer than 1 MB; only its first 1 MB was read." : ""
        if !data.contains(0), let text = String(data: data, encoding: .utf8) {
            var out = "\(path) on \(target.label): \(data.count) bytes of text.\(more)\n\n"
            if text.count > limit {
                let id = outputs.add(conversation: conversation, stdout: text, stderr: "")
                out += SSHOutputFormat.slice(text, offset: 0, limit: limit, id: id, stream: "stdout")
            } else {
                out += text
            }
            return ToolOutput(text: out)
        }
        guard data.count <= 48 * 1024 else {
            return ToolOutput(text: "\(path) on \(target.label) is binary (\(data.count) bytes\(truncated ? " or more" : "")), too large to return. Inspect it with ssh_exec (file, xxd | head, …).")
        }
        return ToolOutput(text: "\(path) on \(target.label): \(data.count) bytes of binary data, base64:\n\(data.base64EncodedString())")
    }

    // MARK: Credentials and servers

    private func saveCredential(_ args: SSHArguments) throws -> ToolOutput {
        guard let name = args.string("name") else { return ToolOutput(text: "Error: missing required argument \"name\".", isError: true) }
        var credential = SSHCredential(name: name, kind: .password, username: args.string("username"), note: args.string("note"))
        credential.password = args.raw("password")
        credential.privateKey = args.raw("private_key")
        credential.passphrase = args.raw("passphrase")
        credential.certificate = args.string("certificate")
        let answers = args.lines("answers")
        credential.answers = answers.isEmpty ? nil : answers
        if credential.privateKey != nil { credential.kind = .privateKey }
        else if !answers.isEmpty { credential.kind = .keyboardInteractive }
        else if credential.password == nil {
            return ToolOutput(text: "Error: give a password, a private_key or answers to save.", isError: true)
        }
        let replaced = store.credential(named: name) != nil
        try store.save(credential)
        let saved = store.credential(named: credential.name) ?? credential
        var text = "\(replaced ? "Replaced" : "Saved") credential \(saved.name) (\(saved.summary))."
        if let info = saved.privateKey.flatMap(SSHKeyFormat.inspect), info.encrypted, (saved.passphrase ?? "").isEmpty {
            text += " The key is encrypted and no passphrase was saved: pass passphrase when you use it, or save it again with the passphrase."
        }
        if let pub = saved.publicKey { text += "\nPublic key: \(pub)" }
        return ToolOutput(text: text)
    }

    private func listCredentials() -> ToolOutput {
        let all = store.credentials
        guard !all.isEmpty else { return ToolOutput(text: "No credentials are saved.") }
        return ToolOutput(text: all.map { c in
            var line = "- \(c.name): \(c.summary)"
            if let user = c.username { line += ", user \(user)" }
            if let note = c.note { line += " — \(note)" }
            if let pub = c.publicKey { line += "\n  public key: \(pub)" }
            return line
        }.joined(separator: "\n"))
    }

    private func getCredential(_ args: SSHArguments) throws -> ToolOutput {
        guard let name = args.string("name") else { return ToolOutput(text: "Error: missing required argument \"name\".", isError: true) }
        guard let c = store.credential(named: name) else { throw SSHStoreError.missing("No saved credential is named \"\(name)\".") }
        var fields: [(String, String)] = [("name", c.name), ("kind", c.kind.rawValue)]
        if let v = c.username { fields.append(("username", v)) }
        if let v = c.password { fields.append(("password", v)) }
        if let v = c.passphrase { fields.append(("passphrase", v)) }
        if let v = c.answers { fields.append(("answers", v.joined(separator: "\n"))) }
        if let v = c.certificate { fields.append(("certificate", v)) }
        if let v = c.publicKey { fields.append(("public_key", v)) }
        if let v = c.note { fields.append(("note", v)) }
        if let v = c.privateKey { fields.append(("private_key", v)) }
        return ToolOutput(text: fields.map { key, value in value.contains("\n") ? "\(key):\n\(value)" : "\(key): \(value)" }.joined(separator: "\n"))
    }

    private func deleteCredential(_ args: SSHArguments) throws -> ToolOutput {
        guard let name = args.string("name") else { return ToolOutput(text: "Error: missing required argument \"name\".", isError: true) }
        guard store.credential(named: name) != nil else { throw SSHStoreError.missing("No saved credential is named \"\(name)\".") }
        try store.deleteCredential(name)
        let users = store.servers.filter { $0.credential == name }.map(\.name)
        return ToolOutput(text: "Deleted credential \(name)." + (users.isEmpty ? "" : " These servers still name it: \(users.joined(separator: ", "))."))
    }

    private func saveServer(_ args: SSHArguments) throws -> ToolOutput {
        if let config = args.raw("ssh_config") {
            let entries = SSHConfigImport.parse(config)
            guard !entries.isEmpty else { return ToolOutput(text: "Error: no Host blocks with a name were found in ssh_config.", isError: true) }
            var lines: [String] = []
            for var entry in entries {
                if entry.server.user.isEmpty, let user = args.string("user") { entry.server.user = user }
                if let credential = args.string("credential"), entry.identity == nil { entry.server.credential = credential }
                do {
                    try store.save(entry.server)
                    var line = "- \(entry.server.name): \(entry.server.address)"
                    if !entry.server.jump.isEmpty { line += " via \(entry.server.jump.joined(separator: " → "))" }
                    if let id = entry.server.credential, store.credential(named: id) == nil {
                        line += " — no credential named \(id) is saved yet; save the key with ssh_credential_save name=\(id)"
                    }
                    lines.append(line)
                } catch {
                    lines.append("- \(entry.server.name): not saved: \(error.localizedDescription)")
                }
            }
            return ToolOutput(text: "Imported from ssh_config:\n" + lines.joined(separator: "\n"))
        }
        guard let name = args.string("name"), let host = args.string("host") else {
            return ToolOutput(text: "Error: give name, host and user, or ssh_config.", isError: true)
        }
        let existing = store.server(named: name)
        guard let user = args.string("user") ?? existing?.user else {
            return ToolOutput(text: "Error: missing required argument \"user\".", isError: true)
        }
        let server = SSHServer(name: name, host: host, port: args.int("port") ?? 22, user: user,
                               credential: args.string("credential"), jump: args.list("jump"), note: args.string("note"))
        if let credential = server.credential, store.credential(named: credential) == nil {
            return ToolOutput(text: "Error: no saved credential is named \"\(credential)\". Save it first with ssh_credential_save.", isError: true)
        }
        try store.save(server)
        var text = "\(existing == nil ? "Saved" : "Replaced") server \(server.name): \(server.address)"
        if let c = server.credential { text += ", credential \(c)" }
        if !server.jump.isEmpty { text += ", via \(server.jump.joined(separator: " → "))" }
        return ToolOutput(text: text + ".")
    }

    private func listServers() -> ToolOutput {
        let all = store.servers
        guard !all.isEmpty else { return ToolOutput(text: "No servers are saved.") }
        return ToolOutput(text: all.map { s in
            var line = "- \(s.name): \(s.address)"
            line += s.credential.map { ", credential \($0)" } ?? ", no credential"
            if !s.jump.isEmpty { line += ", via \(s.jump.joined(separator: " → "))" }
            if store.isAlwaysAllowed(s.name) { line += ", commands run without asking" }
            if let note = s.note { line += " — \(note)" }
            return line
        }.joined(separator: "\n"))
    }

    private func deleteServer(_ args: SSHArguments) throws -> ToolOutput {
        guard let name = args.string("name") else { return ToolOutput(text: "Error: missing required argument \"name\".", isError: true) }
        guard store.server(named: name) != nil else { throw SSHStoreError.missing("No saved server is named \"\(name)\".") }
        try store.deleteServer(name)
        return ToolOutput(text: "Deleted server \(name).")
    }

    private func keygen(_ args: SSHArguments) async throws -> ToolOutput {
        guard let raw = args.string("name") else { return ToolOutput(text: "Error: missing required argument \"name\".", isError: true) }
        let name = try SSHStore.validate(raw)
        guard store.credential(named: name) == nil else {
            return ToolOutput(text: "Error: a credential named \(name) exists already. Pick another name, or delete it first.", isError: true)
        }
        let type = SSHKeyGenerator.KeyType(rawValue: args.string("type")?.lowercased() ?? "ed25519") ?? .ed25519
        let comment = args.string("comment") ?? name
        let key = try await Task.detached(priority: .userInitiated) { try SSHKeyGenerator.generate(type, comment: comment) }.value
        try store.save(SSHCredential(name: name, kind: .privateKey, privateKey: key.privateKey, publicKey: key.publicKey))
        return ToolOutput(text: "Generated a \(type == .rsa ? "4096-bit RSA" : "ED25519") key and saved it as credential \(name). Add this line to ~/.ssh/authorized_keys on the server:\n\(key.publicKey)")
    }
}
