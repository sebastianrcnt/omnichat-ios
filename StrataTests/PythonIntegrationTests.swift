import Foundation
import Testing
@testable import Strata

/// The bundled Pyodide core in a real web view on the simulator. The sympy run downloads packages (or uses the cache)
/// and is skipped when the CDN can't be reached.
@MainActor
@Suite(.serialized)
struct PythonIntegrationTests {
    private func runtime() -> (PythonRuntime, ToolImageStore) {
        let store = ToolImageStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("py-it-\(UUID().uuidString)"))
        return (PythonRuntime(images: store), store)
    }

    private static func online() async -> Bool {
        var request = URLRequest(url: Pyodide.cdnBase.appendingPathComponent("pyodide-lock.json"))
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    @Test func onePlusOneWithTheBundledCore() async {
        let (python, _) = runtime()
        defer { python.dispose() }
        let chat = UUID()
        let out = await python.run(code: "1+1", conversationID: chat, limits: PythonLimits(run: .seconds(30), setup: .seconds(120)),
                                   outputLimit: 1000, canView: false)
        #expect(out.text == "2", "\(out.text)")
        #expect(!out.isError)

        // State persists within the chat; printing and the last value are both shown, in order.
        _ = await python.run(code: "x = 20", conversationID: chat, canView: false)
        let second = await python.run(code: "print('a')\nimport sys\nprint('b', file=sys.stderr)\nx + 1", conversationID: chat, canView: false)
        #expect(second.text == "a\nb\n21", "\(second.text)")

        let failed = await python.run(code: "def f():\n    return 1/0\nf()", conversationID: chat, canView: false)
        #expect(failed.isError)
        #expect(failed.text.contains("ZeroDivisionError"), "\(failed.text)")
        #expect(failed.text.contains("<run"), "\(failed.text)")
        #expect(!failed.text.contains("_pyodide"), "\(failed.text)")
    }

    @Test func aRunPastTheLimitIsStoppedAndTheSessionResets() async {
        let (python, _) = runtime()
        defer { python.dispose() }
        let chat = UUID()
        _ = await python.run(code: "y = 5", conversationID: chat, canView: false)
        let slow = await python.run(code: "while True: pass", conversationID: chat,
                                    limits: PythonLimits(run: .seconds(2), setup: .seconds(120)), canView: false)
        #expect(slow.isError)
        #expect(slow.text.contains("Timed out after"), "\(slow.text)")
        #expect(slow.text.contains("reset"), "\(slow.text)")
        // The model was told; the next run just works on a fresh interpreter.
        let next = await python.run(code: "'y' in globals()", conversationID: chat, canView: false)
        #expect(next.text == "False", "\(next.text)")
    }

    @Test func theWorkerCannotBypassTheProxy() async throws {
        let (python, _) = runtime()
        defer { python.dispose() }
        let out = await python.run(code: "from js import fetch\ntry:\n    await fetch('https://example.com/')\n    print('reached')\nexcept Exception as e:\n    print('blocked')",
                                   conversationID: UUID(), canView: false)
        // Python's fetch goes through the proxy; the worker's own fetch, outside it, is blocked by the page's policy.
        _ = out
        let host = try #require(python.testHost)
        let probe = try await host.probe("https://example.com/")
        #expect(probe.contains("\"reached\":false"), "\(probe)")
    }

    @Test func pythonReachesTheWeb() async throws {
        guard await Self.online() else { return }
        let (python, _) = runtime()
        defer { python.dispose() }
        let code = """
        from pyodide.http import pyfetch, open_url
        r = await pyfetch('https://example.com/')
        print(r.status, 'Example Domain' in await r.string())
        print('Example Domain' in open_url('https://example.com/').read())
        """
        let out = await python.run(code: code, conversationID: UUID(), canView: false)
        #expect(out.text.contains("200 True\nTrue"), "\(out.text)")
    }

    @Test func sympyAndAFigure() async throws {
        guard await Self.online() else { return } // packages come from the CDN on first use
        let (python, store) = runtime()
        defer { python.dispose() }
        let chat = UUID()
        let out = await python.run(code: "import sympy as sp\nx = sp.symbols('x')\nsp.solve(x**2 - 4, x)", conversationID: chat,
                                   limits: PythonLimits(run: .seconds(60), setup: .seconds(240)), canView: true)
        #expect(out.text == "[-2, 2]", "\(out.text)")

        let plot = await python.run(code: "import matplotlib.pyplot as plt\nplt.plot([1, 2, 3])\nplt.show()", conversationID: chat,
                                    limits: PythonLimits(run: .seconds(60), setup: .seconds(240)), canView: true)
        let id = plot.figures.first?.id ?? ""
        #expect(plot.figures.count == 1 && id.hasPrefix("figure-1-"), "\(plot.text)")
        #expect(plot.text.contains("\(id) (640x480)"), "\(plot.text)")
        let file = try #require(plot.figures.first?.file)
        #expect(store.data(file: file).flatMap(ToolImageStore.pngSize)?.0 == 640)
    }

    /// A figure is closed after its run is saved, but the model often keeps working on it in a later run
    /// ("add a title"): the changed figure, or one the run ends on, is saved again; an untouched one is not.
    @Test func aFigureChangedInALaterRunIsSavedAgain() async throws {
        guard await Self.online() else { return }
        let (python, _) = runtime()
        defer { python.dispose() }
        let chat = UUID()
        let limits = PythonLimits(run: .seconds(60), setup: .seconds(240))
        let first = await python.run(code: "import matplotlib.pyplot as plt\nfig, ax = plt.subplots()\nax.plot([1, 2, 3])",
                                     conversationID: chat, limits: limits, canView: true)
        #expect(first.figures.map { FigureReference.shortID($0.id) } == ["figure-1"], "\(first.text)")
        let edited = await python.run(code: "ax.set_title('Growth')", conversationID: chat, limits: limits, canView: true)
        #expect(edited.figures.map { FigureReference.shortID($0.id) } == ["figure-2"], "\(edited.text)")
        let untouched = await python.run(code: "n = 1", conversationID: chat, limits: limits, canView: true)
        #expect(untouched.figures.isEmpty, "\(untouched.text)")
        let shown = await python.run(code: "fig", conversationID: chat, limits: limits, canView: true)
        #expect(shown.figures.map { FigureReference.shortID($0.id) } == ["figure-3"], "\(shown.text)")

        let many = await python.run(code: "for i in range(10):\n    plt.figure()\n    plt.plot([i])", conversationID: chat,
                                    limits: limits, canView: true)
        #expect(many.figures.count == 8, "\(many.text)")
        #expect(many.text.contains("2 more"), "\(many.text)")
    }
}
