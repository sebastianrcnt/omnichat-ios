"""Real sockets for Strata's Python, installed by worker.js at start-up.

sockets.js bridges Emscripten's socket file descriptors to the app's network stack, so `socket`, `select` and C
extensions work unchanged. This module fills in what sits above them in Pyodide:

- socket constants Pyodide's build leaves out (SO_REUSEADDR, ...) and socketpair();
- ssl: Pyodide's ssl is a stub without OpenSSL, so TLS runs in the app, on the socket itself (plain bytes go in and
  out of the same file descriptor afterwards);
- asyncio: the browser event loop (WebLoop) gains the selector loop's socket support and waits asynchronously, so
  top-level `await` with sockets works next to pyfetch; asyncio.run() inside a run uses a blocking selector loop.
"""

import asyncio
import base64
import os
import select
import selectors
import socket
import ssl
import time
import weakref
from asyncio import base_events, events, selector_events, tasks

import _socket
import _strata_net
from pyodide.ffi import to_js
from pyodide.webloop import WebLoop

# MARK: socket

# Linux's numbers (Emscripten's libc uses them); the bridge accepts and ignores the options it can't apply.
_CONSTANTS = {
    "SO_DEBUG": 1, "SO_REUSEADDR": 2, "SO_TYPE": 3, "SO_ERROR": 4, "SO_DONTROUTE": 5, "SO_BROADCAST": 6,
    "SO_SNDBUF": 7, "SO_RCVBUF": 8, "SO_KEEPALIVE": 9, "SO_OOBINLINE": 10, "SO_LINGER": 13, "SO_REUSEPORT": 15,
    "SO_RCVLOWAT": 18, "SO_SNDLOWAT": 19, "SO_RCVTIMEO": 20, "SO_SNDTIMEO": 21, "SO_ACCEPTCONN": 30,
    "SO_PROTOCOL": 38, "SO_DOMAIN": 39, "TCP_NODELAY": 1, "TCP_MAXSEG": 2, "TCP_KEEPIDLE": 4, "TCP_KEEPINTVL": 5,
    "TCP_KEEPCNT": 6, "TCP_USER_TIMEOUT": 18, "IP_TOS": 1, "IP_TTL": 2,
}
for _name, _value in _CONSTANTS.items():
    if not hasattr(socket, _name):
        setattr(socket, _name, _value)
        setattr(_socket, _name, _value)


def socketpair(family=None, type=socket.SOCK_STREAM, proto=0):
    """A connected pair of sockets, kept in the worker (asyncio's self-pipe uses one)."""
    a = socket.socket(socket.AF_INET, type, proto)
    b = socket.socket(socket.AF_INET, type, proto)
    _strata_net.pair(a.fileno(), b.fileno())
    return a, b


socket.socketpair = socketpair


def _select(rlist, wlist, xlist, timeout=None):
    """select.select() over poll(), which the bridge serves (the sockets are not in Emscripten's own select)."""
    if timeout is not None and timeout < 0:
        raise ValueError("timeout must be non-negative")
    fds = {}
    objects = {}
    for flag, items in ((select.POLLIN, rlist), (select.POLLOUT, wlist), (select.POLLPRI, xlist)):
        for item in items:
            fd = item if isinstance(item, int) else item.fileno()
            fds[fd] = fds.get(fd, 0) | flag
            objects.setdefault((fd, flag), item)
    poller = select.poll()
    for fd, mask in fds.items():
        poller.register(fd, mask)
    ready = poller.poll(None if timeout is None else timeout * 1000)
    readable, writable, special = [], [], []
    for fd, revents in ready:
        if revents & (select.POLLIN | select.POLLERR | select.POLLHUP) and (fd, select.POLLIN) in objects:
            readable.append(objects[(fd, select.POLLIN)])
        if revents & (select.POLLOUT | select.POLLERR | select.POLLHUP) and (fd, select.POLLOUT) in objects:
            writable.append(objects[(fd, select.POLLOUT)])
        if revents & select.POLLPRI and (fd, select.POLLPRI) in objects:
            special.append(objects[(fd, select.POLLPRI)])
    return readable, writable, special


