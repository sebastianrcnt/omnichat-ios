import CLibSSH2
import CryptoKit
import Foundation

// The SSH engine: libssh2 (with OpenSSL's libcrypto, `Vendor/CLibSSH2.xcframework`) behind an async API. Each
// operation connects, runs and disconnects on a thread of its own: the sessions are non-blocking and every wait is a
// short poll that checks the deadline and the task's cancellation, so a stuck server never holds a thread for long.
// A jump host's session carries the next one: the next session's bytes go through a direct-tcpip channel by way of
// libssh2's send/recv callbacks, all on the same thread and socket.

/// How a hop proves who it is, tried in order.
enum SSHAuth: Sendable, Equatable {
    case password(String)
    /// An OpenSSH or PEM private key. `certificate`: an OpenSSH certificate line to present with it.
    case privateKey(String, passphrase: String?, certificate: String? = nil)
    /// Answers to keyboard-interactive prompts, in the order they are asked.
    case keyboardInteractive([String])

    var method: String {
        switch self {
        case .password: "password"
        case .privateKey: "publickey"
        case .keyboardInteractive: "keyboard-interactive"
        }
    }
}

/// One machine on the way: the target is the last hop, the jump hosts come before it.
struct SSHHop: Sendable, Equatable {
    var host: String
    var port: Int = 22
    var user: String
    var auths: [SSHAuth] = []

    /// `host:port`, the key of its known host entry (`[host]:port` would read as a list in the UI).
    var hostPort: String { "\(host.lowercased()):\(port)" }
    var label: String { port == 22 ? "\(user)@\(host)" : "\(user)@\(host):\(port)" }
}

/// The server's host key, as the known hosts check sees it.
struct SSHHostKey: Sendable, Equatable {
    var hostPort: String
    var type: String
    /// `SHA256:` and the unpadded base64 of the key's SHA-256, as OpenSSH prints it.
    var fingerprint: String
}

/// Keyboard-interactive prompts nobody gave an answer for, for the user to answer (a 2FA code, a password).
struct SSHPromptRequest: Sendable, Equatable {
    struct Prompt: Sendable, Equatable {
        var text: String
        /// The server says the answer may be shown as it is typed.
        var echo: Bool
    }
    var hop: String
    var name: String
    var instruction: String
    var prompts: [Prompt]
}

enum SSHError: Error, LocalizedError, Equatable {
    case resolve(host: String, detail: String)
    case connect(host: String, port: Int, detail: String)
    case timedOut(String)
    case cancelled
    case handshake(host: String, detail: String)
    case hostKeyChanged(hostPort: String, type: String, expected: String, actual: String)
    case authentication(hop: String, tried: [String], allowed: String, detail: String)
    case key(String)
    case channel(String)
    case sftp(path: String, detail: String)
    case disconnected(String)

    var errorDescription: String? {
        switch self {
        case .resolve(let host, let detail): "Couldn't resolve \(host): \(detail)."
        case .connect(let host, let port, let detail): "Couldn't connect to \(host) port \(port): \(detail)."
        case .timedOut(let what): "Timed out \(what)."
        case .cancelled: "Cancelled."
        case .handshake(let host, let detail): "The SSH handshake with \(host) failed: \(detail)."
        case .hostKeyChanged(let hostPort, let type, let expected, let actual):
            "The host key of \(hostPort) changed: it is now \(type) \(actual), but \(expected) was saved when OmniChat first connected. The server may have been reinstalled, or someone may be intercepting the connection. Nothing was sent. If the change is expected, the user can reset this host in Settings > SSH > Known hosts."
        case .authentication(let hop, let tried, let allowed, let detail):
            "Authentication failed for \(hop)"
                + (tried.isEmpty ? ": no credentials to try" : " (tried \(tried.joined(separator: ", ")))")
                + (detail.isEmpty ? "" : ": \(detail)")
                + (allowed.isEmpty ? "." : ". The server accepts: \(allowed).")
        case .key(let detail): detail
        case .channel(let detail): detail
        case .sftp(let path, let detail): "\(path): \(detail)."
        case .disconnected(let detail): "The connection dropped: \(detail)."
        }
    }
}

