import Foundation

/// Runs a package's HTTP tool: builds the request from its manifest (`HTTPRequestBuilder`), sends it from an ephemeral
/// session (no cookies, no cache), and projects the response for the model (`ResponseProjection`). The package reaches
/// only the hosts it declared: every redirect is checked again (at most 3, never from https to http), and a private,
/// local or loopback address is refused unless the package declared `privateNetwork`. Secrets go into the request here
/// and nowhere else; every text that leaves is scrubbed of them.
struct HTTPToolRunner: Sendable {
    /// The largest body read; a bigger response fails instead of filling memory.
    static let bodyLimit = 2 * 1_048_576
    static let maxRedirects = 3

    var configuration: @Sendable () -> URLSessionConfiguration = { HTTPToolRunner.ephemeral() }
    var resolver: any HostResolving = SystemHostResolver()

    static func ephemeral() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return c
    }

    /// The prepared call: the request, and what the approval card shows of it.
    struct Prepared: Sendable {
        var request: HTTPRequestBuilder.Built
        var secrets: [String]
    }

    /// Builds the request. A failure is the text the model gets.
    static func prepare(tool: PackageTool, package: InstalledPackage, arguments: [String: PackageJSON],
                        secrets: PackageSecretStore) -> Result<Prepared, ToolFailure> {
        let manifest = package.manifest
        do throws(HTTPRequestBuilder.Failure) {
            let built = try HTTPRequestBuilder.build(tool: tool, manifest: manifest, arguments: arguments) { name in
                secrets.value(name, package: package.id)
            }
            return .success(Prepared(request: built, secrets: secrets.values(package: package.id)))
        } catch {
            switch error {
            case .missingSecret(let declaration):
                return .failure(ToolFailure(Self.missingSecret(package: package.name, label: declaration.label)))
            case .bad(let reason):
                return .failure(ToolFailure("Could not build the \(tool.name) request: \(reason)"))
            }
        }
    }

    static func missingSecret(package: String, label: String) -> String {
        "The \(package) package has no \(label) yet. Ask the user to add it in Settings › Packages › \(package)."
    }

    /// Sends the request and projects the response.
    func run(_ prepared: Prepared, tool: PackageTool, package: InstalledPackage) async -> ToolOutput {
        let built = prepared.request
        let manifest = package.manifest
        func fail(_ text: String) -> ToolOutput {
            ToolOutput(text: PackageSecretStore.scrub(text, secrets: prepared.secrets), isError: true)
        }
        guard URLTemplate.packageHostAllowed(built.host, network: manifest.network) else {
            return fail(Self.blocked(host: built.host, package: package.name))
        }
        if !manifest.privateNetwork {
            do { try await URLGuard.validate(built.url, resolver: resolver) } catch {
                return fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
        var request = URLRequest(url: built.url, timeoutInterval: TimeInterval(tool.timeoutSeconds))
        request.httpMethod = built.method
        for (name, value) in built.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = built.body
        if request.value(forHTTPHeaderField: "User-Agent") == nil { request.setValue("OmniChat", forHTTPHeaderField: "User-Agent") }

        let redirects = RedirectBudget(max: Self.maxRedirects, startsSecure: built.url.scheme?.lowercased() == "https")
        let network = manifest.network
        let checksPrivate = !manifest.privateNetwork
        let resolver = resolver
        let blockedHost = LockedValue<String?>(nil)
        let allow: LimitedDownload.RedirectCheck = { url in
            let host = url.host(percentEncoded: false) ?? ""
            guard redirects.take(url), URLTemplate.packageHostAllowed(host, network: network) else {
                blockedHost.set(host)
                return false
            }
            if checksPrivate, (try? await URLGuard.validate(url, resolver: resolver)) == nil {
                blockedHost.set(host)
                return false
            }
            return true
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await LimitedDownload.data(for: request, configuration: configuration(), limit: Self.bodyLimit,
                                                              allowRedirect: allow)
        } catch is CancellationError {
            return fail("Cancelled.")
        } catch let error as LimitedDownload.Failure {
            return fail("The response is too large: \(error.localizedDescription)")
        } catch let error as URLError where error.code == .timedOut {
            return fail("\(built.host) did not answer within \(tool.timeoutSeconds) seconds.")
        } catch {
            // A refused redirect can end the task with an error instead of the 3xx response.
            if let host = blockedHost.get() { return fail(Self.blocked(host: host, package: package.name)) }
            return fail("The request to \(built.host) failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { return fail("The request to \(built.host) failed: no HTTP response.") }
        // A refused redirect leaves the 3xx response itself.
        if (300..<400).contains(http.statusCode), let host = blockedHost.get() {
            return fail(Self.blocked(host: host, package: package.name))
        }
        guard (200..<300).contains(http.statusCode) else {
            return fail(Self.statusMessage(http.statusCode, package: package.name, body: data))
        }
        do {
            let output = try ResponseProjection.project(body: data, spec: tool.response)
            let scrub = { (text: String) in PackageSecretStore.scrub(text, secrets: prepared.secrets) }
            var result = ToolOutput(text: scrub(output.text))
            result.sources = output.sources.map { SourceCandidate(title: scrub($0.title), url: scrub($0.url), content: scrub($0.content)) }
            return result
        } catch {
            return fail("Could not read the response from \(built.host): \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
    }

    static func blocked(host: String, package: String) -> String {
        "Blocked: \(host) is not a host the \(package) package may reach."
    }

    /// What the model hears for an HTTP error, with the start of the body (already scrubbed by the caller).
    static func statusMessage(_ status: Int, package: String, body: Data) -> String {
        let reason = switch status {
        case 401, 403: "the token may be wrong or expired: ask the user to check Settings › Packages › \(package)"
        case 404: "not found"
        case 429: "rate limited: wait or narrow the request"
        case 500..<600: "the server failed"
        default: "the request was refused"
        }
        let text = String(decoding: body.prefix(2000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = text.isEmpty ? "" : "\n" + String(text.prefix(500))
        return "HTTP \(status): \(reason).\(excerpt)"
    }
}

/// A tool call's failure text, for the model.
struct ToolFailure: Error, Sendable, Equatable {
    var text: String
    init(_ text: String) { self.text = text }
}

/// Counts redirects and refuses a downgrade from https.
private final class RedirectBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int
    private let startsSecure: Bool

    init(max: Int, startsSecure: Bool) {
        left = max
        self.startsSecure = startsSecure
    }

    func take(_ url: URL) -> Bool {
        lock.withLock {
            guard left > 0 else { return false }
            let scheme = url.scheme?.lowercased()
            guard scheme == "https" || (scheme == "http" && !startsSecure) else { return false }
            left -= 1
            return true
        }
    }
}

final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}