select.select = _select

# MARK: ssl

_NO_TLS_SERVER = "TLS servers aren't supported here: Python can make TLS connections, but not accept them."


def _load_verify_locations(self, cafile=None, capath=None, cadata=None):
    if cafile is None and capath is None and cadata is None:
        raise TypeError("cafile, capath and cadata cannot be all omitted")
    cas = self.__dict__.setdefault("_strata_cas", [])
    if cafile:
        path = os.fspath(cafile)
        # certifi's bundle is the public roots, which the system trusts already.
        if not path.replace("\\", "/").endswith("certifi/cacert.pem"):
            with open(path, "rb") as f:
                cas.append(_pem(f.read()))
    if capath:
        for name in sorted(os.listdir(capath)):
            full = os.path.join(capath, name)
            if os.path.isfile(full):
                with open(full, "rb") as f:
                    cas.append(_pem(f.read()))
    if cadata:
        cas.append(cadata if isinstance(cadata, str) else _pem(bytes(cadata)))


def _pem(data):
    if b"-----BEGIN" in data:
        return data.decode("ascii", "replace")
    return ssl.DER_cert_to_PEM_cert(data)


def _set_alpn_protocols(self, protocols):
    self._strata_alpn = [p if isinstance(p, str) else p.decode("ascii") for p in protocols]


ssl.SSLContext.load_verify_locations = _load_verify_locations
ssl.SSLContext.set_alpn_protocols = _set_alpn_protocols


class _TLSState:
    """What the handshake told: version, cipher, ALPN and the server's certificate."""

    def __init__(self, info):
        self.version = info.get("version")
        self.cipher = info.get("cipher")
        self.bits = info.get("bits") or 0
        self.alpn = info.get("alpn") or None
        self.der = base64.b64decode(info["cert"]) if info.get("cert") else None
        self.subject = info.get("subject")

    def peercert(self, binary_form=False):
        if binary_form:
            return self.der
        if self.der is None:
            return None
        return {"subject": ((("commonName", self.subject),),)} if self.subject else {}


def _handshake(fd, context, server_hostname, timeout):
    """TLS on a connected socket, done by the app: certificates are checked against the system's roots plus the
    context's own CAs, and the host name when the context asks for it."""
    if context is None:
        context = ssl.create_default_context()
    if context.check_hostname and not server_hostname:
        raise ValueError("check_hostname requires server_hostname")
    verify = context.verify_mode != ssl.CERT_NONE
    cas = "".join(getattr(context, "_strata_cas", [])) or None
    alpn = ",".join(getattr(context, "_strata_alpn", []))
    info = _strata_net.tls(fd, server_hostname or "", verify, bool(verify and context.check_hostname), cas, alpn,
                           -1 if timeout is None else timeout * 1000)
    info = info.to_py() if hasattr(info, "to_py") else dict(info)
    if info.get("error"):
        message = info.get("message") or info["error"]
        if info.get("verify"):
            error = ssl.SSLCertVerificationError(1, f"[SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: {message}")
            error.verify_code = 1
            error.verify_message = message
            error.reason = "CERTIFICATE_VERIFY_FAILED"
            raise error
        if info["error"] == "ETIMEDOUT":
            raise TimeoutError("_ssl.c: The handshake operation timed out")
        raise ssl.SSLError(1, f"[SSL] {message}")
    return _TLSState(info)


_stub_create = ssl.SSLSocket._create.__func__


def _create(cls, sock, server_side=False, do_handshake_on_connect=True, suppress_ragged_eofs=True,
            server_hostname=None, context=None, session=None):
    if server_side:
        raise NotImplementedError(_NO_TLS_SERVER)
    self = _stub_create(cls, sock, server_side, False, suppress_ragged_eofs, server_hostname, context, session)
    self._strata_tls = None
    self._strata_handshake_on_connect = do_handshake_on_connect
    try:
        self.getpeername()
        connected = True
    except OSError:
        connected = False  # wrapped before connect(): the handshake follows it
    if connected and do_handshake_on_connect:
        timeout = self.gettimeout()
        if timeout == 0.0:
            self.settimeout(None)  # a non-blocking socket still completes its handshake here
        try:
            self.do_handshake()
        finally:
            self.settimeout(timeout)
    return self


