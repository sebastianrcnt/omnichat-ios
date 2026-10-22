import Foundation
import Network
import Security
import Testing
@testable import Strata

// Python's real sockets (`PySocketBridge`, `sockets.js`, `strata_net.py`). Every server here runs in the test process on
// loopback: nothing reaches the network outside the simulator.

// MARK: - Local servers

/// A loopback server in the test process. `handle` serves each connection (TCP) or each peer (UDP).
final class LocalTestServer: @unchecked Sendable {
    private let listener: NWListener
    let queue = DispatchQueue(label: "local-test-server")
    private let lock = NSLock()
    private var _log = Data()
    private var connections: [NWConnection] = []

    /// What clients sent, for servers that keep it (SMTP).
    var log: Data { lock.withLock { _log } }

    func record(_ data: Data) { lock.withLock { _log.append(data) } }

    init(_ parameters: NWParameters = .tcp, handle: @escaping @Sendable (NWConnection, LocalTestServer) -> Void) throws {
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [unowned self] conn in
            lock.withLock { connections.append(conn) }
            conn.start(queue: queue)
            handle(conn, self)
        }
    }

    /// Starts listening; the port.
    func start() async throws -> Int {
        let once = TestOnce()
        return try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if once.claim() { cont.resume(returning: Int(listener.port?.rawValue ?? 0)) }
                case .failed(let error):
                    if once.claim() { cont.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        for conn in lock.withLock({ connections }) { conn.cancel() }
    }

    // MARK: Behaviors

    /// Sends back what it receives.
    static func echo(_ conn: NWConnection, _ server: LocalTestServer) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            if let data, !data.isEmpty { conn.send(content: data, completion: .idempotent) }
            if complete || error != nil {
                conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                return
            }
            echo(conn, server)
        }
    }

    /// Reads and never answers.
    static func silent(_ conn: NWConnection, _ server: LocalTestServer) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, complete, error in
            if !complete, error == nil { silent(conn, server) }
        }
    }

    /// A UDP peer that sends each datagram back.
    static func echoDatagrams(_ conn: NWConnection, _ server: LocalTestServer) {
        conn.receiveMessage { data, _, _, error in
            if let data { conn.send(content: data, completion: .idempotent) }
            if error == nil { echoDatagrams(conn, server) }
        }
    }

    /// An HTTP/1.1 server: one request per connection, answered with its request line.
    static func http(_ conn: NWConnection, _ server: LocalTestServer) {
        httpRead(conn, buffer: Data())
    }

    private static func httpRead(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let line = head.components(separatedBy: "\r\n").first ?? ""
                let body = Data("you sent: \(line)".utf8)
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(response.utf8) + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    conn.cancel()
                })
                return
            }
            if complete || error != nil { conn.cancel(); return }
            httpRead(conn, buffer: buffer)
        }
    }

    /// Enough SMTP for smtplib: greeting, EHLO, MAIL, RCPT, DATA, QUIT. Keeps every line it gets in `log`.
    static func smtp(_ conn: NWConnection, _ server: LocalTestServer) {
        conn.send(content: Data("220 test.local ESMTP\r\n".utf8), completion: .idempotent)
        smtpRead(conn, server, buffer: Data(), inData: false)
    }

    private static func smtpRead(_ conn: NWConnection, _ server: LocalTestServer, buffer: Data, inData: Bool) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var buffer = buffer
            var inData = inData
            if let data {
                buffer.append(data)
                server.record(data)
            }
            while let newline = buffer.range(of: Data("\r\n".utf8)) {
                let line = String(decoding: buffer[..<newline.lowerBound], as: UTF8.self)
                buffer.removeSubrange(..<newline.upperBound)
                let reply: String?
                if inData {
                    if line == "." { inData = false; reply = "250 2.0.0 queued" } else { reply = nil }
                } else {
                    let verb = line.prefix(4).uppercased()
                    switch verb {
                    case "EHLO": reply = "250-test.local\r\n250 8BITMIME"
                    case "HELO", "MAIL", "RCPT", "RSET", "NOOP": reply = "250 OK"
                    case "DATA": inData = true; reply = "354 go ahead"
                    case "QUIT": reply = "221 bye"
                    default: reply = "502 not implemented"
                    }
                }
                if let reply {
                    conn.send(content: Data((reply + "\r\n").utf8), completion: .idempotent)
                    if reply.hasPrefix("221") { conn.cancel(); return }
                }
            }
            if complete || error != nil { conn.cancel(); return }
            smtpRead(conn, server, buffer: buffer, inData: inData)
        }
    }
}

final class TestOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var _hosts: [String] = []
    var count: Int { lock.withLock { value } }
    var hosts: [String] { lock.withLock { _hosts } }
    func add(_ host: String) { lock.withLock { value += 1; _hosts.append(host) } }
}

