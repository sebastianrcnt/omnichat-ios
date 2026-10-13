import Foundation

/// What running a plugin needs of a web page beyond a fetch, so it can be tested with a fake.
@MainActor
protocol PluginPage: FetchablePage {
    /// Runs a function body that may `await`, and returns its string result; throws `WebToolError.timeout` after `timeout`.
    func callAsync(_ body: String, timeout: Duration) async throws -> String
    /// Stops waiting for a pending `load` without stopping the page (it keeps loading while the plugin runs).
    func abandonLoad()
}

/// A time limit that ran out while running a plugin, and which one.
struct PluginTimeout: Error, Equatable {
    var what: String
    var limit: Duration
}

/// Load the plugin's page, wait until it is usable, run the plugin.
enum PluginPipeline {
    static let pollInterval: Duration = .milliseconds(150)

    @MainActor
    private final class LoadState { var result: Result<Void, Error>? }

    /// - Parameters:
    ///   - navigate: starts the page; by default `page.load(url, timeout: timeouts.load)` (tests load literal HTML).
    /// - Returns: the invocation's JSON (see `PluginScript.format`).
    ///
    /// Some pages never finish loading (a long poll, a stuck tracker, an app-style page). The page is polled from the
    /// start: once the document is parsed and `waitFor` (if any) matches, the plugin runs without waiting for the
    /// load to end, and when the load limit passes it runs on whatever has arrived rather than failing.
    @MainActor
    static func run(_ plugin: WebPlugin, url: URL, arguments: String, page: some PluginPage,
                    timeouts: FetchTimeouts, maxCharacters: Int,
                    navigate: (@MainActor () async throws -> Void)? = nil,
                    progress: @escaping @MainActor (Double) -> Void = { _ in }) async throws -> String {
        let waitFor = plugin.manifest.waitFor
        let probe = PluginScript.probe(waitFor: waitFor)
        let state = LoadState()
        progress(0)
        page.onProgress = { progress(FetchProgress.loading($0)) }
        defer { page.onProgress = nil }
        let start = navigate ?? { try await page.load(url, timeout: timeouts.load) }
        Task { @MainActor in
            do { try await start(); state.result = .success(()) } catch { state.result = .failure(error) }
        }
        // Whatever ends the wait, the load stops being waited for (the page itself is stopped by its owner).
        defer { if state.result == nil { page.abandonLoad() } }

        let started = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            var loadTimedOut = false
            switch state.result {
            case .failure(let error as WebToolError) where error == .timeout: loadTimedOut = true
            case .failure(let error): throw error // a failed navigation, or a redirect the URL guard refused
            default: break
            }
            let limitHit = loadTimedOut || ContinuousClock.now - started >= timeouts.load
            let seen = (try? await page.evaluate(probe, timeout: timeouts.probe)).flatMap(PluginScript.Probe.decode)
            if let seen, seen.isReady(waitFor: waitFor) { break }
            if limitHit {
                // Run on what arrived, as long as the page is there at all.
                guard seen?.committed == true else { throw PluginTimeout(what: "loading the plugin's page", limit: timeouts.load) }
                break
            }
            try await Task.sleep(for: pollInterval)
        }
        progress(FetchProgress.loaded)

        let settle = plugin.manifest.settle.map { Duration.milliseconds(Int(($0 * 1000).rounded())) } ?? timeouts.settle
        try await Task.sleep(for: settle)
        progress(FetchProgress.extracting)
        do {
            let json = try await page.callAsync(PluginScript.invocation(plugin, arguments: arguments, maxCharacters: maxCharacters),
                                                timeout: timeouts.script)
            progress(FetchProgress.done)
            return json
        } catch WebToolError.timeout {
            throw PluginTimeout(what: "the plugin script", limit: timeouts.script)
        }
    }
}

/// Runs one plugin and returns the invocation's JSON. The real one uses a pooled hidden web view.
/// The arguments are the resolved JSON object.
typealias PluginExecutor = @MainActor @Sendable (WebPlugin, URL, String) async throws -> String

