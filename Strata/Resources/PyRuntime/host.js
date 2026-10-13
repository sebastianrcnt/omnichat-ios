// The page side of Strata's Python runtime. Python itself runs in a Web Worker (worker.js), so a run that never ends
// can be stopped by terminating the worker; the app talks to this page with callAsyncJavaScript.

let worker = null;
let pending = null;
let seq = 0;

function settle(value) {
  const p = pending;
  if (!p) return;
  pending = null;
  clearTimeout(p.timer);
  p.resolve(value);
}

function kill() {
  if (worker) {
    worker.onmessage = null;
    worker.onerror = null;
    worker.terminate();
    worker = null;
  }
}

function start() {
  worker = new Worker("worker.js", { type: "module" });
  worker.onmessage = (event) => {
    if (pending && event.data && event.data.id === pending.id) settle(event.data);
  };
  worker.onerror = (event) => {
    const message = (event && event.message) || "the Python worker stopped";
    kill();
    settle({ status: "crashed", message });
  };
  worker.onmessageerror = () => {
    kill();
    settle({ status: "crashed", message: "a message from the Python worker could not be read" });
  };
}

// Sends one request to the worker and waits for its answer, at most `limitMs`. When the limit passes the worker is
// terminated (its state is gone) and the answer says so.
function call(message, limitMs) {
  return new Promise((resolve) => {
    const id = ++seq;
    const started = performance.now();
    const timer = setTimeout(() => {
      pending = null;
      kill();
      resolve({ status: "timeout", elapsedMs: performance.now() - started });
    }, limitMs);
    pending = { id, resolve, timer };
    worker.postMessage(Object.assign({ id }, message));
  });
}

window.strataPython = {
  // Returns a JSON string: { phase, status, fresh, ... } (see PythonRunReply in the app).
  async run(code, runLimitMs, setupLimitMs) {
    let fresh = false;
    if (!worker) {
      fresh = true;
      start();
      const init = await call({ type: "init" }, setupLimitMs);
      if (init.status !== "ok") {
        kill();
        return JSON.stringify(Object.assign({ phase: "init", fresh }, init));
      }
    }
    const load = await call({ type: "load", code }, setupLimitMs);
    if (load.status !== "ok") {
      if (load.status !== "error") kill();
      return JSON.stringify(Object.assign({ phase: "load", fresh }, load));
    }
    const run = await call({ type: "run", code }, runLimitMs);
    return JSON.stringify(Object.assign({ phase: "run", fresh, loadErrors: load.errors || [] }, run));
  },

  reset() {
    kill();
    settle({ status: "reset" });
    return "ok";
  },

  // Test hook: whether direct network access from the worker is blocked.
  async probe(url) {
    if (!worker) {
      start();
      const init = await call({ type: "init" }, 60000);
      if (init.status !== "ok") return JSON.stringify(init);
    }
    return JSON.stringify(await call({ type: "probe", url }, 15000));
  },
};
