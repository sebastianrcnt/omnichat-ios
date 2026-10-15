import Foundation
import Testing
@testable import Strata

// MARK: - Helpers

/// A fake network for the scheme handler: canned responses by URL, every request recorded.
private final class FakeNetwork: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: (Int, Data)] = [:]
    private(set) var requested: [String] = []

    func set(_ url: String, status: Int = 200, body: Data) { lock.withLock { responses[url] = (status, body) } }
    var count: Int { lock.withLock { requested.count } }

    var fetch: PyNetworkFetch {
        { [self] request in
            let url = request.url!.absoluteString
            let canned: (Int, Data)? = lock.withLock {
                requested.append(url)
                return responses[url]
            }
            guard let (status, body) = canned else { throw URLError(.cannotConnectToHost) }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            return (body, response)
        }
    }
}

private func tempDir(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
}

private func request(_ url: String, method: String = "GET") -> URLRequest {
    var r = URLRequest(url: URL(string: url)!)
    r.httpMethod = method
    return r
}

/// A 1x1 PNG with the given IHDR size (only the header matters to the store).
private func png(width: Int, height: Int) -> Data {
    var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
    for v in [width, height] { bytes += [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    bytes += [8, 6, 0, 0, 0]
    return Data(bytes)
}

// MARK: - Scheme handler

struct PyodideServerTests {
    private let wheel = Data("numpy wheel bytes".utf8)

    private func server(network: FakeNetwork, hash: String? = nil) -> (PyodideServer, PyodidePackageCache) {
        let root = tempDir("pyroot")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("pyodide"), withIntermediateDirectories: true)
        try? Data("<html></html>".utf8).write(to: root.appendingPathComponent("index.html"))
        try? Data("core".utf8).write(to: root.appendingPathComponent("pyodide/pyodide.mjs"))
        let cache = PyodidePackageCache(directory: tempDir("pycache"))
        let lock = PyodideLock(hashes: ["numpy-2.4.6-cp314-cp314-pyemscripten_2026_0_wasm32.whl": hash ?? PyodideServer.sha256(wheel)])
        return (PyodideServer(root: root, lock: lock, cache: cache, fetch: network.fetch), cache)
    }

    private let numpyURL = "strata-py://app/pyodide/numpy-2.4.6-cp314-cp314-pyemscripten_2026_0_wasm32.whl"
    private var cdnURL: String { "https://cdn.jsdelivr.net/pyodide/v\(Pyodide.version)/full/numpy-2.4.6-cp314-cp314-pyemscripten_2026_0_wasm32.whl" }

    @Test func pythonMayReachAnyWebURLButNotOtherSchemes() {
        for url in ["https://example.com/", "http://example.com/a?b=1", "https://api.github.com/repos/x/y"] {
            #expect(PyodideAllowlist.allows(URL(string: url)!), "\(url)")
        }
        for url in ["file:///etc/passwd", "strata-py://app/index.html", "ftp://example.com/x", "https://user:pw@example.com/"] {
            #expect(!PyodideAllowlist.allows(URL(string: url)!), "\(url)")
        }
    }

    @Test func packageSourcesAreTheCDNReleaseAndPyPI() {
        let allowed = [
            "https://cdn.jsdelivr.net/pyodide/v\(Pyodide.version)/full/micropip-0.11.1-py3-none-any.whl",
            "https://pypi.org/pypi/attrs/json",
            "https://pypi.org/pypi/attrs/25.1.0/json",
            "https://pypi.org/simple/attrs/",
            "https://files.pythonhosted.org/packages/ab/cd/attrs-25.1.0-py3-none-any.whl",
        ]
        let refused = [
            "https://cdn.jsdelivr.net/pyodide/v0.27.0/full/numpy.whl", // another release
            "https://cdn.jsdelivr.net/npm/evil/x.js",
            "http://pypi.org/pypi/attrs/json", // not https
            "https://pypi.org/account/login/",
            "https://pypi.org.evil.com/pypi/attrs/json",
            "https://files.pythonhosted.org/other/x",
            "https://example.com/",
            "https://user:pw@pypi.org/pypi/attrs/json",
            "https://pypi.org:8443/pypi/attrs/json",
        ]
        for url in allowed { #expect(PyodideAllowlist.isPackageSource(URL(string: url)!), "\(url)") }
        for url in refused { #expect(!PyodideAllowlist.isPackageSource(URL(string: url)!), "\(url)") }
    }

    @Test func aPackageIsDownloadedCheckedCachedAndThenServedFromTheCache() async {
        let network = FakeNetwork()
        network.set(cdnURL, body: wheel)
        let (server, cache) = server(network: network)

        let first = await server.respond(to: request(numpyURL))
        #expect(first.status == 200)
        #expect(first.body == wheel)
        #expect(network.requested == [cdnURL])
        #expect(cache.read("numpy-2.4.6-cp314-cp314-pyemscripten_2026_0_wasm32.whl") == wheel)

        let second = await server.respond(to: request(numpyURL))
        #expect(second.status == 200)
        #expect(second.body == wheel)
        #expect(network.count == 1) // a cache hit: no second download
    }

    @Test func aDownloadThatDoesNotMatchTheLockIsRefusedAndNotCached() async {
        let network = FakeNetwork()
        network.set(cdnURL, body: Data("tampered".utf8))
        let (server, cache) = server(network: network)
        let response = await server.respond(to: request(numpyURL))
        #expect(response.status == 502)
        #expect(String(decoding: response.body, as: UTF8.self).contains("sha256"))
        #expect(cache.read("numpy-2.4.6-cp314-cp314-pyemscripten_2026_0_wasm32.whl") == nil)
    }

    @Test func aDamagedCacheEntryIsFetchedAgain() async {
        let network = FakeNetwork()
        network.set(cdnURL, body: wheel)
        let (server, cache) = server(network: network)
        cache.write(Data("corrupt".utf8), as: "numpy-2.4.6-cp314-cp314-pyemscripten_2026_0_wasm32.whl")
        let response = await server.respond(to: request(numpyURL))
        #expect(response.body == wheel)
        #expect(network.count == 1)
    }

    @Test func aFileTheLockDoesNotListIsNotFetched() async {
        let network = FakeNetwork()
        let (server, _) = server(network: network)
        let response = await server.respond(to: request("strata-py://app/pyodide/evil-1.0-py3-none-any.whl"))
        #expect(response.status == 404)
        #expect(network.count == 0)
    }

    @Test func bundledFilesAreServedWithThePolicyAndTraversalIsRefused() async {
        let (server, _) = server(network: FakeNetwork())
        let page = await server.respond(to: request("strata-py://app/index.html"))
        #expect(page.status == 200)
        #expect(page.mimeType == "text/html")
        #expect(page.headers["Content-Security-Policy"] == Pyodide.contentSecurityPolicy)
        let script = await server.respond(to: request("strata-py://app/pyodide/pyodide.mjs"))
        #expect(script.mimeType == "text/javascript")
        let escape = await server.respond(to: request("strata-py://app/pyodide/../../etc/passwd"))
        #expect(escape.status == 404)
        let otherHost = await server.respond(to: request("strata-py://evil/index.html"))
        #expect(otherHost.status == 404)
    }

    @Test func theProxyCarriesAnyWebRequest() async {
        let network = FakeNetwork()
        network.set("https://pypi.org/pypi/attrs/json", body: Data("{\"info\":{}}".utf8))
        let (server, _) = server(network: network)
        let proxied = "strata-py://app/proxy?u=" + "https://pypi.org/pypi/attrs/json".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let ok = await server.respond(to: request(proxied))
        #expect(ok.status == 200)
        #expect(ok.body == Data("{\"info\":{}}".utf8))

        network.set("https://example.com/x", body: Data("hi".utf8))
        let other = "strata-py://app/proxy?u=" + "https://example.com/x".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let reached = await server.respond(to: request(other))
        #expect(reached.status == 200)
        #expect(reached.body == Data("hi".utf8))
        let post = await server.respond(to: request(proxied, method: "POST"))
        #expect(post.status == 200)
        let file = "strata-py://app/proxy?u=" + "file:///etc/hosts".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(await server.respond(to: request(file)).status == 400)
        #expect(network.requested == ["https://pypi.org/pypi/attrs/json", "https://example.com/x", "https://pypi.org/pypi/attrs/json"])
    }

    @Test func aCDNRequestThroughTheProxyIsCheckedAgainstTheLock() async {
        let network = FakeNetwork()
        network.set(cdnURL, body: Data("tampered".utf8))
        let (server, _) = server(network: network)
        let proxied = "strata-py://app/proxy?u=" + cdnURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let response = await server.respond(to: request(proxied))
        #expect(response.status == 502)
    }

    @Test func theBundledLockMatchesThePinnedRelease() throws {
        let root = try #require(Pyodide.bundleRoot)
        let data = try Data(contentsOf: root.appendingPathComponent("pyodide/pyodide-lock.json"))
        let lock = try PyodideLock(data: data)
        #expect(lock.hashes.keys.contains { $0.hasPrefix("numpy-") })
        #expect(lock.hashes.keys.contains { $0.hasPrefix("sympy-") })
        #expect(lock.hashes.values.allSatisfy { $0.count == 64 })
        for file in ["pyodide.mjs", "pyodide.asm.mjs", "pyodide.asm.wasm", "python_stdlib.zip", "LICENSE"] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("pyodide/\(file)").path), "\(file)")
        }
        let package = try String(contentsOf: root.appendingPathComponent("pyodide/pyodide.mjs"), encoding: .utf8)
        #expect(package.contains(Pyodide.version))
    }
}

