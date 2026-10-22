import Foundation
import CryptoKit

// What the Python page can load, served through the `strata-py://` scheme: the bundled runtime, Pyodide packages
// (bundled with the app and checked against the lock file's sha256), and a proxy
// that carries Python's web requests (any http(s) URL, any method). Nothing here touches WebKit, so it is tested directly.

enum Pyodide {
    /// The pinned release. The bundled core, the lock file and the CDN path must all be this version.
    static let version = "314.0.7"
    static let scheme = "strata-py"
    static let host = "app"
    static let pageURL = URL(string: "strata-py://app/index.html")!
    static let cdnBase = URL(string: "https://cdn.jsdelivr.net/pyodide/v\(version)/full/")!

    /// The page's (and the worker's) policy: scripts, workers and network requests only from the app's own scheme.
    static let contentSecurityPolicy = "default-src 'none'; script-src strata-py: 'wasm-unsafe-eval'; worker-src strata-py:; connect-src strata-py:"

    /// `Caches/PyodidePackages`: every downloaded package, all versions (Settings shows its size and clears it).
    static var packagesRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("PyodidePackages", isDirectory: true)
    }

    /// `Caches/PyodidePackages/<version>`.
    static var defaultCacheDirectory: URL { packagesRoot.appendingPathComponent(version, isDirectory: true) }

    /// The `PyRuntime` folder in the app bundle.
    static var bundleRoot: URL? { Bundle.main.url(forResource: "PyRuntime", withExtension: nil) }
}

/// The package files `pyodide-lock.json` lists, with their sha256.
struct PyodideLock: Sendable, Equatable {
    /// file name → lowercase hex sha256.
    var hashes: [String: String]

    init(hashes: [String: String]) { self.hashes = hashes }

    init(data: Data) throws {
        struct File: Decodable { var packages: [String: Package] }
        struct Package: Decodable {
            var fileName: String
            var sha256: String
            enum CodingKeys: String, CodingKey { case fileName = "file_name", sha256 }
        }
        let file = try JSONDecoder().decode(File.self, from: data)
        var out: [String: String] = [:]
        for package in file.packages.values {
            // A plain file name (a full URL would be fetched from elsewhere, which is never allowed).
            let name = package.fileName
            guard !name.contains("/"), !name.isEmpty else { continue }
            out[name] = package.sha256.lowercased()
        }
        hashes = out
    }

    func sha256(of fileName: String) -> String? { hashes[fileName] }
}

/// One response to the page.
struct PyResponse: Sendable, Equatable {
    var status: Int
    var mimeType: String
    var body: Data
    var headers: [String: String] = [:]

    static func error(_ status: Int, _ message: String) -> PyResponse {
        PyResponse(status: status, mimeType: "text/plain", body: Data(message.utf8))
    }
}

/// Which outside URLs the proxy may reach: any http(s) URL without credentials in it.
enum PyodideAllowlist {
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.user == nil, url.password == nil, url.host(percentEncoded: false)?.isEmpty == false else { return false }
        return true
    }

    /// The package sources micropip uses: the pinned Pyodide CDN release, PyPI's JSON and simple APIs, and PyPI's file host.
    static func isPackageSource(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        let path = url.path(percentEncoded: false)
        guard !path.contains("/../"), !path.hasSuffix("/..") else { return false }
        switch host {
        case "cdn.jsdelivr.net":
            return path.hasPrefix("/pyodide/v\(Pyodide.version)/full/") && path.count > "/pyodide/v\(Pyodide.version)/full/".count
        case "pypi.org":
            // /pypi/<name>/json, /pypi/<name>/<version>/json, /simple/<name>/
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            if parts.first == "pypi", parts.last == "json", (3...4).contains(parts.count) { return true }
            if parts.first == "simple", parts.count == 2 { return true }
            return false
        case "files.pythonhosted.org":
            return path.hasPrefix("/packages/")
        default:
            return false
        }
    }

    /// The package file a CDN URL names, when it is one the lock lists (served like a local package request).
    static func cdnFileName(_ url: URL) -> String? {
        guard url.host(percentEncoded: false)?.lowercased() == "cdn.jsdelivr.net" else { return nil }
        let prefix = "/pyodide/v\(Pyodide.version)/full/"
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix(prefix) else { return nil }
        let name = String(path.dropFirst(prefix.count))
        return name.contains("/") || name.isEmpty ? nil : name
    }
}