/// A test CA and a `localhost` certificate it signed (also valid for 127.0.0.1), until 2028-12-25. To make new ones:
///   openssl ecparam -name prime256v1 -genkey -noout -out ca.key
///   openssl req -x509 -new -key ca.key -subj "/CN=OpenChat Test CA" -days 3650 -out ca.pem \
///     -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign
///   openssl ecparam -name prime256v1 -genkey -noout -out leaf.key
///   openssl req -new -key leaf.key -subj "/CN=localhost" -out leaf.csr
///   openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 800 -out leaf.pem -extfile <(printf \
///     "subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature")
///   openssl pkcs12 -export -legacy -inkey leaf.key -in leaf.pem -passout pass:test -out leaf.p12
/// (Apple refuses TLS server certificates valid for more than 825 days, so the leaf can't outlive that.)
enum TestTLS {
    static let caPEM = """
    -----BEGIN CERTIFICATE-----
    MIIBejCCASCgAwIBAgIUQWqaovcgrU5oegWyI25V1K/cNjwwCgYIKoZIzj0EAwIw
    GzEZMBcGA1UEAwwQT3BlbkNoYXQgVGVzdCBDQTAeFw0yNjEwMDEwMDAwMDBaFw0z
    NjEwMDEwMDAwMDBaMBsxGTAXBgNVBAMMEE9wZW5DaGF0IFRlc3QgQ0EwWTATBgcq
    hkjOPQIBBggqhkjOPQMBBwNCAATMBwoJGL1zPgt9wH86MRP0tQF64/5DT8mjZUDz
    3WvSjzgKCCrpL/quE7KbpRrXqPupoERr8vn2zQPoHjQic6hNo0IwQDAPBgNVHRMB
    Af8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjAdBgNVHQ4EFgQUPDwNgng3BkbOexzh
    Yy1nP/0cWrIwCgYIKoZIzj0EAwIDSAAwRQIgGa/vDMsYYDkZUKEpKHMRPeDg0Cag
    u06ptLKzQubs+60CIQDBWdjxSGBFPJhlv66N0/srVo9UhXTNXRRIb6qRBz+JdA==
    -----END CERTIFICATE-----
    """

    static let leafP12 = """
    MIIFegIBAzCCBTgGCSqGSIb3DQEHAaCCBSkEggUlMIIFITCCBBcGCSqGSIb3DQEHBqCCBAgwggQEAgEAMIID/QYJKoZIhvcNAQcBMBwGCiqGSIb3DQEMAQYw
    DgQI1c72/0k8gXMCAggAgIID0EvPsXm9XtZsH/Iz04JXmMhH7M9tPdjYSxe0Z8cpXX+KbKOPGQ1+qmvf5uA1rE77lngCzuCZHbAu3IyKNL3V/LXhahKgVWFD
    Sbnir9olvIetyAhGaWDI0CPpDE7kf9HnBvl+oSHrfhRSmKC1XVYtGCMSdIF9aziY8l34oNRicQETlGsnFV+ncu7eeriNX3gwa7yizPeKyMEec2fmI5Kg9eED
    EalmWfs3psof90cvtE0911vNnHwGtKJOxuOgsHjIuVJYSPm+iULfg4OgHRap3z59PRVUOpWxGh+m64dkMkNRZDrEe+yJoM9t4CrkcOFrBJFgVV2hfDYWMQj6
    tz8LX+6/OvJxYGQB7Dogt6zYP3zY7dgzuaAUmRQsLYRsQFxqr/k3lpsSnL8y9eth7vEm67y3vTg451BeKrHpLISVkPl/MeBStsq2rWHV9XmkqkTjEAq9sDtx
    c93uf39mKTBnA6TgHoCPxhNmuDZOsNMrJauwACaYFF3ZPK922RnMvskEu7aEfHnS9KWQPsslFs6mZSj4D/g/RLMMtfI2cbN3W/zB+pIz/f7e3cTvR8RnciN2
    TLiCvdKdgrl6fPZ/pbgl5Sf0fZ2Fxp0sFhOHS0M72eLkjN/00IVZ+rm3KbDZl+qxGEa5v93EUIxgJWMJttmdWmcZgMtAm5ruy8BZIU6Qvo9uVR1yVYxvD+9r
    j94+P23H7tQdw63sHzbMWBGJhMXCbgmnaZVIxX/N7K1g2b1b4QGDttVP+0R1PgXMIQ2Ln/C+AV0cdoXgUw4s8pzvDZeHUFU/V/swpFkIUL1AtnMHxohY1wmd
    XDYfBwlEXXBBcgmFxwPcCU6YjCnMUKkke60RlzzyHMYVegwu/VRwDseoDDzTnGcpMaiIa6GmvDOMTI8HICxQ/Q/V+Fd/rmBLyvV0SvTerh2IGXlYtyrRaYmp
    bH/Vx1i70hUlEh6mPlWOxng2LHQ6YFgXipoe+BG2Ap9JwH8AdvD4la1E7IlgaX2tykFtEJwI0V6QBJiy/qJ3ucn1hpl1XqqlxLsthPPfcmSOD2n/QcsZLB5a
    53/MeDeunpw49OnA1OGADJipTCQPaOy+YV2k9bQRt48/qcI27b5wQzY5uunh/0UU2kTRPnuf6AT/WOEMKnxbSG8qFCYKZaDG0OKJVFgTiMhuGTzbSupu833a
    nUGVcu0ajbeVI4iilqaWjaJA76MQbIoD7fiBquXZmxG+qjlrHLATjgAv8jEtKqbc4IeIZyfQO7mk0L6VLFe594izM2Da3rSkfia110kT+kt73+c+H5CpYcC/
    +2xsQrYwggECBgkqhkiG9w0BBwGggfQEgfEwge4wgesGCyqGSIb3DQEMCgECoIG0MIGxMBwGCiqGSIb3DQEMAQMwDgQI6sAr+xPsCHcCAggABIGQ/PtnDZEz
    0pf4INEpWHzWNe2qqDaWL7sjuCOKaOG4BvEtNAkXqUzMIpo7sOYEqEabGltWnJr3GcDG8mNzReLoN5tXd5TfpHKIvqcZOJEvmKyHLJZSZKBoyJv+KIHcFUk1
    fPl02eRUeSqc89CkEZao6iYIbt5HF3lxkUHnFwchcV55NROl9ZvDP7cnpeNI447UMSUwIwYJKoZIhvcNAQkVMRYEFHWEcG/O19cW6MheZoW1GC2L6IZIMDkw
    ITAJBgUrDgMCGgUABBS38eWxPBYggyJwaoU8ctLZ18IRrAQQwP1OaqDfFcTLj/ewXU/gdwICCAA=
    """

