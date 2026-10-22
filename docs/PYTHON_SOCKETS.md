# Python sockets: real TCP/UDP for the Pyodide sandbox

Status: approved by the product owner on 2026-10-22, implemented on the `sockets` branch the same day. Goal:
**practically every Python package that uses TCP or UDP works** in `run_python`. That covers pure-Python clients (`pg8000`,
`pymysql`, `redis`, `smtplib`, `imaplib`, `ftplib`, `paramiko`, `dnspython`), asyncio clients (`asyncpg`, `aiohttp`,
`websockets`), and C extensions built for Pyodide that call the socket syscalls themselves.

## Before

- Pyodide runs in a dedicated worker (`Strata/Resources/PyRuntime/worker.js`) inside a WKWebView served from
  `strata-py://app` (`Strata/Tools/Python/PyodideServer.swift`).
- HTTP(S) only: `fetch` and `XMLHttpRequest` are rewritten to `strata-py://app/proxy?u=…`, and `PyNetwork` makes the
  request natively. No CORS limits, public hosts only (`URLGuard`), a 200 MB cap, and no cookies. This path is unchanged.
- `socket.socket().connect(...)` failed. Emscripten's SOCKFS backs sockets with a WebSocket to `ws://host:port`, and
  nothing answers there.

## Design: replace SOCKFS's transport, not Python's `socket` module

Patching Python's `socket` module would miss C extensions. Instead, the Emscripten fd-level socket layer stays and its
transport is replaced by a native bridge. Four pieces:

| Piece | File | Job |
|---|---|---|
| Worker socket layer | `Strata/Resources/PyRuntime/sockets.js` | SOCKFS sockets whose operations call the bridge |
| Python glue | `Strata/Resources/PyRuntime/strata_net.py` | constants, `socketpair`, `select`, `ssl`, `asyncio` |
| Native bridge | `Strata/Tools/Python/PySocketBridge.swift` | Network.framework sockets, policy, limits, activity |
| Approval card | `Strata/Engine/ToolApprovals.swift`, `Strata/DesignSystem/PythonViews.swift` | the network card |

### 1. Worker side (`sockets.js`)

- `Module.SOCKFS.createSocket` is replaced after `loadPyodide`. New sockets are ordinary SOCKFS nodes (so `fstat`, `dup`,
  `close`, `select`, `fcntl` and Pyodide's C wrappers keep working) whose `sock_ops` call the bridge: `bind`, `connect`,
  `listen`, `accept`, `sendmsg`, `recvmsg`, `poll`, `getname`, `ioctl(FIONREAD, FIONBIO)`, `fcntl64(F_GETFL/F_SETFL)` and
  `shutdown`. `AF_INET` and `AF_INET6`, `SOCK_STREAM` and `SOCK_DGRAM`; `SOCK_RAW` raises `PermissionError`.
- Three syscalls don't go through `sock_ops`, so they are swapped in the wasm imports as Pyodide instantiates its module
  (`hookInstantiate` wraps `WebAssembly.instantiate` / `instantiateStreaming`; call it before `loadPyodide`):
  - `__syscall_poll`: Emscripten's ignores the timeout. Ours sends every bridged fd to the bridge in one call that waits
    up to the timeout; files and pipes are always ready; with nothing to watch it is a native sleep.
  - `__syscall_getsockopt`: `SO_ERROR` (asyncio reads it after a non-blocking connect), `SO_TYPE`, `SO_DOMAIN`,
    `SO_PROTOCOL`, `SO_ACCEPTCONN` and plausible values for buffer sizes, `TCP_NODELAY` and `IP_TTL`.
  - `__syscall_getsockname`: Emscripten reads the socket's fields directly; a socket that connected without blocking
    learns its local port first. `__syscall_recvfrom` is wrapped only to pass `MSG_PEEK` / `MSG_DONTWAIT` on.
- `setsockopt` is Pyodide's own and accepts the common options (they have no effect).
- Pyodide passes `fcntl`'s variadic arguments on as a pointer; `F_SETFL` reads the flags through it (Emscripten's own
  only ever adds flags, so `setblocking(True)` never took).
- **Deviation: synchronous `XMLHttpRequest`, not `SharedArrayBuffer` + `Atomics.wait`.** Cross-origin isolation works
  (COOP/COEP from the scheme handler give `crossOriginIsolated === true`), but a SAB round trip needs worker → page →
  `WKScriptMessageHandler` (JSON only, so payloads go base64) → page → `Atomics.notify`. A synchronous POST to
  `strata-py://app/sock` from the worker is one hop with binary bodies, and it needs no headers that could break the
  page's other loads. Each request and reply is one frame: a little-endian u32 length, that many bytes of JSON, then
  the payload bytes. Errors come back as errno names (`{"errno": "ECONNREFUSED"}`).
- A synchronous XHR spins a nested run loop, and WebKit runs `FinalizationRegistry` callbacks there. Pyodide's frees a
  proxy's Python object, which needs the GIL CPython released for the syscall: a fatal `NoGilError`. `sockets.js`
  wraps `FinalizationRegistry` so callbacks that arrive during a bridge call wait for the next task.

