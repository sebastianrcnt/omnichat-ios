#!/usr/bin/env python3
"""Tiny OpenAI-compatible mock gateway for Strata smoke runs.

  python3 Tools/mock_server.py [port]      (default 8765, binds 127.0.0.1)

GET  /v1/models              -> one model with a context length
POST /v1/chat/completions    -> SSE stream. Behaviour depends on the conversation:
  * last user text contains "short"  -> the scripted tool loop with a one-sentence final answer
  * last user text contains "many"   -> seven tool rounds, each with reasoning and a preamble, then the answer
  * last user text contains "plain"  -> reasoning + a markdown answer, no tools
  * otherwise, scripted tool loop: round 0 = reasoning + web_search tool call,
    round 1 = reasoning + web_fetch tool call, round 2 = final markdown answer that cites the
    <source id="N"> blocks found in the tool messages with [N].
Streaming is deliberately bursty (small and large chunks) and tool-call arguments are split across chunks.
No auth is checked; the API key is never logged.
"""
import json
import hashlib
import copy
import os
import threading
import uuid
from urllib.parse import urlparse, parse_qs
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RESUMABLE = "--resumable" in sys.argv
DROP_AFTER = int(os.environ.get("MOCK_DROP_AFTER", "0"))
STREAMS = {}
IDEMPOTENCY = {}
REGISTRY_LOCK = threading.Lock()
RETENTION_SECONDS = 1800
DROP_BEFORE_HEADERS = int(os.environ.get("MOCK_DROP_BEFORE_HEADERS", "0"))


def normalize_key(value):
    if re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", value, re.I | re.ASCII):
        return value.lower()
    if re.fullmatch(r"[0-7][0-9A-HJKMNP-TV-Z]{25}", value, re.I | re.ASCII):
        return value.upper()
    raise ValueError("Idempotency-Key must be UUIDv4 or ULID")


def prune_registry():
    for rid, stream in list(STREAMS.items()):
        if stream.finished_at is not None and time.monotonic() - stream.finished_at >= RETENTION_SECONDS:
            del STREAMS[rid]
            if stream.key is not None:
                IDEMPOTENCY.pop((stream.owner, stream.key), None)


REASONING_0 = ("The user wants current information, so I should search the web first.\n\n"
               "I will look for official documentation and a good tutorial.\n\n")
REASONING_1 = ("The first result looks authoritative. Let me read that page in full to be sure.\n\n")
REASONING_2 = ("I have enough to answer now. I should cite the sources with their ids, keep it concise, "
               "and mention the Korean summary at the end.\n\n")

