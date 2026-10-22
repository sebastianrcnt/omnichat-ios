#!/usr/bin/env python3
"""Tiny OpenAI-compatible mock gateway for Strata smoke runs.

  python3 Tools/mock_server.py [port]      (default 8765, binds 127.0.0.1)

GET  /v1/models              -> one model with a context length
POST /v1/chat/completions    -> SSE stream. Behaviour depends on the conversation:
  * last user text contains "short"  -> the scripted tool loop with a one-sentence final answer
  * last user text contains "many"   -> seven tool rounds, each with reasoning and a preamble, then the answer
  * last user text contains "plain"  -> reasoning + a markdown answer, no tools
  * last user text contains "longthink" -> long Markdown reasoning (bold headings, code, lists), then a short answer
  * last user text contains "feedsample" -> the chat-feed mockup: search, three reads (one blocked), a second
    search, two reads plus a page of its own choosing, then an answer with block quotes (use -StrataFakeTools 1)
  * otherwise, scripted tool loop: round 0 = reasoning + web_search tool call,
    round 1 = reasoning + web_fetch tool call, round 2 = final markdown answer that cites the
    <source id="N"> blocks found in the tool messages with [N].
  With --showcase (App Store screenshots; see SHOWCASE below), /v1/models lists showcase model names, titles fit the
  showcase chats, and these run instead (real tools, not -StrataFakeTools):
  * "Lisbon"           -> web_search, three Wikipedia reads in parallel, then a cited answer with a table
  * "invest"           -> run_python (numpy + matplotlib), then an answer that places the figure
  * "Save my home server" -> ssh_credential_save + ssh_server_save for the local mock SSH host (setup chat)
  * "home server"      -> ssh_exec on the saved server "homelab", then a short health summary
  MOCK_SHOWCASE_PAUSE (seconds, default 1.4) paces the thought lines, so the live activity feed can be captured.
Streaming is deliberately bursty (small and large chunks) and tool-call arguments are split across chunks.
Model "strata-mock-responses" only answers the Responses API, like OpenAI's Responses-only models:
POST /v1/chat/completions with it -> 404 "only supported in v1/responses"
POST /v1/responses           -> Responses SSE: reasoning summary, then a web_search call (first round, when tools
                                are offered), then a short answer
No auth is checked; the API key is never logged.
"""
import json
from pathlib import Path
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
SHOWCASE = "--showcase" in sys.argv
RESPONSES_ONLY = "strata-mock-responses"
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

LONG_THINKING = ("**Understanding the question**\n\n"
                 "The user asks how tides work. I should explain the *Moon's gravity* first, then the Sun's part. "
                 "A short comparison of spring and neap tides will help. Keep it friendly and concrete.\n\n"
                 "**Planning the explanation**\n\n"
                 "- Start with the tidal bulge on the near side.\n"
                 "- Explain the far-side bulge with `inertia`, not a second pull.\n"
                 "- Mention that most coasts get **two high tides** a day.\n\n"
                 "**Checking the numbers**\n\n"
                 "The lunar day is about 24 hours 50 minutes, so high tide comes about 50 minutes later each day. "
                 "The Sun's tidal effect is roughly 46% of the Moon's. That is enough detail for now.\n\n")

ARTIFACT_HTML = """<!doctype html>
<html><head><meta charset="utf-8"><title>Bouncing dots</title>
<script src="https://cdn.jsdelivr.net/npm/canvas-confetti@1.9.3/dist/confetti.browser.min.js"></script>
<style>body{font-family:-apple-system,sans-serif;margin:0;padding:16px;background:#111;color:#eee}
canvas{width:100%;height:320px;background:#1d1d1f;border-radius:12px}button{font-size:16px;padding:8px 14px;margin:12px 8px 0 0}</style>
</head><body>
<h2>Bouncing dots</h2>
<canvas id="c"></canvas>
<button onclick="add()">Add dot</button><button onclick="window.confetti && confetti()">Confetti</button>
<p><a href="#c">Jump to the canvas</a> &middot; <a href="https://developer.apple.com/documentation/webkit">WebKit docs</a></p>
<script>
const c=document.getElementById('c'),x=c.getContext('2d');let dots=[];
function size(){c.width=c.clientWidth*devicePixelRatio;c.height=c.clientHeight*devicePixelRatio}
function add(){dots.push({x:Math.random()*c.width,y:Math.random()*c.height,vx:(Math.random()-.5)*8,vy:(Math.random()-.5)*8,h:Math.random()*360})}
function tick(){x.clearRect(0,0,c.width,c.height);for(const d of dots){d.x+=d.vx;d.y+=d.vy;if(d.x<0||d.x>c.width)d.vx*=-1;if(d.y<0||d.y>c.height)d.vy*=-1;
x.fillStyle=`hsl(${d.h},80%,60%)`;x.beginPath();x.arc(d.x,d.y,14,0,7);x.fill()}requestAnimationFrame(tick)}
size();for(let i=0;i<5;i++)add();tick();
</script></body></html>"""