/// Downloaded package files, by name, under one directory.
struct PyodidePackageCache: Sendable {
    var directory: URL

    func url(for fileName: String) -> URL { directory.appendingPathComponent(fileName) }

    func read(_ fileName: String) -> Data? { try? Data(contentsOf: url(for: fileName), options: .mappedIfSafe) }

    func write(_ data: Data, as fileName: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: fileName), options: .atomic)
    }

    func remove(_ fileName: String) { try? FileManager.default.removeItem(at: url(for: fileName)) }

    /// Bytes on disk.
    var size: Int64 {
        guard let items = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in items {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    func clear() { try? FileManager.default.removeItem(at: directory) }
}

/// Fetches an outside URL for the server (the real one is URLSession, refusing redirects off the allowlist).
typealias PyNetworkFetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

struct PyodideServer: Sendable {
    /// The bundled `PyRuntime` folder.
    var root: URL
    var lock: PyodideLock
    var cache: PyodidePackageCache
    var fetch: PyNetworkFetch
    /// Largest download accepted through the proxy.
    var maxDownload = 200 * 1024 * 1024
    /// Python's sockets (`strata-py://app/sock`); nil refuses them.
    var sockets: PySocketBridge?

    /// The real server for the app: bundle, lock and cache directory.
    static func live() -> PyodideServer? {
        guard let root = Pyodide.bundleRoot,
              let data = try? Data(contentsOf: root.appendingPathComponent("pyodide/pyodide-lock.json")),
              let lock = try? PyodideLock(data: data) else { return nil }
        return PyodideServer(root: root, lock: lock, cache: PyodidePackageCache(directory: Pyodide.defaultCacheDirectory),
                             fetch: PyNetwork.fetch)
    }

    static func mimeType(for fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "html": "text/html"
        case "js", "mjs": "text/javascript"
        case "wasm": "application/wasm"
        case "json": "application/json"
        case "zip": "application/zip"
        case "whl": "application/zip"
        case "tar", "bz2", "gz": "application/octet-stream"
        default: "application/octet-stream"
        }
    }

    func respond(to request: URLRequest) async -> PyResponse {
        guard let url = request.url, url.scheme?.lowercased() == Pyodide.scheme,
              url.host(percentEncoded: false) == Pyodide.host else { return .error(404, "Not found") }
        let path = url.path(percentEncoded: false)
        if path == "/proxy" {
            guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "u" })?.value,
                  let target = URL(string: raw) else { return .error(400, "Bad proxy request") }
            return await proxy(target, original: request)
        }
        if path == "/sock" {
            guard let sockets else { return .error(404, "Not found") }
            let body = request.httpBody ?? request.httpBodyStream.map(Self.drain) ?? Data()
            return PyResponse(status: 200, mimeType: "application/octet-stream", body: await sockets.handle(body),
                              headers: ["Cache-Control": "no-store"])
        }
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !relative.isEmpty, !relative.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            return .error(404, "Not found")
        }
        if relative.hasPrefix("pyodide/"), lock.sha256(of: String(relative.dropFirst("pyodide/".count))) != nil {
            return await package(String(relative.dropFirst("pyodide/".count)))
        }
        // Bundled files first (the page, the worker, the core).
        let local = root.appendingPathComponent(relative)
        if let data = try? Data(contentsOf: local, options: .mappedIfSafe) {
            return PyResponse(status: 200, mimeType: Self.mimeType(for: relative), body: data, headers: Self.pageHeaders(relative))
        }
        if relative.hasPrefix("pyodide/") {
            let name = String(relative.dropFirst("pyodide/".count))
            return await package(name)
        }
        return .error(404, "Not found")
    }

    /// Pages and scripts carry the CSP (a worker's policy comes from its own response).
    static func pageHeaders(_ path: String) -> [String: String] {
        var headers = ["Cache-Control": "no-store"]
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "html" || ext == "js" || ext == "mjs" { headers["Content-Security-Policy"] = Pyodide.contentSecurityPolicy }
        return headers
    }

    /// Only bundled wheels are executable dependencies. Never consult a cache from a previous Debug build or the CDN.
    func package(_ fileName: String) async -> PyResponse {
        guard !fileName.contains("/"), let expected = lock.sha256(of: fileName),
              let data = try? Data(contentsOf: root.appendingPathComponent("pyodide/" + fileName), options: .mappedIfSafe) else {
            return .error(404, "This package isn't available in OmniChat")
        }
        guard Self.sha256(data) == expected else {
            return .error(502, "The bundled package does not match its sha256 in pyodide-lock.json.")
        }
        return PyResponse(status: 200, mimeType: Self.mimeType(for: fileName), body: data)
    }

    /// Request headers the page adds for its own origin, which mean nothing to the outside site.
    static let pageOnlyHeaders: Set<String> = ["host", "origin", "referer", "content-length", "connection"]

    /// Response headers that describe the transfer from the site, not the body handed to the page.
    static let transferHeaders: Set<String> = ["content-length", "content-encoding", "transfer-encoding", "connection",
                                              "content-security-policy", "set-cookie"]

    /// A web request from Python: any http(s) URL and method, with its headers and body; the response keeps its status and
    /// headers. Lock-listed CDN packages are served from the checked cache.
    func proxy(_ target: URL, original: URLRequest) async -> PyResponse {
        guard PyodideAllowlist.allows(target) else { return .error(400, "Python can reach http and https URLs only.") }
        let method = (original.httpMethod ?? "GET").uppercased()
        if method == "GET", let name = PyodideAllowlist.cdnFileName(target), lock.sha256(of: name) != nil { return await package(name) }
        guard !PyodideAllowlist.isPackageSource(target),
              !["whl", "wasm"].contains(target.pathExtension.lowercased()) else {
            return .error(403, "This package isn't available in OmniChat")
        }
        var request = URLRequest(url: target)
        request.httpMethod = method
        for (name, value) in original.allHTTPHeaderFields ?? [:] where !Self.pageOnlyHeaders.contains(name.lowercased()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = original.httpBody ?? original.httpBodyStream.map(Self.drain)
        do {
            let (data, response) = try await fetch(request)
            guard data.count <= maxDownload else { return .error(502, "The download is too large.") }
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                guard let name = key as? String, let value = value as? String, !Self.transferHeaders.contains(name.lowercased()) else { continue }
                headers[name] = value
            }
            headers.removeValue(forKey: "Content-Type")
            let mime = response.value(forHTTPHeaderField: "Content-Type") ?? response.mimeType ?? "application/octet-stream"
            return PyResponse(status: response.statusCode, mimeType: mime, body: data, headers: headers)
        } catch {
            return .error(502, "The request failed: \(error.localizedDescription)")
        }
    }

    private static func drain(_ stream: InputStream) -> Data {
        var data = Data()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return data
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The real network side of the proxy: an ephemeral session (no cookies kept). Like the other web tools it reaches
/// public hosts only, redirects included, so a page that talks the model into `pyfetch("http://192.168.0.1/…")` gets
/// nothing; the body is cut off past the download limit instead of being buffered whole.
enum PyNetwork {
    static let maxBytes = 200 * 1024 * 1024

    private static let configuration: URLSessionConfiguration = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        return config
    }()

    static func allowed(_ url: URL) async -> Bool {
        guard PyodideAllowlist.allows(url) else { return false }
        return (try? await URLGuard.validate(url)) != nil
    }

    static let fetch: PyNetworkFetch = { request in
        guard let url = request.url else { throw URLError(.badURL) }
        try await URLGuard.validate(url)
        let (data, response) = try await LimitedDownload.data(for: request, configuration: configuration, limit: maxBytes,
                                                              allowRedirect: { await allowed($0) })
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