ANSWER = """# Liquid Glass in SwiftUI

Liquid Glass is Apple's new material for **controls**. Use `glassEffect` on buttons and bars, and keep body text off the glass [{a}][{b}].

## Key points

- Group nearby controls in a `GlassEffectContainer` so they blend [{a}]
- Use `glassEffectID` with a namespace to morph between states
- Never put long text on glass; it hurts readability [{c}][{b}]

1. Add `.glassEffect()` to a control
2. Wrap related controls in a container
3. Test in light and dark mode

> Glass belongs on the controls layer, not the content layer.

```swift
Button("Send", systemImage: "arrow.up") {{ send() }}
    .buttonStyle(.glassProminent)
```

```swift
let step1 = configure(glassEffect: .regular, id: 1) // a long line to make this scroll sideways\nlet step2 = configure(glassEffect: .regular, id: 2) // a long line to make this scroll sideways\nlet step3 = configure(glassEffect: .regular, id: 3) // a long line to make this scroll sideways\nlet step4 = configure(glassEffect: .regular, id: 4) // a long line to make this scroll sideways\nlet step5 = configure(glassEffect: .regular, id: 5) // a long line to make this scroll sideways\nlet step6 = configure(glassEffect: .regular, id: 6) // a long line to make this scroll sideways\nlet step7 = configure(glassEffect: .regular, id: 7) // a long line to make this scroll sideways\nlet step8 = configure(glassEffect: .regular, id: 8) // a long line to make this scroll sideways\nlet step9 = configure(glassEffect: .regular, id: 9) // a long line to make this scroll sideways\nlet step10 = configure(glassEffect: .regular, id: 10) // a long line to make this scroll sideways\nlet step11 = configure(glassEffect: .regular, id: 11) // a long line to make this scroll sideways\nlet step12 = configure(glassEffect: .regular, id: 12) // a long line to make this scroll sideways\nlet step13 = configure(glassEffect: .regular, id: 13) // a long line to make this scroll sideways\nlet step14 = configure(glassEffect: .regular, id: 14) // a long line to make this scroll sideways\nlet step15 = configure(glassEffect: .regular, id: 15) // a long line to make this scroll sideways\nlet step16 = configure(glassEffect: .regular, id: 16) // a long line to make this scroll sideways\nlet step17 = configure(glassEffect: .regular, id: 17) // a long line to make this scroll sideways\nlet step18 = configure(glassEffect: .regular, id: 18) // a long line to make this scroll sideways\nlet step19 = configure(glassEffect: .regular, id: 19) // a long line to make this scroll sideways\nlet step20 = configure(glassEffect: .regular, id: 20) // a long line to make this scroll sideways\nlet step21 = configure(glassEffect: .regular, id: 21) // a long line to make this scroll sideways\nlet step22 = configure(glassEffect: .regular, id: 22) // a long line to make this scroll sideways\nlet step23 = configure(glassEffect: .regular, id: 23) // a long line to make this scroll sideways\nlet step24 = configure(glassEffect: .regular, id: 24) // a long line to make this scroll sideways\nlet step25 = configure(glassEffect: .regular, id: 25) // a long line to make this scroll sideways\nlet step26 = configure(glassEffect: .regular, id: 26) // a long line to make this scroll sideways\nlet step27 = configure(glassEffect: .regular, id: 27) // a long line to make this scroll sideways\nlet step28 = configure(glassEffect: .regular, id: 28) // a long line to make this scroll sideways\nlet step29 = configure(glassEffect: .regular, id: 29) // a long line to make this scroll sideways\nlet step30 = configure(glassEffect: .regular, id: 30) // a long line to make this scroll sideways
```

| API | Use | Notes |
|---|---|---|
| `glassEffect` | Apply the material | Only on controls, never on body text or long reading surfaces |
| `GlassEffectContainer` | Blend neighbours | Groups nearby glass so they merge and morph together |

- **본명/출생**: 조진세 (2~3천 회, ~~x~~)
- **신체 **: 키 177cm
- 그는 "때문에 **꿈을 이뤘다고 생각한다**"

**한국어 요약:** **"글래스"**는 컨트롤에만 쓰고, **본문(텍스트)**는 유리 위에 올리지 않는 것이 좋습니다 [{a}] [{unknown}].
"""

TRANSLATE_SAMPLE = (
    "## Sorting a list\n\n"
    "To sort an array in place, call `sort()` on it. The method keeps the original order of equal elements [1].\n\n"
    "- Use `sorted()` when you need a new array\n"
    "- Read [the documentation](https://developer.apple.com/documentation/swift/array) for the details\n\n"
    "```swift\nvar names = [\"Ada\", \"Grace\"]\nnames.sort()\n```\n\n"
    "| Method | Mutates |\n| --- | --- |\n| sort | yes |\n| sorted | no |\n\n"
    "Remember that sorting large collections takes more time than people usually expect."
)

FONT_SAMPLE = (
    "## Liquid Glass 사용 가이드\n\n"
    "Liquid Glass는 **컨트롤과 내비게이션**에만 쓰세요. Apply it to *controls* and bars, never to body text [{a}][{b}]. "
    "본문 뒤에 깔면 가독성이 떨어지고 줄 간격이 답답해 보입니다.\n\n"
    "- **그룹화**: 인접한 컨트롤은 `GlassEffectContainer`로 묶습니다 [{c}]\n"
    "- Keep tint rare: 강조가 필요한 단 하나의 버튼에만\n\n"
    "```swift\nGlassEffectContainer {{\n    Button(\"저장\") {{ save() }}\n}}\n```\n\n"
    "In short: **콘텐츠가 주인공**이고 glass is the chrome."
)