    static func identity() throws -> SecIdentity {
        let data = try #require(Data(base64Encoded: leafP12, options: .ignoreUnknownCharacters))
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: "test"] as CFDictionary, &items)
        #expect(status == errSecSuccess, "SecPKCS12Import: \(status)")
        let list = try #require(items as? [[String: Any]])
        let identity = try #require(list.first?[kSecImportItemIdentity as String])
        return identity as! SecIdentity // swiftlint:disable:this force_cast
    }

    /// TCP with TLS, as the `localhost` certificate.
    static func parameters() throws -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let identity = try identity()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, try #require(sec_identity_create(identity)))
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "echo/1")
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }
}

// MARK: - Pure parts

struct PySocketUnitTests {
    @Test func framesCarryJSONAndBinaryPayloads() throws {
        let payload = Data([0, 1, 2, 255, 0x0D, 0x0A])
        let frame = PySocketFrame.encode(["op": "send", "id": 3], payload: payload)
        let (args, body) = try #require(PySocketFrame.decode(frame))
        #expect(args["op"] as? String == "send")
        #expect((args["id"] as? NSNumber)?.intValue == 3)
        #expect(body == payload)
        #expect(PySocketFrame.decode(Data([1, 0])) == nil)
        #expect(PySocketFrame.decode(Data([200, 0, 0, 0]) + Data("{}".utf8)) == nil)
    }

    @Test func publicAddressesGoAndLocalOnesAsk() {
        #expect(PySocketPolicy.verdict(host: "example.com", addresses: ["93.184.216.34"]) == .allow)
        #expect(PySocketPolicy.verdict(host: "one.one.one.one", addresses: ["2606:4700:4700::1111"]) == .allow)
        for (host, address) in [("127.0.0.1", "127.0.0.1"), ("localhost", "::1"), ("nas", "192.168.1.20"), ("10.1.2.3", "10.1.2.3"),
                                ("172.16.0.9", "172.16.0.9"), ("printer.local", "192.168.0.7"), ("cgnat", "100.64.3.4"),
                                ("ula", "fd12:3456::1"), ("linklocal", "fe80::1"), ("169.254.10.10", "169.254.10.10")] {
            #expect(PySocketPolicy.verdict(host: host, addresses: [address]) == .ask, "\(host) \(address)")
        }
        // A public name that resolves to a private address is local all the same.
        #expect(PySocketPolicy.verdict(host: "sneaky.example", addresses: ["93.184.216.34", "192.168.1.1"]) == .ask)
        for address in ["224.0.0.251", "239.255.255.250", "255.255.255.255", "ff02::fb"] {
            guard case .refuse(let note) = PySocketPolicy.verdict(host: address, addresses: [address]) else {
                Issue.record("\(address) should be refused")
                continue
            }
            #expect(note.contains("entitlement"))
        }
    }