// MARK: - Output

struct PythonOutputFormatterTests {
    private let figure = ToolImage(id: "figure-3", width: 640, height: 480, file: "x/figure-3.png")

    @Test func outputThenTheLastValueThenTheTraceback() {
        let ok = PythonOutputFormatter.format(.finished(output: "a\nb\n", result: "42", error: nil, loadErrors: []),
                                              figures: [], limit: 1000, sessionReset: false, canView: false)
        #expect(ok.text == "a\nb\n42")
        #expect(!ok.isError)
        let failed = PythonOutputFormatter.format(.finished(output: "partial", result: nil, error: "Traceback ...\nValueError: x\n", loadErrors: []),
                                                  figures: [], limit: 1000, sessionReset: false, canView: false)
        #expect(failed.text == "partial\nTraceback ...\nValueError: x")
        #expect(failed.isError)
        let empty = PythonOutputFormatter.format(.finished(output: "", result: nil, error: nil, loadErrors: []),
                                                 figures: [], limit: 1000, sessionReset: false, canView: false)
        #expect(empty.text == "(no output)")
    }

    @Test func longOutputKeepsItsStartAndEndWithANote() {
        let text = String(repeating: "x", count: 900) + "TAIL"
        let out = PythonOutputFormatter.format(.finished(output: text, result: nil, error: nil, loadErrors: []),
                                               figures: [], limit: 100, sessionReset: false, canView: false)
        #expect(out.text.hasPrefix(String(repeating: "x", count: 75)))
        #expect(out.text.hasSuffix("TAIL"))
        #expect(out.text.contains("[Output truncated: 804 characters omitted.]"))
        #expect(PythonOutputFormatter.cap("short", limit: 100) == "short")
    }

