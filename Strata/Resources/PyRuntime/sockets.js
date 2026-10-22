// Real TCP and UDP sockets for Strata's Python worker. Emscripten's SOCKFS keeps the socket file descriptors (so
// CPython's `socket`, `select` and C extensions work unchanged); its transport, a WebSocket per peer that reaches
// nothing here, is replaced by the app's native bridge (Network.framework), reached with synchronous requests to
// strata-py://app/sock. The worker is dedicated to Python, so blocking it while a call waits is fine.
//
// Every request and reply is one frame: a little-endian u32 length, that many bytes of JSON, then the payload bytes.
// Errors come back as errno names (`{ errno: "ECONNREFUSED" }`) and are raised with Emscripten's numbers.

const BRIDGE = "strata-py://app/sock";
const O_NONBLOCK = 2048;
const POLLIN = 1, POLLOUT = 4, POLLERR = 8, POLLHUP = 16, POLLNVAL = 32;
const MSG_PEEK = 2, MSG_DONTWAIT = 64;
const SOCK_STREAM = 1, SOCK_DGRAM = 2;
// Sockets one interpreter may have open (the bridge enforces it too).
const MAX_SOCKETS = 64;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

let M = null; // the Emscripten module, once Pyodide is loaded
let note = () => {}; // writes a line to the run's output
let nextId = 1; // native ids for the sockets created here; the bridge numbers accepted ones from 1 << 20
let openCount = 0;
let recvFlags = 0; // the flags of the recvfrom being served (SOCKFS doesn't pass them on)
let pendingWait = null; // the WebLoop's outstanding asynchronous poll
let inCall = 0; // a synchronous bridge call is in progress (Python has released its GIL for the syscall)

// MARK: Bridge

function frame(args, payload) {
  const json = encoder.encode(JSON.stringify(args));
  const out = new Uint8Array(4 + json.length + (payload ? payload.length : 0));
  new DataView(out.buffer).setUint32(0, json.length, true);
  out.set(json, 4);
  if (payload) out.set(payload, 4 + json.length);
  return out;
}

function unframe(buffer) {
  const bytes = new Uint8Array(buffer);
  if (bytes.length < 4) return { errno: "EIO", data: new Uint8Array(0) };
  const length = new DataView(buffer).getUint32(0, true);
  const reply = JSON.parse(decoder.decode(bytes.subarray(4, 4 + length)));
  reply.data = bytes.subarray(4 + length);
  return reply;
}

function call(args, payload) {
  const xhr = new XMLHttpRequest();
  xhr.open("POST", BRIDGE, false);
  xhr.responseType = "arraybuffer";
  inCall++;
  try {
    xhr.send(frame(args, payload));
  } catch (e) {
    return { errno: "EIO", data: new Uint8Array(0) };
  } finally {
    inCall--;
  }
  if (xhr.status !== 200 || !xhr.response) return { errno: "EIO", data: new Uint8Array(0) };
  const reply = unframe(xhr.response);
  if (reply.note) note(reply.note);
  return reply;
}

async function callAsync(args, signal) {
  const response = await fetch(BRIDGE, { method: "POST", body: frame(args), signal });
  const reply = unframe(await response.arrayBuffer());
  if (reply.note) note(reply.note);
  return reply;
}

function errnoError(name) {
  return new M.FS.ErrnoError(M.ERRNO_CODES[name] || M.ERRNO_CODES.EIO);
}

function check(reply) {
  if (reply.errno) throw errnoError(reply.errno);
  return reply;
}

// MARK: Sockets

// The host a SOCKFS address stands for: Emscripten's resolver hands out fake 172.29.x.x addresses and keeps the names.
function realHost(addr) {
  const text = String(addr);
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(text);
  const v4 = mapped ? mapped[1] : text;
  return M.DNS.lookup_addr(v4) || v4;
}

function socketOf(fd) {
  const stream = M.FS.getStream(fd);
  const sock = stream && stream.node && stream.node.sock;
  return sock && sock.sock_ops === ops ? sock : null;
}

function blocking(sock) {
  return !(sock.stream.flags & O_NONBLOCK);
}

function ensureId(sock) {
  if (!sock.id) sock.id = nextId++;
  return sock.id;
}

