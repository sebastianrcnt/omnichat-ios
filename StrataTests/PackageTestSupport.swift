import Foundation
@testable import Strata

/// Builds packages for tests from a manifest dictionary and extra files.
enum TestPackages {
    static func manifest(id: String = "com.example.demo", name: String = "Demo", namespace: String = "demo", version: String = "1.0.0",
                         extra: [String: Any] = [:]) -> [String: Any] {
        var m: [String: Any] = ["format": 1, "id": id, "name": name, "namespace": namespace, "version": version,
                                "description": "A test package."]
        for (k, v) in extra { m[k] = v }
        return m
    }

    /// A GET tool against api.example.com.
    static func getTool(_ name: String = "search", path: String = "/search", query: [String: String] = ["q": "{q}"],
                        extra: [String: Any] = [:]) -> [String: Any] {
        var t: [String: Any] = [
            "name": name, "kind": "http", "description": "Search the demo service.",
            "parameters": ["type": "object", "properties": ["q": ["type": "string", "description": "What to find"]], "required": ["q"]],
            "request": ["method": "GET", "url": "https://api.example.com" + path, "query": query],
        ]
        for (k, v) in extra { t[k] = v }
        return t
    }

    static func files(_ manifest: [String: Any], _ extra: [String: String] = [:]) throws -> [String: Data] {
        var files = ["manifest.json": try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])]
        for (path, text) in extra { files[path] = Data(text.utf8) }
        return files
    }

    static func bundle(_ manifest: [String: Any], _ extra: [String: String] = [:]) throws -> PackageBundle {
        try PackageBundle.load(files: try files(manifest, extra))
    }

    /// The package signed with `key` (base64url private key from `PackageKeys.generate`).
    static func signed(_ manifest: [String: Any], key: (privateKey: String, publicKey: String), _ extra: [String: String] = [:],
                       chain: [PackageSignature.Link]? = nil, original: String? = nil) throws -> PackageBundle {
        var m = manifest
        m["publisher"] = ["name": "Example", "key": original ?? key.publicKey]
        var files = try PackageBundle.packed(try self.files(m, extra))
        let signature = try PackageSignature.sign(checksums: files[PackageChecksums.fileName]!, with: try PackageKeys.privateKey(key.privateKey),
                                                  original: original, chain: chain)
        files[PackageSignature.fileName] = signature.encoded()
        return try PackageBundle.load(files: files)
    }

    static func installed(_ bundle: PackageBundle, trust: PackageTrust = .unsigned, namespace: String? = nil) -> InstalledPackage {
        InstalledPackage(record: PackageRecord(id: bundle.manifest.id, version: bundle.manifest.version, trust: trust,
                                               keys: bundle.verification.keys.map(\.string), namespace: namespace ?? bundle.manifest.namespace,
                                               onInNewChats: false, installedAt: .now, consents: []),
                         bundle: bundle)
    }
}

/// Resolves every host to one address (public unless told otherwise).
struct PackageTestResolver: HostResolving {
    var address = "93.184.216.34"
    func resolve(_ host: String) async -> [String] { [address] }
}

/// Answers package HTTP requests from a script keyed by `host + path`, and records what was sent.
final class PackageHTTPStub: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: String
        var headers: [String: String] = ["Content-Type": "application/json"]
        /// A redirect to this URL instead of a body.
        var location: String?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var log: [URLRequest] = []

    static func reset(_ replies: [String: Reply]) { lock.withLock { self.replies = replies; log = [] } }
    static var requests: [URLRequest] { lock.withLock { log } }

    static func configuration() -> URLSessionConfiguration {
        let c = HTTPToolRunner.ephemeral()
        c.protocolClasses = [PackageHTTPStub.self]
        return c
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let key = (url.host() ?? "") + url.path
        var logged = request
        if logged.httpBody == nil, let stream = request.httpBodyStream {
            var body = Data()
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
            stream.close()
            logged.httpBody = body
        }
        let reply = Self.lock.withLock { () -> Reply in
            Self.log.append(logged)
            return Self.replies[key] ?? Reply(status: 404, body: #"{"error":"no stub for \#(key)"}"#)
        }
        if let location = reply.location, let target = URL(string: location) {
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