    @Test func figuresAreListedAndViewImageIsNamedOnlyWhenUsable() {
        let viewable = PythonOutputFormatter.format(.finished(output: "", result: nil, error: nil, loadErrors: []),
                                                    figures: [figure], limit: 1000, sessionReset: false, canView: true)
        #expect(viewable.text == "Figure saved: figure-3 (640x480). Call view_image with an id to look at one.")
        #expect(viewable.figures == [figure])
        let listed = PythonOutputFormatter.format(.finished(output: "", result: nil, error: nil, loadErrors: []),
                                                  figures: [figure, figure], limit: 1000, sessionReset: false, canView: false)
        #expect(listed.text == "Figures saved: figure-3 (640x480), figure-3 (640x480).")
    }

    @Test func theFirstRunAfterAResetSaysSo() {
        let out = PythonOutputFormatter.format(.finished(output: "1", result: nil, error: nil, loadErrors: []),
                                               figures: [], limit: 1000, sessionReset: true, canView: false)
        #expect(out.text == PythonOutputFormatter.resetNote + "\n\n1")
    }

    @Test func aTimeoutTellsTheElapsedSecondsAndThatStateWasReset() {
        let out = PythonOutputFormatter.format(.timedOut(phase: "run", elapsed: .milliseconds(30_200), limit: .seconds(30)),
                                               figures: [], limit: 1000, sessionReset: false, canView: false)
        #expect(out.isError)
        #expect(out.text.hasPrefix("Error: Timed out after 30.2 s: the code has a 30 s limit."))
        #expect(out.text.contains("variables, imports and files from earlier runs are gone"))
        #expect(PythonFailure(errorText: out.text) == .timedOut)
    }