function kind(sock) {
  return sock.type === SOCK_STREAM ? "tcp" : "udp";
}

function createSocket(family, type, protocol) {
  if (family !== 2 && family !== 10) throw errnoError("EAFNOSUPPORT");
  const nonblocking = type & O_NONBLOCK;
  type &= ~(O_NONBLOCK | 524288); // SOCK_NONBLOCK, SOCK_CLOEXEC
  if (type !== SOCK_STREAM && type !== SOCK_DGRAM) {
    throw errnoError(type === 3 ? "EPERM" : "ESOCKTNOSUPPORT"); // SOCK_RAW needs privileges apps don't have
  }
  if (protocol && protocol !== (type === SOCK_STREAM ? 6 : 17)) throw errnoError("EPROTONOSUPPORT");
  if (openCount >= MAX_SOCKETS) throw errnoError("EMFILE");
  const sock = {
    family, type, protocol, sock_ops: ops, id: 0, refs: 1,
    state: "new", // new, bound, connecting, connected, listening, closed
    server: null, error: null, peers: {}, pending: [], recv_queue: [], // read by Emscripten code that peeks at SOCKFS sockets
    pair: null, inbox: [], peerClosed: false, // a socketpair end, kept in the worker
  };
  const name = M.SOCKFS.nextname();
  const node = M.FS.createNode(M.SOCKFS.root, name, 49152, 0);
  node.sock = sock;
  sock.stream = M.FS.createStream({ path: name, node, flags: 2 | nonblocking, seekable: false, stream_ops: streamOps });
  openCount++;
  return sock;
}

// What poll can tell without the bridge: a socketpair end, or a socket that has no native side yet.
function localEvents(sock) {
  if (sock.pair) {
    let mask = POLLOUT;
    if (sock.inbox.length || sock.peerClosed) mask |= POLLIN;
    if (sock.peerClosed) mask |= POLLHUP;
    return mask;
  }
  if (sock.state === "closed") return POLLNVAL;
  return sock.type === SOCK_STREAM ? POLLOUT | POLLHUP : POLLOUT;
}

// A TCP socket that connected without blocking learns its local address when someone asks (getsockname).
function learnLocalEnd(sock) {
  if (sock.sport || !sock.id || sock.pair || sock.type !== SOCK_STREAM) return;
  if (sock.state !== "connected" && sock.state !== "connecting") return;
  const status = call({ op: "status", id: sock.id });
  if (status.localPort) {
    sock.saddr = status.localHost || sock.saddr;
    sock.sport = status.localPort;
  }
}

function isLocal(sock) {
  return sock.pair || !sock.id || sock.state === "closed";
}