def _do_handshake(self, block=False):
    if self._server_side:
        raise NotImplementedError(_NO_TLS_SERVER)
    self._strata_tls = _handshake(self.fileno(), self._context, self._server_hostname, self.gettimeout())


def _connect(self, addr):
    socket.socket.connect(self, addr)
    if self._strata_handshake_on_connect:
        self.do_handshake()


def _connect_ex(self, addr):
    try:
        _connect(self, addr)
        return 0
    except OSError as e:
        return e.errno or 1


def _tls(self):
    return getattr(self, "_strata_tls", None)


ssl.SSLSocket._create = classmethod(_create)
ssl.SSLSocket.do_handshake = _do_handshake
ssl.SSLSocket.connect = _connect
ssl.SSLSocket.connect_ex = _connect_ex
ssl.SSLSocket.getpeercert = lambda self, binary_form=False: _tls(self) and _tls(self).peercert(binary_form)
ssl.SSLSocket.version = lambda self: _tls(self) and _tls(self).version
ssl.SSLSocket.cipher = lambda self: _tls(self) and (_tls(self).cipher, _tls(self).version, _tls(self).bits)
ssl.SSLSocket.selected_alpn_protocol = lambda self: _tls(self) and _tls(self).alpn
ssl.SSLSocket.pending = lambda self: 0
ssl.SSLSocket.shutdown = socket.socket.shutdown


def _accept(self):
    raise NotImplementedError(_NO_TLS_SERVER)


ssl.SSLSocket.accept = _accept


def get_server_certificate(addr, ssl_version=ssl.PROTOCOL_TLS_CLIENT, ca_certs=None, timeout=socket._GLOBAL_DEFAULT_TIMEOUT):
    host, port = addr
    context = ssl.create_default_context(cafile=ca_certs) if ca_certs else ssl._create_unverified_context()
    with socket.create_connection(addr, timeout=timeout) as sock:
        with context.wrap_socket(sock, server_hostname=host) as tls:
            return ssl.DER_cert_to_PEM_cert(tls.getpeercert(True))


ssl.get_server_certificate = get_server_certificate


class _SSLObjectInfo:
    """`transport.get_extra_info("ssl_object")` for a TLS connection the app made."""

    def __init__(self, state, context, server_hostname):
        self._state = state
        self.context = context
        self.server_hostname = server_hostname
        self.server_side = False

    def getpeercert(self, binary_form=False):
        return self._state.peercert(binary_form)

    def version(self):
        return self._state.version

    def cipher(self):
        return (self._state.cipher, self._state.version, self._state.bits)

    def selected_alpn_protocol(self):
        return self._state.alpn

    def compression(self):
        return None


def _tls_extra(state, context, server_hostname):
    info = _SSLObjectInfo(state, context, server_hostname)
    return {"ssl_object": info, "sslcontext": context, "peercert": info.getpeercert(), "cipher": info.cipher(),
            "compression": None}


# MARK: asyncio


