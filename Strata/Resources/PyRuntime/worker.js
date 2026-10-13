// Strata's Python worker: one Pyodide interpreter. Messages from host.js:
//   { id, type: "init" }          -> { id, status: "ok" | "error", message }
//   { id, type: "load", code }    -> { id, status: "ok", errors: [String] }   (packages the code imports)
//   { id, type: "run", code }     -> { id, status: "ok", output, result, error, figures: [{ png }], truncated }
// Network access goes only to the app's own scheme: absolute http(s) URLs are sent through its proxy, which allows the
// Pyodide CDN and PyPI and refuses everything else (and the page's CSP blocks any other origin).

import { loadPyodide } from "./pyodide/pyodide.mjs";

const realFetch = self.fetch.bind(self);
self.fetch = (input, init) => {
  const url = typeof input === "string" ? input : input instanceof URL ? input.href : input && input.url;
  if (typeof url === "string" && /^https?:/i.test(url)) {
    const proxied = "strata-py://app/proxy?u=" + encodeURIComponent(url);
    input = typeof input === "string" || input instanceof URL ? proxied : new Request(proxied, input);
  }
  return realFetch(input, init);
};

// Output kept per run; anything past this is dropped in the worker (the app caps it again for the model).
const OUTPUT_LIMIT = 400000;
let py = null;
let runFn = null;
let output = [];
let outputSize = 0;
let truncated = false;
const decoders = { out: new TextDecoder(), err: new TextDecoder() };

function write(stream) {
  return (buffer) => {
    const text = decoders[stream].decode(buffer, { stream: true });
    if (outputSize < OUTPUT_LIMIT) {
      output.push(text);
      outputSize += text.length;
    } else {
      truncated = true;
    }
    return buffer.length;
  };
}

const HARNESS = `
import sys, io, base64, linecache, traceback, warnings
warnings.filterwarnings("ignore", message=".*non-interactive.*")
warnings.filterwarnings("ignore", message=".*FigureCanvasAgg.*")
from pyodide.code import eval_code_async

namespace = {"__name__": "__main__"}
run_count = 0
MAX_FIGURES = 8

def format_error(e, filename):
    tb = e.__traceback__
    while tb is not None and tb.tb_frame.f_code.co_filename != filename:
        tb = tb.tb_next
    return "".join(traceback.format_exception(type(e), e, tb))

def figures():
    plt = sys.modules.get("matplotlib.pyplot")
    if plt is None:
        return []
    out = []
    try:
        for num in plt.get_fignums()[:MAX_FIGURES]:
            fig = plt.figure(num)
            buf = io.BytesIO()
            fig.savefig(buf, format="png", dpi=100)
            out.append(base64.b64encode(buf.getvalue()).decode("ascii"))
    finally:
        plt.close("all")
    return out

async def run(code):
    global run_count
    run_count += 1
    filename = f"<run {run_count}>"
    linecache.cache[filename] = (len(code), None, code.splitlines(True), filename)
    result = None
    error = None
    try:
        value = await eval_code_async(code, namespace, filename=filename)
        if value is not None:
            try:
                result = repr(value)
            except BaseException as e:
                result = f"<repr() failed: {type(e).__name__}: {e}>"
    except BaseException as e:
        error = format_error(e, filename)
    try:
        sys.stdout.flush()
        sys.stderr.flush()
    except Exception:
        pass
    try:
        figs = figures()
    except BaseException as e:
        figs = []
        error = (error or "") + "Could not save the figures: " + "".join(traceback.format_exception_only(type(e), e))
    return [result, error, figs]
`;

async function init() {
  py = await loadPyodide({
    indexURL: "strata-py://app/pyodide/",
    packageBaseUrl: "strata-py://app/pyodide/",
    env: { HOME: "/home/pyodide", MPLBACKEND: "Agg" },
    stdout: () => {},
    stderr: () => {},
  });
  py.setStdout({ write: write("out") });
  py.setStderr({ write: write("err") });
  const harness = py.globals.get("dict")();
  await py.runPythonAsync(HARNESS, { globals: harness });
  runFn = harness.get("run");
}

async function loadImports(code) {
  const errors = [];
  try {
    await py.loadPackagesFromImports(code, {
      messageCallback: () => {},
      errorCallback: (message) => errors.push(String(message)),
    });
  } catch (e) {
    errors.push(String((e && e.message) || e));
  }
  return errors;
}

async function run(code) {
  output = [];
  outputSize = 0;
  truncated = false;
  const proxy = await runFn(code);
  const [result, error, figures] = proxy.toJs();
  proxy.destroy();
  for (const stream of ["out", "err"]) {
    const rest = decoders[stream].decode();
    if (rest) output.push(rest);
  }
  return { output: output.join(""), result, error, figures: figures.map((png) => ({ png })), truncated };
}

async function probe(url) {
  try {
    const response = await realFetch(url);
    return { status: "ok", reached: true, code: response.status };
  } catch (e) {
    return { status: "ok", reached: false, message: String((e && e.message) || e) };
  }
}

self.onmessage = async (event) => {
  const { id, type, code, url } = event.data || {};
  try {
    if (type === "init") {
      await init();
      self.postMessage({ id, status: "ok" });
    } else if (type === "load") {
      self.postMessage({ id, status: "ok", errors: await loadImports(code) });
    } else if (type === "run") {
      self.postMessage(Object.assign({ id, status: "ok" }, await run(code)));
    } else if (type === "probe") {
      self.postMessage(Object.assign({ id }, await probe(url)));
    } else {
      self.postMessage({ id, status: "error", message: "unknown request " + type });
    }
  } catch (e) {
    const message = String((e && e.message) || e);
    // A fatal error leaves the interpreter unusable: the host starts a new one.
    const fatal = /fatal error|out of memory|memory access out of bounds|RangeError/i.test(message) || (py && py._api && py._api.fatal_error_occurred);
    self.postMessage({ id, status: fatal ? "crashed" : "error", message });
  }
};