const ops = {
  poll(sock) {
    if (isLocal(sock)) return localEvents(sock);
    const reply = call({ op: "poll", fds: [[sock.id, POLLIN | POLLOUT]], timeout: 0 });
    return reply.revents ? reply.revents[0] : POLLERR;
  },

  ioctl(sock, request, arg) {
    switch (request) {
      case 21531: { // FIONREAD
        let bytes = 0;
        if (sock.pair) bytes = sock.inbox.reduce((n, chunk) => n + chunk.length, 0);
        else if (sock.id) bytes = call({ op: "status", id: sock.id }).available || 0;
        M.HEAP32[arg >>> 2] = bytes;
        return 0;
      }
      case 21537: // FIONBIO
        if (M.HEAP32[arg >>> 2]) sock.stream.flags |= O_NONBLOCK;
        else sock.stream.flags &= ~O_NONBLOCK;
        return 0;
      default:
        return -M.ERRNO_CODES.EINVAL;
    }
  },

  // `varargs` points at the call's variadic arguments (Pyodide passes fcntl's on as they came).
  fcntl64(sock, cmd, varargs) {
    if (cmd === 3) return sock.stream.flags; // F_GETFL
    if (cmd === 4) { // F_SETFL (Emscripten's own only ever adds flags, so setblocking(True) never took)
      const arg = M.HEAP32[varargs >>> 2];
      sock.stream.flags = (sock.stream.flags & ~O_NONBLOCK) | (arg & O_NONBLOCK);
      return 0;
    }
    return -1; // the rest: Emscripten's default
  },

  close(sock) {
    if (sock.state === "closed") return 0;
    sock.state = "closed";
    openCount--;
    if (sock.pair) {
      sock.pair.peerClosed = true;
      wake();
    } else if (sock.id) {
      call({ op: "close", id: sock.id });
    }
    return 0;
  },

  bind(sock, addr, port) {
    if (sock.state !== "new") throw errnoError("EINVAL");
    const host = realHost(addr);
    const reply = check(call({ op: "bind", id: ensureId(sock), kind: kind(sock), host, port }));
    sock.saddr = reply.host || host;
    sock.sport = reply.port;
    sock.state = "bound";
  },

  connect(sock, addr, port) {
    if (sock.state === "listening") throw errnoError("EISCONN");
    if (sock.type === SOCK_STREAM) {
      if (sock.state === "connected") throw errnoError("EISCONN");
      if (sock.state === "connecting") {
        // A repeated connect() asks how the first one went.
        const status = call({ op: "status", id: sock.id });
        if (status.errno) { sock.state = "closed"; throw errnoError(status.errno); }
        if (status.connected) { sock.state = "connected"; throw errnoError("EISCONN"); }
        throw errnoError("EALREADY");
      }
    }
    const host = realHost(addr);
    const reply = call({ op: "connect", id: ensureId(sock), kind: kind(sock), host, port, block: blocking(sock) });
    sock.daddr = host;
    sock.dport = port;
    if (reply.errno === "EINPROGRESS") {
      sock.state = "connecting";
      throw errnoError("EINPROGRESS");
    }
    if (reply.errno) {
      sock.daddr = sock.dport = undefined;
      throw errnoError(reply.errno);
    }
    sock.state = "connected";
    if (reply.localPort) {
      sock.saddr = reply.localHost || sock.saddr;
      sock.sport = reply.localPort;
    }
  },

  listen(sock, backlog) {
    if (sock.type !== SOCK_STREAM) throw errnoError("EOPNOTSUPP");
    if (sock.state === "new") ops.bind(sock, "0.0.0.0", 0);
    if (sock.state === "listening") return;
    if (sock.state !== "bound") throw errnoError("EINVAL");
    check(call({ op: "listen", id: sock.id, backlog }));
    sock.state = "listening";
  },

  accept(listener) {
    if (listener.state !== "listening") throw errnoError("EINVAL");
    const reply = check(call({ op: "accept", id: listener.id, block: blocking(listener) }));
    let sock;
    try {
      sock = createSocket(listener.family, SOCK_STREAM, listener.protocol);
    } catch (e) {
      call({ op: "close", id: reply.id });
      throw e;
    }
    sock.id = reply.id;
    sock.state = "connected";
    sock.daddr = reply.host;
    sock.dport = reply.port;
    sock.saddr = listener.saddr;
    sock.sport = listener.sport;
    return sock;
  },

  getname(sock, peer) {
    if (peer) {
      if (sock.daddr === undefined) throw errnoError("ENOTCONN");
      return { addr: sock.daddr, port: sock.dport };
    }
    learnLocalEnd(sock);
    return { addr: sock.saddr || "0.0.0.0", port: sock.sport || 0 };
  },

  sendmsg(sock, buffer, offset, length, addr, port) {
    const data = new Uint8Array(buffer.buffer, buffer.byteOffset + offset, length).slice();
    if (sock.pair) {
      if (sock.peerClosed) throw errnoError("EPIPE");
      if (data.length) sock.pair.inbox.push(data);
      wake();
      return length;
    }
    if (sock.type === SOCK_STREAM) {
      if (sock.state !== "connected" && sock.state !== "connecting") throw errnoError(sock.state === "closed" ? "EBADF" : "ENOTCONN");
      const reply = check(call({ op: "send", id: sock.id, block: blocking(sock) }, data));
      if (sock.state === "connecting") sock.state = "connected";
      return reply.n;
    }
    let host, toPort;
    if (addr === undefined || addr === null) {
      if (sock.daddr === undefined) throw errnoError("EDESTADDRREQ");
      host = sock.daddr;
      toPort = sock.dport;
    } else {
      host = realHost(addr);
      toPort = port;
    }
    const reply = check(call({ op: "sendto", id: ensureId(sock), host, port: toPort, block: blocking(sock) }, data));
    if (reply.localPort && !sock.sport) sock.sport = reply.localPort;
    return reply.n;
  },

  recvmsg(sock, length) {
    const flags = recvFlags;
    if (sock.pair) {
      if (!sock.inbox.length) {
        if (sock.peerClosed) return null;
        throw errnoError("EAGAIN"); // nothing could ever arrive while this one thread waits
      }
      const chunk = sock.inbox[0];
      const part = chunk.subarray(0, length);
      if (!(flags & MSG_PEEK)) {
        if (part.length < chunk.length) sock.inbox[0] = chunk.subarray(part.length);
        else sock.inbox.shift();
      }
      return { buffer: part, addr: "127.0.0.1", port: 0 };
    }
    if (sock.type === SOCK_STREAM && sock.state !== "connected" && sock.state !== "connecting") {
      throw errnoError(sock.state === "closed" ? "EBADF" : "ENOTCONN");
    }
    const block = blocking(sock) && !(flags & MSG_DONTWAIT);
    const reply = check(call({ op: "recv", id: ensureId(sock), max: length, peek: !!(flags & MSG_PEEK), block }));
    if (sock.state === "connecting") sock.state = "connected";
    if (reply.eof && reply.data.length === 0) return null;
    return { buffer: reply.data, addr: reply.host || sock.daddr, port: reply.port || sock.dport };
  },

  shutdown(sock, how) {
    if (how !== 0 && how !== 1 && how !== 2) return -M.ERRNO_CODES.EINVAL;
    if (sock.pair) {
      if (how !== 0) { sock.pair.peerClosed = true; wake(); }
      return 0;
    }
    if (!sock.id || (sock.state !== "connected" && sock.state !== "connecting")) return -M.ERRNO_CODES.ENOTCONN;
    const reply = call({ op: "shutdown", id: sock.id, how });
    return reply.errno ? -M.ERRNO_CODES[reply.errno] : 0;
  },
};