    @Test func activitySummarizesFlowsInOrder() {
        var activity = PySocketActivity()
        #expect(activity.summary() == nil)
        activity.add(.init(proto: "TCP", host: "db.local", port: 5432), sent: 120, received: 4500)
        activity.add(.init(proto: "UDP", host: "fe80::1", port: 53), sent: 40)
        activity.add(.init(proto: "TCP", host: "db.local", port: 5432), received: 1_000_000)
        activity.add(.init(proto: "TCP", host: "192.168.1.5", port: 51000, inbound: true), received: 3)
        activity.listening = ["TCP 8000"]
        #expect(activity.summary(localAddress: "192.168.1.23") ==
                "Network: TCP db.local:5432, 120 B sent, 1.0 MB received; UDP [fe80::1]:53, 40 B sent, 0 B received; "
                + "TCP from 192.168.1.5:51000, 0 B sent, 3 B received; listening on TCP port 8000 (192.168.1.23)")
        for port in 1...8 { activity.add(.init(proto: "TCP", host: "h\(port)", port: port)) }
        #expect(activity.summary()?.contains("5 more") == true)
    }

    @Test func theRunsOutputEndsWithItsNetworkLine() {
        let outcome = PythonOutcome.finished(output: "hi\n", result: nil, error: nil, loadErrors: [])
        let out = PythonOutputFormatter.format(outcome, figures: [], limit: 1000, sessionReset: false, canView: false,
                                               network: "Network: TCP example.com:80, 10 B sent, 20 B received")
        #expect(out.text == "hi\n\n[Network: TCP example.com:80, 10 B sent, 20 B received]")
        let quiet = PythonOutputFormatter.format(outcome, figures: [], limit: 1000, sessionReset: false, canView: false)
        #expect(quiet.text == "hi")
    }
}

extension PySocketUnitTests {
    @Test func theCardShowsTheNetworkLineApart() {
        let output = "hi\n\n[Network: TCP example.com:80, 10 B sent, 20 B received]"
        #expect(PythonRunDetail.networkLine(output) == "Network: TCP example.com:80, 10 B sent, 20 B received")
        #expect(PythonRunDetail.networkLine("hi") == nil)
        #expect(PythonRunDetail.networkLine("[Network: printed by the code\nacross lines]") == nil)
    }

    @Test func theToolDescriptionTellsTheModelAboutSockets() {
        let text = ToolDefinition.runPython.function.description
        for phrase in ["TCP and UDP sockets", "TLS", "PermissionError", "ICMP", "multicast", "from the internet", "subprocess", "background"] {
            #expect(text.contains(phrase), "\(phrase)")
        }
    }
}

// MARK: - The bridge, frame by frame

@Suite(.serialized)
struct PySocketBridgeTests {
    private func call(_ bridge: PySocketBridge, _ args: [String: Any], _ payload: Data = Data()) async -> ([String: Any], Data) {
        let reply = await bridge.handle(PySocketFrame.encode(args, payload: payload))
        return PySocketFrame.decode(reply) ?? ([:], Data())
    }

    @Test func aRunsBytesAreBudgeted() async throws {
        let server = try LocalTestServer(handle: LocalTestServer.echo)
        let port = try await server.start()
        defer { server.stop() }
        let bridge = PySocketBridge(approve: { _, _, _ in true }, byteBudget: 10)
        bridge.beginRun(conversationID: UUID(), callID: "call_1")
        defer { bridge.closeAll() }
        let (connected, _) = await call(bridge, ["op": "connect", "id": 1, "kind": "tcp", "host": "127.0.0.1", "port": port, "block": true])
        #expect(connected["errno"] == nil, "\(connected)")
        let (first, _) = await call(bridge, ["op": "send", "id": 1, "block": true], Data("12345678".utf8))
        #expect((first["n"] as? NSNumber)?.intValue == 8)
        let (second, _) = await call(bridge, ["op": "send", "id": 1, "block": true], Data("12345678".utf8))
        #expect(second["errno"] as? String == "ENOBUFS")
        #expect((second["note"] as? String)?.contains("budget") == true)
        let activity = bridge.endRun()
        #expect(activity.summary()?.contains("TCP 127.0.0.1:\(port), 8 B sent") == true, "\(activity)")
    }

    @Test func atMostSixtyFourSocketsAndCloseAllEndsThem() async throws {
        let bridge = PySocketBridge(approve: { _, _, _ in true })
        bridge.beginRun(conversationID: UUID(), callID: "call_1")
        for id in 1...PySocketBridge.maxSockets {
            let (reply, _) = await call(bridge, ["op": "bind", "id": id, "kind": "udp", "host": "127.0.0.1", "port": 0])
            #expect(reply["errno"] == nil, "\(id): \(reply)")
        }
        #expect(bridge.openCount == PySocketBridge.maxSockets)
        let (over, _) = await call(bridge, ["op": "bind", "id": 999, "kind": "udp", "host": "127.0.0.1", "port": 0])
        #expect(over["errno"] as? String == "EMFILE")
        bridge.closeAll()
        #expect(bridge.openCount == 0)
        _ = bridge.endRun()
    }