/// What a command did.
struct SSHExecResult: Sendable, Equatable {
    var stdout: SSHOutput
    var stderr: SSHOutput
    var exitStatus: Int?
    var exitSignal: String?
    /// The command was still running at the deadline; the channel was closed (the remote process may live on).
    var timedOut = false
    var duration: Duration = .zero
}

/// A stream's bytes: all of them up to `cap`, else the start and the end with the middle left out.
struct SSHOutput: Sendable, Equatable {
    static let headCap = 256 * 1024
    static let tailCap = 768 * 1024

    private(set) var head = Data()
    private(set) var tail = Data()
    private(set) var total = 0

    init() {}
    init(_ data: Data) { append(data) }

    mutating func append(_ data: Data) {
        total += data.count
        var rest = data[...]
        if head.count < Self.headCap {
            let take = min(Self.headCap - head.count, rest.count)
            head.append(rest.prefix(take))
            rest = rest.dropFirst(take)
        }
        guard !rest.isEmpty else { return }
        tail.append(rest)
        if tail.count > Self.tailCap { tail = Data(tail.suffix(Self.tailCap)) }
    }

    /// Bytes left out in the middle.
    var omitted: Int { total - head.count - tail.count }

    var text: String {
        let start = String(decoding: head, as: UTF8.self)
        guard !tail.isEmpty else { return start }
        let end = String(decoding: tail, as: UTF8.self)
        return omitted > 0 ? start + "\n[… \(omitted) bytes left out …]\n" + end : start + end
    }
}

/// Answers keyboard-interactive prompts the credentials can't: nil gives up.
typealias SSHPromptHandler = @Sendable (SSHPromptRequest) async -> [String]?
/// Accepts or rejects a host key (trust on first use lives in `SSHStore`).
typealias SSHHostKeyCheck = @Sendable (SSHHostKey) throws -> Void

/// Connects and runs one operation at a time per call; calls run in parallel.
struct SSHClient: Sendable {
    var checkHostKey: SSHHostKeyCheck
    var prompt: SSHPromptHandler?
    var connectTimeout: Duration = .seconds(20)

    /// Runs `command` on the last hop. Its output streams are read to the end, or until `timeout`, when what came so
    /// far is returned with `timedOut`.
    func exec(_ hops: [SSHHop], command: String, stdin: Data? = nil, timeout: Duration) async throws -> SSHExecResult {
        try await run(hops) { chain in try chain.exec(command, stdin: stdin, timeout: timeout) }
    }

    /// Writes `data` to `path` with SFTP, replacing the file. Returns the bytes written.
    func upload(_ hops: [SSHHop], data: Data, to path: String, mode: Int = 0o644, timeout: Duration) async throws -> Int {
        try await run(hops) { chain in try chain.upload(data, to: path, mode: mode, timeout: timeout) }
    }

    /// Reads `path` with SFTP, up to `limit` bytes (`truncated` when the file is longer).
    func download(_ hops: [SSHHop], from path: String, limit: Int, timeout: Duration) async throws -> (data: Data, truncated: Bool) {
        try await run(hops) { chain in try chain.download(path, limit: limit, timeout: timeout) }
    }

    /// Connects and authenticates, then disconnects: the host key and the authentication method that worked.
    func test(_ hops: [SSHHop]) async throws -> (hostKey: SSHHostKey, method: String) {
        try await run(hops) { chain in (chain.targetHostKey!, chain.targetMethod) }
    }

    private func run<T: Sendable>(_ hops: [SSHHop], _ body: @escaping @Sendable (SSHChain) throws -> T) async throws -> T {
        guard !hops.isEmpty else { throw SSHError.channel("No server to connect to.") }
        let control = SSHControl(deadline: .now + connectTimeout)
        let check = checkHostKey, prompt = prompt
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                SSHThreads.queue.async {
                    cont.resume(with: Result {
                        try SSHLibrary.ready()
                        let chain = SSHChain(control: control, checkHostKey: check, prompt: prompt)
                        defer { chain.close() }
                        try chain.connect(hops)
                        return try body(chain)
                    })
                }
            }
        } onCancel: { control.cancel() }
    }
}