const streamOps = {
  poll(stream) { return ops.poll(stream.node.sock); },
  ioctl(stream, request, arg) { return ops.ioctl(stream.node.sock, request, arg); },
  read(stream, buffer, offset, length) {
    const msg = ops.recvmsg(stream.node.sock, length);
    if (!msg) return 0;
    buffer.set(msg.buffer, offset);
    return msg.buffer.length;
  },
  write(stream, buffer, offset, length) { return ops.sendmsg(stream.node.sock, buffer, offset, length); },
  dup(stream) { stream.node.sock.refs++; },
  close(stream) {
    const sock = stream.node.sock;
    if (--sock.refs > 0) return;
    ops.close(sock);
  },
};

// MARK: Syscalls the module imports

// poll(): SOCKFS answers at once and ignores the timeout, so every wait would spin or fail. Sockets are asked of the
// bridge in one call that waits up to the timeout; anything else (files, pipes) is always ready.
function poll(fds, nfds, timeout) {
  let ready = 0;
  const bridged = [];
  for (let i = 0; i < nfds; i++) {
    const at = fds + 8 * i;
    const fd = M.HEAP32[at >>> 2];
    const events = M.HEAP16[(at + 4) >>> 1];
    let revents = 0;
    if (fd >= 0) {
      const stream = M.FS.getStream(fd);
      const sock = stream && stream.node && stream.node.sock;
      if (!stream) revents = POLLNVAL;
      else if (sock && sock.sock_ops === ops) {
        if (!isLocal(sock)) { bridged.push([at, sock, events]); continue; }
        revents = localEvents(sock);
      } else {
        revents = stream.stream_ops.poll ? stream.stream_ops.poll(stream, -1) : POLLIN | POLLOUT;
      }
      revents &= events | POLLERR | POLLHUP | POLLNVAL;
    }
    M.HEAP16[(at + 6) >>> 1] = revents;
    if (revents) ready++;
  }
  if (bridged.length || (!ready && timeout !== 0)) {
    // With nothing to watch this is a sleep, done natively instead of spinning.
    const reply = call({ op: "poll", fds: bridged.map(([, sock, events]) => [sock.id, events]), timeout: ready ? 0 : timeout });
    if (reply.errno === "EINTR") return -M.ERRNO_CODES.EINTR;
    bridged.forEach(([at, , events], k) => {
      const revents = (reply.revents ? reply.revents[k] : POLLERR) & (events | POLLERR | POLLHUP | POLLNVAL);
      M.HEAP16[(at + 6) >>> 1] = revents;
      if (revents) ready++;
    });
  }
  return ready;
}

