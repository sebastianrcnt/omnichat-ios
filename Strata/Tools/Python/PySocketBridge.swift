import Foundation
import Network
import Security

// Real sockets for Python. The worker's socket layer (`sockets.js`) sends every socket call to `strata-py://app/sock`
// and Network.framework carries it: TCP connections, listeners, UDP, and TLS on a connected socket (relayed through a
// loopback listener, since Network.framework can't add TLS to a live connection). Public addresses are reached freely;
// private and local ones wait for the user's approval, once per chat and host. Payloads are never logged; the run's
// card shows hosts, ports and byte counts.

/// One frame of the bridge, both ways: a little-endian u32 length, that much JSON, then the payload.
enum PySocketFrame {
    static func decode(_ data: Data) -> (args: [String: Any], payload: Data)? {
        let bytes = [UInt8](data.prefix(4))
        guard bytes.count == 4 else { return nil }
        let length = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        guard data.count >= 4 + length,
              let args = try? JSONSerialization.jsonObject(with: data.subdata(in: data.startIndex + 4 ..< data.startIndex + 4 + length)) as? [String: Any]
        else { return nil }
        return (args, data.subdata(in: data.startIndex + 4 + length ..< data.endIndex))
    }

    static func encode(_ json: [String: Any], payload: Data = Data()) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        var out = Data(capacity: 4 + body.count + payload.count)
        let n = UInt32(body.count)
        out.append(contentsOf: [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24 & 0xFF)])
        out.append(body)
        out.append(payload)
        return out
    }
}

/// Which destinations Python reaches without asking.
enum PySocketPolicy {
    enum Verdict: Equatable {
        case allow
        /// A private, LAN or loopback destination: the user decides.
        case ask
        /// Never possible here; the note says why.
        case refuse(note: String)
    }

    static func verdict(host: String, addresses: [String]) -> Verdict {
        if addresses.contains(where: isMulticastOrBroadcast) {
            return .refuse(note: "Multicast and broadcast need an entitlement from Apple that OmniChat doesn't have.")
        }
        if URLGuard.isBlockedHostname(host) || addresses.contains(where: { URLGuard.isBlocked(address: $0) }) { return .ask }
        return .allow
    }

    static func isMulticastOrBroadcast(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let b = withUnsafeBytes(of: &v4) { Array($0) }
            return (224...239).contains(b[0]) || b == [255, 255, 255, 255]
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 { return withUnsafeBytes(of: &v6) { $0[0] } == 0xFF }
        return false
    }

    static func isLoopback(_ address: String) -> Bool {
        address == "::1" || address.hasPrefix("127.") || address.lowercased() == "localhost"
    }

    static func isIPLiteral(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }
}

/// What one run did on the network, for its card and the model: destinations with bytes each way, and listeners.
struct PySocketActivity: Sendable, Equatable {
    struct Flow: Sendable, Hashable {
        var proto: String
        var host: String
        var port: Int
        var inbound = false
    }

    struct Counts: Sendable, Equatable {
        var sent = 0
        var received = 0
    }

    var flows: [Flow: Counts] = [:]
    /// The order flows first appeared in.
    var order: [Flow] = []
    /// Listening ports, as "TCP 8000".
    var listening: [String] = []

    var isEmpty: Bool { flows.isEmpty && listening.isEmpty }

    mutating func add(_ flow: Flow, sent: Int = 0, received: Int = 0) {
        if flows[flow] == nil { order.append(flow) }
        flows[flow, default: Counts()].sent += sent
        flows[flow, default: Counts()].received += received
    }

    static let shownFlows = 6

    /// "Network: TCP example.com:443, 1.2 kB sent, 45 kB received; listening on TCP port 8000 (192.168.1.23)". Nil
    /// when nothing happened.
    func summary(localAddress: String? = nil) -> String? {
        guard !isEmpty else { return nil }
        var parts: [String] = order.prefix(Self.shownFlows).map { flow in
            let counts = flows[flow] ?? Counts()
            let peer = flow.host.contains(":") ? "[\(flow.host)]:\(flow.port)" : "\(flow.host):\(flow.port)"
            return "\(flow.proto) \(flow.inbound ? "from " : "")\(peer), \(Self.bytes(counts.sent)) sent, \(Self.bytes(counts.received)) received"
        }
        if order.count > Self.shownFlows { parts.append("\(order.count - Self.shownFlows) more") }
        for port in listening {
            parts.append("listening on \(port.replacingOccurrences(of: " ", with: " port "))" + (localAddress.map { " (\($0))" } ?? ""))
        }
        return "Network: " + parts.joined(separator: "; ")
    }

    static func bytes(_ n: Int) -> String {
        if n < 1000 { return "\(n) B" }
        if n < 1_000_000 { return String(format: "%.1f kB", Double(n) / 1000) }
        return String(format: "%.1f MB", Double(n) / 1_000_000)
    }
}

/// The interpreter's sockets. Every state change happens on one serial queue (Network.framework's callbacks are
/// delivered there too), and calls that wait register a condition that each change re-checks.
final class PySocketBridge: @unchecked Sendable {
    static let maxSockets = 64
    /// UDP peers across all sockets. Each is its own `NWConnection` (outbound per destination, inbound per sender),
    /// so the socket count alone doesn't bound them.
    static let maxFlows = 128
    /// Bytes in and out per run, like the web proxy's limit.
    static let maxRunBytes = PyNetwork.maxBytes
    /// Received bytes held per socket before reading from the network pauses.
    static let receiveLimit = 4 << 20
    /// Bytes handed to the network and not yet sent before a send waits.
    static let sendLimit = 4 << 20
    static let firstAcceptedID = 1 << 20
    /// A card nobody answers counts as a refusal after this.
    static let approvalLimit: Duration = .seconds(300)
    static let connectTimeout = 60

    typealias Approver = @Sendable (NetworkApproval, UUID?, String?) async -> Bool

    private let queue = DispatchQueue(label: "cc.coolservices.strata.python-sockets")
    private let resolver: any HostResolving
    private let approve: Approver
    private let onWaitingForUser: @Sendable (Bool) -> Void
    private let onActivity: @Sendable (PySocketActivity) -> Void
    /// Bytes in and out per run (`maxRunBytes`, smaller in tests).
    private let byteBudget: Int

    // Queue state.
    private var sockets: [Int: Sock] = [:]
    private var waiters: [UUID: Waiter] = [:]
    private var cancelledWaits: Set<UUID> = []
    private var nextAcceptedID = PySocketBridge.firstAcceptedID
    private var conversationID: UUID?
    private var callID: String?
    private var inRun = false
    private var runBytes = 0
    private var activity = PySocketActivity()
    /// Hosts the user refused during this run (asked again in a later run).
    private var refused: Set<String> = []
    private var approvals: [String: Task<Bool, Never>] = [:]
    private var activityPending = false

