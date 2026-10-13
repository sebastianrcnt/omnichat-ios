// Runs the app's page extractor (Readability.js + Extractor.js) on real pages in a WKWebView on the Mac, the way
// the fetch tool does on a phone: same user script, same iPhone user agent, a 390×844 view. Used by
// tools/extract-check.sh; see there for usage.
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 5 else {
    FileHandle.standardError.write("usage: extract-check <Readability.js> <Extractor.js> <out-dir> <url>...\n".data(using: .utf8)!)
    exit(2)
}
let reader = try! String(contentsOfFile: args[1], encoding: .utf8)
let extractor = try! String(contentsOfFile: args[2], encoding: .utf8)
let outDir = URL(fileURLWithPath: args[3])
let urls = Array(args.dropFirst(4))
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// Seconds to wait after `didFinish` for script-rendered content, like the app's settle delay.
let settle = Double(ProcessInfo.processInfo.environment["SETTLE"] ?? "") ?? 2.0

func row(_ n: String, _ method: String, _ reader: String, _ chars: String, _ url: String) -> String {
    func pad(_ s: String, _ w: Int, left: Bool = false) -> String {
        let fill = String(repeating: " ", count: max(0, w - s.count))
        return left ? fill + s : s + fill
    }
    return pad(n, 4) + pad(method, 13) + pad(reader, 8, left: true) + pad(chars, 9, left: true) + "  " + url
}

final class Runner: NSObject, WKNavigationDelegate {
    let web: WKWebView
    var queue: [(index: Int, url: String)]
    var current: (index: Int, url: String)?
    var timer: DispatchWorkItem?

    init(urls: [String]) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WKUserScript(source: reader + "\n;\n" + extractor,
                                                                injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        queue = urls.enumerated().map { ($0.offset + 1, $0.element) }
        super.init()
        web.navigationDelegate = self
        print(row("#", "method", "reader", "chars", "url"))
    }

    func next() {
        timer?.cancel()
        guard !queue.isEmpty else { exit(0) }
        current = queue.removeFirst()
        guard let url = URL(string: current!.url) else { report(error: "bad url"); return }
        web.load(URLRequest(url: url))
        let t = DispatchWorkItem { [weak self] in self?.report(error: "timeout") }
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: t)
    }

    func report(error: String) {
        guard let c = current else { return }
        print(row("\(c.index)", "FAIL", "-", "-", c.url) + "  (\(error))")
        current = nil
        next()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let c = current else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            let js = """
            (function(){
              var reader = 0;
              try { var a = new Readability(document.cloneNode(true)).parse(); reader = a && a.textContent ? a.textContent.trim().length : 0; } catch (e) {}
              var r = JSON.parse(strataExtract(400000));
              r.reader = reader; r.final = location.href;
              return JSON.stringify(r);
            })()
            """
            webView.evaluateJavaScript(js) { res, err in
                guard self.current?.index == c.index else { return }
                guard let s = res as? String, let d = s.data(using: .utf8),
                      let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                    self.report(error: err.map { "\($0)" } ?? "no result"); return
                }
                let text = r["text"] as? String ?? ""
                let file = outDir.appendingPathComponent(String(format: "%02d.txt", c.index))
                let header = "url: \(c.url)\nfinal: \(r["final"] ?? "")\ntitle: \(r["title"] ?? "")\nmethod: \(r["method"] ?? "")\nreadability: \(r["reader"] ?? 0) chars\nresult: \(text.count) chars\n\n"
                try? (header + text).write(to: file, atomically: true, encoding: .utf8)
                print(row("\(c.index)", r["method"] as? String ?? "?", "\(r["reader"] as? Int ?? 0)", "\(text.count)", c.url))
                self.current = nil
                self.next()
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error: error.localizedDescription) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error: error.localizedDescription) }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let runner = Runner(urls: urls)
// WebKit throttles views that are not in a window; park one far off-screen.
let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 390, height: 844), styleMask: .borderless, backing: .buffered, defer: false)
window.contentView = runner.web
window.orderBack(nil)
runner.next()
app.run()