    @Test func runningOutOfMemorySaysTheSessionWasReset() {
        let out = PythonOutputFormatter.format(.outOfMemory(detail: nil), figures: [], limit: 1000, sessionReset: false, canView: false)
        #expect(out.isError)
        #expect(out.text.contains("out of memory"))
        #expect(out.text.contains("reset"))
        #expect(PythonFailure(errorText: out.text) == .outOfMemory)
    }

    @Test func thePagesReplyBecomesAnOutcome() throws {
        let limits = PythonLimits(run: .seconds(30), setup: .seconds(180))
        func outcome(_ json: String) throws -> PythonOutcome {
            PythonOutcome(reply: try JSONDecoder().decode(PythonReply.self, from: Data(json.utf8)), limits: limits)
        }
        #expect(try outcome(#"{"phase":"run","status":"timeout","fresh":false,"elapsedMs":30012}"#)
                == .timedOut(phase: "run", elapsed: .milliseconds(30012), limit: .seconds(30)))
        #expect(try outcome(#"{"phase":"load","status":"timeout","elapsedMs":180000}"#)
                == .timedOut(phase: "load", elapsed: .seconds(180), limit: .seconds(180)))
        #expect(try outcome(#"{"phase":"run","status":"ok","output":"hi\n","result":"3","figures":[]}"#)
                == .finished(output: "hi\n", result: "3", error: nil, loadErrors: []))
        #expect(try outcome(#"{"phase":"run","status":"crashed","message":"RangeError"}"#) == .outOfMemory(detail: "RangeError"))
        #expect(try outcome(#"{"phase":"init","status":"error","message":"no wasm"}"#) == .failed("no wasm"))
        #expect(PythonOutcome.timedOut(phase: "run", elapsed: .zero, limit: .zero).lostState)
        #expect(!PythonOutcome.failed("x").lostState)
    }

    @Test func failureLabels() {
        #expect(PythonFailure(errorText: "Traceback (most recent call last):\nZeroDivisionError") == .exception)
        #expect(PythonFailure(errorText: "Error: Python could not run: x") == .failed)
        #expect(PythonFailure(errorText: "Error: no image with id \"figure-9\".") == .failed)
    }
}

// MARK: - Session

struct PythonSessionLedgerTests {
    private let a = UUID(), b = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func anotherChatTakesTheInterpreterOver() {
        var ledger = PythonSessionLedger()
        let r1 = ledger.claim(a, now: t0)
        #expect(!r1)
        let r2 = ledger.claim(a, now: t0)
        #expect(!r2)
        let r3 = ledger.claim(b, now: t0)
        #expect(r3)
        #expect(ledger.owner == b)
    }

    @Test func theResetNoteComesOnceAfterALossTheModelWasNotToldAbout() {
        var ledger = PythonSessionLedger()
        // First ever run: fresh, but nothing was lost.
        let r4 = ledger.finishRun(a, fresh: true, hadSession: false, lostState: false, now: t0)
        #expect(!r4)
        let r5 = ledger.finishRun(a, fresh: false, hadSession: true, lostState: false, now: t0)
        #expect(!r5)
        // Disposed (idle, another chat): the next run is fresh and says so, once.
        ledger.disposed()
        let r6 = ledger.finishRun(a, fresh: true, hadSession: true, lostState: false, now: t0)
        #expect(r6)
        let r7 = ledger.finishRun(a, fresh: false, hadSession: true, lostState: false, now: t0)
        #expect(!r7)
        // A timeout already told the model: no second note on the next fresh run.
        let r8 = ledger.finishRun(a, fresh: false, hadSession: true, lostState: true, now: t0)
        #expect(!r8)
        let r9 = ledger.finishRun(a, fresh: true, hadSession: true, lostState: false, now: t0)
        #expect(!r9)
        // ...but a later loss it was not told about is noted again.
        let r10 = ledger.finishRun(a, fresh: true, hadSession: true, lostState: false, now: t0)
        #expect(r10)
    }