    init(resolver: any HostResolving = SystemHostResolver(),
         approve: @escaping Approver = { approval, conversation, callID in
             await ToolApprovals.shared.approveNetwork(approval, conversation: conversation, callID: callID)
         },
         onWaitingForUser: @escaping @Sendable (Bool) -> Void = { _ in },
         onActivity: @escaping @Sendable (PySocketActivity) -> Void = { _ in },
         byteBudget: Int = PySocketBridge.maxRunBytes) {
        self.resolver = resolver
        self.byteBudget = byteBudget
        self.approve = approve
        self.onWaitingForUser = onWaitingForUser
        self.onActivity = onActivity
    }

    // MARK: Runs

    /// A run starts: approvals show under its call, and its byte budget and activity start over.
    func beginRun(conversationID: UUID?, callID: String?) {
        queue.sync {
            self.conversationID = conversationID
            self.callID = callID
            inRun = true
            runBytes = 0
            refused = []
            activity = PySocketActivity()
            activity.listening = listeningPorts()
        }
    }

    /// The run ended: what it did on the network. Cards still waiting are withdrawn (a refusal).
    func endRun() -> PySocketActivity {
        queue.sync {
            inRun = false
            for task in approvals.values { task.cancel() }
            approvals = [:]
            activity.listening = listeningPorts()
            return activity
        }
    }

    /// Every socket closes (the interpreter was reset, or the chat stopped).
    func closeAll() {
        queue.sync { closeAllNow() }
    }

    var openCount: Int { queue.sync { sockets.count } }

    /// UDP peers with a live flow (tests).
    var openFlows: Int { queue.sync { flowCount } }

    // MARK: Requests

    /// Serves one frame from the worker.
    func handle(_ body: Data) async -> Data {
        guard let (args, payload) = PySocketFrame.decode(body), let op = args["op"] as? String else {
            return PySocketFrame.encode(["errno": "EINVAL"])
        }
        let a = Args(args)
        let reply: Reply
        switch op {
        case "hello":
            await sync { self.closeAllNow() }
            reply = .ok
        case "connect": reply = await connect(a)
        case "bind": reply = await bind(a)
        case "listen": reply = await sync { self.listen(a) }
        case "accept": reply = await accept(a)
        case "send": reply = await send(a, payload)
        case "sendto": reply = await sendTo(a, payload)
        case "recv": reply = await receive(a)
        case "poll": reply = await poll(a)
        case "status": reply = await sync { self.status(a) }
        case "shutdown": reply = await sync { self.shutdown(a) }
        case "close":
            await sync { self.sockets[a.int("id")].map(self.close) }
            reply = .ok
        case "tls": reply = await startTLS(a, payload)
        default: reply = .error("EINVAL")
        }
        return PySocketFrame.encode(reply.json, payload: reply.data)
    }

    private struct Args: @unchecked Sendable {
        let raw: [String: Any]
        init(_ raw: [String: Any]) { self.raw = raw }
        /// Clamped to ±1e9: the values come from the code (ids, ports, sizes, timeouts in ms), and wider ones only
        /// overflow later arithmetic.
        func int(_ key: String) -> Int {
            guard let n = raw[key] as? NSNumber else { return 0 }
            let d = n.doubleValue
            return d.isFinite ? Int(min(max(d, -1e9), 1e9)) : 0
        }
        func string(_ key: String) -> String { raw[key] as? String ?? "" }
        func bool(_ key: String) -> Bool { (raw[key] as? NSNumber)?.boolValue ?? false }
    }

    private struct Reply: @unchecked Sendable {
        var json: [String: Any]
        var data = Data()
        static let ok = Reply(json: [:])
        static func error(_ errno: String, note: String? = nil) -> Reply {
            var json: [String: Any] = ["errno": errno]
            if let note { json["note"] = "[Network] " + note }
            return Reply(json: json)
        }
    }

    // MARK: Sockets

    private final class Sock: @unchecked Sendable {
        enum Kind { case tcp, udp }
        enum State: Equatable { case idle, connecting, connected, failed(String), closed }

        let id: Int
        let kind: Kind
        var state: State = .idle
        /// A failed connect's error was read with SO_ERROR.
        var errorReported = false
        /// The peer as the code named it.
        var host = ""
        var port = 0
        var proto: String { kind == .tcp ? "TCP" : "UDP" }

        // TCP: the connection the code reads and writes (the TLS one once TLS started).
        var connection: NWConnection?
        var relay: TLSRelay?
        var rx: [Data] = []
        var rxCount = 0
        var rxEOF = false
        var readShut = false
        var writeShut = false
        var txQueued = 0
        var streamError: String?
        var reading: Set<ObjectIdentifier> = []

        // Bound and listening.
        var listener: NWListener?
        var listening = false
        var boundPort = 0
        var accepted: [NWConnection] = []

        // UDP: a flow per peer, and the datagrams from all of them.
        var flows: [String: Flow] = [:]
        var datagrams: [(host: String, port: Int, data: Data)] = []
        var datagramBytes = 0

        init(id: Int, kind: Kind) {
            self.id = id
            self.kind = kind
        }
    }

    private final class Flow: @unchecked Sendable {
        let connection: NWConnection
        let host: String
        let port: Int
        let inbound: Bool
        init(connection: NWConnection, host: String, port: Int, inbound: Bool) {
            self.connection = connection
            self.host = host
            self.port = port
            self.inbound = inbound
        }
    }

    /// TLS over a connected socket: a TLS connection to a loopback listener, whose accepted end is piped to the
    /// plain connection.
    private final class TLSRelay: @unchecked Sendable {
        let raw: NWConnection
        var listener: NWListener?
        var inner: NWConnection?
        var tls: NWConnection?
        /// Bytes from the server before the inner end was ready.
        var pending: [Data] = []
        var rawEOF = false
        var verifyFailure: String?
        init(raw: NWConnection) { self.raw = raw }

        func cancel() {
            listener?.cancel()
            inner?.cancel()
            tls?.cancel()
            raw.cancel()
        }
    }

    private struct Waiter {
        var ready: @Sendable () -> Bool
        var resume: @Sendable (Bool) -> Void
    }

    /// The TLS stack's verify callback, handed to the queue.
    private final class Completion: @unchecked Sendable {
        let call: (Bool) -> Void
        init(_ call: @escaping (Bool) -> Void) { self.call = call }
    }

    /// A flag for callbacks that may fire more than once (state handlers), touched on the queue only.
    private final class Once: @unchecked Sendable {
        private var done = false
        /// True the first time.
        func claim() -> Bool {
            if done { return false }
            done = true
            return true
        }
    }

