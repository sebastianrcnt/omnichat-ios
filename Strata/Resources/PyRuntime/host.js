// The page side of Strata's Python runtime. Python itself runs in a Web Worker (worker.js), so a run that never ends
// can be stopped by terminating the worker; the app talks to this page with callAsyncJavaScript.

let worker = null;
let pending = null;
let seq = 0;
// While the app waits for the user (a network card), the running call's clock stops.
let holds = 0;

function settle(value) {
  const p = pending;
  if (!p) return;
  pending = null;
  clearTimeout(p.timer);
  p.resolve(value);
}

// Starts the pending call's clock with the time it has left.
function arm(p) {
  p.armedAt = performance.now();
  p.timer = setTimeout(() => {
    if (pending !== p) return;
    pending = null;
    kill();
    p.resolve({ status: "timeout", elapsedMs: performance.now() - p.started - p.heldMs });
  }, Math.max(0, p.remaining));
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
    const p = { id, resolve, timer: null, started: performance.now(), remaining: limitMs, heldMs: 0, heldAt: 0 };
    pending = p;
    if (holds === 0) arm(p);
    else p.heldAt = performance.now();
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

  // Stops the running call's clock while the user is asked something (nested), and restarts it with what was left.
  hold(on) {
    const p = pending;
    if (on) {
      holds++;
      if (holds === 1 && p && p.timer) {
        clearTimeout(p.timer);
        p.timer = null;
        p.remaining -= performance.now() - p.armedAt;
        p.heldAt = performance.now();
      }
    } else if (holds > 0) {
      holds--;
      if (holds === 0 && p && !p.timer) {
        if (p.heldAt) p.heldMs += performance.now() - p.heldAt;
        arm(p);
      }
    }
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

// Tells the app the page is ready to run code: the load event alone doesn't say this module has run.
window.webkit.messageHandlers.strataPythonReady.postMessage(true);