// getsockopt(): SOCKFS knows only SO_ERROR, and only from its WebSocket. CPython reads SO_TYPE and friends to build a
// socket from a file descriptor; asyncio reads SO_ERROR after a non-blocking connect.
function getsockopt(fd, level, optname, optval, optlen, original, rest) {
  const sock = socketOf(fd);
  if (!sock) return original(fd, level, optname, optval, optlen, ...rest);
  let value = 0;
  if (level === 1) { // SOL_SOCKET
    switch (optname) {
      case 4: // SO_ERROR
        if (sock.id && !sock.pair) {
          const status = call({ op: "status", id: sock.id, clear: true });
          if (status.errno) value = M.ERRNO_CODES[status.errno] || M.ERRNO_CODES.EIO;
          else if (status.connected && sock.state === "connecting") sock.state = "connected";
        }
        break;
      case 3: value = sock.type; break; // SO_TYPE
      case 39: value = sock.family; break; // SO_DOMAIN
      case 38: value = sock.protocol || (sock.type === SOCK_STREAM ? 6 : 17); break; // SO_PROTOCOL
      case 30: value = sock.state === "listening" ? 1 : 0; break; // SO_ACCEPTCONN
      case 7: case 8: value = 262144; break; // SO_SNDBUF, SO_RCVBUF
      case 13: // SO_LINGER: { l_onoff, l_linger }
        M.HEAP32[optval >>> 2] = 0;
        M.HEAP32[(optval + 4) >>> 2] = 0;
        M.HEAP32[optlen >>> 2] = 8;
        return 0;
      default: value = 0;
    }
  } else if (level === 6) { // IPPROTO_TCP
    value = optname === 1 ? 1 : 0; // TCP_NODELAY is always on
  } else if (level === 0) { // IPPROTO_IP
    value = optname === 2 ? 64 : 0; // IP_TTL
  } else {
    return -M.ERRNO_CODES.ENOPROTOOPT;
  }
  M.HEAP32[optval >>> 2] = value;
  M.HEAP32[optlen >>> 2] = 4;
  return 0;
}

// A synchronous XMLHttpRequest spins a nested run loop, and WebKit runs FinalizationRegistry callbacks there. Pyodide's
// frees a garbage-collected proxy's Python object, which needs the GIL that CPython released for the socket syscall:
// it would be a fatal error. Callbacks that come during a call wait for the next task instead.
function guardFinalizers() {
  const Registry = globalThis.FinalizationRegistry;
  if (!Registry || Registry.strataGuarded) return;
  const deferred = [];
  let scheduled = false;
  const drain = () => {
    scheduled = false;
    if (inCall) return schedule();
    for (const run of deferred.splice(0)) run();
  };
  const schedule = () => {
    if (!scheduled) { scheduled = true; setTimeout(drain, 0); }
  };
  class Guarded extends Registry {
    constructor(callback) {
      super((held) => {
        if (!inCall) return callback(held);
        deferred.push(() => callback(held));
        schedule();
      });
    }
  }
  Guarded.strataGuarded = true;
  globalThis.FinalizationRegistry = Guarded;
}

