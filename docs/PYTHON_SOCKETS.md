# Python sockets: real TCP/UDP for the Pyodide sandbox

Status: approved by the product owner on 2026-10-22, not started. Goal: **practically every Python package that uses
TCP or UDP works** in `run_python`. That covers pure-Python clients (`pg8000`, `pymysql`, `redis`, `smtplib`, `imaplib`,
`ftplib`, `paramiko`, `dnspython`), asyncio clients (`asyncpg`, `aiohttp`, `websockets`), and C extensions built for
Pyodide that call the socket syscalls themselves.

## Today

- Pyodide runs in a dedicated worker (`Strata/Resources/PyRuntime/worker.js`) inside a WKWebView served from
  `strata-py://app` (`Strata/Tools/Python/PyodideServer.swift`).
- HTTP(S) only: `fetch` and `XMLHttpRequest` are rewritten to `strata-py://app/proxy?u=…`, and `PyNetwork` makes the
  request natively. No CORS limits, public hosts only (`URLGuard`), a 200 MB cap, and no cookies.
- `socket.socket().connect(...)` fails. Emscripten's SOCKFS backs sockets with a WebSocket to `ws://host:port`, and
  nothing answers there.

## Design: replace SOCKFS's transport, not Python's `socket` module

Patching Python's `socket` module would miss C extensions, and would break `ssl` (CPython's `ssl` needs a real fd).
Instead, keep the Emscripten fd-level socket layer and replace its transport with a native bridge.

1. **Worker side (JS).** Override SOCKFS's socket operations on the Pyodide module: `connect`, `bind`, `listen`,
   `accept`, `sendmsg`, `recvmsg`, `poll`, `close`, `getname`, `getpeername`, `ioctl(FIONREAD)`, `shutdown`, and the
   socket options that matter (`SO_ERROR`, `TCP_NODELAY`, `SO_REUSEADDR`, `SO_KEEPALIVE`). Find the
   exported SOCKFS / syscall hooks in the pinned Pyodide build first. If SOCKFS isn't reachable, hook `__syscall_*`
   socket syscalls.
2. **Blocking without async.** CPython calls are synchronous, so the worker posts a request to the host and waits with
   `Atomics.wait` on a `SharedArrayBuffer`. The host writes the reply into the buffer and calls `Atomics.notify`.
   - This needs cross-origin isolation: serve the page and worker with `Cross-Origin-Opener-Policy: same-origin` and
     `Cross-Origin-Embedder-Policy: require-corp` from the custom scheme handler.
   - Check that WKWebView custom schemes honor them and that `crossOriginIsolated === true` in the worker.
   - Fallback if they don't: a synchronous `XMLHttpRequest` to `strata-py://app/sock/...` handled natively. It's
     slower but works in workers.
3. **Host side (Swift).** A new `PySocketBridge`:
   - `NWConnection` for TCP and UDP. `NWListener` for bind and listen on the device (LAN only).
   - Per-fd receive buffers, so `poll` and `select` can answer readable, writable, error and hangup without waiting.
   - Timeouts follow `settimeout`. Non-blocking sockets get `EAGAIN` and `EINPROGRESS` right.
4. **DNS.** Emscripten resolves names to fake addresses (172.29.x.x) and keeps the mapping. The bridge maps a fake
   address back to its host name and lets `NWConnection` resolve it. Real `getaddrinfo` results (several A/AAAA
   records) are a nice-to-have. UDP DNS clients (`dnspython`) just use UDP sockets.
5. **TLS.** Once sockets are real fds, Pyodide's `ssl` module works on top: OpenSSL runs in wasm. Use the `certifi`
   bundle so certificate checks pass. Check that it ships, or vendor it.
6. **asyncio.** Pyodide's default `WebLoop` has no socket support. For code that uses asyncio sockets, run with a
   `SelectorEventLoop` over the bridged `select`/`poll`. The worker is dedicated, so blocking it is fine. Make
   `asyncio.run(...)` in user code pick it, through a policy set at init. Keep the WebLoop path working for `pyfetch`.

## Policy (product owner's defaults)

- Public addresses: allowed without asking.
- Private and LAN addresses (RFC 1918, link-local, loopback, `.local`, CGNAT 100.64/10, IPv6 ULA and link-local):
  allowed after an approval card, the same `SSHRequests`-style card. Once approved, it holds for that chat and host.
  If the package system's `ToolApprovals` lands first, use it.
- Listening sockets: device-local and LAN only. Show "Python is listening on port N" in the run's card.
- Limits:
  - At most 64 open sockets per interpreter.
  - A per-run byte budget like `PyNetwork.maxBytes`.
  - Every socket closes when the run's interpreter resets or the chat stops.
- Never log payloads. The run card shows host:port, protocol, and bytes in and out.

## What iOS can't do (document it in the tool's prompt text)

- Raw sockets and ICMP (`ping`): there's no `SOCK_RAW` for apps.
- Multicast and broadcast (mDNS, SSDP, Wake-on-LAN): these need Apple's `com.apple.developer.networking.multicast`
  entitlement, which needs a request to Apple. Write up the steps; don't request it.
- Inbound connections from the internet: carrier NAT blocks them. Same-Wi-Fi works.
- Background: connections may drop when the app is suspended, beyond the continued-processing lease.

## Tests (Swift Testing, no external network)

- A local mock TCP/UDP server in the test process (`NWListener`) and/or `Tools/mock_server.py` extensions.
- Python-level tests through the real Pyodide runtime, as `PythonToolTests` does:
  - echo over TCP, blocking and non-blocking
  - `select`
  - UDP echo
  - `settimeout` expiry
  - connection refused (`ConnectionRefusedError`)
  - TLS to a local server with a test CA
  - `asyncio.open_connection`
  - an HTTP/1.1 request written by hand over a socket
  - a `bind`/`listen`/`accept` round trip
- Policy:
  - a private address asks once
  - a refusal raises `PermissionError`
  - the limits hold
  - reset closes sockets
- Package smoke tests against local servers where they're cheap (`redis` with a fake RESP server, `smtplib` with a
  tiny SMTP server). Real Postgres or MySQL is optional and done by hand. Write down how.