private enum SSHThreads {
    /// Operations block their thread while they wait on the socket (in short polls), so they stay off Swift's pool.
    static let queue = DispatchQueue(label: "cc.coolservices.strata.ssh", qos: .userInitiated, attributes: .concurrent)
}

private enum SSHLibrary {
    private static let status: Int32 = libssh2_init(0)
    static func ready() throws {
        guard status == 0 else { throw SSHError.channel("The SSH library failed to start (\(status)).") }
    }
}

/// Cancellation and the deadline of one operation, shared with the thread that runs it.
final class SSHControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var deadline: ContinuousClock.Instant
    /// What the deadline is for, for the error ("while connecting").
    private var phase = "while connecting"

    init(deadline: ContinuousClock.Instant) { self.deadline = deadline }

    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }

    func setDeadline(_ instant: ContinuousClock.Instant, phase: String) { lock.withLock { deadline = instant; self.phase = phase } }
    /// Time spent waiting for the user doesn't count.
    func extend(by duration: Duration) { lock.withLock { deadline = deadline + duration } }

    /// Throws when cancelled or past the deadline; otherwise the time left.
    func check() throws -> Duration {
        let (c, d, p) = lock.withLock { (cancelled, deadline, phase) }
        if c { throw SSHError.cancelled }
        let left = d - .now
        if left <= .zero { throw SSHError.timedOut(p) }
        return left
    }
}

/// What the C callbacks of one session reach through its abstract pointer.
private final class SSHSessionContext {
    /// The channel on the session before this one that carries this session's bytes (a jump), or nil for a socket.
    var tunnel: OpaquePointer?
    /// Answers keyboard-interactive prompts during `libssh2_userauth_keyboard_interactive_ex`.
    var respond: ((_ name: String, _ instruction: String, _ prompts: [SSHPromptRequest.Prompt]) -> [String])?
}

/// The sessions of one connection, the first hop's at the bottom (it owns the socket).
private final class SSHChain {
    let control: SSHControl
    let checkHostKey: SSHHostKeyCheck
    let prompt: SSHPromptHandler?
    private var fd: Int32 = -1
    private var sessions: [OpaquePointer] = []
    private var contexts: [Unmanaged<SSHSessionContext>] = []
    /// `tunnels[i]` carries session `i + 1`, on session `i`.
    private var tunnels: [OpaquePointer] = []
    private(set) var targetHostKey: SSHHostKey?
    private(set) var targetMethod = ""

    init(control: SSHControl, checkHostKey: @escaping SSHHostKeyCheck, prompt: SSHPromptHandler?) {
        self.control = control
        self.checkHostKey = checkHostKey
        self.prompt = prompt
    }

    private var top: OpaquePointer { sessions[sessions.count - 1] }

    // MARK: Connecting