    // MARK: Queue helpers

    private func sync<T>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in queue.async { cont.resume(returning: body()) } }
    }

    /// Waits until `ready` holds (true), `timeoutMs` passes (false; -1 waits for good) or the request goes away.
    private func wait(_ timeoutMs: Int, until ready: @escaping @Sendable () -> Bool) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                queue.async {
                    if self.cancelledWaits.remove(id) != nil { cont.resume(returning: false); return }
                    if ready() { cont.resume(returning: true); return }
                    if timeoutMs == 0 { cont.resume(returning: false); return }
                    self.waiters[id] = Waiter(ready: ready, resume: { cont.resume(returning: $0) })
                    if timeoutMs > 0 {
                        self.queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) { self.finishWait(id, false) }
                    }
                }
            }
        } onCancel: {
            queue.async {
                if self.waiters[id] != nil { self.finishWait(id, false) } else { self.cancelledWaits.insert(id) }
            }
        }
    }

    private func finishWait(_ id: UUID, _ result: Bool) {
        waiters.removeValue(forKey: id)?.resume(result)
    }

    /// Something changed: waits whose condition now holds go on.
    private func signal() {
        for (id, waiter) in waiters where waiter.ready() { finishWait(id, true) }
    }

    private func newSocket(_ id: Int, kind: Sock.Kind) -> Sock? {
        if let sock = sockets[id] { return sock }
        guard sockets.count < Self.maxSockets else { return nil }
        let sock = Sock(id: id, kind: kind)
        sockets[id] = sock
        return sock
    }

    private func close(_ sock: Sock) {
        sock.state = .closed
        sock.relay?.cancel()
        sock.connection?.cancel()
        sock.listener?.cancel()
        for conn in sock.accepted { conn.cancel() }
        for flow in sock.flows.values { flow.connection.cancel() }
        sock.accepted = []
        sock.flows = [:]
        sockets[sock.id] = nil
        if sock.listening { publishActivity(now: true) }
        signal()
    }

    private var flowCount: Int { sockets.values.reduce(0) { $0 + $1.flows.count } }

    /// Starts a UDP flow and drops it from its socket once it fails or is cancelled.
    private func start(_ flow: Flow, on sock: Sock) {
        let key = "\(flow.host)|\(flow.port)"
        flow.connection.stateUpdateHandler = { [weak sock] state in
            switch state {
            case .failed, .cancelled:
                if let sock, sock.flows[key] === flow { sock.flows[key] = nil }
            default: break
            }
        }
        flow.connection.start(queue: queue)
        readDatagrams(sock, flow)
    }

    private func closeAllNow() {
        for sock in Array(sockets.values) { close(sock) }
    }

    private func listeningPorts() -> [String] {
        sockets.values.filter { $0.listening || ($0.kind == .udp && $0.listener != nil) }.map { "\($0.proto) \($0.boundPort)" }.sorted()
    }

    /// Live activity for the run's card, at most twice a second (and at once when a listener opens or closes).
    private func publishActivity(now: Bool = false) {
        guard inRun else { return }
        activity.listening = listeningPorts()
        if now {
            onActivity(activity)
            return
        }
        guard !activityPending else { return }
        activityPending = true
        queue.asyncAfter(deadline: .now() + .milliseconds(500)) {
            self.activityPending = false
            if self.inRun { self.onActivity(self.activity) }
        }
    }

    /// Counts bytes against the run's budget; false once it's spent.
    private func spend(_ n: Int) -> Bool {
        guard runBytes + n <= byteBudget else { return false }
        runBytes += n
        return true
    }

    private var budgetNote: String { "This run's network budget (\(PySocketActivity.bytes(byteBudget)) in and out) is used up." }

    static func errno(_ error: NWError) -> String {
        switch error {
        case .posix(let code): posixName(code)
        case .dns: "EHOSTUNREACH"
        case .tls: "ECONNRESET"
        default: "EIO"
        }
    }

    static func posixName(_ code: POSIXErrorCode) -> String {
        switch code {
        case .ECONNREFUSED: "ECONNREFUSED"
        case .ETIMEDOUT: "ETIMEDOUT"
        case .EHOSTUNREACH: "EHOSTUNREACH"
        case .ENETUNREACH: "ENETUNREACH"
        case .ENETDOWN: "ENETDOWN"
        case .EHOSTDOWN: "EHOSTDOWN"
        case .ECONNRESET: "ECONNRESET"
        case .ECONNABORTED: "ECONNABORTED"
        case .EPIPE: "EPIPE"
        case .EADDRINUSE: "EADDRINUSE"
        case .EADDRNOTAVAIL: "EADDRNOTAVAIL"
        case .EACCES, .EPERM: "EACCES"
        case .ECANCELED: "ECONNABORTED"
        case .ENOTCONN: "ENOTCONN"
        case .EMSGSIZE: "EMSGSIZE"
        case .ENOBUFS: "ENOBUFS"
        default: "EIO"
        }
    }

    /// The text of an endpoint's host ("192.168.1.2", "fe80::1", "example.com"), without an interface scope.
    static func describe(_ endpoint: NWEndpoint) -> (host: String, port: Int) {
        guard case .hostPort(let host, let port) = endpoint else { return ("", 0) }
        let text: String = switch host {
        case .ipv4(let a): "\(a)"
        case .ipv6(let a):
            if let v4 = a.asIPv4 { "\(v4)" } else { "\(a)" }
        case .name(let n, _): n
        @unknown default: "\(host)"
        }
        let unscoped = text.split(separator: "%").first.map(String.init) ?? text
        return (unscoped, Int(port.rawValue))
    }

    private static func tcpOptions() -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = connectTimeout
        return tcp
    }

    private static func tcpParameters() -> NWParameters { NWParameters(tls: nil, tcp: tcpOptions()) }

    // MARK: Policy

    private enum Authorization {
        case allowed([String])
        case refused(String, note: String?)
    }

    /// Resolves `host` and decides: public addresses go, local ones ask the user (once per chat and host), and the
    /// interpreter's own loopback listeners need no one's leave.
    private func authorize(host: String, port: Int, proto: String) async -> Authorization {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let addresses = PySocketPolicy.isIPLiteral(bare) ? [bare] : await resolver.resolve(bare)
        if addresses.isEmpty { return .refused("EHOSTUNREACH", note: "Could not resolve \(bare).") }
        switch PySocketPolicy.verdict(host: bare, addresses: addresses) {
        case .allow: return .allowed(addresses)
        case .refuse(let note): return .refused("EACCES", note: note)
        case .ask: break
        }
        let own = await sync {
            self.sockets.values.contains { $0.listener != nil && $0.boundPort == port && $0.proto == proto }
        }
        if own, addresses.allSatisfy(PySocketPolicy.isLoopback) { return .allowed(addresses) }
        let key = bare.lowercased()
        let approval = NetworkApproval(host: bare, address: addresses.first == bare ? nil : addresses.first, port: port, proto: proto)
        let task: Task<Bool, Never>? = await sync {
            if self.refused.contains(key) { return nil }
            if let pending = self.approvals[key] { return pending }
            guard self.inRun else { return nil }
            let (approve, waiting, conversation, call) = (self.approve, self.onWaitingForUser, self.conversationID, self.callID)
            let task = Task<Bool, Never> {
                waiting(true)
                defer { waiting(false) }
                return await withTaskGroup(of: Bool?.self) { group in
                    group.addTask { await approve(approval, conversation, call) }
                    group.addTask {
                        try? await Task.sleep(for: PySocketBridge.approvalLimit)
                        return nil
                    }
                    let first = await group.next() ?? nil
                    group.cancelAll()
                    return first ?? false
                }
            }
            self.approvals[key] = task
            return task
        }
        let allowed = await task?.value ?? false
        await sync {
            self.approvals[key] = nil
            if !allowed { self.refused.insert(key) }
        }
        return allowed ? .allowed(addresses) : .refused("EACCES", note: "The user did not allow connecting to \(bare):\(port).")
    }

    // MARK: TCP

    private func connect(_ a: Args) async -> Reply {
        let id = a.int("id"), host = a.string("host"), port = a.int("port")
        let kind: Sock.Kind = a.string("kind") == "udp" ? .udp : .tcp
        guard (1...65535).contains(port), !host.isEmpty else { return .error(port == 0 ? "ECONNREFUSED" : "EINVAL") }
        let problem: Reply? = await sync {
            guard let sock = self.newSocket(id, kind: kind) else { return .error("EMFILE") }
            if kind == .tcp {
                guard sock.state == .idle else { return .error(sock.state == .connecting ? "EALREADY" : "EISCONN") }
                sock.listener?.cancel() // bound first, as a client: the listener goes
                sock.listener = nil
                sock.state = .connecting
            }
            sock.host = host
            sock.port = port
            return nil
        }
        if let problem { return problem }
        if kind == .udp { return await connectUDP(id: id, host: host, port: port) }

        let attempt = Task { await self.establish(id: id, host: host, port: port) }
        if !a.bool("block") { return .error("EINPROGRESS") }
        await attempt.value
        return await sync {
            guard let sock = self.sockets[id] else { return .error("EBADF") }
            switch sock.state {
            case .connected:
                sock.errorReported = true
                return Reply(json: self.localEndpoint(sock))
            case .failed(let e):
                sock.errorReported = true
                return .error(e, note: self.notes.removeValue(forKey: id))
            default: return .error("ECONNABORTED")
            }
        }
    }

    private func localEndpoint(_ sock: Sock) -> [String: Any] {
        guard let local = (sock.relay?.raw ?? sock.connection)?.currentPath?.localEndpoint else { return [:] }
        let (host, port) = Self.describe(local)
        return ["localHost": host, "localPort": port]
    }

    /// Policy, then each resolved address in turn until one connects.
    private func establish(id: Int, host: String, port: Int) async {
        let verdict = await authorize(host: host, port: port, proto: "TCP")
        guard case .allowed(let addresses) = verdict else {
            if case .refused(let e, let note) = verdict { await sync { self.fail(id, e, note: note) } }
            return
        }
        var last = "ECONNREFUSED"
        for address in addresses {
            switch await attempt(id: id, address: address, port: port) {
            case nil: return
            case "closed": return
            case let error?: last = error
            }
        }
        let error = last
        await sync { self.fail(id, error, note: nil) }
    }

    private var notes: [Int: String] = [:]

    private func fail(_ id: Int, _ errno: String, note: String?) {
        guard let sock = sockets[id], sock.state != .closed else { return }
        sock.connection?.cancel()
        sock.connection = nil
        sock.state = .failed(errno)
        if let note { notes[id] = note }
        signal()
    }

    /// One address: nil once connected, else the error (or "closed" when the code closed the socket meanwhile).
    private func attempt(id: Int, address: String, port: Int) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            queue.async { [self] in
                guard let sock = self.sockets[id], sock.state == .connecting, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                    cont.resume(returning: "closed")
                    return
                }
                let conn = NWConnection(host: NWEndpoint.Host(address), port: nwPort, using: Self.tcpParameters())
                sock.connection = conn
                let once = Once()
                conn.stateUpdateHandler = { [weak self, weak sock] state in
                    guard let self, let sock else { return }
                    switch state {
                    case .ready:
                        guard once.claim() else { return }
                        sock.state = .connected
                        self.watch(sock, conn)
                        self.read(sock, from: conn)
                        self.activity.add(.init(proto: "TCP", host: sock.host, port: sock.port))
                        self.publishActivity()
                        self.signal()
                        cont.resume(returning: nil)
                    case .waiting(let error), .failed(let error):
                        guard once.claim() else { return }
                        conn.cancel()
                        if sock.connection === conn { sock.connection = nil }
                        cont.resume(returning: sock.state == .closed ? "closed" : Self.errno(error))
                    case .cancelled:
                        guard once.claim() else { return }
                        cont.resume(returning: "closed")
                    default: break
                    }
                }
                conn.start(queue: self.queue)
            }
        }
    }

    /// Errors after a connection was established: a reset or a dropped network.
    private func watch(_ sock: Sock, _ conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self, weak sock] state in
            guard let self, let sock, sock.connection === conn else { return }
            switch state {
            case .failed(let error), .waiting(let error):
                if sock.streamError == nil { sock.streamError = Self.errno(error) }
                sock.rxEOF = true
                self.signal()
            default: break
            }
        }
    }

    /// Keeps a receive pending on `conn`: into the socket's buffer (paused while it's full), or through a TLS relay.
    private func read(_ sock: Sock, from conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        guard sock.state != .closed, !sock.reading.contains(key) else { return }
        let piped = sock.relay.map { $0.raw === conn || $0.inner === conn } ?? false
        if !piped {
            guard conn === sock.connection, sock.rxCount < Self.receiveLimit, !sock.rxEOF, !sock.readShut else { return }
        }
        sock.reading.insert(key)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self, weak sock] data, _, complete, error in
            guard let self, let sock else { return }
            sock.reading.remove(key)
            guard sock.state != .closed else { return }
            if let relay = sock.relay, relay.raw === conn || relay.inner === conn {
                self.pipe(relay, from: conn, data: data, complete: complete || error != nil)
                if !complete, error == nil { self.read(sock, from: conn) }
                return
            }
            guard conn === sock.connection else { return }
            if let data, !data.isEmpty, !sock.readShut {
                sock.rx.append(data)
                sock.rxCount += data.count
            }
            if complete { sock.rxEOF = true }
            if let error, !complete {
                if sock.streamError == nil { sock.streamError = Self.errno(error) }
                sock.rxEOF = true
            }
            self.signal()
            if !complete, error == nil { self.read(sock, from: conn) }
        }
    }

    private func send(_ a: Args, _ payload: Data) async -> Reply {
        let id = a.int("id"), block = a.bool("block")
        while true {
            let result: Reply? = await sync { [self] in
                guard let sock = self.sockets[id] else { return .error("EBADF") }
                switch sock.state {
                case .connecting: return nil
                case .failed(let e): return .error(e)
                case .idle, .closed: return .error("ENOTCONN")
                case .connected: break
                }
                if sock.writeShut { return .error("EPIPE") }
                if let error = sock.streamError { return .error(error == "ECONNRESET" ? error : "EPIPE") }
                guard sock.txQueued < Self.sendLimit, let conn = sock.connection else { return nil }
                guard self.spend(payload.count) else { return .error("ENOBUFS", note: self.budgetNote) }
                let n = payload.count
                sock.txQueued += n
                conn.send(content: payload, completion: .contentProcessed { [weak self, weak sock] error in
                    guard let self, let sock else { return }
                    sock.txQueued -= n
                    if let error, sock.streamError == nil { sock.streamError = Self.errno(error) }
                    self.signal()
                })
                self.activity.add(.init(proto: "TCP", host: sock.host, port: sock.port, inbound: sock.id >= Self.firstAcceptedID), sent: n)
                self.publishActivity()
                return Reply(json: ["n": n])
            }
            if let result { return result }
            if !block { return .error("EAGAIN") }
            let ready = await wait(-1) { [weak self] in
                guard let sock = self?.sockets[id] else { return true }
                return sock.state != .connecting && (sock.txQueued < Self.sendLimit || sock.streamError != nil || sock.state != .connected)
            }
            if !ready { return .error("EINTR") }
        }
    }

    private func receive(_ a: Args) async -> Reply {
        let id = a.int("id"), max = Swift.max(0, a.int("max")), peek = a.bool("peek"), block = a.bool("block")
        while true {
            let result: Reply? = await sync {
                guard let sock = self.sockets[id] else { return .error("EBADF") }
                return sock.kind == .tcp ? self.takeStream(sock, max: max, peek: peek) : self.takeDatagram(sock, max: max, peek: peek)
            }
            if let result { return result }
            if !block { return .error("EAGAIN") }
            let ready = await wait(-1) { [weak self] in
                guard let self, let sock = self.sockets[id] else { return true }
                return self.readable(sock)
            }
            if !ready { return .error("EINTR") }
        }
    }

    private func readable(_ sock: Sock) -> Bool {
        if sock.kind == .udp { return !sock.datagrams.isEmpty || sock.state == .closed }
        switch sock.state {
        case .connecting, .idle: return false
        case .failed, .closed: return true
        case .connected: return sock.rxCount > 0 || sock.rxEOF || sock.readShut || sock.streamError != nil
        }
    }

    /// Bytes for recv(): nil when it would block.
    private func takeStream(_ sock: Sock, max: Int, peek: Bool) -> Reply? {
        switch sock.state {
        case .connecting: return nil
        case .idle, .closed: return .error("ENOTCONN")
        case .failed(let e): return .error(e)
        case .connected: break
        }
        if sock.readShut { return Reply(json: ["eof": true]) }
        if sock.rxCount > 0 {
            var out = Data()
            var remaining = max
            if peek {
                for chunk in sock.rx where remaining > 0 {
                    out.append(chunk.prefix(remaining))
                    remaining -= Swift.min(remaining, chunk.count)
                }
                return Reply(json: ["n": out.count], data: out)
            }
            while remaining > 0, let chunk = sock.rx.first {
                if chunk.count <= remaining {
                    out.append(chunk)
                    remaining -= chunk.count
                    sock.rx.removeFirst()
                } else {
                    out.append(chunk.prefix(remaining))
                    sock.rx[0] = Data(chunk.dropFirst(remaining))
                    remaining = 0
                }
            }
            guard spend(out.count) else { return .error("ENOBUFS", note: budgetNote) }
            sock.rxCount -= out.count
            activity.add(.init(proto: "TCP", host: sock.host, port: sock.port, inbound: sock.id >= Self.firstAcceptedID), received: out.count)
            publishActivity()
            if let conn = sock.connection { read(sock, from: conn) }
            return Reply(json: ["n": out.count], data: out)
        }
        if sock.rxEOF, sock.streamError != "ECONNRESET" { return Reply(json: ["eof": true]) }
        if let error = sock.streamError { return .error(error) }
        if sock.rxEOF { return Reply(json: ["eof": true]) }
        return nil
    }

    private func status(_ a: Args) -> Reply {
        guard let sock = sockets[a.int("id")] else { return .error("EBADF") }
        var json: [String: Any] = ["connected": sock.state == .connected]
        if case .failed(let e) = sock.state, !sock.errorReported {
            json["errno"] = e
            if a.bool("clear") { sock.errorReported = true }
        }
        if json["errno"] != nil, let note = notes.removeValue(forKey: sock.id) { json["note"] = "[Network] " + note }
        json["available"] = sock.kind == .tcp ? sock.rxCount : (sock.datagrams.first?.data.count ?? 0)
        if sock.kind == .tcp, sock.state == .connected { json.merge(localEndpoint(sock)) { a, _ in a } }
        return Reply(json: json)
    }

    private func shutdown(_ a: Args) -> Reply {
        guard let sock = sockets[a.int("id")] else { return .error("EBADF") }
        guard sock.state == .connected, let conn = sock.connection else { return .error("ENOTCONN") }
        let how = a.int("how")
        if how == 0 || how == 2 {
            sock.readShut = true
            sock.rx = []
            sock.rxCount = 0
        }
        if (how == 1 || how == 2), !sock.writeShut {
            sock.writeShut = true
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        }
        signal()
        return .ok
    }

    // MARK: Listening

    private func bind(_ a: Args) async -> Reply {
        let id = a.int("id"), host = a.string("host"), port = a.int("port")
        let kind: Sock.Kind = a.string("kind") == "udp" ? .udp : .tcp
        guard (0...65535).contains(port) else { return .error("EINVAL") }
        let created: Bool = await sync { self.newSocket(id, kind: kind) != nil }
        guard created else { return .error("EMFILE") }
        let params = kind == .tcp ? Self.tcpParameters() : NWParameters.udp
        params.allowLocalEndpointReuse = true
        let loopback = PySocketPolicy.isLoopback(host)
        if loopback { params.requiredInterfaceType = .loopback }
        let listener: NWListener
        do {
            if port == 0 { listener = try NWListener(using: params) }
            else { listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: UInt16(port))!) }
        } catch {
            return .error((error as? NWError).map(Self.errno) ?? "EADDRINUSE")
        }
        let result: String? = await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            queue.async { [self] in
                guard let sock = self.sockets[id], sock.state != .closed else { cont.resume(returning: "EBADF"); return }
                sock.listener = listener
                let once = Once()
                listener.newConnectionHandler = { [weak self, weak sock] conn in
                    guard let self, let sock, sock.listener === listener else { conn.cancel(); return }
                    self.inbound(conn, to: sock)
                }
                listener.stateUpdateHandler = { [weak self, weak sock] state in
                    switch state {
                    case .ready:
                        guard once.claim() else { return }
                        sock?.boundPort = Int(listener.port?.rawValue ?? 0)
                        if sock?.kind == .udp { self?.publishActivity(now: true) }
                        cont.resume(returning: nil)
                    case .failed(let error), .waiting(let error):
                        listener.cancel()
                        guard once.claim() else { return }
                        if sock?.listener === listener { sock?.listener = nil }
                        cont.resume(returning: Self.errno(error))
                    case .cancelled:
                        guard once.claim() else { return }
                        cont.resume(returning: "EBADF")
                    default: break
                    }
                }
                listener.start(queue: self.queue)
            }
        }
        if let result { return .error(result == "EIO" ? "EADDRINUSE" : result) }
        return await sync {
            guard let sock = self.sockets[id] else { return .error("EBADF") }
            return Reply(json: ["port": sock.boundPort, "host": loopback ? "127.0.0.1" : "0.0.0.0"])
        }
    }

    private func listen(_ a: Args) -> Reply {
        guard let sock = sockets[a.int("id")], sock.kind == .tcp, sock.listener != nil else { return .error("EINVAL") }
        sock.listening = true
        publishActivity(now: true)
        return .ok
    }

    /// A connection from outside: queued for accept() (TCP), or a new peer's flow (UDP).
    private func inbound(_ conn: NWConnection, to sock: Sock) {
        if sock.kind == .udp {
            let (host, port) = Self.describe(conn.endpoint)
            guard flowCount < Self.maxFlows else { conn.cancel(); return }
            let flow = Flow(connection: conn, host: host, port: port, inbound: true)
            sock.flows["\(host)|\(port)"] = flow
            start(flow, on: sock)
            return
        }
        guard sock.accepted.count < 128 else { conn.cancel(); return }
        let once = Once()
        conn.stateUpdateHandler = { [weak self, weak sock] state in
            guard let self, let sock else { return }
            switch state {
            case .ready:
                guard once.claim() else { return }
                sock.accepted.append(conn)
                self.signal()
            case .failed, .cancelled:
                sock.accepted.removeAll { $0 === conn }
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func accept(_ a: Args) async -> Reply {
        let id = a.int("id"), block = a.bool("block")
        while true {
            let result: Reply? = await sync {
                guard let sock = self.sockets[id], sock.listening else { return .error("EINVAL") }
                guard !sock.accepted.isEmpty else { return nil }
                let conn = sock.accepted.removeFirst()
                guard self.sockets.count < Self.maxSockets else {
                    conn.cancel()
                    return .error("EMFILE")
                }
                let new = Sock(id: self.nextAcceptedID, kind: .tcp)
                self.nextAcceptedID += 1
                let (host, port) = Self.describe(conn.endpoint)
                new.host = host
                new.port = port
                new.state = .connected
                new.connection = conn
                self.sockets[new.id] = new
                self.watch(new, conn)
                self.read(new, from: conn)
                self.activity.add(.init(proto: "TCP", host: host, port: port, inbound: true))
                self.publishActivity()
                return Reply(json: ["id": new.id, "host": host, "port": port])
            }
            if let result { return result }
            if !block { return .error("EAGAIN") }
            let ready = await wait(-1) { [weak self] in
                guard let sock = self?.sockets[id] else { return true }
                return !sock.accepted.isEmpty || !sock.listening
            }
            if !ready { return .error("EINTR") }
        }
    }

    // MARK: UDP

    private func connectUDP(id: Int, host: String, port: Int) async -> Reply {
        switch await flow(id: id, host: host, port: port) {
        case .success:
            return await sync {
                guard let sock = self.sockets[id] else { return .error("EBADF") }
                sock.state = .connected
                return .ok
            }
        case .failure(let reply): return reply
        }
    }

    private enum FlowResult: @unchecked Sendable {
        case success(Flow)
        case failure(Reply)
    }

    /// The socket's flow to a peer: an existing one, or a new one once the policy allows it.
    private func flow(id: Int, host: String, port: Int) async -> FlowResult {
        let key = "\(host)|\(port)"
        if let existing: Flow = await sync({ self.sockets[id]?.flows[key] }) { return .success(existing) }
        let verdict = await authorize(host: host, port: port, proto: "UDP")
        guard case .allowed(let addresses) = verdict else {
            if case .refused(let e, let note) = verdict { return .failure(.error(e, note: note)) }
            return .failure(.error("EACCES"))
        }
        return await sync {
            guard let sock = self.sockets[id], sock.state != .closed else { return .failure(.error("EBADF")) }
            if let existing = sock.flows[key] { return .success(existing) }
            guard self.flowCount < Self.maxFlows else {
                return .failure(.error("ENOBUFS", note: "Python can talk UDP with at most \(Self.maxFlows) peers at once. Close sockets you no longer need."))
            }
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return .failure(.error("EINVAL")) }
            let params = NWParameters.udp
            if sock.boundPort > 0, let local = NWEndpoint.Port(rawValue: UInt16(sock.boundPort)) {
                params.allowLocalEndpointReuse = true
                params.requiredLocalEndpoint = .hostPort(host: "0.0.0.0", port: local)
            }
            let conn = NWConnection(host: NWEndpoint.Host(addresses[0]), port: nwPort, using: params)
            let flow = Flow(connection: conn, host: host, port: port, inbound: false)
            sock.flows[key] = flow
            self.start(flow, on: sock)
            return .success(flow)
        }
    }

    private func readDatagrams(_ sock: Sock, _ flow: Flow) {
        flow.connection.receiveMessage { [weak self, weak sock] data, _, _, error in
            guard let self, let sock, sock.state != .closed, sock.flows["\(flow.host)|\(flow.port)"] === flow else { return }
            if let data, !data.isEmpty, sock.datagramBytes + data.count <= Self.receiveLimit {
                sock.datagrams.append((flow.host, flow.port, data))
                sock.datagramBytes += data.count
                self.signal()
            }
            if error == nil { self.readDatagrams(sock, flow) }
        }
    }

    private func sendTo(_ a: Args, _ payload: Data) async -> Reply {
        let id = a.int("id"), host = a.string("host"), port = a.int("port")
        guard (1...65535).contains(port), !host.isEmpty else { return .error("EINVAL") }
        guard payload.count <= 65507 else { return .error("EMSGSIZE") }
        let created: Bool = await sync { self.newSocket(id, kind: .udp) != nil }
        guard created else { return .error("EMFILE") }
        switch await flow(id: id, host: host, port: port) {
        case .failure(let reply): return reply
        case .success(let flow):
            return await sync {
                guard let sock = self.sockets[id] else { return .error("EBADF") }
                guard self.spend(payload.count) else { return .error("ENOBUFS", note: self.budgetNote) }
                flow.connection.send(content: payload, completion: .idempotent)
                self.activity.add(.init(proto: "UDP", host: flow.host, port: flow.port, inbound: flow.inbound), sent: payload.count)
                self.publishActivity()
                var json: [String: Any] = ["n": payload.count]
                if sock.boundPort == 0, let local = flow.connection.currentPath?.localEndpoint { json["localPort"] = Self.describe(local).port }
                return Reply(json: json)
            }
        }
    }

    private func takeDatagram(_ sock: Sock, max: Int, peek: Bool) -> Reply? {
        guard let first = sock.datagrams.first else { return sock.state == .closed ? .error("EBADF") : nil }
        let data = first.data.prefix(max)
        if !peek {
            guard spend(data.count) else { return .error("ENOBUFS", note: budgetNote) }
            sock.datagrams.removeFirst()
            sock.datagramBytes -= first.data.count
            activity.add(.init(proto: "UDP", host: first.host, port: first.port, inbound: sock.flows["\(first.host)|\(first.port)"]?.inbound ?? false),
                         received: data.count)
            publishActivity()
        }
        return Reply(json: ["n": data.count, "host": first.host, "port": first.port], data: Data(data))
    }

    // MARK: Poll

    static let POLLIN = 1, POLLOUT = 4, POLLERR = 8, POLLHUP = 16, POLLNVAL = 32

    private func events(_ sock: Sock?) -> Int {
        guard let sock else { return Self.POLLNVAL }
        if sock.kind == .udp { return Self.POLLOUT | (sock.datagrams.isEmpty ? 0 : Self.POLLIN) }
        if sock.listening { return sock.accepted.isEmpty ? 0 : Self.POLLIN }
        switch sock.state {
        case .idle: return Self.POLLOUT | Self.POLLHUP
        case .connecting: return 0
        case .failed: return Self.POLLIN | Self.POLLOUT | Self.POLLERR | Self.POLLHUP
        case .closed: return Self.POLLNVAL
        case .connected:
            var mask = 0
            if sock.rxCount > 0 || sock.rxEOF || sock.readShut || sock.streamError != nil { mask |= Self.POLLIN }
            if !sock.writeShut && (sock.txQueued < Self.sendLimit || sock.streamError != nil) { mask |= Self.POLLOUT }
            if sock.streamError != nil { mask |= Self.POLLERR }
            if sock.rxEOF && (sock.writeShut || sock.streamError != nil) { mask |= Self.POLLHUP }
            return mask
        }
    }

    private func poll(_ a: Args) async -> Reply {
        let fds = (a.raw["fds"] as? [[NSNumber]] ?? []).map { ($0.first?.intValue ?? 0, $0.count > 1 ? $0[1].intValue : 0) }
        let timeout = a.int("timeout")
        let compute: @Sendable () -> [Int] = { [weak self] in
            guard let self else { return fds.map { _ in Self.POLLNVAL } }
            return fds.map { id, wanted in self.events(self.sockets[id]) & (wanted | Self.POLLERR | Self.POLLHUP | Self.POLLNVAL) }
        }
        let first = await sync(compute)
        if timeout == 0 || first.contains(where: { $0 != 0 }) { return Reply(json: ["revents": first]) }
        let ready = await wait(timeout) { compute().contains { $0 != 0 } }
        if !ready && Task.isCancelled { return .error("EINTR") }
        return Reply(json: ["revents": await sync(compute)])
    }

    // MARK: TLS

    private func startTLS(_ a: Args, _ payload: Data) async -> Reply {
        let id = a.int("id"), host = a.string("host"), verify = a.bool("verify"), checkHostname = a.bool("checkHostname")
        let alpn = a.raw["alpn"] as? [String] ?? []
        let timeoutMs = a.int("timeout") > 0 ? a.int("timeout") : 60_000
        let anchors = Self.certificates(pem: String(decoding: payload, as: UTF8.self))

        // A loopback listener for the TLS connection to reach; its accepted end is piped to the server.
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        guard let listener = try? NWListener(using: params) else { return .error("EIO") }
        let relay: TLSRelay? = await sync { [self] in
            guard let sock = self.sockets[id], sock.kind == .tcp, sock.state == .connected, sock.relay == nil,
                  let raw = sock.connection else { return nil }
            let relay = TLSRelay(raw: raw)
            relay.listener = listener
            relay.pending = sock.rx // bytes that came before the handshake belong to it
            sock.rx = []
            sock.rxCount = 0
            sock.relay = relay
            listener.newConnectionHandler = { [weak self, weak sock, weak relay] conn in
                guard let self, let sock, let relay, relay.inner == nil else { conn.cancel(); return }
                relay.inner = conn
                conn.stateUpdateHandler = { [weak self, weak sock, weak relay] state in
                    guard let self, let sock, let relay, case .ready = state else { return }
                    for chunk in relay.pending { conn.send(content: chunk, completion: .idempotent) }
                    relay.pending = []
                    if relay.rawEOF { conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent) }
                    self.read(sock, from: conn)
                }
                conn.start(queue: self.queue)
            }
            self.read(sock, from: raw) // already running for the plain socket; from now on it feeds the relay
            return relay
        }
        guard let relay else { listener.cancel(); return .error("ENOTCONN") }

        let port: NWEndpoint.Port? = await withCheckedContinuation { cont in
            queue.async {
                let once = Once()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: if once.claim() { cont.resume(returning: listener.port) }
                    case .failed, .cancelled: if once.claim() { cont.resume(returning: nil) }
                    default: break
                    }
                }
                listener.start(queue: self.queue)
            }
        }
        guard let port else { return await tlsFailed(id, relay, message: "the local relay could not start") }

        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions
        if !host.isEmpty, !PySocketPolicy.isIPLiteral(host) { sec_protocol_options_set_tls_server_name(sec, host) }
        for protocolName in alpn where !protocolName.isEmpty { sec_protocol_options_add_tls_application_protocol(sec, protocolName) }
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        let queue = self.queue
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            guard verify else { complete(true); return }
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, checkHostname && !host.isEmpty ? host as CFString : nil))
            if !anchors.isEmpty {
                SecTrustSetAnchorCertificates(secTrust, anchors as CFArray)
                SecTrustSetAnchorCertificatesOnly(secTrust, false)
            }
            var error: CFError?
            let ok = SecTrustEvaluateWithError(secTrust, &error)
            if !ok {
                let message = (error as Error?)?.localizedDescription ?? "the certificate is not trusted"
                queue.async { relay.verifyFailure = message }
            }
            let done = Completion(complete)
            queue.async { done.call(ok) }
        }, DispatchQueue.global(qos: .userInitiated))
        let tlsParams = NWParameters(tls: options, tcp: Self.tcpOptions())
        let tls = NWConnection(host: "127.0.0.1", port: port, using: tlsParams)

        let failure: String? = await withCheckedContinuation { cont in
            queue.async {
                relay.tls = tls
                let once = Once()
                let finish: @Sendable (String?) -> Void = { result in
                    guard once.claim() else { return }
                    cont.resume(returning: result)
                }
                tls.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(nil)
                    case .failed(let error), .waiting(let error): finish(relay.verifyFailure ?? Self.tlsMessage(error))
                    case .cancelled: finish("the connection closed")
                    default: break
                    }
                }
                tls.start(queue: queue)
                queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) { finish("ETIMEDOUT") }
            }
        }
        if let failure {
            let verifyFailed = await sync { relay.verifyFailure != nil }
            if failure == "ETIMEDOUT" { return await tlsFailed(id, relay, message: "the handshake timed out", errno: "ETIMEDOUT") }
            return await tlsFailed(id, relay, message: failure, verify: verifyFailed)
        }
        return await sync {
            guard let sock = self.sockets[id], sock.relay === relay else { return .error("EBADF") }
            relay.listener?.cancel()
            relay.listener = nil
            sock.connection = tls
            self.watch(sock, tls)
            self.read(sock, from: tls)
            return Reply(json: Self.metadata(tls))
        }
    }

    private func tlsFailed(_ id: Int, _ relay: TLSRelay, message: String, verify: Bool = false, errno: String = "ECONNRESET") async -> Reply {
        await sync {
            relay.cancel()
            if let sock = self.sockets[id], sock.relay === relay {
                sock.relay = nil
                sock.connection = nil
                sock.state = .failed("ECONNRESET")
                sock.errorReported = true
            }
            self.signal()
        }
        var json: [String: Any] = ["errno": errno, "error": errno, "message": message]
        if verify { json["verify"] = true }
        return Reply(json: json)
    }

    /// Moves bytes between the server and the TLS connection's loopback end.
    private func pipe(_ relay: TLSRelay, from conn: NWConnection, data: Data?, complete: Bool) {
        if conn === relay.raw {
            if let inner = relay.inner {
                if let data, !data.isEmpty { inner.send(content: data, completion: .idempotent) }
                if complete { inner.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent) }
            } else {
                if let data, !data.isEmpty { relay.pending.append(data) }
                if complete { relay.rawEOF = true }
            }
        } else {
            if let data, !data.isEmpty { relay.raw.send(content: data, completion: .idempotent) }
            if complete { relay.raw.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent) }
        }
    }

    static func tlsMessage(_ error: NWError) -> String {
        if case .tls(let status) = error {
            return (SecCopyErrorMessageString(status, nil) as String?) ?? "TLS error \(status)"
        }
        return error.localizedDescription
    }

    /// Certificates from PEM text (the CAs a context loaded).
    static func certificates(pem: String) -> [SecCertificate] {
        var out: [SecCertificate] = []
        var rest = Substring(pem)
        while let begin = rest.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = rest.range(of: "-----END CERTIFICATE-----", range: begin.upperBound ..< rest.endIndex) {
            let body = rest[begin.upperBound ..< end.lowerBound].filter { !$0.isWhitespace }
            if let der = Data(base64Encoded: String(body)), let cert = SecCertificateCreateWithData(nil, der as CFData) { out.append(cert) }
            rest = rest[end.upperBound...]
        }
        return out
    }

    /// The negotiated version, cipher and ALPN protocol, and the server's certificate.
    static func metadata(_ conn: NWConnection) -> [String: Any] {
        guard let tls = conn.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return [:] }
        let sec = tls.securityProtocolMetadata
        var json: [String: Any] = [:]
        json["version"] = switch sec_protocol_metadata_get_negotiated_tls_protocol_version(sec) {
        case .TLSv13: "TLSv1.3"
        case .TLSv12: "TLSv1.2"
        case .TLSv11: "TLSv1.1"
        case .TLSv10: "TLSv1"
        default: "TLS"
        }
        let suite = sec_protocol_metadata_get_negotiated_tls_ciphersuite(sec).rawValue
        let (name, bits) = cipherName(suite)
        json["cipher"] = name
        json["bits"] = bits
        if let alpn = sec_protocol_metadata_copy_negotiated_protocol(sec) {
            json["alpn"] = String(cString: alpn)
            free(UnsafeMutableRawPointer(mutating: alpn))
        }
        var leaf: SecCertificate?
        sec_protocol_metadata_access_peer_certificate_chain(sec) { cert in
            if leaf == nil { leaf = sec_certificate_copy_ref(cert).takeRetainedValue() }
        }
        if let leaf {
            json["cert"] = (SecCertificateCopyData(leaf) as Data).base64EncodedString()
            if let subject = SecCertificateCopySubjectSummary(leaf) as String? { json["subject"] = subject }
        }
        return json
    }

    /// OpenSSL's names for the suites Apple's TLS negotiates.
    static func cipherName(_ suite: UInt16) -> (String, Int) {
        switch suite {
        case 0x1301: ("TLS_AES_128_GCM_SHA256", 128)
        case 0x1302: ("TLS_AES_256_GCM_SHA384", 256)
        case 0x1303: ("TLS_CHACHA20_POLY1305_SHA256", 256)
        case 0xC02B: ("ECDHE-ECDSA-AES128-GCM-SHA256", 128)
        case 0xC02C: ("ECDHE-ECDSA-AES256-GCM-SHA384", 256)
        case 0xC02F: ("ECDHE-RSA-AES128-GCM-SHA256", 128)
        case 0xC030: ("ECDHE-RSA-AES256-GCM-SHA384", 256)
        case 0xCCA8: ("ECDHE-RSA-CHACHA20-POLY1305", 256)
        case 0xCCA9: ("ECDHE-ECDSA-CHACHA20-POLY1305", 256)
        default: (String(format: "0x%04X", suite), 0)
        }
    }
}