// Swaps the syscalls above into the module's imports as Pyodide instantiates its wasm (its own loader passes them to
// WebAssembly.instantiate or instantiateStreaming), and guards its finalizers. Call before loadPyodide.
export function hookInstantiate() {
  guardFinalizers();
  const patch = (imports) => {
    const env = imports && imports.env;
    if (!env || !env.__syscall_poll || !env.__syscall_socket || env.__strataSockets) return;
    env.__strataSockets = true;
    const wrap = (name, make) => {
      const original = env[name];
      const wrapped = make(original);
      if (original.sig) wrapped.sig = original.sig;
      env[name] = wrapped;
    };
    wrap("__syscall_poll", (original) => (fds, nfds, timeout) => (M ? poll(fds, nfds, timeout) : original(fds, nfds, timeout)));
    wrap("__syscall_getsockopt", (original) => (fd, level, optname, optval, optlen, ...rest) =>
      M ? getsockopt(fd, level, optname, optval, optlen, original, rest) : original(fd, level, optname, optval, optlen, ...rest));
    wrap("__syscall_getsockname", (original) => (fd, ...rest) => {
      const sock = M && socketOf(fd);
      if (sock) learnLocalEnd(sock); // Emscripten reads the socket's fields directly
      return original(fd, ...rest);
    });
    wrap("__syscall_recvfrom", (original) => (fd, buf, len, flags, addr, addrlen) => {
      recvFlags = flags;
      try {
        return original(fd, buf, len, flags, addr, addrlen);
      } finally {
        recvFlags = 0;
      }
    });
  };
  const instantiate = WebAssembly.instantiate;
  WebAssembly.instantiate = function (source, imports, ...rest) {
    patch(imports);
    return instantiate.call(this, source, imports, ...rest);
  };
  const streaming = WebAssembly.instantiateStreaming;
  if (streaming) {
    WebAssembly.instantiateStreaming = function (source, imports, ...rest) {
      patch(imports);
      return streaming.call(this, source, imports, ...rest);
    };
  }
}

// MARK: Python's side

function wake() {
  if (pendingWait) pendingWait.abort();
}

// The functions `strata_net.py` calls, as the JS module `_strata_net`.
const api = {
  // Joins two fresh sockets into a pair (socket.socketpair(), asyncio's self-pipe).
  pair(a, b) {
    const x = socketOf(a), y = socketOf(b);
    if (!x || !y) return false;
    x.pair = y;
    y.pair = x;
    x.state = y.state = "connected";
    return true;
  },

  // Starts TLS on a connected socket; the reply's fields, or `error` (and `verify` for a certificate that failed).
  // `alpn` is comma-separated; `timeout` in ms, -1 for none.
  tls(fd, host, verify, checkHostname, cadata, alpn, timeout) {
    const sock = socketOf(fd);
    if (!sock || sock.pair || sock.type !== SOCK_STREAM || !sock.id) return { error: "TLS needs a connected TCP socket" };
    const reply = call({ op: "tls", id: sock.id, host: host || sock.daddr || "", verify, checkHostname,
                         alpn: alpn ? alpn.split(",") : [], timeout },
                       cadata ? encoder.encode(cadata) : null);
    delete reply.data;
    if (reply.errno && !reply.error) reply.error = reply.errno;
    return reply;
  },

  // The WebLoop's wait: revents for [[fd, events]], as soon as one is ready, after `timeout` ms, or 0s once woken.
  async wait(list, timeout) {
    const local = [];
    const bridged = [];
    list.forEach(([fd, events], k) => {
      const stream = M.FS.getStream(fd);
      const sock = stream && stream.node && stream.node.sock;
      if (!stream) local[k] = POLLNVAL;
      else if (sock && sock.sock_ops === ops && !isLocal(sock)) bridged.push([k, sock.id, events]);
      else local[k] = (sock && sock.sock_ops === ops ? localEvents(sock) : POLLIN | POLLOUT) & (events | POLLERR | POLLHUP | POLLNVAL);
    });
    const result = list.map((_, k) => local[k] || 0);
    if (result.some((r) => r) || !bridged.length) return result;
    const controller = new AbortController();
    pendingWait = controller;
    try {
      const reply = await callAsync({ op: "poll", fds: bridged.map(([, id, events]) => [id, events]), timeout }, controller.signal);
      bridged.forEach(([k, , events], i) => { result[k] = (reply.revents ? reply.revents[i] : POLLERR) & (events | POLLERR | POLLHUP); });
    } catch (e) {
      // Woken (the watched set changed) or the page is going away: the loop asks again.
    } finally {
      if (pendingWait === controller) pendingWait = null;
    }
    return result;
  },

  wake,
};

// Takes over SOCKFS once Pyodide is loaded: new sockets are bridged ones. `write` adds a line to the run's output.
export function installSockets(pyodide, write) {
  M = pyodide._module;
  note = write;
  M.SOCKFS.createSocket = createSocket;
  call({ op: "hello" }); // a new interpreter: sockets left from an earlier one close
  pyodide.registerJsModule("_strata_net", api);
}