    func connect(_ hops: [SSHHop]) throws {
        for (i, hop) in hops.enumerated() {
            let context = Unmanaged.passRetained(SSHSessionContext())
            contexts.append(context)
            guard let session = libssh2_session_init_ex(nil, nil, nil, context.toOpaque()) else {
                throw SSHError.channel("Couldn't start an SSH session.")
            }
            sessions.append(session)
            libssh2_session_set_blocking(session, 0)
            if i == 0 {
                fd = try Self.openSocket(host: hop.host, port: hop.port, control: control)
            } else {
                let tunnel = try pointer(on: sessions[i - 1], "opening a tunnel to \(hop.host)") {
                    libssh2_channel_direct_tcpip_ex(sessions[i - 1], hop.host, Int32(clamping: hop.port), "127.0.0.1", 22)
                }
                tunnels.append(tunnel)
                context.takeUnretainedValue().tunnel = tunnel
                _ = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, sshGeneric(unsafeBitCast(sshTunnelSend, to: UnsafeRawPointer.self)))
                _ = libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, sshGeneric(unsafeBitCast(sshTunnelRecv, to: UnsafeRawPointer.self)))
            }
            let rc = try call(session) { libssh2_session_handshake(session, fd) }
            if rc != 0 { throw SSHError.handshake(host: hop.host, detail: lastError(session, rc)) }
            let key = try hostKey(session, hop: hop)
            try checkHostKey(key)
            let method = try authenticate(session, hop: hop)
            if i == hops.count - 1 {
                targetHostKey = key
                targetMethod = method
            }
        }
    }

    private func hostKey(_ session: OpaquePointer, hop: SSHHop) throws -> SSHHostKey {
        var length = 0
        var type: Int32 = 0
        guard let raw = libssh2_session_hostkey(session, &length, &type), length > 0 else {
            throw SSHError.handshake(host: hop.host, detail: "the server sent no host key")
        }
        let blob = Data(bytes: raw, count: length)
        return SSHHostKey(hostPort: hop.hostPort, type: SSHKeyFormat.keyType(ofBlob: blob) ?? "unknown",
                          fingerprint: SSHKeyFormat.fingerprint(ofBlob: blob))
    }

    /// Tries the hop's credentials in order; keyboard-interactive the server still wants after them (a second factor,
    /// or no credentials at all) goes to the prompt handler. Returns the method that got in.
    private func authenticate(_ session: OpaquePointer, hop: SSHHop) throws -> String {
        let user = hop.user
        var allowed = ""
        let list = try optionalPointer(on: session) { libssh2_userauth_list(session, user, UInt32(user.utf8.count)) }
        if let list { allowed = String(cString: list) }
        if libssh2_userauth_authenticated(session) == 1 { return "none" }
        let methods = Set(allowed.split(separator: ",").map(String.init))
        var tried: [String] = []
        var detail = ""
        var promptedAlready = false
        let passwords = hop.auths.compactMap { if case .password(let p) = $0 { p } else { nil } }

        for auth in hop.auths {
            switch auth {
            case .password(let password):
                if methods.contains("password") {
                    tried.append("password")
                    let rc = try call(session) {
                        libssh2_userauth_password_ex(session, user, UInt32(user.utf8.count), password, UInt32(password.utf8.count), nil)
                    }
                    if rc == 0 || libssh2_userauth_authenticated(session) == 1 { return "password" }
                    detail = lastError(session, rc)
                } else if methods.contains("keyboard-interactive") {
                    // Many servers ask for the password as a keyboard-interactive prompt.
                    tried.append("password (keyboard-interactive)")
                    promptedAlready = true
                    if try keyboardInteractive(session, hop: hop, answers: [password], allowPrompt: true) { return "keyboard-interactive" }
                    detail = lastError(session, -1)
                }
            case .privateKey(let key, let passphrase, let certificate):
                guard methods.contains("publickey") else { continue }
                tried.append("publickey")
                let publicKey = certificate?.trimmingCharacters(in: .whitespacesAndNewlines)
                let rc = try call(session) {
                    libssh2_userauth_publickey_frommemory(session, user, user.utf8.count,
                                                          publicKey, publicKey?.utf8.count ?? 0,
                                                          key, key.utf8.count, passphrase ?? "")
                }
                if rc == 0 || libssh2_userauth_authenticated(session) == 1 { return "publickey" }
                // The server's no is one of these two; anything else failed here, reading or using the key.
                if rc != LIBSSH2_ERROR_AUTHENTICATION_FAILED && rc != LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED {
                    let info = SSHKeyFormat.inspect(key)
                    if info?.encrypted == true {
                        detail = (passphrase ?? "").isEmpty ? "the private key is encrypted and no passphrase was given"
                            : "the private key could not be decrypted (wrong passphrase?)"
                    } else {
                        detail = "the private key could not be read (\(lastError(session, rc)))"
                    }
                } else {
                    detail = "the server refused the key"
                }
            case .keyboardInteractive(let answers):
                guard methods.contains("keyboard-interactive") else { continue }
                tried.append("keyboard-interactive")
                promptedAlready = true
                if try keyboardInteractive(session, hop: hop, answers: answers + passwords, allowPrompt: true) { return "keyboard-interactive" }
                detail = lastError(session, -1)
            }
        }
        // A second factor after a key, or a server that only asks questions: the user answers. After a partial success
        // the server lists only what is left, so it is asked again.
        if !promptedAlready, prompt != nil, !tried.isEmpty,
           let again = try optionalPointer(on: session, { libssh2_userauth_list(session, user, UInt32(user.utf8.count)) }) {
            allowed = String(cString: again)
        }
        if !promptedAlready, prompt != nil, allowed.split(separator: ",").contains("keyboard-interactive") {
            tried.append("keyboard-interactive")
            if try keyboardInteractive(session, hop: hop, answers: passwords, allowPrompt: true) { return "keyboard-interactive" }
            detail = lastError(session, -1)
        }
        throw SSHError.authentication(hop: hop.label, tried: tried, allowed: allowed, detail: detail)
    }

    private func keyboardInteractive(_ session: OpaquePointer, hop: SSHHop, answers: [String], allowPrompt: Bool) throws -> Bool {
        let context = contexts[sessions.count - 1].takeUnretainedValue()
        var queue = answers
        let handler = allowPrompt ? prompt : nil
        let control = control
        context.respond = { name, instruction, prompts in
            guard !prompts.isEmpty else { return [] }
            if queue.count >= prompts.count {
                defer { queue.removeFirst(prompts.count) }
                return Array(queue.prefix(prompts.count))
            }
            // Answers of our own first, the rest from the user.
            let known = queue
            queue = []
            guard let handler else { return known }
            let rest = Array(prompts.dropFirst(known.count))
            let request = SSHPromptRequest(hop: hop.label, name: name, instruction: instruction, prompts: rest)
            let started = ContinuousClock.now
            let answered = Self.wait(for: handler, request, control: control)
            control.extend(by: .now - started)
            return known + (answered ?? [])
        }
        defer { context.respond = nil }
        let rc = try call(session) {
            libssh2_userauth_keyboard_interactive_ex(session, hop.user, UInt32(hop.user.utf8.count), sshKeyboardInteractive)
        }
        return rc == 0 || libssh2_userauth_authenticated(session) == 1
    }

    /// Blocks this (non-pool) thread until the user answers, the operation is cancelled, or 10 minutes pass.
    private static func wait(for handler: @escaping SSHPromptHandler, _ request: SSHPromptRequest, control: SSHControl) -> [String]? {
        final class Box: @unchecked Sendable { var value: [String]?; let done = DispatchSemaphore(value: 0) }
        let box = Box()
        let task = Task { box.value = await handler(request); box.done.signal() }
        let limit = ContinuousClock.now + .seconds(600)
        while box.done.wait(timeout: .now() + 0.2) == .timedOut {
            if control.isCancelled || .now > limit { task.cancel(); return nil }
        }
        return box.value
    }

    private static func openSocket(host: String, port: Int, control: SSHControl) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var list: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &list)
        guard rc == 0, let list else {
            throw SSHError.resolve(host: host, detail: String(cString: gai_strerror(rc)))
        }
        defer { freeaddrinfo(list) }
        var lastError = "no address"
        var entry: UnsafeMutablePointer<addrinfo>? = list
        while let info = entry {
            entry = info.pointee.ai_next
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard fd >= 0 else { lastError = String(cString: strerror(errno)); continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            if Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 { return fd }
            guard errno == EINPROGRESS else { lastError = String(cString: strerror(errno)); Darwin.close(fd); continue }
            do {
                while true {
                    let left = try control.check()
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let n = poll(&pfd, 1, Int32(min(200, max(1, left.sshMilliseconds))))
                    if n > 0 { break }
                    if n < 0 && errno != EINTR { break }
                }
            } catch {
                Darwin.close(fd)
                throw error
            }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            if err == 0 { return fd }
            lastError = String(cString: strerror(err))
            Darwin.close(fd)
        }
        throw SSHError.connect(host: host, port: port, detail: lastError)
    }

    // MARK: Waiting

    /// Waits until the socket can move the bytes the bottom session waits for (or a short while, for a jump session
    /// whose bytes may already sit in a buffer below it).
    private func waitSocket() throws {
        let left = try control.check()
        let bottom = sessions[0]
        let directions = libssh2_session_block_directions(bottom)
        var events: Int16 = 0
        if directions & LIBSSH2_SESSION_BLOCK_INBOUND != 0 { events |= Int16(POLLIN) }
        if directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { events |= Int16(POLLOUT) }
        if events == 0 { events = Int16(POLLIN) }
        var pfd = pollfd(fd: fd, events: events, revents: 0)
        let slice = sessions.count > 1 ? 10 : 200
        _ = poll(&pfd, 1, Int32(min(slice, max(1, left.sshMilliseconds))))
    }

    /// Calls until the result isn't EAGAIN.
    @discardableResult
    private func call(_ session: OpaquePointer, _ body: () -> Int32) throws -> Int32 {
        while true {
            let rc = body()
            if rc != LIBSSH2_ERROR_EAGAIN { return rc }
            try waitSocket()
        }
    }

    private func callSize(_ body: () -> Int) throws -> Int {
        while true {
            let n = body()
            if n != Int(LIBSSH2_ERROR_EAGAIN) { return n }
            try waitSocket()
        }
    }

    /// Calls a libssh2 function that returns NULL for both EAGAIN and failure.
    private func pointer<T>(on session: OpaquePointer, _ what: String, _ body: () -> T?) throws -> T {
        while true {
            if let p = body() { return p }
            let errno = libssh2_session_last_errno(session)
            guard errno == LIBSSH2_ERROR_EAGAIN else { throw SSHError.channel("Failed \(what): \(lastError(session, errno)).") }
            try waitSocket()
        }
    }

    /// Like `pointer`, but NULL without an error is an answer too (`libssh2_userauth_list` when "none" got in).
    private func optionalPointer<T>(on session: OpaquePointer, _ body: () -> T?) throws -> T? {
        while true {
            if let p = body() { return p }
            let errno = libssh2_session_last_errno(session)
            guard errno == LIBSSH2_ERROR_EAGAIN else { return nil }
            try waitSocket()
        }
    }

    private func lastError(_ session: OpaquePointer, _ rc: Int32) -> String {
        var message: UnsafeMutablePointer<CChar>?
        var length: Int32 = 0
        _ = libssh2_session_last_error(session, &message, &length, 0)
        if let message, length > 0 { return String(cString: message) }
        return "error \(rc)"
    }

    // MARK: Exec

    func exec(_ command: String, stdin: Data?, timeout: Duration) throws -> SSHExecResult {
        let session = top
        let started = ContinuousClock.now
        control.setDeadline(.now + timeout, phase: "after \(SSHDurations.text(timeout))")
        let channel = try pointer(on: session, "opening a channel") {
            libssh2_channel_open_ex(session, "session", 7, 2 * 1024 * 1024, 32768, nil, 0)
        }
        defer { libssh2_channel_free(channel) }
        let rc = try call(session) { libssh2_channel_process_startup(channel, "exec", 4, command, UInt32(command.utf8.count)) }
        if rc != 0 { throw SSHError.channel("The server refused to run the command: \(lastError(session, rc)).") }

        var result = SSHExecResult(stdout: SSHOutput(), stderr: SSHOutput())
        let input = stdin ?? Data()
        var written = 0
        var eofSent = false
        var buffer = [CChar](repeating: 0, count: 32 * 1024)
        do {
            while true {
                // Output that never pauses must not keep the loop from the deadline and Stop (`waitSocket` checks them
                // only when nothing moved).
                _ = try control.check()
                var moved = false
                if written < input.count {
                    let n = input.withUnsafeBytes { raw in
                        libssh2_channel_write_ex(channel, 0, raw.baseAddress!.advanced(by: written).assumingMemoryBound(to: CChar.self),
                                                 input.count - written)
                    }
                    if n > 0 { written += n; moved = true }
                    else if n < 0 && n != Int(LIBSSH2_ERROR_EAGAIN) { throw SSHError.disconnected(lastError(session, Int32(n))) }
                } else if !eofSent {
                    let r = libssh2_channel_send_eof(channel)
                    if r == 0 { eofSent = true; moved = true }
                    else if r != LIBSSH2_ERROR_EAGAIN { eofSent = true } // the command closed its input already
                }
                for stream: Int32 in [0, 1] {
                    while true {
                        let n = libssh2_channel_read_ex(channel, stream, &buffer, buffer.count)
                        if n > 0 {
                            let data = buffer.withUnsafeBytes { Data($0.prefix(n)) }
                            if stream == 0 { result.stdout.append(data) } else { result.stderr.append(data) }
                            moved = true
                            _ = try control.check()
                        } else if n == 0 || n == Int(LIBSSH2_ERROR_EAGAIN) {
                            break
                        } else {
                            throw SSHError.disconnected(lastError(session, Int32(n)))
                        }
                    }
                }
                if libssh2_channel_eof(channel) == 1 { break }
                if !moved { try waitSocket() }
            }
            control.setDeadline(.now + .seconds(10), phase: "closing the channel")
            try call(session) { libssh2_channel_close(channel) }
            try call(session) { libssh2_channel_wait_closed(channel) }
            let status = libssh2_channel_get_exit_status(channel)
            var signal: UnsafeMutablePointer<CChar>?
            var signalLength = 0
            if libssh2_channel_get_exit_signal(channel, &signal, &signalLength, nil, nil, nil, nil) == 0, let signal {
                if signalLength > 0 { result.exitSignal = String(cString: signal) }
                libssh2_free(session, signal)
            }
            result.exitStatus = result.exitSignal == nil ? Int(status) : nil
        } catch SSHError.timedOut {
            result.timedOut = true
            control.setDeadline(.now + .seconds(2), phase: "closing the channel")
            _ = try? call(session) { libssh2_channel_close(channel) }
        }
        result.duration = .now - started
        return result
    }

    // MARK: SFTP

    private func withSFTP<T>(_ timeout: Duration, _ body: (OpaquePointer, OpaquePointer) throws -> T) throws -> T {
        let session = top
        control.setDeadline(.now + timeout, phase: "after \(SSHDurations.text(timeout))")
        let sftp = try pointer(on: session, "starting SFTP") { libssh2_sftp_init(session) }
        defer { _ = try? call(session) { libssh2_sftp_shutdown(sftp) } }
        return try body(session, sftp)
    }

    private func sftpFailure(_ sftp: OpaquePointer, _ session: OpaquePointer, path: String) -> SSHError {
        let code = libssh2_sftp_last_error(sftp)
        let detail = switch code {
        case 2: "no such file or directory"
        case 3: "permission denied"
        case 4: "failed (is it a directory, or is the disk full?)"
        default: lastError(session, libssh2_session_last_errno(session))
        }
        return .sftp(path: path, detail: detail)
    }

    func upload(_ data: Data, to path: String, mode: Int, timeout: Duration) throws -> Int {
        try withSFTP(timeout) { session, sftp in
            let flags = UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC)
            let handle: OpaquePointer
            do {
                handle = try pointer(on: session, "opening \(path)") {
                    libssh2_sftp_open_ex(sftp, path, UInt32(path.utf8.count), flags, mode, LIBSSH2_SFTP_OPENFILE)
                }
            } catch { throw sftpFailure(sftp, session, path: path) }
            defer { _ = try? call(session) { libssh2_sftp_close_handle(handle) } }
            var offset = 0
            while offset < data.count {
                let n = try data.withUnsafeBytes { raw in
                    try callSize {
                        libssh2_sftp_write(handle, raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: CChar.self),
                                           min(data.count - offset, 32 * 1024))
                    }
                }
                guard n > 0 else { throw sftpFailure(sftp, session, path: path) }
                offset += n
            }
            return offset
        }
    }

    func download(_ path: String, limit: Int, timeout: Duration) throws -> (data: Data, truncated: Bool) {
        try withSFTP(timeout) { session, sftp in
            let handle: OpaquePointer
            do {
                handle = try pointer(on: session, "opening \(path)") {
                    libssh2_sftp_open_ex(sftp, path, UInt32(path.utf8.count), UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE)
                }
            } catch { throw sftpFailure(sftp, session, path: path) }
            defer { _ = try? call(session) { libssh2_sftp_close_handle(handle) } }
            var data = Data()
            var buffer = [CChar](repeating: 0, count: 32 * 1024)
            while data.count <= limit {
                let n = try callSize { libssh2_sftp_read(handle, &buffer, buffer.count) }
                if n == 0 { return (data, false) }
                guard n > 0 else { throw sftpFailure(sftp, session, path: path) }
                data.append(buffer.withUnsafeBytes { Data($0.prefix(n)) })
            }
            return (data.prefix(limit), true)
        }
    }

    // MARK: Closing

    func close() {
        control.setDeadline(.now + .seconds(2), phase: "disconnecting")
        for i in sessions.indices.reversed() {
            let session = sessions[i]
            _ = try? call(session) { libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "bye", "") }
            libssh2_session_free(session)
            contexts[i].release()
            if i > 0, tunnels.indices.contains(i - 1) {
                let tunnel = tunnels[i - 1]
                _ = try? call(sessions[i - 1]) { libssh2_channel_close(tunnel) }
                libssh2_channel_free(tunnel)
            }
        }
        sessions = []
        contexts = []
        tunnels = []
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }
}