class _TLSLoop:
    """TLS for asyncio's transports: the handshake runs in the app (blocking the worker for its duration), then the
    plain socket transport carries the decrypted bytes. asyncio's own TLS (SSLObject over memory BIOs) needs OpenSSL."""

    def _make_ssl_transport(self, rawsock, protocol, sslcontext, waiter=None, *, server_side=False,
                            server_hostname=None, extra=None, server=None, ssl_handshake_timeout=None,
                            ssl_shutdown_timeout=None, call_connection_made=True):
        if server_side:
            raise NotImplementedError(_NO_TLS_SERVER)
        try:
            state = _handshake(rawsock.fileno(), sslcontext, server_hostname, ssl_handshake_timeout or 60)
        except BaseException:
            rawsock.close()
            raise
        extra = dict(extra or {})
        extra.update(_tls_extra(state, sslcontext, server_hostname))
        return self._make_socket_transport(rawsock, protocol, waiter, extra=extra, server=server)

    async def start_tls(self, transport, protocol, sslcontext, *, server_side=False, server_hostname=None,
                        ssl_handshake_timeout=None, ssl_shutdown_timeout=None):
        if server_side:
            raise NotImplementedError(_NO_TLS_SERVER)
        sock = transport.get_extra_info("socket")
        if sock is None:
            raise TypeError(f"transport {transport!r} has no socket")
        transport.pause_reading()
        state = _handshake(sock.fileno(), sslcontext, server_hostname, ssl_handshake_timeout or 60)
        transport._extra.update(_tls_extra(state, sslcontext, server_hostname))
        transport.set_protocol(protocol)
        transport.resume_reading()
        return transport


class _outside_loop:
    """Steps out of the browser loop's running task for a blocking selector loop: asyncio allows one running loop and
    one current task at a time, and puts both back afterwards."""

    def __enter__(self):
        self.loop = events._get_running_loop()
        self.task = tasks.current_task(self.loop) if self.loop is not None else None
        if self.task is not None:
            tasks._leave_task(self.loop, self.task)
        if self.loop is not None:
            events._set_running_loop(None)
        return self

    def __exit__(self, *exc):
        if self.loop is not None:
            events._set_running_loop(self.loop)
        if self.task is not None:
            tasks._enter_task(self.loop, self.task)
        return False


class SelectorLoop(_TLSLoop, asyncio.SelectorEventLoop):
    """asyncio's selector loop, for asyncio.run() and new_event_loop() inside a run. It blocks the worker until it is
    done, which is fine for socket code; a JavaScript promise (pyfetch) can't settle meanwhile, so code that mixes them
    needs top-level `await` instead."""

    def _nested(self, run, *args):
        with _outside_loop():
            return run(*args)

    def run_forever(self):
        return self._nested(super().run_forever)

    def run_until_complete(self, future):
        return self._nested(super().run_until_complete, future)


class _Selector(selectors.PollSelector):
    """The WebLoop's watched file descriptors: its pump waits on them asynchronously, so a change wakes that wait."""

    def __init__(self, changed):
        super().__init__()
        self._changed = changed

    def register(self, fileobj, events, data=None):
        key = super().register(fileobj, events, data)
        self._changed()
        return key

    def unregister(self, fileobj):
        key = super().unregister(fileobj)
        self._changed()
        return key

    def modify(self, fileobj, events, data=None):
        key = super().modify(fileobj, events, data)
        self._changed()
        return key


def _run_handle(handle):
    if not handle._cancelled:
        handle._run()


_READ_EVENTS = select.POLLIN | select.POLLERR | select.POLLHUP | select.POLLNVAL
_WRITE_EVENTS = select.POLLOUT | select.POLLERR | select.POLLHUP | select.POLLNVAL
_BSEL = selector_events.BaseSelectorEventLoop
_BASE = base_events.BaseEventLoop