    /// One UDP socket used to add a native connection per destination without limit (audit).
    @Test func udpPeersAreCappedPerInterpreter() async throws {
        let bridge = PySocketBridge(approve: { _, _, _ in true })
        bridge.beginRun(conversationID: UUID(), callID: "call_1")
        defer { bridge.closeAll(); _ = bridge.endRun() }
        // Nothing listens on these ports; a datagram to a closed loopback port just goes nowhere.
        for i in 0..<PySocketBridge.maxFlows {
            let (reply, _) = await call(bridge, ["op": "sendto", "id": 1, "host": "127.0.0.1", "port": 41_000 + i], Data("x".utf8))
            #expect(reply["errno"] == nil, "\(i): \(reply)")
        }
        let (over, _) = await call(bridge, ["op": "sendto", "id": 2, "host": "127.0.0.1", "port": 40_999], Data("x".utf8))
        #expect(over["errno"] as? String == "ENOBUFS")
        #expect((over["note"] as? String)?.contains("UDP") == true)
        // An existing peer still works.
        let (again, _) = await call(bridge, ["op": "sendto", "id": 1, "host": "127.0.0.1", "port": 41_000], Data("x".utf8))
        #expect(again["errno"] == nil, "\(again)")
        bridge.closeAll()
        #expect(bridge.openFlows == 0)
    }

    @Test func localHostsAreAskedOncePerRunAndARefusalSticks() async throws {
        let server = try LocalTestServer(handle: LocalTestServer.echo)
        let port = try await server.start()
        defer { server.stop() }
        let asked = TestCounter()
        let bridge = PySocketBridge(approve: { approval, _, _ in
            asked.add(approval.host)
            try? await Task.sleep(for: .milliseconds(200))
            return false
        })
        bridge.beginRun(conversationID: UUID(), callID: "call_1")
        defer { bridge.closeAll() }
        // Two connections at once share one card.
        async let a = call(bridge, ["op": "connect", "id": 1, "kind": "tcp", "host": "127.0.0.1", "port": port, "block": true])
        async let b = call(bridge, ["op": "connect", "id": 2, "kind": "tcp", "host": "127.0.0.1", "port": port, "block": true])
        let (first, second) = await (a.0, b.0)
        #expect(first["errno"] as? String == "EACCES")
        #expect(second["errno"] as? String == "EACCES")
        #expect((first["note"] as? String)?.contains("did not allow") == true, "\(first)")
        // Refused for the rest of the run, without asking again.
        let (third, _) = await call(bridge, ["op": "connect", "id": 3, "kind": "tcp", "host": "127.0.0.1", "port": port, "block": true])
        #expect(third["errno"] as? String == "EACCES")
        #expect(asked.count == 1)
        #expect(asked.hosts == ["127.0.0.1"])
        _ = bridge.endRun()
    }
}

// MARK: - Python, through the real runtime

@MainActor
@Suite(.serialized)
struct PythonSocketTests {
    private static let limits = PythonLimits(run: .seconds(30), setup: .seconds(120))

