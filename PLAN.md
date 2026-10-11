# Strata iOS app: plan (2026-10-11)

UI reference: `reference/claude-ios-2026-10-11/`. The README there has per-screen notes.

## Decided

- **Platform**: SwiftUI, iOS 26+, Liquid Glass (`glassEffect`, `.buttonStyle(.glass)`, `GlassEffectContainer`). Glass goes on controls only; body text never sits on glass.
- **Branding**: no logo. The accent color is user-selectable (presets plus a custom ColorPicker); the default is purple.
- **Language**: English only, localization-ready. Every user-facing string goes through a String Catalog (`Localizable.xcstrings`). No Korean (or other) translations yet.
- **Backend**: the existing OpenAI-compatible gateway (`llm-api`) with a pasted API key, stored in the Keychain.
- **History**: stored on device only (SwiftData).
- **Web search**: on device, **DuckDuckGo only** for now (the html.duckduckgo.com lite page, in a hidden WKWebView).
  - Engines are data-driven: a URL template plus XPath selectors copied from SearXNG's engine files, with tiny JS for special cases (DDG challenge-form detection).
  - Naver, Brave, Wikipedia, and Exa (through the gateway) are possible later.
- **Web fetch**: on device, in a hidden WKWebView with a non-persistent data store, extracted with Readability.js.
  - Private and LAN addresses are blocked. Output is truncated to a token budget.
  - Naver blog URLs get rewritten to `m.blog.naver.com`.
- **Tool loop**: the app sends fixed `web_search` / `web_fetch` tool definitions every time, which keeps the prefix cache stable. When the model calls a tool, the app runs it, appends the result, and continues.
  - The UI shows a collapsible "Searched the web, read N pages >" row and inline source chips.
- **Thinking**: the raw reasoning chain (`reasoning_content`), not a summary.
  - While thinking: an animated accent indicator plus a live last-line preview.
  - When done: the row collapses to "Thought for Ns >", and tapping it opens a sheet with the full chain that auto-follows while streaming.
- **Composer chip**: effort only (single model), opening an effort sub-page with token-cap hints (low / medium / high / extra / max).
- **Context ring** (top right): context fill. Tapping it opens a Usage sheet with Context, Balance (USD, this chat's cost, today's spend), and optionally the last-turn cache hit.
- **Kept**: sidebar (history, search, new chat, pinned), the `...` menu (pin, rename, share as text, delete), copy/regenerate under answers, a stop button while generating, and the chat title in the header.
- **Dropped**: model picker and more models, projects, permissions, device, research, connectors, skills, attachments (camera/photos/files), voice mode, gift button, read-aloud, thumbs.

## Server work needed

- Expose the model context length (e.g. in `/v1/models`) for the context ring.
- A small balance/spend endpoint authenticated by API key (e.g. `/v1/balance`) for the Usage sheet.

## Open

- Real-device install: free Apple ID (re-sign every 7 days) or a paid developer account (TestFlight).