/// `run_plugin`: looks the plugin up, checks its arguments and page URL, runs it under the fetch deadline.
struct RunPluginTool {
    var registry: PluginRegistry = .bundled
    /// Names turned on in Settings.
    var enabled: Set<String> = AppSettings.currentEnabledPlugins
    var resolver: any HostResolving = SystemHostResolver()
    /// Characters of result returned (Settings > Fetch length, as for `web_fetch`).
    var limit: Int = AppSettings.currentFetchLength
    var timeouts = FetchTimeouts.current
    /// Test seam; `nil` runs in the hidden web view.
    var executor: PluginExecutor?

    /// - Parameter arguments: the plugin's args, a JSON object string ("" for none).
    @MainActor
    func run(name: String, arguments: String) async -> ToolOutput {
        let started = ContinuousClock.now
        do {
            return try await Deadline.run(timeouts.overall) { try await self.execute(name: name, arguments: arguments) }
        } catch is CancellationError {
            return ToolOutput(text: "Error: cancelled.", isError: true)
        } catch WebToolError.timeout {
            let text = WebToolError.timeoutMessage(after: ContinuousClock.now - started, limit: timeouts.overall, what: "the whole plugin run")
            return ToolOutput(text: "Error: \(text)", isError: true)
        } catch let timeout as PluginTimeout {
            let text = WebToolError.timeoutMessage(after: ContinuousClock.now - started, limit: timeout.limit, what: timeout.what)
            return ToolOutput(text: "Error: \(text)", isError: true)
        } catch {
            return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true)
        }
    }

    @MainActor
    private func execute(name: String, arguments: String) async throws -> ToolOutput {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let plugin = registry.plugin(named: trimmed), enabled.contains(trimmed) else {
            throw PluginError.unknown(trimmed, available: registry.enabled(enabled).map(\.name))
        }
        let args = try plugin.manifest.resolveArguments(arguments)
        let url = try plugin.manifest.pageURL(arguments: args)
        let host = url.host(percentEncoded: false) ?? ""
        guard PluginManifest.hostAllowed(host, hosts: plugin.manifest.hosts) else {
            throw PluginError.hostNotAllowed(host, plugin: plugin.name)
        }
        try await URLGuard.validate(url, resolver: resolver)

        let run = executor ?? Self.runWithWebView(resolver: resolver, timeouts: timeouts, limit: limit)
        let json = try await run(plugin, url, PluginManifest.json(args))
        // Formatting a long result is not main-thread work.
        let limit = limit
        let out = try await Task.detached(priority: .userInitiated) { try PluginScript.format(json: json, plugin: plugin, limit: limit) }.value
        return ToolOutput(text: out.text, sources: [SourceCandidate(title: out.title, url: out.url.isEmpty ? url.absoluteString : out.url,
                                                                    content: out.content)])
    }

    /// The real executor: a pooled hidden web view (navigations guarded like a fetch). Progress goes to `ToolProgress`.
    @MainActor
    static func runWithWebView(resolver: any HostResolving, timeouts: FetchTimeouts, limit: Int) -> PluginExecutor {
        { plugin, url, args in
            let pool = WebViewPool.shared
            let view = pool.acquire(reader: false, resolver: resolver)
            var reusable = false
            defer { pool.release(view, reusable: reusable) }
            let sink = ToolContext.progressSink
            let json = try await PluginPipeline.run(plugin, url: url, arguments: args, page: view, timeouts: timeouts,
                                                    maxCharacters: limit, progress: { sink?($0) })
            reusable = true
            return json
        }
    }
}

/// The plugin a `run_plugin` call names, and the page it opens (display only: the feed shows the call by its site).
enum PluginCall {
    static func name(in arguments: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else { return nil }
        return (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func pageURL(in arguments: String, registry: PluginRegistry = .bundled) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
              let name = obj["name"] as? String, let plugin = registry.plugin(named: name),
              let args = try? plugin.manifest.resolveArguments(obj["args"]) else { return nil }
        return (try? plugin.manifest.pageURL(arguments: args))?.absoluteString
    }
}