CODE_SAMPLE = """Here are three small examples.

```swift
struct GlassButton: View {
    let title: String
    var action: () -> Void = {}
    var body: some View {
        Button(title, systemImage: "arrow.up") { action() } // send it
            .buttonStyle(.glassProminent)
            .padding(12)
    }
}
```

```python
import json

def fib(n: int) -> int:
    \"\"\"Return the n-th Fibonacci number.\"\"\"
    return n if n < 2 else fib(n - 1) + fib(n - 2)

print(json.dumps({"fib": [fib(i) for i in range(10)], "ok": True}))
```

```json
{"name": "strata", "version": 1.5, "tags": ["chat", "ios"], "beta": null}
```

```
no language given: guessed from the code if it is short
x = 5
```

```mermaid
graph TD; A-->B;
```
"""


PLAIN = """Sure. Here is a plain answer with **bold**, *italic*, `inline code` and a [link](https://example.com).

- First item
- Second item with a longer description that wraps onto another line for layout testing

Done."""


def sse(handler, obj):
    handler.wfile.write(b"data: " + json.dumps(obj, ensure_ascii=False).encode() + b"\n\n")
    handler.wfile.flush()


def chunk(delta, finish=None, usage=None):
    c = {"id": "mock", "object": "chat.completion.chunk", "model": "strata-mock",
         "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
    if usage:
        c["usage"] = usage
    return c


def pieces(text, sizes=(3, 7, 2, 25, 5, 60, 4)):
    i, k = 0, 0
    while i < len(text):
        n = sizes[k % len(sizes)]
        yield text[i:i + n]
        i += n
        k += 1


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # never log headers/keys
        sys.stderr.write("mock: " + (fmt % args) + "\n")

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def owner(self):
        # Synthetic credentials only: hash for isolation, never log/store their raw value.
        return hashlib.sha256(self.headers.get("Authorization", self.headers.get("x-api-key", "anonymous")).encode()).digest()

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path.startswith("/v1/streams/by-key/"):
            try:
                key = normalize_key(parsed.path.rsplit("/", 1)[-1])
            except ValueError as error:
                return self._json(422, {"error": {"message": str(error)}})
            with REGISTRY_LOCK:
                prune_registry()
                rid = IDEMPOTENCY.get((self.owner(), key))
                stream = STREAMS.get(rid)
            if stream is None:
                return self._json(404, {"error": {"message": "unknown key"}})
            return self._json(200, {"request_id": rid, "state": stream.state, "last_seq": len(stream.events)})
        if parsed.path.startswith("/v1/streams/"):
            rid = parsed.path.split("/")[3]
            with REGISTRY_LOCK:
                prune_registry()
                stream = STREAMS.get(rid)
            if stream and stream.owner != self.owner():
                return self._json(403, {"error": {"message": "forbidden"}})
            if not stream:
                return self._json(404, {"error": {"message": "expired"}})
            if parsed.path.endswith("/status"):
                return self._json(200, {"state": stream.state, "last_seq": len(stream.events)})
            after = int(parse_qs(parsed.query).get("after", [self.headers.get("Last-Event-ID", "0")])[0])
            return self.replay(rid, stream, after)
        if self.path.rstrip("/").endswith("/models"):
            self._json(200, {"object": "list", "data": [{"id": "strata-mock", "object": "model", "max_model_len": 262144,
                      "architecture": {"input_modalities": ["text", "image"], "output_modalities": ["text"]}}]})
        else:
            self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        if self.path.endswith("/cancel"):
            rid = self.path.split("/")[3]
            with REGISTRY_LOCK:
                prune_registry()
                stream = STREAMS.get(rid)
            if stream and stream.owner != self.owner():
                return self._json(403, {"error": {"message": "forbidden"}})
            if not stream:
                return self._json(404, {})
            stream.cancelled = True
            return self._json(200, {"state": "cancelled", "last_seq": len(stream.events)})
        length = int(self.headers.get("Content-Length", "0"))
        req = json.loads(self.rfile.read(length) or b"{}")
        msgs = req.get("messages", [])
        image_parts = [p for m in msgs if isinstance(m.get("content"), list) for p in m["content"] if p.get("type") == "image_url"]
        sys.stderr.write(f"mock: request with {len(image_parts)} image_url part(s)" +
                         "".join(f" [{p['image_url']['url'][:23]}...]" for p in image_parts) + "\n")
        user_text = ""
        for m in reversed(msgs):
            if m.get("role") == "user":
                c = m.get("content")
                user_text = c if isinstance(c, str) else " ".join(p.get("text", "") for p in c if p.get("type") == "text")
                break
        # Tool messages since the last user message
        tail = []
        for m in reversed(msgs):
            if m.get("role") == "user":
                break
            tail.append(m)
        rounds = sum(1 for m in tail if m.get("role") == "assistant" and m.get("tool_calls"))
        tools_enabled = bool(req.get("tools")) and req.get("tool_choice") != "none"

        if RESUMABLE and self.headers.get("X-Strata-Resumable") == "1":
            key = self.headers.get("Idempotency-Key")
            try:
                if key is not None:
                    key = normalize_key(key)
                after = int(self.headers.get("Last-Event-ID", "0"))
                if after < 0:
                    raise ValueError("invalid cursor")
            except ValueError as error:
                return self._json(422, {"error": {"message": str(error)}})
            fingerprint = hashlib.sha256(json.dumps(req, sort_keys=True, separators=(",", ":")).encode()).digest()
            owner = self.owner()
            with REGISTRY_LOCK:
                prune_registry()
                rid = IDEMPOTENCY.get((owner, key)) if key is not None else None
                stream = STREAMS.get(rid)
                created = stream is None
                if stream is not None and stream.fingerprint != fingerprint:
                    return self._json(422, {"error": {"message": "idempotency conflict"}})
                if after > (len(stream.events) if stream else 0):
                    return self._json(400, {"error": {"message": "invalid cursor"}})
                if created:
                    rid = "req_" + uuid.uuid4().hex[:24]
                    stream = ReplayBuffer(owner, key, fingerprint)
                    STREAMS[rid] = stream
                    if key is not None:
                        IDEMPOTENCY[(owner, key)] = rid
            if created:
                worker = copy.copy(self)
                worker.wfile = stream
                def produce():
                    try:
                        worker.generate(req, user_text, tail, rounds, tools_enabled)
                    except InterruptedError:
                        stream.state = "cancelled"
                    finally:
                        stream.close()
                threading.Thread(target=produce, daemon=True).start()
            if not self.before_stream_headers(rid, stream, created):
                self.close_connection = True
                return
            return self.replay(rid, stream, after, drop_after=DROP_AFTER)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        raw_wfile = self.wfile
        self.wfile = _Chunked(raw_wfile)
        try:
            self.generate(req, user_text, tail, rounds, tools_enabled)
        finally:
            self.wfile = raw_wfile

    def before_stream_headers(self, rid, stream, created):
        global DROP_BEFORE_HEADERS
        with REGISTRY_LOCK:
            if created and DROP_BEFORE_HEADERS > 0:
                DROP_BEFORE_HEADERS -= 1
                return False  # accept generation, then close socket without any response headers
        return True

    def replay(self, rid, stream, after, drop_after=0):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("X-Billing-Request-Id", rid)
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        writer = _Chunked(self.wfile)
        sent = 0
        try:
            while True:
                with stream.condition:
                    if after >= len(stream.events) and not stream.done:
                        stream.condition.wait(timeout=1)
                    events = stream.events[after:]
                    done = stream.done
                for event in events:
                    after += 1
                    writer.write(f"id: {after}\n".encode() + event)
                    writer.flush()
                    sent += 1
                    if drop_after and sent >= drop_after:
                        self.close_connection = True
                        return
                if done:
                    writer.close()
                    return
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def generate(self, req, user_text, tail, rounds, tools_enabled):
        plain = "plain" in user_text.lower() or not tools_enabled
        finished = False
        prompt_tokens = 400 + 900 * rounds
        many = "many" in user_text.lower() and not plain  # 7 tool rounds with a preamble each, then the answer
        last_tool_round = 6 if many else 1
        if user_text.startswith("Context checkpoint"):
            # Handoff notes (compaction): a short, well-formed set, ending in a list, not a heading.
            self.stream_reasoning("Writing the handoff notes.\n\n")
            self.stream_content("## Goal\nThe user is researching Liquid Glass in SwiftUI and wants practical guidance.\n\n"
                                "## Progress\n- Searched the web and read Apple's page on applying Liquid Glass to custom views [1].\n"
                                "- Learned: use glassEffect on controls, group them in a GlassEffectContainer, morph with glassEffectID; never put body text on glass.\n\n"
                                "## Remaining\n- Answer the latest question using these findings.\n\n"
                                "## Sources\n- [1] Applying Liquid Glass to custom views - https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views\n")
            usage = {"prompt_tokens": 300, "completion_tokens": 160}
            finished = True
        elif user_text.startswith("[Strata handoff notes]"):
            self.stream_reasoning("The notes already hold the findings.\n\n")
            self.stream_content("Continuing from the notes: use Liquid Glass on **controls** only, grouped in a container, never behind body text [1].")
            usage = {"prompt_tokens": 500, "completion_tokens": 40}
            finished = True
        elif "codesample" in user_text.lower():
            # An answer that is mostly code, to look at syntax highlighting.
            self.stream_reasoning("Show a few languages.\n\n")
            self.stream_content(CODE_SAMPLE)
            usage = {"prompt_tokens": 200, "completion_tokens": 120}
            finished = True
        elif "translatesample" in user_text.lower():
            # Prose around code, a link, a citation and a table, to look at translation.
            self.stream_reasoning("Write a short guide.\n\n")
            self.stream_content(TRANSLATE_SAMPLE)
            usage = {"prompt_tokens": 200, "completion_tokens": 120}
            finished = True
        elif many and rounds <= last_tool_round:
            self.stream_reasoning(f"Round {rounds + 1}: decide what to look at next.\n\n")
            self.stream_content(f"Checking source set {rounds + 1}.")
            if rounds % 2 == 0:
                self.stream_tool_call(f"call_s{rounds}", "web_search", json.dumps({"query": f"liquid glass topic {rounds}"}))
            else:
                self.stream_tool_call(f"call_f{rounds}", "web_fetch", json.dumps({"url": f"https://developer.apple.com/documentation/swiftui/page{rounds}"}))
            usage = {"prompt_tokens": prompt_tokens, "completion_tokens": 40}
        elif "parallel" in user_text.lower() and rounds == 0:
            # One round with several calls at once: a search, two different pages and a repeat of the first.
            self.stream_reasoning("Several lookups are independent, so ask for them together.\n\n")
            base = "https://developer.apple.com/documentation/swiftui/"
            self.stream_tool_call("call_p1", "web_search", json.dumps({"query": "liquid glass"}), index=0)
            self.stream_tool_call("call_p2", "web_fetch", json.dumps({"url": base + "applying-liquid-glass-to-custom-views"}), index=1)
            self.stream_tool_call("call_p3", "web_fetch", json.dumps({"url": base + "glasseffect"}), index=2)
            self.stream_tool_call("call_p4", "web_fetch", json.dumps({"url": base + "applying-liquid-glass-to-custom-views"}), index=3)
            usage = {"prompt_tokens": prompt_tokens, "completion_tokens": 80}
        elif plain:
            self.stream_text("Quick thought: this is a simple request.\n\n", PLAIN)
            usage = {"prompt_tokens": 120, "completion_tokens": 90,
                     "prompt_tokens_details": {"cached_tokens": 64}, "completion_tokens_details": {"reasoning_tokens": 12}}
        elif rounds == 0 and not many:
            self.stream_reasoning(REASONING_0)
            self.stream_content("Let me search for the official guidance.")
            self.stream_tool_call("call_s1", "web_search", json.dumps({"query": "SwiftUI liquid glass guidelines"}))
            usage = {"prompt_tokens": prompt_tokens, "completion_tokens": 60, "completion_tokens_details": {"reasoning_tokens": 40}}
        elif rounds == 1 and not many and "parallel" not in user_text.lower():
            self.stream_reasoning(REASONING_1)
            self.stream_tool_call("call_f1", "web_fetch", json.dumps({"url": "https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views"}))
            usage = {"prompt_tokens": prompt_tokens, "completion_tokens": 50, "completion_tokens_details": {"reasoning_tokens": 30}}
        else:
            ids = re.findall(r'<source id="(\d+)"', "\n".join(str(m.get("content", "")) for m in tail if m.get("role") == "tool"))
            ids = sorted(set(int(i) for i in ids)) or [1]
            a = ids[0]
            b = ids[1] if len(ids) > 1 else ids[0]
            c = ids[2] if len(ids) > 2 else ids[0]
            self.stream_reasoning(REASONING_2)
            if "fontsample" in user_text.lower():
                self.stream_content(FONT_SAMPLE.format(a=a, b=b, c=c))
            elif "short" in user_text.lower():
                self.stream_content(f"Apply glass to **controls** only, never to body text [{a}][{b}][{c}].")
            else:
                self.stream_content(ANSWER.format(a=a, b=b, c=c, unknown=97))
            usage = {"prompt_tokens": prompt_tokens, "completion_tokens": 420,
                     "prompt_tokens_details": {"cached_tokens": prompt_tokens - 300},
                     "completion_tokens_details": {"reasoning_tokens": 80}}
        sse(self, chunk({}, finish="tool_calls" if (not finished and not plain and rounds <= (last_tool_round if many else 1)) else "stop"))
        if req.get("stream_options", {}).get("include_usage"):
            sse(self, {"id": "mock", "object": "chat.completion.chunk", "model": "strata-mock", "choices": [], "usage": usage})
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.wfile.close()

    def stream_reasoning(self, text):
        for p in pieces(text):
            sse(self, chunk({"reasoning_content": p}))
            time.sleep(0.03)

    def stream_content(self, text):
        for p in pieces(text):
            sse(self, chunk({"content": p}))
            time.sleep(0.02)

    def stream_text(self, reasoning, content):
        self.stream_reasoning(reasoning)
        self.stream_content(content)

    def stream_tool_call(self, call_id, name, args, index=0):
        sse(self, chunk({"tool_calls": [{"index": index, "id": call_id, "type": "function", "function": {"name": name, "arguments": ""}}]}))
        for p in pieces(args, sizes=(6, 9, 4)):
            sse(self, chunk({"tool_calls": [{"index": index, "function": {"arguments": p}}]}))
            time.sleep(0.02)


class ReplayBuffer:
    def __init__(self, owner=None, key=None, fingerprint=None):
        self.owner, self.key, self.fingerprint = owner, key, fingerprint
        self.finished_at = None
        self.condition = threading.Condition()
        self.events = []
        self.done = False
        self.cancelled = False
        self.state = "running"

    def write(self, data):
        with self.condition:
            if self.cancelled:
                raise InterruptedError("cancelled")
            self.events.append(data)
            self.condition.notify_all()

    def flush(self):
        pass

    def close(self):
        with self.condition:
            if self.done:
                return
            if not self.events or self.events[-1] != b"data: [DONE]\n\n":
                self.events.append(b"data: [DONE]\n\n")
            self.done = True
            self.finished_at = time.monotonic()
            if self.state == "running":
                self.state = "done"
            self.condition.notify_all()


class _Chunked:
    """Minimal chunked-transfer writer around the socket file."""
    def __init__(self, raw):
        self.raw = raw

    def write(self, data):
        if data:
            self.raw.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")

    def flush(self):
        self.raw.flush()

    def close(self):
        self.raw.write(b"0\r\n\r\n")
        self.raw.flush()


if __name__ == "__main__":
    port = next((int(arg) for arg in sys.argv[1:] if arg.isdigit()), 8765)
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"mock gateway on http://127.0.0.1:{port}/v1", flush=True)
    srv.serve_forever()