class StrataWebLoop(_TLSLoop, WebLoop, selector_events.BaseSelectorEventLoop):
    """Pyodide's WebLoop (callbacks on the browser's event loop, so JavaScript promises like pyfetch settle) with the
    selector loop's socket support: streams, servers, datagrams and sock_* calls. Instead of blocking in select(), a
    pump task waits for the watched sockets through the bridge without blocking the worker."""

    def __init__(self):
        WebLoop.__init__(self)
        self._init_selector()

    def _init_selector(self):
        """The selector loop's state, on a WebLoop (a new one, or Pyodide's own once its class is swapped)."""
        self._selector = _Selector(self._selector_changed)
        self._transports = weakref.WeakValueDictionary()
        self._ssock = self._csock = None
        self._internal_fds = 0
        self._ready = []
        self._scheduled = []
        self._stopping = False
        self._closed = False
        self._default_executor = None
        self._executor_shutdown_called = False
        self._thread_id = None
        self._clock_resolution = time.get_clock_info("monotonic").resolution
        self.slow_callback_duration = 0.1
        self._pumping = False

    # The selector loop's versions over the WebLoop's "not available in browsers".
    add_reader = _BSEL.add_reader
    remove_reader = _BSEL.remove_reader
    add_writer = _BSEL.add_writer
    remove_writer = _BSEL.remove_writer
    sock_recv = _BSEL.sock_recv
    sock_recv_into = _BSEL.sock_recv_into
    sock_recvfrom = _BSEL.sock_recvfrom
    sock_recvfrom_into = _BSEL.sock_recvfrom_into
    sock_sendall = _BSEL.sock_sendall
    sock_sendto = _BSEL.sock_sendto
    sock_connect = _BSEL.sock_connect
    sock_accept = _BSEL.sock_accept
    create_connection = _BASE.create_connection
    create_server = _BASE.create_server
    connect_accepted_socket = _BASE.connect_accepted_socket
    create_datagram_endpoint = _BASE.create_datagram_endpoint
    sock_sendfile = _BASE.sock_sendfile
    sendfile = _BASE.sendfile

    def _add_callback(self, handle):
        if not handle._cancelled:
            self.call_soon(_run_handle, handle)

    def _selector_changed(self):
        if not self._selector.get_map():
            return
        if self._pumping:
            _strata_net.wake()
        else:
            self._pumping = True
            self.create_task(self._pump())

    async def _pump(self):
        try:
            while self._selector.get_map():
                keys = list(self._selector.get_map().values())
                wanted = [(key.fd, (select.POLLIN if key.events & selectors.EVENT_READ else 0)
                           | (select.POLLOUT if key.events & selectors.EVENT_WRITE else 0)) for key in keys]
                revents = (await _strata_net.wait(to_js(wanted), 30000)).to_py()
                ready = []
                current = self._selector.get_map()
                for (fd, _), mask in zip(wanted, revents):
                    key = current.get(fd)
                    if not mask or key is None:
                        continue
                    events = 0
                    if mask & _READ_EVENTS:
                        events |= selectors.EVENT_READ
                    if mask & _WRITE_EVENTS:
                        events |= selectors.EVENT_WRITE
                    if events & key.events:
                        ready.append((key, events & key.events))
                if ready:
                    self._process_events(ready)
                    await asyncio.sleep(0)  # the callbacks run before the next wait asks again
        finally:
            self._pumping = False
        if self._selector.get_map():
            self._selector_changed()


class _Policy(type(events._get_event_loop_policy())):
    """The browser loop for Pyodide's own use and top-level `await`; new_event_loop() gives a selector loop."""

    def get_event_loop(self):
        if not isinstance(self._default_loop, StrataWebLoop):
            self._default_loop = StrataWebLoop()
        return self._default_loop

    def new_event_loop(self):
        return SelectorLoop()

    def set_event_loop(self, loop):
        if isinstance(loop, WebLoop):
            self._default_loop = loop  # the runtime's own loop stays; a user's selector loop is used directly


_pyodide_run = asyncio.run


def _run(main, *, debug=None, loop_factory=None):
    if not isinstance(events._get_running_loop(), WebLoop):
        return _pyodide_run(main, debug=debug, loop_factory=loop_factory)
    with _outside_loop():
        with asyncio.Runner(debug=debug, loop_factory=loop_factory or SelectorLoop) as runner:
            return runner.run(main)


def install():
    """Gives Pyodide's own loop (the one top-level `await` and its promises run on) the selector loop's socket support,
    and makes asyncio.run() use a selector loop."""
    policy = events._get_event_loop_policy()
    loop = policy.get_event_loop()
    if isinstance(loop, WebLoop) and not isinstance(loop, StrataWebLoop):
        loop.__class__ = StrataWebLoop
        loop._init_selector()
    policy.__class__ = _Policy
    asyncio.run = _run
