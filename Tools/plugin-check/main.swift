// Runs one of the app's site plugins on the real site in a WKWebView on the Mac, the way `run_plugin` does on a phone:
// same manifest checks, URL building, readiness polling, invocation script and result formatting (PluginCore.swift is
// compiled in), same iPhone user agent, a 390×844 view. Used by tools/plugin-check.sh; see there for usage.
import AppKit
import WebKit

let argv = CommandLine.arguments
guard argv.count >= 3 else {
    FileHandle.standardError.write("usage: plugin-check <plugins-dir> <name> [<args-json>]\n".data(using: .utf8)!)
    exit(2)
}
let env = ProcessInfo.processInfo.environment
/// Seconds to wait for the page to become ready before running anyway (the app's "Standard" page timeout).
let loadLimit = Double(env["LOAD"] ?? "") ?? 15
let scriptLimit = Double(env["SCRIPT"] ?? "") ?? 10
/// Characters of result kept (the app's default fetch length).
let limit = Int(env["LIMIT"] ?? "") ?? 24_000

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
    exit(1)
}
func note(_ message: String) { FileHandle.standardError.write("\(message)\n".data(using: .utf8)!) }

let registry = PluginRegistry.load(directory: URL(fileURLWithPath: argv[1]))
for problem in registry.problems { note("skipped \(problem)") }
guard let plugin = registry.plugin(named: argv[2]) else {
    fail("no plugin named \(argv[2]) (loaded: \(registry.plugins.map(\.name).joined(separator: ", ")))")
}
let resolved: [String: Any]
let url: URL
do {
    resolved = try plugin.manifest.resolveArguments(argv.count > 3 ? argv[3] : nil)
    url = try plugin.manifest.pageURL(arguments: resolved)
} catch { fail(error.localizedDescription) }
guard PluginManifest.hostAllowed(url.host(percentEncoded: false) ?? "", hosts: plugin.manifest.hosts) else {
    fail(PluginError.hostNotAllowed(url.host ?? "", plugin: plugin.name).localizedDescription)
}
note("plugin: \(plugin.name)\nurl: \(url.absoluteString)\nargs: \(PluginManifest.json(resolved))")

final class Delegate: NSObject, WKNavigationDelegate {
    var finished = false
    var failure: String?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = error.localizedDescription }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = error.localizedDescription }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let config = WKWebViewConfiguration()
config.websiteDataStore = .nonPersistent()
let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
let delegate = Delegate()
web.navigationDelegate = delegate
// WebKit throttles views that are not in a window; park one far off-screen.
let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 390, height: 844), styleMask: .borderless, backing: .buffered, defer: false)
window.contentView = web
window.orderBack(nil)

Task { @MainActor in
    let start = Date()
    web.load(URLRequest(url: url))
    let probe = PluginScript.probe(waitFor: plugin.manifest.waitFor)
    var ranAnyway = false
    while true {
        if let failure = delegate.failure { fail("the page failed to load: \(failure)") }
        let seen = ((try? await web.evaluateJavaScript(probe)) as? String).flatMap(PluginScript.Probe.decode)
        if let seen, seen.isReady(waitFor: plugin.manifest.waitFor) { break }
        if Date().timeIntervalSince(start) >= loadLimit {
            guard seen?.committed == true else { fail("timed out after \(Int(loadLimit)) s loading the page") }
            ranAnyway = true
            break
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
    }
    note(String(format: "ready after %.1f s (didFinish: %@%@)", Date().timeIntervalSince(start), delegate.finished ? "yes" : "no",
                ranAnyway ? ", load limit hit, ran anyway" : ""))
    try? await Task.sleep(nanoseconds: UInt64((plugin.manifest.settle ?? 0.6) * 1e9))
    let body = PluginScript.invocation(plugin, arguments: PluginManifest.json(resolved), maxCharacters: limit)
    let timer = Task { try await Task.sleep(nanoseconds: UInt64(scriptLimit * 1e9)); fail("the plugin script timed out after \(Int(scriptLimit)) s") }
    do {
        let json = (try await web.callAsyncJavaScript(body, contentWorld: .page) as? String) ?? ""
        timer.cancel()
        let out = try PluginScript.format(json: json, plugin: plugin, limit: limit)
        note(String(format: "done after %.1f s, %d characters", Date().timeIntervalSince(start), out.content.count))
        print(out.text)
        exit(0)
    } catch {
        fail(error.localizedDescription)
    }
}
app.run()