### 2. Native bridge (`PySocketBridge`)

- One per interpreter, owned by the `PyodideServer` that serves the page. All state lives on one serial queue, where
  Network.framework delivers its callbacks too; calls that wait (blocking `recv`, `accept`, `connect`, `poll`) register
  a condition that every state change re-checks.
- TCP: `NWConnection` per socket, each resolved address tried in turn (`.waiting` counts as failure, so a refused
  connection fails at once instead of retrying). Received bytes are buffered (up to 4 MB, then reading pauses), sends
  queue up to 4 MB before `send` blocks or returns `EAGAIN`. `connect` on a non-blocking socket returns `EINPROGRESS`.
- Listening: `NWListener` (loopback only when bound to a loopback address), up to 128 waiting connections.
- UDP: one `NWConnection` per peer; a bound socket also gets an `NWListener` for datagrams from new peers.
- Timeouts follow `settimeout`: CPython turns them into `poll` calls with a timeout, which the bridge serves.
- DNS: Emscripten's `getaddrinfo` hands out fake 172.29.x.x addresses and keeps the names; `sockets.js` maps a fake
  address back to its name and the bridge resolves it (`SystemHostResolver`) for the policy check, then connects to
  the resolved addresses. Real multi-record `getaddrinfo` results are not exposed to Python (names still connect).
  `dnspython` and other UDP DNS clients just use UDP sockets.

### 3. TLS (deviation)

Pyodide 314's `ssl` is a stub without OpenSSL (its `do_handshake` only works with Node's sockets), and there is no
OpenSSL package in the lock file. So TLS runs in the app:

