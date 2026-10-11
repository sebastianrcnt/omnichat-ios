#!/usr/bin/env python3
"""Tiny OpenAI-compatible mock gateway for Strata smoke runs.

  python3 Tools/mock_server.py [port]      (default 8765, binds 127.0.0.1)

GET  /v1/models              -> one model with a context length
POST /v1/chat/completions    -> SSE stream. Behaviour depends on the conversation:
  * last user text contains "plain"  -> reasoning + a markdown answer, no tools
  * otherwise, scripted tool loop: round 0 = reasoning + web_search tool call,
    round 1 = reasoning + web_fetch tool call, round 2 = final markdown answer that cites the
    <source id="N"> blocks found in the tool messages with [N].
Streaming is deliberately bursty (small and large chunks) and tool-call arguments are split across chunks.
No auth is checked; the API key is never logged.
"""
import json
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

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

| API | Use |
|---|---|
| `glassEffect` | Apply the material |
| `GlassEffectContainer` | Blend neighbours |

**한국어 요약:** **"글래스"**는 컨트롤에만 쓰고, **본문(텍스트)**는 유리 위에 올리지 않는 것이 좋습니다 [{a}] [{unknown}].
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

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            self._json(200, {"object": "list", "data": [{"id": "strata-mock", "object": "model", "max_model_len": 262144}]})
        else:
            self._json(404, {"error": {"message": "not found"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        req = json.loads(self.rfile.read(length) or b"{}")
        msgs = req.get("messages", [])
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

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        raw_wfile = self.wfile
        self.wfile = _Chunked(raw_wfile)

        plain = "plain" in user_text.lower() or not tools_enabled
        prompt_tokens = 400 + 900 * rounds
        if plain:
            self.stream_text("Quick thought: this is a simple request.\n\n", PLAIN)
            usage = {"prompt_tokens": 120, "completion_tokens": 90,
                     "prompt_tokens_details": {"cached_tokens": 64}, "completion_tokens_details": {"reasoning_tokens": 12}}
        elif rounds == 0:
            self.stream_reasoning(REASONING_0)
            self.stream_tool_call("call_s1", "web_search", json.dumps({"query": "SwiftUI liquid glass guidelines"}))
            usage = {"prompt_tokens": prompt_tokens, "completion_tokens": 60, "completion_tokens_details": {"reasoning_tokens": 40}}
        elif rounds == 1:
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
            self.stream_content(ANSWER.format(a=a, b=b, c=c, unknown=97))
            usage = {"prompt_tokens": prompt_tokens, "completion_tokens": 420,
                     "prompt_tokens_details": {"cached_tokens": prompt_tokens - 300},
                     "completion_tokens_details": {"reasoning_tokens": 80}}
        sse(self, chunk({}, finish="tool_calls" if (not plain and rounds < 2) else "stop"))
        if req.get("stream_options", {}).get("include_usage"):
            sse(self, {"id": "mock", "object": "chat.completion.chunk", "model": "strata-mock", "choices": [], "usage": usage})
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.wfile.close()
        self.wfile = raw_wfile  # keep-alive: the next request on this connection needs the raw writer

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

    def stream_tool_call(self, call_id, name, args):
        sse(self, chunk({"tool_calls": [{"index": 0, "id": call_id, "type": "function", "function": {"name": name, "arguments": ""}}]}))
        for p in pieces(args, sizes=(6, 9, 4)):
            sse(self, chunk({"tool_calls": [{"index": 0, "function": {"arguments": p}}]}))
            time.sleep(0.02)


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
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"mock gateway on http://127.0.0.1:{port}/v1", flush=True)
    srv.serve_forever()