    @Test func idleAfterTenMinutes() {
        var ledger = PythonSessionLedger()
        #expect(!ledger.isIdle(now: t0))
        _ = ledger.claim(a, now: t0)
        _ = ledger.finishRun(a, fresh: true, hadSession: false, lostState: false, now: t0)
        #expect(!ledger.isIdle(now: t0.addingTimeInterval(599)))
        #expect(ledger.isIdle(now: t0.addingTimeInterval(600)))
        ledger.disposed()
        #expect(!ledger.isIdle(now: t0.addingTimeInterval(6000)))
    }

    @Test func switchingChatsDisposesUnlessTheOwnersReplyIsRunning() {
        var ledger = PythonSessionLedger()
        #expect(!ledger.shouldDispose(onSwitchTo: b))
        _ = ledger.claim(a, now: t0)
        #expect(!ledger.shouldDispose(onSwitchTo: a))
        #expect(ledger.shouldDispose(onSwitchTo: b))
        #expect(ledger.shouldDispose(onSwitchTo: nil))
        #expect(!ledger.shouldDispose(onSwitchTo: b, busy: a))
    }

}

// MARK: - Tool list

@MainActor
struct PythonToolListTests {
    @Test func theListDependsOnlyOnTheSettingAndTheModel() throws {
        #expect(ToolDefinition.available(python: false, images: true) == ToolDefinition.standard)
        #expect(ToolDefinition.available(python: false, images: false) == ToolDefinition.standard)
        #expect(ToolDefinition.available(python: true, images: false).map(\.function.name)
                == ["web_search", "web_fetch", "run_plugin", "run_python"])
        #expect(ToolDefinition.available(python: true, images: true).map(\.function.name)
                == ["web_search", "web_fetch", "run_plugin", "run_python", "view_image"])
        for python in [false, true] {
            for images in [false, true] {
                let a = try ChatRequest.encoder.encode(ToolDefinition.available(python: python, images: images))
                let b = try ChatRequest.encoder.encode(ToolDefinition.available(python: python, images: images))
                #expect(a == b)
            }
        }
    }

    @Test func theDescriptionsHoldNoDatesOrCounts() {
        for tool in [ToolDefinition.runPython, ToolDefinition.viewImage] {
            let text = tool.function.description
            #expect(text.range(of: #"\b(19|20)\d\d\b"#, options: .regularExpression) == nil, "\(text)")
        }
        #expect(ToolDefinition.runPython.function.description.contains("numpy"))
        #expect(ToolDefinition.runPython.function.description.contains("persist"))
    }

    private func endpoint(images: Bool) -> Endpoint {
        Endpoint(connectionID: UUID(), connectionName: "t", baseURL: URL(string: "http://localhost/v1")!, apiKey: nil, headers: [:],
                 model: ModelInfo(id: "m", supportsImages: images, supportsTools: true))
    }

    @Test func theRunnerSendsPythonOnlyWhenOnAndViewImageOnlyToAnImageModel() async throws {
        for (python, images, expected) in [(false, true, 3), (true, false, 4), (true, true, 5)] {
            let streamer = ScriptedStreamer([[ChatDelta(content: "ok")]])
            var runner = TurnRunner(streamer: streamer, tools: FakeTools())
            runner.python = python
            _ = try await runner.run(endpoint: endpoint(images: images), messages: [.user("hi")], effort: nil) { _ in }
            #expect(streamer.requests.first?.tools?.count == expected)
        }
    }
}

// MARK: - view_image

@MainActor
struct ViewImageTests {
    private func store() -> ToolImageStore { ToolImageStore(root: tempDir("images")) }

    @Test func figuresGetIdsThatAreUniqueWithinTheChat() {
        let store = store()
        let chat = UUID(), other = UUID()
        let one = store.addFigure(png: png(width: 640, height: 480), conversationID: chat)
        let two = store.addFigure(png: png(width: 800, height: 600), conversationID: chat)
        let elsewhere = store.addFigure(png: png(width: 10, height: 10), conversationID: other)
        #expect(one?.id == "figure-1")
        #expect(two?.id == "figure-2")
        #expect(two?.listing == "figure-2 (800x600)")
        #expect(elsewhere?.id == "figure-1")
        #expect(store.image(id: "figure-2", conversationID: chat) == two)
        #expect(store.image(id: "figure-2", conversationID: other) == nil)
        #expect(store.image(id: "../figure-1", conversationID: chat) == nil)
        store.removeAll(conversationID: chat)
        #expect(store.figureIDs(conversationID: chat).isEmpty)
    }