- `ssl.SSLContext.wrap_socket(...)` / `SSLSocket.do_handshake()` call the bridge's `tls` op on the socket's fd. The
  bridge starts a TLS `NWConnection` to a one-shot loopback listener whose accepted end is piped to the raw TCP
  connection (Network.framework can't add TLS to a live connection). From then on the same fd carries plain bytes.
- Verification: the system's roots plus the context's own CAs (`load_verify_locations(cadata=/cafile=)`), the host name
  when `check_hostname` is set, SNI and ALPN, TLS 1.2 minimum. `CERT_NONE` skips the check. `certifi`'s bundle is
  ignored (the system roots stand in for it).
- `getpeercert(binary_form=True)` returns the leaf's DER; the dict form has only the subject's common name.
  `version()`, `cipher()` and `selected_alpn_protocol()` work.
- asyncio: `loop.create_connection(ssl=...)`, `open_connection(ssl=...)` and `start_tls` do the same handshake (the
  worker blocks for it), then a plain socket transport carries the decrypted bytes.
- Not supported: TLS servers (`server_side=True`, `start_server(ssl=...)`), client certificates
  (`load_cert_chain`), `ssl.MemoryBIO` / `SSLObject` used directly.

### 4. asyncio (adjusted)

- Pyodide's own `WebLoop` (the loop top-level `await` and its promises run on) gets the selector loop's socket support
  in place: `strata_net.install()` swaps its class to `StrataWebLoop`, which takes `add_reader`, `sock_*`,
  `create_connection`, `create_server`, `create_datagram_endpoint` and friends from `BaseSelectorEventLoop`. Instead
  of blocking in `select()`, a pump task awaits the bridge's asynchronous `poll` (a `fetch`), so JavaScript promises
  (`pyfetch`) and timers keep settling. So top-level `await asyncio.open_connection(...)` works next to `pyfetch`.
- `asyncio.run()` and `new_event_loop()` give a `SelectorLoop` that blocks the worker until done. asyncio allows one
  running loop and one current task per thread, so the selector loop steps out of the WebLoop's running task and puts
  it back afterwards. A JavaScript promise can't settle while it blocks: `pyfetch` inside `asyncio.run` hangs, which
  the tool description says (use top-level `await`).

## Policy

- Public addresses: allowed without asking.
- Private and local addresses (RFC 1918, link-local, loopback, `.local`, CGNAT 100.64/10, IPv6 ULA and link-local,
  per `URLGuard`), including a public name that resolves to one: a network card under the run's line, "Allow Python
  to connect to host?" with Allow in this chat / Deny. Allowed holds for that chat and host for the app session
  (`ToolApprovals.allowInChat("network/<host>")`). A refusal raises `PermissionError` and the run's output says
  "The user did not allow connecting to host:port."; the host isn't asked again in that run. A card nobody answers
  in 5 minutes, a stopped turn, or a run that ends counts as a refusal. The run's time limit stops while the card waits.
- The interpreter's own loopback listeners need no card (a server and client in the same code).
- Multicast and broadcast destinations are refused with a note (see below).
- Listening sockets: on the device and the LAN. The run's network line says "listening on TCP port N (192.168.x.y)".
- Limits:
  - At most 64 open sockets per interpreter (`EMFILE`; enforced in the worker and the bridge).
  - A per-run byte budget of `PyNetwork.maxBytes` in and out (`ENOBUFS` with a note).
  - Every socket closes when the interpreter resets (time limit, memory, chat switch, idle) or the turn is stopped.
- Payloads are never logged. The run card shows host:port, protocol and bytes each way, live while it runs and as the
  last line of the output ("[Network: TCP db.local:5432, 1.2 kB sent, 45 kB received]"), which the model sees too.

## What iOS can't do (in the tool description)

- Raw sockets and ICMP (`ping`): there's no `SOCK_RAW` for apps.
- Multicast and broadcast (mDNS, SSDP, Wake-on-LAN): these need Apple's `com.apple.developer.networking.multicast`
  entitlement. To get it (not requested):
  1. Request it at developer.apple.com/contact/request/networking-multicast with the app's bundle IDs and why it needs
     multicast (e.g. "Python code the user runs discovers and talks to devices on their network").
  2. Once granted, enable it on the App IDs (`cc.coolservices.strata`, the Mac app) in Certificates, Identifiers &
     Profiles and regenerate the profiles.
  3. Add `com.apple.developer.networking.multicast = true` to the entitlements in `project.yml`, plus
     `NSBonjourServices` for any Bonjour types (`NSLocalNetworkUsageDescription` is already set and mentions Python).
  4. Drop the multicast refusal in `PySocketPolicy.verdict`, and in the bridge join groups with `NWConnectionGroup` /
     `NWMulticastGroup` for `IP_ADD_MEMBERSHIP` (not implemented today).
- Inbound connections from the internet: carrier NAT blocks them. Same Wi-Fi works.
- Background: connections may drop when the app is suspended, beyond the continued-processing lease.

## Tests (Swift Testing, no external network)

`StrataTests/PythonSocketTests.swift` runs loopback servers (`NWListener`) in the test process: TCP echo, a silent
server, UDP echo, HTTP/1.1, SMTP, and TLS with a test CA (certificate valid until 2028-12-25; the file says how to make
new ones). Through the real Pyodide runtime:

- TCP echo blocking and non-blocking, `select`, `select.poll`, `makefile`, non-blocking `connect_ex` + `SO_ERROR`
- UDP `sendto`/`recvfrom` and connected UDP
- `settimeout` expiry (`TimeoutError`) and `ConnectionRefusedError`
- an HTTP/1.1 request by hand, and `http.client`
- `bind`/`listen`/`accept` in the same code, without a card
- TLS with `cadata`, ALPN, `getpeercert`, an untrusted certificate (`SSLCertVerificationError`), `CERT_NONE`
- asyncio: `open_connection` on both loops, with and without TLS, `start_server`, datagram endpoints, and a JavaScript
  promise on the page's loop
- `smtplib` sending a message
- policy: a local host asks once per chat (the card answered through `ToolApprovals.shared`), a refusal raises
  `PermissionError`, 64 sockets, raw sockets and multicast refused, a reset closes every socket

`PySocketBridgeTests` drives the bridge frame by frame (byte budget, socket limit, one card for concurrent connections,
refusal for the rest of the run); `PySocketUnitTests` covers the policy, frames, the activity line and the description.

Packages from PyPI or the Pyodide CDN (`redis`, `pymysql`, `pg8000`, `aiohttp`, `asyncpg`, `paramiko`) download from
the network, so they aren't in the test suite. To try a real database by hand:

```sh
# On the Mac, a throwaway Postgres and MySQL reachable from the simulator (it shares the Mac's network)
docker run --rm -e POSTGRES_PASSWORD=pw -p 5432:5432 postgres:17
docker run --rm -e MYSQL_ROOT_PASSWORD=pw -p 3306:3306 mysql:8
```

Then ask the app to run, and allow the card for the Mac's LAN address (or `127.0.0.1` in the simulator):

```python
import micropip; await micropip.install(["pg8000", "pymysql"])
import pg8000.native, pymysql
print(pg8000.native.Connection("postgres", host="127.0.0.1", password="pw").run("select version()"))
print(pymysql.connect(host="127.0.0.1", user="root", password="pw").cursor().execute("select 1"))
```

`asyncpg` (in Pyodide's lock file): `conn = await asyncpg.connect("postgresql://postgres:pw@127.0.0.1/postgres")` with
top-level `await`.

## Tell the model

The `run_python` description (`Strata/Networking/ChatAPI.swift`) says, briefly: real TCP and UDP sockets through the
`socket` module and libraries on top (database drivers, `smtplib`, `imaplib`, `paramiko`, asyncio streams, `aiohttp`),
TLS as a client; private and LAN addresses ask first and a refusal raises `PermissionError`; not possible: raw sockets
or ICMP, multicast or broadcast (needs an Apple entitlement), connections from the internet, `subprocess`;
connections can drop in the background; files live only in the chat's interpreter; `pyfetch` needs top-level `await`
rather than `asyncio.run`. The description is the same for every request, so the prompt cache holds within a chat.