    private func runtime(approve: PySocketBridge.Approver? = { _, _, _ in true }) -> PythonRuntime {
        let store = ToolImageStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("py-sock-\(UUID().uuidString)"))
        let python = PythonRuntime(images: store)
        python.approveNetwork = approve
        return python
    }

    private func run(_ python: PythonRuntime, _ code: String, chat: UUID, limits: PythonLimits = limits) async -> ToolOutput {
        await python.run(code: code, conversationID: chat, limits: limits, outputLimit: 20000, canView: false)
    }

    /// The run's output without its "[Network: …]" line.
    private func body(_ out: ToolOutput) -> String {
        out.text.components(separatedBy: "\n\n[Network: ").first ?? out.text
    }

    @Test func tcpEchoBlockingNonBlockingAndSelect() async throws {
        let server = try LocalTestServer(handle: LocalTestServer.echo)
        let port = try await server.start()
        defer { server.stop() }
        let python = runtime()
        defer { python.dispose() }
        let out = await run(python, """
        import socket, select, errno
        s = socket.create_connection(("127.0.0.1", \(port)), timeout=5)
        s.sendall(b"hello")
        print(s.recv(100))
        s.setblocking(False)
        try:
            s.recv(10)
            print("no block?")
        except BlockingIOError:
            print("would block")
        s.send(b"x" * 10)
        r, w, _ = select.select([s], [s], [], 5)
        print(len(r), len(w), s.recv(100))
        s.setblocking(True)
        f = s.makefile("rwb")
        f.write(b"line one\\nline two\\n"); f.flush()
        print(f.readline(), f.readline())
        print(s.getpeername() == ("127.0.0.1", \(port)), s.getsockname()[1] > 0)
        f.close(); s.close()

        # Non-blocking connect, as asyncio and most drivers do it.
        c = socket.socket()
        c.setblocking(False)
        print(c.connect_ex(("127.0.0.1", \(port))) in (0, errno.EINPROGRESS))
        _, w, _ = select.select([], [c], [], 5)
        print(len(w), c.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR))
        c.send(b"nb"); select.select([c], [], [], 5); print(c.recv(10))
        p = select.poll(); p.register(c, select.POLLIN); print(p.poll(50))
        c.close()
        """, chat: UUID())
        #expect(!out.isError, "\(out.text)")
        #expect(body(out) == """
        b'hello'
        would block
        1 1 b'xxxxxxxxxx'
        b'line one\\n' b'line two\\n'
        True True
        True
        1 0
        b'nb'
        []
        """, "\(out.text)")
        #expect(out.text.contains("[Network: TCP 127.0.0.1:\(port), "), "\(out.text)")
    }

    @Test func udpEchoAndPeers() async throws {
        let server = try LocalTestServer(.udp, handle: LocalTestServer.echoDatagrams)
        let port = try await server.start()
        defer { server.stop() }
        let python = runtime()
        defer { python.dispose() }
        let out = await run(python, """
        import socket
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        u.settimeout(5)
        u.sendto(b"ping", ("127.0.0.1", \(port)))
        data, peer = u.recvfrom(100)
        print(data, peer == ("127.0.0.1", \(port)))
        u.sendto(b"a" * 1200, ("127.0.0.1", \(port)))
        print(len(u.recv(4096)))
        u.close()
        c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        c.settimeout(5)
        c.connect(("127.0.0.1", \(port)))
        c.send(b"connected")
        print(c.recv(100))
        c.close()
        """, chat: UUID())
        #expect(!out.isError, "\(out.text)")
        #expect(body(out) == "b'ping' True\n1200\nb'connected'", "\(out.text)")
        #expect(out.text.contains("UDP 127.0.0.1:\(port)"), "\(out.text)")
    }

    @Test func timeoutsAndRefusedConnections() async throws {
        let server = try LocalTestServer(handle: LocalTestServer.silent)
        let port = try await server.start()
        defer { server.stop() }
        let closed = try LocalTestServer(handle: LocalTestServer.silent)
        let closedPort = try await closed.start()
        closed.stop()
        try await Task.sleep(for: .milliseconds(200))
        let python = runtime()
        defer { python.dispose() }
        let out = await run(python, """
        import socket, time
        s = socket.create_connection(("127.0.0.1", \(port)), timeout=5)
        s.settimeout(0.5)
        t = time.monotonic()
        try:
            s.recv(10)
        except TimeoutError as e:
            print("timeout", type(e).__name__, round(time.monotonic() - t, 1) >= 0.4)
        s.close()
        try:
            socket.create_connection(("127.0.0.1", \(closedPort)), timeout=5)
        except ConnectionRefusedError as e:
            print("refused", e.errno)
        """, chat: UUID())
        #expect(!out.isError, "\(out.text)")
        #expect(body(out).hasPrefix("timeout TimeoutError True\nrefused "), "\(out.text)")
    }

    @Test func httpByHandAndWithHTTPClient() async throws {
        let server = try LocalTestServer(handle: LocalTestServer.http)
        let port = try await server.start()
        defer { server.stop() }
        let python = runtime()
        defer { python.dispose() }
        let out = await run(python, """
        import socket, http.client
        s = socket.create_connection(("127.0.0.1", \(port)))
        s.sendall(b"GET /hand HTTP/1.1\\r\\nHost: test\\r\\nConnection: close\\r\\n\\r\\n")
        chunks = []
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
        s.close()
        response = b"".join(chunks)
        print(response.split(b"\\r\\n")[0], response.split(b"\\r\\n\\r\\n")[1])
        conn = http.client.HTTPConnection("127.0.0.1", \(port), timeout=5)
        conn.request("POST", "/client", body=b"x")
        r = conn.getresponse()
        print(r.status, r.read())
        """, chat: UUID())
        #expect(!out.isError, "\(out.text)")
        #expect(body(out) == "b'HTTP/1.1 200 OK' b'you sent: GET /hand HTTP/1.1'\n200 b'you sent: POST /client HTTP/1.1'", "\(out.text)")
    }

    @Test func bindListenAcceptRoundTripNeedsNoApproval() async throws {
        let asked = TestCounter()
        let python = runtime(approve: { approval, _, _ in
            asked.add(approval.host)
            return false
        })
        defer { python.dispose() }
        let out = await run(python, """
        import socket
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 0))
        srv.listen()
        port = srv.getsockname()[1]
        c = socket.create_connection(("127.0.0.1", port), timeout=5)
        srv.settimeout(5)
        conn, addr = srv.accept()
        c.sendall(b"to server")
        print(conn.recv(100), addr[0])
        conn.sendall(b"to client")
        print(c.recv(100))
        conn.close()
        print(c.recv(100))
        c.close(); srv.close()
        """, chat: UUID())
        #expect(!out.isError, "\(out.text)")
        #expect(body(out) == "b'to server' 127.0.0.1\nb'to client'\nb''", "\(out.text)")
        #expect(asked.count == 0)
    }

    @Test func tlsWithATestCA() async throws {
        let server = try LocalTestServer(try TestTLS.parameters(), handle: LocalTestServer.echo)
        let port = try await server.start()
        defer { server.stop() }
        let python = runtime()
        defer { python.dispose() }
        let ca = TestTLS.caPEM.replacingOccurrences(of: "\n", with: "\\n")
        let out = await run(python, """
        import socket, ssl
        CA = "\(ca)"
        ctx = ssl.create_default_context(cadata=CA)
        ctx.set_alpn_protocols(["echo/1"])
        with socket.create_connection(("localhost", \(port)), timeout=10) as raw:
            with ctx.wrap_socket(raw, server_hostname="localhost") as s:
                s.sendall(b"secret")
                print(s.recv(100), s.version() in ("TLSv1.2", "TLSv1.3"), s.selected_alpn_protocol())
                print(dict(x[0] for x in s.getpeercert()["subject"]))
        try:
            with socket.create_connection(("localhost", \(port)), timeout=10) as raw:
                ssl.create_default_context().wrap_socket(raw, server_hostname="localhost")
        except ssl.SSLCertVerificationError:
            print("untrusted")
        insecure = ssl.create_default_context()
        insecure.check_hostname = False
        insecure.verify_mode = ssl.CERT_NONE
        with insecure.wrap_socket(socket.create_connection(("127.0.0.1", \(port)), timeout=10)) as s:
            s.sendall(b"unchecked"); print(s.recv(100))
        """, chat: UUID())
        #expect(!out.isError, "\(out.text)")
        #expect(body(out) == "b'secret' True echo/1\n{'commonName': 'localhost'}\nuntrusted\nb'unchecked'", "\(out.text)")
    }

    @Test func asyncioStreamsOnBothLoops() async throws {
        let server = try LocalTestServer(handle: LocalTestServer.echo)
        let port = try await server.start()
        defer { server.stop() }
        let tls = try LocalTestServer(try TestTLS.parameters(), handle: LocalTestServer.echo)
        let tlsPort = try await tls.start()
        defer { tls.stop() }
        let python = runtime()
        defer { python.dispose() }
        let chat = UUID()
        let ca = TestTLS.caPEM.replacingOccurrences(of: "\n", with: "\\n")
        let setup = await run(python, """
        import asyncio, ssl
        async def echo(data, port=\(port), **kw):
            r, w = await asyncio.wait_for(asyncio.open_connection("127.0.0.1", port, **kw), 10)
            w.write(data)
            await w.drain()
            got = await asyncio.wait_for(r.read(100), 10)
            w.close()
            await w.wait_closed()
            return got
        ctx = ssl.create_default_context(cadata="\(ca)")
        """, chat: chat)
        #expect(!setup.isError, "\(setup.text)")
        // Top-level await runs on the page's loop; asyncio.run makes a selector loop.
        let top = await run(python, "print(await echo(b'top-level'))\nprint(await asyncio.gather(echo(b'a'), echo(b'b')))", chat: chat)
        #expect(body(top) == "b'top-level'\n[b'a', b'b']", "\(top.text)")
        let ran = await run(python, "print(asyncio.run(echo(b'asyncio.run')))", chat: chat)
        #expect(body(ran) == "b'asyncio.run'", "\(ran.text)")
        let secure = await run(python, """
        print(await echo(b'tls top', port=\(tlsPort), ssl=ctx, server_hostname="localhost"))
        print(asyncio.run(echo(b'tls run', port=\(tlsPort), ssl=ctx, server_hostname="localhost")))
        """, chat: chat)
        #expect(body(secure) == "b'tls top'\nb'tls run'", "\(secure.text)")
        // A server in asyncio, with a client in the same loop.
        let served = await run(python, """
        async def serve():
            async def handle(r, w):
                w.write(b"hi " + await r.readline())
                await w.drain()
                w.close()
            srv = await asyncio.start_server(handle, "127.0.0.1", 0)
            port = srv.sockets[0].getsockname()[1]
            r, w = await asyncio.open_connection("127.0.0.1", port)
            w.write(b"there\\n")
            data = await r.read()
            w.close()
            srv.close()
            await srv.wait_closed()
            return data
        print(asyncio.run(serve()))
        print(await serve())
        """, chat: chat)
        #expect(body(served) == "b'hi there\\n'\nb'hi there\\n'", "\(served.text)")
        // The page's loop still settles JavaScript promises and timers (pyfetch relies on it).
        let promise = await run(python, "import js\nawait asyncio.sleep(0.05)\nprint(await js.Promise.resolve(7))", chat: chat)
        #expect(body(promise) == "7", "\(promise.text)")
        // UDP in asyncio.
        let datagrams = await run(python, """
        class Echo(asyncio.DatagramProtocol):
            def __init__(self):
                self.got = asyncio.get_running_loop().create_future()
            def datagram_received(self, data, addr):
                self.got.set_result(data)
        async def udp():
            loop = asyncio.get_running_loop()
            server, _ = await loop.create_datagram_endpoint(lambda: Echo(), local_addr=("127.0.0.1", 0))
            port = server.get_extra_info("sockname")[1]
            client, proto = await loop.create_datagram_endpoint(Echo, remote_addr=("127.0.0.1", port))
            client.sendto(b"dgram")
            server.close()
            client.close()
            return port > 0
        print(await udp())
        """, chat: chat)
        #expect(body(datagrams) == "True", "\(datagrams.text)")
    }

    @Test func smtplibSendsMail() async throws {
        let server = try LocalTestServer(handle: LocalTestServer.smtp)
        let port = try await server.start()
        defer { server.stop() }
        let python = runtime()
        defer { python.dispose() }
        let out = await run(python, """
        import smtplib
        from email.message import EmailMessage
        msg = EmailMessage()
        msg["From"] = "a@test.local"; msg["To"] = "b@test.local"; msg["Subject"] = "Greetings"
        msg.set_content("Hello from Pyodide")
        with smtplib.SMTP("127.0.0.1", \(port), timeout=10) as smtp:
            print(smtp.send_message(msg))
        """, chat: UUID())
        #expect(!out.isError, "\(out.text)")
        #expect(body(out) == "{}", "\(out.text)")
        let log = String(decoding: server.log, as: UTF8.self)
        #expect(log.contains("Subject: Greetings"), "\(log)")
        #expect(log.contains("Hello from Pyodide"))
        #expect(log.lowercased().contains("rcpt to:<b@test.local>"))
    }

    @Test func aLocalHostIsAskedOnceAndARefusalRaisesPermissionError() async throws {
        let server = try LocalTestServer(handle: LocalTestServer.echo)
        let port = try await server.start()
        defer { server.stop() }
        let python = runtime(approve: nil) // cards in the chat, answered below
        defer { python.dispose() }
        let approvals = ToolApprovals.shared
        let allowed = UUID(), refused = UUID()
        var cards: [ToolApprovals.Request] = []
        let answering = Task { @MainActor in
            while !Task.isCancelled {
                for request in approvals.all where request.conversationID == allowed || request.conversationID == refused {
                    cards.append(request)
                    approvals.answer(request.id, .network(request.conversationID == allowed))
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { answering.cancel() }
        let code = "import socket\ns = socket.create_connection(('127.0.0.1', \(port)), timeout=5)\ns.sendall(b'ok')\nprint(s.recv(10))\ns.close()"
        let first = await ToolContext.$callID.withValue("call_a") { await run(python, code, chat: allowed) }
        #expect(body(first) == "b'ok'", "\(first.text)")
        let second = await ToolContext.$callID.withValue("call_b") { await run(python, code, chat: allowed) }
        #expect(body(second) == "b'ok'", "\(second.text)")
        #expect(cards.count == 1)
        if case .network(let approval) = cards.first?.kind {
            #expect(approval.host == "127.0.0.1")
            #expect(approval.port == port)
            #expect(approval.proto == "TCP")
        } else {
            Issue.record("expected a network card, got \(cards)")
        }
        #expect(cards.first?.callID == "call_a")

        let denied = await ToolContext.$callID.withValue("call_c") {
            await run(python, "import socket\ntry:\n    socket.create_connection(('127.0.0.1', \(port)), timeout=5)\nexcept PermissionError as e:\n    print('PermissionError', e.errno)", chat: refused)
        }
        #expect(body(denied).contains("PermissionError"), "\(denied.text)")
        #expect(denied.text.contains("The user did not allow connecting to 127.0.0.1:\(port)."), "\(denied.text)")
        #expect(cards.count == 2)
    }

    @Test func limitsHoldAndAResetClosesEverySocket() async throws {
        let server = try LocalTestServer(handle: LocalTestServer.echo)
        let port = try await server.start()
        defer { server.stop() }
        let python = runtime()
        defer { python.dispose() }
        let chat = UUID()
        let out = await run(python, """
        import socket, errno
        socks = []
        try:
            for _ in range(100):
                socks.append(socket.socket())
        except OSError as e:
            print(len(socks), e.errno == errno.EMFILE)
        for s in socks:
            s.close()
        try:
            socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
        except PermissionError:
            print("no raw sockets")
        try:
            socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b"x", ("224.0.0.251", 5353))
        except PermissionError:
            print("no multicast")
        kept = [socket.create_connection(("127.0.0.1", \(port)), timeout=5) for _ in range(3)]
        """, chat: chat)
        // The bridge's note says why, between the run's own lines.
        #expect(body(out).hasPrefix("""
        64 True
        no raw sockets
        [Network] Multicast and broadcast need an entitlement from Apple that OpenChat doesn't have.
        no multicast
        """), "\(out.text)")
        #expect(python.testHost?.sockets?.openCount == 3)
        // A run past its limit resets the interpreter, and its sockets close with it.
        let slow = await run(python, "while True: pass", chat: chat, limits: PythonLimits(run: .seconds(2), setup: .seconds(120)))
        #expect(slow.text.contains("Timed out"), "\(slow.text)")
        #expect(python.testHost?.sockets?.openCount ?? 0 == 0)
    }
}