    @Test func theToolAttachesAStoredFigure() throws {
        let store = store()
        let chat = UUID()
        let figure = try #require(store.addFigure(png: png(width: 640, height: 480), conversationID: chat))
        let tool = ViewImageTool(store: store)
        let out = tool.run(id: "figure-1", conversationID: chat, readsImages: true)
        #expect(out.text == "figure-1 (640x480) is attached in the next message.")
        #expect(out.viewedImage == figure)
        let missing = tool.run(id: "figure-7", conversationID: chat, readsImages: true)
        #expect(missing.isError)
        #expect(missing.text.contains("Available: figure-1."))
        let blind = tool.run(id: "figure-1", conversationID: chat, readsImages: false)
        #expect(blind.isError)
    }

    @Test func theImageFollowsTheToolResultsInOneUserMessageAndIsRebuiltIdentically() throws {
        let store = store()
        let chat = UUID()
        let figure = try #require(store.addFigure(png: png(width: 640, height: 480), conversationID: chat))
        let calls = [ToolCall(id: "c1", name: "run_python", arguments: "{\"code\":\"plot()\"}"),
                     ToolCall(id: "c2", name: "view_image", arguments: "{\"id\":\"figure-1\"}")]
        let outputs = [ToolOutput(text: "Figure saved: figure-1 (640x480).", figures: [figure]),
                       ToolOutput(text: "figure-1 (640x480) is attached in the next message.", viewedImage: figure)]
        var live: [APIMessage] = [.user("plot it")]
        MessageAssembler.appendToolRound(to: &live, assistantContent: "", calls: calls, results: outputs, images: store)
        #expect(live.map(\.role) == ["user", "assistant", "tool", "tool", "user"])
        let url = try #require(store.dataURL(file: figure.file))
        #expect(url.hasPrefix("data:image/png;base64,"))
        #expect(live[4].content == .parts([.text("[view_image: figure-1, 640x480]"), .imageURL(url)]))

        // Saved records replay to the same bytes on every later request.
        var records = zip(calls, outputs).map { call, out in
            var r = ToolCallRecord(id: call.id, name: call.name, arguments: call.arguments, result: out.text, isError: false)
            r.figures = out.figures.isEmpty ? nil : out.figures
            r.viewedImage = out.viewedImage
            return r
        }
        let decoded = try JSONDecoder().decode([ToolCallRecord].self, from: JSONEncoder().encode(records))
        #expect(decoded == records)
        records = decoded
        var replay: [APIMessage] = [.user("plot it")]
        MessageAssembler.appendToolRound(to: &replay, assistantContent: "", calls: records.map(\.toolCall),
                                         results: records.map(\.output), images: store)
        #expect(try ChatRequest.encoder.encode(replay) == ChatRequest.encoder.encode(live))
    }

    @Test func aModelWithoutImageInputGetsTheFixedNote() throws {
        let store = store()
        let figure = try #require(store.addFigure(png: png(width: 64, height: 48), conversationID: UUID()))
        var messages: [APIMessage] = []
        MessageAssembler.appendToolRound(to: &messages, assistantContent: "", calls: [ToolCall(id: "c", name: "view_image", arguments: "{}")],
                                         results: [ToolOutput(text: "attached", viewedImage: figure)], readsImages: false, images: store)
        #expect(messages.last == .user("[view_image: figure-1, 64x48]\n" + MessageAssembler.omittedImageNote))
    }