// MARK: - C callbacks

/// `libssh2_session_callback_set2` takes every callback as `void (*)(void)`.
private func sshGeneric(_ pointer: UnsafeRawPointer) -> (@convention(c) () -> Void) {
    unsafeBitCast(pointer, to: (@convention(c) () -> Void).self)
}

private func sshContext(_ abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> SSHSessionContext? {
    guard let raw = abstract?.pointee else { return nil }
    return Unmanaged<SSHSessionContext>.fromOpaque(raw).takeUnretainedValue()
}

/// A jump session writes into its tunnel channel (-EAGAIN tells libssh2 to wait).
private let sshTunnelSend: @convention(c) (libssh2_socket_t, UnsafeRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int = { _, buffer, length, _, abstract in
    guard let tunnel = sshContext(abstract)?.tunnel, let buffer else { return -Int(ECONNRESET) }
    let n = libssh2_channel_write_ex(tunnel, 0, buffer.assumingMemoryBound(to: CChar.self), length)
    if n == Int(LIBSSH2_ERROR_EAGAIN) { return -Int(EAGAIN) }
    return n < 0 ? -Int(ECONNRESET) : n
}

/// A jump session reads from its tunnel channel; its end is the end of the connection.
private let sshTunnelRecv: @convention(c) (libssh2_socket_t, UnsafeMutableRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int = { _, buffer, length, _, abstract in
    guard let tunnel = sshContext(abstract)?.tunnel, let buffer else { return -Int(ECONNRESET) }
    let n = libssh2_channel_read_ex(tunnel, 0, buffer.assumingMemoryBound(to: CChar.self), length)
    if n == Int(LIBSSH2_ERROR_EAGAIN) { return libssh2_channel_eof(tunnel) == 1 ? 0 : -Int(EAGAIN) }
    return n < 0 ? -Int(ECONNRESET) : n
}

private let sshKeyboardInteractive: @convention(c) (UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, Int32, Int32,
                                                    UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,
                                                    UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,
                                                    UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Void = {
    name, nameLength, instruction, instructionLength, count, prompts, responses, abstract in
    guard let respond = sshContext(abstract)?.respond, let responses, count > 0 else { return }
    func text(_ p: UnsafePointer<CChar>?, _ n: Int32) -> String {
        guard let p, n > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: p, count: Int(n)), as: UTF8.self)
    }
    var asked: [SSHPromptRequest.Prompt] = []
    for i in 0..<Int(count) {
        let prompt = prompts![i]
        let words = prompt.text.map { String(decoding: UnsafeRawBufferPointer(start: $0, count: prompt.length), as: UTF8.self) } ?? ""
        asked.append(.init(text: words, echo: prompt.echo != 0))
    }
    let answers = respond(text(name, nameLength), text(instruction, instructionLength), asked)
    for i in 0..<Int(count) {
        let answer = i < answers.count ? answers[i] : ""
        responses[i].text = strdup(answer) // freed by libssh2
        responses[i].length = UInt32(answer.utf8.count)
    }
}

enum SSHDurations {
    static func text(_ d: Duration) -> String {
        let s = Int(d.components.seconds)
        return s < 120 ? "\(s)s" : s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60)s"
    }
}

extension Duration {
    var sshMilliseconds: Int { Int(components.seconds) * 1000 + Int(components.attoseconds / 1_000_000_000_000_000) }
}