FEED_ANSWER_SHORT = """**2024년 합계출산율은 0.75명**으로, 9년 만에 처음 올랐어요 [{kostat}]. 가장 큰 원인은 **혼인 증가**예요 [{hani}][{reuters}].
"""

FEED_ANSWER = """**2024년 합계출산율은 0.75명**으로, 2015년 이후 9년 만에 처음 올랐어요. 출생아도 23만 8천 명으로 3.6% 늘었어요 [{kostat}].

> 2024년 출생아 수는 238,300명으로 전년 대비 8,300명(3.6%) 증가하였다. [{kostat}]

가장 큰 원인은 **혼인 증가**예요. 코로나19로 미뤄진 결혼이 2022년 하반기부터 몰리면서 혼인이 14.8% 늘었어요 [{hani}][{reuters}].

> Marriages, which had been delayed by the pandemic, jumped and led to more first births within two years.

[{bbc}]

여기에 1991~96년생 에코붐 세대가 주 출산 연령에 들어선 효과가 겹쳤어요.

> 둘째 이상 출산은 여전히 줄고 있어 구조적 반등으로 보기는 이르다.

정부는 `저출생 대응 기획부` 신설을 추진하고 있어요 [{korea}].
"""

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

TABLE_SAMPLE = (
    "## 비교\n\n"
    "Glass belongs on controls [{a}].\n\n"
    "| 항목 | **설명** | 출처 [{a}] | 코드 | Notes on a rather long column |\n"
    "| :--- | --- | :---: | --- | ---: |\n"
    "| 컨트롤 | 버튼과 바에 사용 [{a}] | 공식 [{a}][{b}] | `glass[1]` | Keep tint rare and use it for the single most important action only [{c}] |\n"
    "| 본문 | *never* behind text | [{b}] | `x` | 가독성이 떨어집니다 |\n"
    "| Pipe \\| escaped | [link](https://swift.org) | — | `a \\| b` | done |\n\n"
    "That is all [{c}]."
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


# --- Showcase (App Store screenshots) ---------------------------------------------------------------------------

SHOWCASE_MODELS = ["openai/gpt-oss-120b", "qwen/qwen3-235b-a22b", "deepseek/deepseek-v3.2", "moonshotai/kimi-k2",
                   "z-ai/glm-4.6", "mistralai/mistral-medium-3.1"]

SHOWCASE_TITLES = [("first day in Tokyo", "A first day in Tokyo"), ("Tokyo", "Seoul–Tokyo in November"), ("Lisbon", "Late-October city weather"), ("invest", "Investing $500 a month"),
                   ("Save my home server", "Home server setup"), ("home server", "Home server check")]

SSH_PORT = int(os.environ.get("MOCK_SSH_PORT", "18784"))
# A throwaway password for the local mock SSH host (omnichat-store/tools/mock_ssh.py); not a real credential.
SSH_PASSWORD = "showcase-only"
SSH_COMMAND = ("uptime -p && df -h --output=target,size,used,pcent / /mnt/data && "
               "docker ps --format 'table {{.Names}}\\t{{.Status}}'")


FLIGHTS_URL = "https://flight.naver.com/flights/international/SEL-TYO-20261120/TYO-SEL-20261124?adult=1&fareType=Y"


FARES_JS = (Path(__file__).with_name("showcase_fares.js")).read_text().strip()

SCROLL_TO_RESULTS_JS = ("const el = [...document.querySelectorAll('body *')]"
                        ".find(e => e.children.length === 0 && e.textContent.trim() === '왕복 동시 선택');\n"
                        "if (el) el.scrollIntoView({block: 'start'});\n"
                        "return el ? 'Scrolled to the results.' : 'Not found.';")

AIRLINES = {"트리니티항공": "Trinity Airways", "진에어": "Jin Air", "에어부산": "Air Busan", "제주항공": "Jeju Air",
            "이스타항공": "Eastar Jet", "대한항공": "Korean Air", "아시아나항공": "Asiana Airlines", "티웨이항공": "T'way Air",
            "에어서울": "Air Seoul", "에어프레미아": "Air Premia", "피치항공": "Peach", "집에어": "ZIPAIR",
            "일본항공": "Japan Airlines", "전일본공수": "ANA", "에어로케이": "Aero K", "파라타항공": "Parata Air"}

TOKYO_PLACES = [
    {"name": "Sensō-ji", "category": "Temple", "address": "Asakusa, Taitō", "lat": 35.7148, "lng": 139.7967,
     "note": "Tokyo's oldest temple; go early before the crowds."},
    {"name": "Tokyo Skytree", "category": "Observation deck", "address": "Oshiage, Sumida", "lat": 35.7101, "lng": 139.8107,
     "note": "A short walk from Asakusa, best around sunset."},
    {"name": "Ueno Park", "category": "Park and museums", "address": "Ueno, Taitō", "lat": 35.7156, "lng": 139.7745,
     "note": "Late-November leaves, with the National Museum inside."},
    {"name": "Meiji Jingu", "category": "Shrine", "address": "Yoyogi, Shibuya", "lat": 35.6764, "lng": 139.6993,
     "note": "A quiet forest walk next to Harajuku."},
    {"name": "Shibuya Crossing", "category": "Landmark", "address": "Shibuya", "lat": 35.6595, "lng": 139.7005,
     "note": "Watch it from above, then explore the side streets."},
]

# The skill it saves: short enough to read in the approval sheet. FARES returns the text of each listed fare
# (airlines, times, price) for the assistant to read; the showcase itself parses the page with showcase_fares.js.
SKILL_FARES_JS = """// Each listed fare: airlines, times, price
const t = document.body.innerText.split('\\n')
  .map(s => s.trim()).filter(Boolean);
const num = /^[\\d,]+$/, fares = [];
let from = 0;
t.forEach((s, i) => {
  if (s === '왕복' && num.test(t[i + 1])) {
    const a = Math.max(from, i - 16);
    fares.push(t.slice(a, i + 2).join(' '));
    from = i + 3;
  }
});
return fares.slice(0, args.limit ?? 3);"""

FLIGHT_SKILL = {
    "name": "flight-search",
    "description": "Round-trip fares on flight.naver.com: open the results page, read the cheapest options, let the user book.",
    "body": "Open the results page, no form to fill in:\n"
            "https://flight.naver.com/flights/international/FROM-TO-YYYYMMDD/TO-FROM-YYYYMMDD?adult=1\n"
            "Codes: SEL Seoul, TYO Tokyo, OSA Osaka.\n"
            "Run FARES, then browser_show the page so the user picks and books. Never book for them.\n\n"
            "```js script=FARES\n" + SKILL_FARES_JS + "\n```",
}


def flights_view(raw):
    """The fares FARES_JS read, as an OpenUI card with a choice per flight. Empty when nothing was read."""
    match = re.search(r"\[\s*\{.*\}\s*\]", raw, re.S)
    try:
        fares = json.loads(match.group(0)) if match else []
    except ValueError:
        fares = []
    if not fares:
        return "I couldn't read the fares this time; the page is open above.\n"
    def esc(text):
        return text.replace("\\", "\\\\").replace('"', '\\"')
    fares = sorted(fares, key=lambda f: int(re.sub(r"\D", "", f["fare"]) or 0))[:3]
    def airport(t):
        return t.split(" ")[-1]
    same = len({(airport(f["out"][0]), airport(f["out"][1])) for f in fares}) == 1
    route = f'{airport(fares[0]["out"][0])} ⇄ {airport(fares[0]["out"][1])}, ' if same else ""
    items = []
    for i, f in enumerate(fares, 1):
        names = " + ".join(AIRLINES.get(a, a) for a in f["airlines"]) or "Several airlines"
        fare = "₩" + f["fare"].replace("원", "")
        def leg(times):
            return " → ".join(t if not same else t.split(" ")[0] for t in times)
        detail = f"Out {leg(f['out'])} · Back {leg(f['back'])}"
        items.append(f'RadioItem("{esc(fare)} · {esc(names)}", "{esc(detail)}", "{i}")')
    return ("The three lowest fares on the first page of results:\n\n```openui\n"
            "root = Card([header, pick, actions])\n"
            f'header = CardHeader("Seoul → Tokyo · Nov 20–24", "Round trip {route}1 adult, economy")\n'
            f'pick = RadioGroup("flight", [{", ".join(items)}], "1")\n'
            'actions = Buttons([Button("Book this flight", @OpenUrl("' + FLIGHTS_URL + '")), '
            'Button("Find hotels", @ToAssistant("Find hotels near Ueno for Nov 20–24"), "secondary")])\n'
            "```\n")


def showcase_scenario(user_text):
    if user_text.startswith("The conversation:") or "give this conversation a title" in user_text:
        return "title"
    if "flight" in user_text.lower() and "Tokyo" in user_text:
        return "flights"
    if "first day in Tokyo" in user_text:
        return "places"
    if "Lisbon" in user_text:
        return "research"
    if "invest" in user_text.lower():
        return "python"
    if "Save my home server" in user_text:
        return "ssh_setup"
    if "home server" in user_text.lower():
        return "ssh"
    return None


RESEARCH_ANSWER = """**Athens** is the warmest and driest of the three in late October, and the sea is still warm enough to swim [{ath}].

| October | Lisbon | Barcelona | Athens |
|---|---|---|---|
| Avg high | 22 °C | 22 °C | 24 °C |
| Sea | 19 °C | 21 °C | 22 °C |
| Rainy days | ~9 | ~6 | ~5 |

**Barcelona** is a close second; **Lisbon** is often wet, so pack a jacket [{bcn}][{lis}].
"""

PYTHON_CODE = """import numpy as np
import matplotlib.pyplot as plt

monthly, years = 500, 30
months = np.arange(years * 12 + 1)

plt.figure(figsize=(7, 4.2))
for rate, color in [(0.04, "#9aa5b1"), (0.06, "#5b8def"), (0.08, "#7c4dff")]:
    r = rate / 12
    balance = monthly * ((1 + r) ** months - 1) / r
    plt.plot(months / 12, balance / 1000, color=color, lw=2.6, label=f"{rate:.0%} a year")
    print(f"{rate:.0%}: ${balance[-1]:,.0f}")

plt.plot(months / 12, monthly * months / 1000, "--", color="#b0b0b0", lw=1.6, label="Paid in")
plt.title("$500 a month for 30 years", loc="left", fontweight="bold")
plt.xlabel("Years")
plt.ylabel("Balance ($ thousands)")
plt.grid(alpha=0.25)
plt.legend(frameon=False)
plt.gca().spines[["top", "right"]].set_visible(False)
plt.tight_layout()
"""

PYTHON_ANSWER = """Your **$180,000** grows to **$347,025** at 4%, **$502,258** at 6% and **$745,180** at 8%.

![Balance over 30 years]({figure})

At 8%, **76%** of the balance is growth.
"""

SSH_ANSWER = """**homelab looks healthy.** Up for 23 days.

- **Disk:** /mnt/data is at **81%** of 3.6 TB.
- **Containers:** all four up, three report healthy.
"""


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
        if self.path.rstrip("/").endswith("/models") and SHOWCASE:
            self._json(200, {"object": "list", "data": [{"id": m, "object": "model", "max_model_len": 131072}
                                                        for m in SHOWCASE_MODELS]})
        elif self.path.rstrip("/").endswith("/models"):
            self._json(200, {"object": "list", "data": [{"id": "strata-mock", "object": "model", "max_model_len": 262144,
                      "architecture": {"input_modalities": ["text", "image"], "output_modalities": ["text"]}},
                      {"id": RESPONSES_ONLY, "object": "model", "max_model_len": 200000}]})
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
        if urlparse(self.path).path.endswith("/responses"):
            return self.responses_api(req)
        if req.get("model") == RESPONSES_ONLY:
            return self._json(404, {"error": {"message": "This model is only supported in v1/responses and not in v1/chat/completions.",
                                              "type": "invalid_request_error", "param": "model", "code": None}})
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

    def responses_api(self, req):
        """A standard Responses API stream (store: false, flat function tools)."""
        items = req.get("input", [])
        sys.stderr.write(f"mock: /responses model={req.get('model')} items={len(items)} "
                         f"instructions={'yes' if req.get('instructions') else 'no'} tools={len(req.get('tools') or [])}\n")
        if any(t.get("type") == "namespace" for t in req.get("tools") or []):
            return self._json(400, {"error": {"message": "namespace tools are not supported here"}})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        raw_wfile = self.wfile
        self.wfile = _Chunked(raw_wfile)
        def ev(obj):
            sse(self, obj)
        try:
            ev({"type": "response.created", "response": {"id": "resp_mock"}})
            ev({"type": "response.reasoning_summary_part.added", "item_id": "rs_1", "summary_index": 0})
            for piece in pieces("Checking what the Responses API route has to say."):
                ev({"type": "response.reasoning_summary_text.delta", "item_id": "rs_1", "summary_index": 0, "delta": piece})
                time.sleep(0.03)
            ev({"type": "response.output_item.done", "output_index": 0,
                "item": {"type": "reasoning", "id": "rs_1", "encrypted_content": "mock-encrypted",
                         "summary": [{"type": "summary_text", "text": "Checking what the Responses API route has to say."}]}})
            answered = any(i.get("type") == "function_call_output" for i in items)
            tools = [t.get("name") for t in req.get("tools") or []]
            usage = {"input_tokens": 40 * (len(items) + 1), "output_tokens": 30,
                     "input_tokens_details": {"cached_tokens": 20 * len(items)}, "output_tokens_details": {"reasoning_tokens": 12}}
            if not answered and "web_search" in tools and req.get("tool_choice") != "none":
                ev({"type": "response.output_item.added", "output_index": 1,
                    "item": {"type": "function_call", "call_id": "call_resp_1", "name": "web_search", "arguments": ""}})
                for piece in pieces(json.dumps({"query": "responses api"})):
                    ev({"type": "response.function_call_arguments.delta", "output_index": 1, "delta": piece})
                ev({"type": "response.completed", "response": {"usage": usage}})
                return
            for piece in pieces("This answer came through the **Responses API**. The model refused Chat Completions, "
                                "so Strata switched and will remember it."):
                ev({"type": "response.output_text.delta", "output_index": 1, "delta": piece})
                time.sleep(0.03)
            ev({"type": "response.completed", "response": {"usage": usage}})
        finally:
            self.wfile.close()
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
        self.messages = req.get("messages", [])
        showcase = showcase_scenario(user_text) if SHOWCASE else None
        if showcase:
            finished = self.showcase(showcase, user_text, tail, rounds)
            usage = {"prompt_tokens": prompt_tokens, "completion_tokens": 240}
            sse(self, chunk({}, finish="stop" if finished else "tool_calls"))
            if req.get("stream_options", {}).get("include_usage"):
                sse(self, {"id": "mock", "object": "chat.completion.chunk", "model": "mock", "choices": [], "usage": usage})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            self.wfile.close()
            return
        if user_text.startswith("The conversation:") or "give this conversation a title" in user_text:
            # A naming request; "Regenerate title" names the current title and asks for another.
            self.stream_content("A fresh title" if "The current title is" in user_text else "SQL NULL in aggregates")
            usage = {"prompt_tokens": 120, "completion_tokens": 6}
            finished = True
        elif user_text.startswith("Context checkpoint"):
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
        elif "longthink" in user_text.lower():
            # Reasoning the way OpenAI's summaries write it: bold headings, inline code and a list, over several seconds.
            self.stream_reasoning(LONG_THINKING)
            self.stream_content("Done thinking. **Short answer** here.")
            usage = {"prompt_tokens": 200, "completion_tokens": 300}
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
        elif "feedsample" in user_text.lower():
            finished = self.feed_sample(tail, rounds)
            usage = {"prompt_tokens": prompt_tokens, "completion_tokens": 120}
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
        elif "artifact" in user_text.lower() and not plain and rounds == 0:
            # A show_html call: a small interactive page with a CDN script and an outside link.
            self.stream_reasoning("A small page shows this best.\n\n")
            self.stream_tool_call("call_h1", "show_html", json.dumps({"title": "Bouncing dots", "html": ARTIFACT_HTML}))
            usage = {"prompt_tokens": prompt_tokens, "completion_tokens": 200}
        elif "artifact" in user_text.lower() and not plain:
            self.stream_content("Open the card above to try it: tap **Add dot** to add another one.")
            usage = {"prompt_tokens": prompt_tokens, "completion_tokens": 20}
            finished = True
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
            if "tablesample" in user_text.lower():
                self.stream_content(TABLE_SAMPLE.format(a=a, b=b, c=c))
            elif "fontsample" in user_text.lower():
                self.stream_content(FONT_SAMPLE.format(a=a, b=b, c=c))
            elif "short" in user_text.lower():
                self.stream_content(f"Apply glass to **controls** only, never to body text [{a}][{b}][{c}].")
            else:
                self.stream_content(ANSWER.format(a=a, b=b, c=c, unknown=97))
            usage = {"prompt_tokens": prompt_tokens, "completion_tokens": 420,
                     "prompt_tokens_details": {"cached_tokens": prompt_tokens - 300},
                     "completion_tokens_details": {"reasoning_tokens": 80}}
        feed = "feedsample" in user_text.lower()
        tool_round = (rounds <= 3) if feed else (not finished and not plain and rounds <= (last_tool_round if many else 1))
        sse(self, chunk({}, finish="tool_calls" if tool_round else "stop"))
        if req.get("stream_options", {}).get("include_usage"):
            sse(self, {"id": "mock", "object": "chat.completion.chunk", "model": "strata-mock", "choices": [], "usage": usage})
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.wfile.close()

    def slow_thoughts(self, sentences, pause):
        """One sentence at a time with a pause after each, so the thought line has time to show it."""
        for sentence in sentences:
            self.stream_reasoning(sentence + " ")
            time.sleep(pause)
        self.stream_reasoning("\n\n")

    def feed_sample(self, tail, rounds):
        """The feed mockup's run. Returns True on the final (answer) round."""
        pause = float(os.environ.get("MOCK_FEED_PAUSE", "1.4"))
        if rounds == 0:
            self.slow_thoughts(["The user wants the latest 2024 fertility figures and why they rose.",
                                "I should check the statistics office release first."], pause)
            self.stream_tool_call("call_fs1", "web_search", json.dumps({"query": "2024 합계출산율 반등 원인"}))
        elif rounds == 1:
            self.slow_thoughts(["The statistics office, Hankyoreh and Chosun look most relevant.",
                                "I will read those three."], pause)
            for i, url in enumerate(["https://kostat.go.kr/board.es?act=view&bid=203&list_no=433",
                                     "https://www.hani.co.kr/arti/society/1185021.html",
                                     "https://www.chosun.com/national/2025/02/26/fertility/"]):
                self.stream_tool_call(f"call_ff{i}", "web_fetch", json.dumps({"url": url}), index=i)
        elif rounds == 2:
            self.slow_thoughts(["The causes are only covered by domestic outlets so far.",
                                "Let me look for an international view as well."], pause)
            self.stream_tool_call("call_fs2", "web_search", json.dumps({"query": "South Korea fertility rate 2024 rebound marriages"}))
        elif rounds == 3:
            self.slow_thoughts(["Reuters and the BBC cover the marriage effect.",
                                "The government briefing should have the official explanation too."], pause)
            for i, url in enumerate(["https://www.reuters.com/world/asia-pacific/south-korea-birth-rate-rises-2025-02-26/",
                                     "https://www.bbc.com/news/articles/korea-fertility",
                                     "https://www.korea.kr/briefing/policyBriefingView.do?newsId=156677"]):
                self.stream_tool_call(f"call_fg{i}", "web_fetch", json.dumps({"url": url}), index=i)
        else:
            text = "\n".join(str(m.get("content", "")) for m in tail if m.get("role") == "tool")
            by_url = {}
            for i, u in re.findall(r'<source id="(\d+)"[^>]*url="([^"]+)"', text):
                by_url.setdefault(u, int(i))
            def cid(fragment, fallback=1):
                return next((i for u, i in by_url.items() if fragment in u), fallback)
            self.slow_thoughts(["The figures and the causes are all here.", "Time to write it up."], pause)
            time.sleep(pause)
            answer = FEED_ANSWER_SHORT if os.environ.get("MOCK_FEED_SHORT") else FEED_ANSWER
            self.stream_content(answer.format(kostat=cid("kostat"), hani=cid("hani"), reuters=cid("reuters"),
                                                   bbc=cid("bbc"), korea=cid("korea.kr")))
            return True
        return False

    def showcase(self, scenario, user_text, tail, rounds):
        """One round of a showcase chat. Returns True on the final (answer) round."""
        pause = float(os.environ.get("MOCK_SHOWCASE_PAUSE", "1.4"))
        tool_text = "\n".join(str(m.get("content", "")) for m in tail if m.get("role") == "tool")
        if scenario == "title":
            # The naming request is either its own ("The conversation: ...") or a question after the whole chat.
            everything = json.dumps(self.messages, ensure_ascii=False)
            self.stream_content(next((t for k, t in SHOWCASE_TITLES if k in everything), "A quick question"))
            return True
        if scenario == "research":
            if rounds == 0:
                self.slow_thoughts(["Three cities, one week in late October.",
                                    "I need the October climate normals for each, and the sea temperature for swimming."], pause)
                self.stream_tool_call("call_r1", "web_search", json.dumps({"query": "Lisbon Barcelona Athens October weather sea temperature"}))
                return False
            if rounds == 1:
                self.slow_thoughts(["Wikipedia's climate tables list monthly highs, lows, rainy days and sea temperatures.",
                                    "I'll read all three city pages at once."], pause)
                for i, city in enumerate(["Lisbon", "Barcelona", "Athens"]):
                    self.stream_tool_call(f"call_r2{i}", "web_fetch", json.dumps({"url": f"https://en.wikipedia.org/wiki/{city}"}), index=i)
                return False
            # MOCK_SHOWCASE_DEEP=1: a second search, then the two best pages it found that aren't Wikipedia.
            if os.environ.get("MOCK_SHOWCASE_DEEP") and rounds == 2:
                self.slow_thoughts(["The tables agree on highs and lows.",
                                    "Sea temperatures vary by source, so let me cross-check them."], pause)
                self.stream_tool_call("call_r3", "web_search", json.dumps({"query": "average sea temperature late October Athens Barcelona Lisbon"}))
                return False
            if os.environ.get("MOCK_SHOWCASE_DEEP") and rounds == 3:
                last = next((str(m.get("content", "")) for m in reversed(tail) if m.get("role") == "tool"), "")
                urls = [u for u in re.findall(r'url="([^"]+)"', last) if "wikipedia.org" not in u][:2]
                self.slow_thoughts(["Two of these results have month-by-month sea data.", "Reading both."], pause)
                for i, url in enumerate(urls):
                    self.stream_tool_call(f"call_r4{i}", "web_fetch", json.dumps({"url": url}), index=i)
                if urls:
                    return False
            by_url = {}
            for i, u in re.findall(r'<source id="(\d+)"[^>]*url="([^"]+)"', tool_text):
                by_url.setdefault(u, int(i))
            def cid(city):
                return next((i for u, i in by_url.items() if u.rstrip("/").endswith("/wiki/" + city)), 1)
            self.stream_content(RESEARCH_ANSWER.format(lis=cid("Lisbon"), bcn=cid("Barcelona"), ath=cid("Athens")))
            return True
        if scenario == "python":
            if rounds == 0:
                self.slow_thoughts(["This is a future-value calculation with monthly contributions.",
                                    "I'll compute it exactly and plot all three rates."], pause / 2)
                self.stream_content("I'll run the numbers on your phone and chart them.")
                self.stream_tool_call("call_py1", "run_python", json.dumps({"code": PYTHON_CODE}))
                return False
            figure = re.search(r"figure-\d+(?:-[0-9a-f]{8})?", tool_text)
            self.stream_content(PYTHON_ANSWER.format(figure=figure.group(0) if figure else "figure-1"))
            return True
        if scenario == "ssh_setup":
            # One after the other: the server names the credential, which must exist first.
            if rounds == 0:
                self.stream_tool_call("call_ss1", "ssh_credential_save", json.dumps(
                    {"name": "homelab", "username": "admin", "password": SSH_PASSWORD}))
                return False
            if rounds == 1:
                self.stream_tool_call("call_ss2", "ssh_server_save", json.dumps(
                    {"name": "homelab", "host": "127.0.0.1", "port": SSH_PORT, "user": "admin", "credential": "homelab",
                     "note": "Home server"}))
                return False
            self.stream_content("Saved **homelab**. Ask me to check on it any time.")
            return True
        if scenario == "flights":
            return self.flights(rounds, tail, pause)
        if scenario == "places":
            if rounds == 0:
                self.slow_thoughts(["Old Tokyo in the east, then across to Shibuya by evening."], pause / 2)
                self.stream_content("Start in the east and end in Shibuya:")
                self.stream_tool_call("call_pl1", "show_places", json.dumps({"title": "A first day in Tokyo", "places": TOKYO_PLACES}))
                return False
            self.stream_content("Swipe the cards for why each one is worth it.")
            return True
        if scenario == "ssh":
            if rounds == 0:
                self.slow_thoughts(["One command can cover uptime, disk space and the containers.",
                                    "I'll chain them so it's a single connection."], pause / 2)
                self.stream_content("Checking **homelab** now.")
                self.stream_tool_call("call_sx1", "ssh_exec", json.dumps({"server": "homelab", "command": SSH_COMMAND}))
                return False
            time.sleep(pause * 2)  # the command's output stays on screen a moment, for the screenshot
            self.slow_thoughts(["Everything is up, and the three health checks pass.",
                                "The data disk at 81% is the only thing worth flagging."], pause)
            self.stream_content(SSH_ANSWER)
            return True
        return True

    def flights(self, rounds, tail, pause):
        """Seoul-Tokyo fares on the real flight site: open it, read the fares with FARES_JS, show the page, map a few
        places, summarize the fares as an interactive view, and offer the search as a skill."""
        def result(call_id):
            return next((str(m.get("content", "")) for m in tail if m.get("role") == "tool" and m.get("tool_call_id") == call_id), "")
        if os.environ.get("MOCK_LOG_TOOLS"):
            with open(os.environ["MOCK_LOG_TOOLS"], "a") as log:
                log.write(f"--- round {rounds}\n" + "\n".join(str(m.get("content", "")) for m in tail if m.get("role") == "tool") + "\n")
        if rounds == 0:
            self.slow_thoughts(["Round trip, Seoul to Tokyo, November 20 to 24.",
                                "I'll search the fares on the flight site in the browser."], pause / 2)
            self.stream_tool_call("call_fl1", "browser_open", json.dumps({"url": FLIGHTS_URL}))
        elif rounds == 1:
            self.slow_thoughts(["The results are in.", "I'll read the fares off the page."], pause / 2)
            self.stream_tool_call("call_fl2", "browser_eval", json.dumps({"js": "const args = {limit: 10};\n" + FARES_JS}))
        elif rounds == 2:
            # MOCK_TEST_SKILL=1: run the skill's own script instead, to check what it returns (see MOCK_LOG_TOOLS).
            js = "const args = {};\n" + SKILL_FARES_JS if os.environ.get("MOCK_TEST_SKILL") else SCROLL_TO_RESULTS_JS
            self.stream_tool_call("call_fl3", "browser_eval", json.dumps({"js": js}))
        elif rounds == 3:
            self.stream_content("These are live fares. Have a look on the page itself.")
            self.stream_tool_call("call_fl4", "browser_show", json.dumps({
                "reason": "These are the live fares for Nov 20–24. Tap a flight to see its booking options, then tap Done."}))
        elif rounds == 4 and os.environ.get("MOCK_FLIGHTS_STOP") == "card":
            # Only the fares, for the screenshot of the interactive answer.
            self.stream_content(flights_view(result("call_fl2")))
            return True
        elif rounds == 4:
            self.stream_content(flights_view(result("call_fl2")) + "\nAnd a few places to start with:")
            self.stream_tool_call("call_fl5", "show_places", json.dumps({"title": "Tokyo first picks", "places": TOKYO_PLACES}))
        elif rounds == 5:
            self.slow_thoughts(["That search worked well.", "Saving it as a skill makes the next one a single step."], pause / 2)
            self.stream_tool_call("call_fl6", "save_skill", json.dumps(FLIGHT_SKILL))
        else:
            saved = "saved" in result("call_fl6").lower() and "not" not in result("call_fl6").lower()
            self.stream_content("I saved **flight-search**, so next time fares take one step." if saved
                                else "Tell me which flight you like and I'll look at hotels nearby.")
            return True
        return False

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