    @Test func historyGoesThroughTheAssemblerWithTheSameRules() throws {
        let store = ToolImageStore.shared
        let chat = UUID()
        defer { store.removeAll(conversationID: chat) }
        let figure = try #require(store.addFigure(png: png(width: 64, height: 48), conversationID: chat))
        var record = ToolCallRecord(id: "c", name: "view_image", arguments: "{\"id\":\"figure-1\"}", result: "attached", isError: false)
        record.viewedImage = figure
        let history = [HistoryMessage(role: "user", text: "q"),
                       HistoryMessage(role: "assistant", text: "It rises.", steps: [ToolStep(assistantContent: "", calls: [record])])]
        let seeing = MessageAssembler.apiMessages(from: history)
        #expect(seeing.map(\.role) == ["user", "assistant", "tool", "user", "assistant"])
        if case .parts(let parts) = seeing[3].content { #expect(parts.count == 2) } else { Issue.record("expected parts") }
        let blind = MessageAssembler.apiMessages(from: history, readsImages: false)
        #expect(blind[3] == .user("[view_image: figure-1, 64x48]\n" + MessageAssembler.omittedImageNote))
    }

    @Test func aFailedCallOrAMissingFileAddsNoImage() throws {
        let store = store()
        let gone = ToolImage(id: "figure-9", width: 1, height: 1, file: "\(UUID().uuidString)/figure-9.png")
        var messages: [APIMessage] = []
        MessageAssembler.appendToolRound(to: &messages, assistantContent: "", calls: [ToolCall(id: "c", name: "view_image", arguments: "{}")],
                                         results: [ToolOutput(text: "Error", isError: true, viewedImage: gone)], images: store)
        #expect(messages.map(\.role) == ["assistant", "tool"])
        MessageAssembler.appendToolRound(to: &messages, assistantContent: "", calls: [ToolCall(id: "d", name: "view_image", arguments: "{}")],
                                         results: [ToolOutput(text: "ok", viewedImage: gone)], images: store)
        #expect(messages.last == .user(parts: [.text("[view_image: figure-9, 1x1]"), .text(MessageAssembler.missingImageNote)]))
    }
}

// MARK: - Router and feed

struct PythonRouterTests {
    @Test func runPythonNeedsAConversationAndPassesTheCode() async {
        let router = ToolRouter(pythonRunner: { code, _, canView in ToolOutput(text: "ran \(code) \(canView)") })
        let none = await router.execute(name: "run_python", arguments: "{\"code\":\"1+1\"}")
        #expect(none.isError)
        let ran = await ToolContext.$conversationID.withValue(UUID()) {
            await ToolContext.$readsImages.withValue(true) { await router.execute(name: "run_python", arguments: "{\"code\":\"1+1\"}") }
        }
        #expect(ran.text == "ran 1+1 true")
        let missing = await router.execute(name: "run_python", arguments: "{}")
        #expect(missing.text == "Error: missing required argument \"code\".")
    }
}

struct PythonFeedTests {
    @Test func aPythonRunIsItsOwnCardBetweenReads() {
        var run = ToolCallRecord(id: "p", name: "run_python", arguments: "{\"code\":\"print(1)\"}", result: "1", isError: false)
        run.figures = [ToolImage(id: "figure-1", width: 640, height: 480, file: "x/figure-1.png")]
        let calls = [FeedCall(id: "f1", isSearch: false, argument: "https://a.com/1", status: .done),
                     FeedCall(record: run),
                     FeedCall(id: "f2", isSearch: false, argument: "https://a.com/2", status: .done)]
        let cards = ActivityFeed.cards(calls: calls, sources: [:])
        #expect(cards.map(\.kind) == [.pages, .python(code: "print(1)"), .pages])
        #expect(cards[1].output == "1")
        #expect(cards[1].figures.map(\.id) == ["figure-1"])
        // The displayed record keeps the output and figures (the card needs them).
        #expect(run.displayOnly.result == "1")
        #expect(run.displayOnly.figures == run.figures)
    }

    @Test func aRunningAndAFailedRun() {
        let pending = FeedCall(pending: PendingToolCall(id: "p", name: "run_python", primaryArgument: "while True: pass"))
        #expect(ActivityFeed.cards(calls: [pending], sources: [:]).first?.isRunning == true)
        let failed = ToolCallRecord(id: "p", name: "run_python", arguments: "{\"code\":\"x\"}",
                                    result: "Error: Timed out after 30 s: the code has a 30 s limit.", isError: true)
        let card = ActivityFeed.cards(calls: [FeedCall(record: failed)], sources: [:]).first
        #expect(card?.pythonFailure == .timedOut)
        #expect(ProcessSegment.toolTitle(calls: [failed]) == "Ran Python")
    }
}
