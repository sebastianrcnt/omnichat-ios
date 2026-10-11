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
- **Composer chip**: model + effort (see Scope changes). Effort opens a sub-page with token-cap hints (low / medium / high / extra / max).
- **Context ring** (top right): context fill. Tapping it opens a Usage sheet with Context, Balance (USD, this chat's cost, today's spend), and optionally the last-turn cache hit.
- **Kept**: sidebar (history, search, new chat, pinned), the `...` menu (pin, rename, share as text, delete), copy/regenerate under answers, a stop button while generating, and the chat title in the header.
- **Dropped**: projects, permissions, device, research, connectors, skills, file attachments, voice mode, gift button, read-aloud, thumbs. (Image attachments and a model picker are back in v1; see Scope changes below.)

## Scope changes (2026-10-11, later)

### Image attachments
- The composer "+" opens a sheet like reference screenshot 01: a camera tile, a recent-photos strip (PhotosPicker), and "Add photo".
- Images go out as OpenAI `content` parts: `{type:"image_url", image_url:{url:"data:image/jpeg;base64,..."}}`. Downscale to about 1568 px on the long side, JPEG at about 0.8 quality.
- Thumbnails show in the composer before sending and in the user bubble afterwards. They persist in SwiftData with external storage.
- Each model has a "supports images" flag. If the selected model doesn't support images, attaching is disabled with an explanation.
- Info.plist carries camera and photo-library usage strings (localizable via InfoPlist.strings / String Catalog).

### Multiple OpenAI-compatible connections
- Settings has a "Connections" list. Each connection has a name, base URL, API key (Keychain, one item per connection), optional custom headers, and a model list fetched from `/models` (manual model entry as fallback).
- Per model: context length, supports images, supports reasoning effort (whether `reasoning_effort` is sent), supports tools (default on).
- A default "Strata" connection preset (`https://llm-api.coolservices.cc/v1`) ships with the app.
- The model picker is back: the composer chip shows model + effort. Tapping it opens a sheet with models grouped by connection, an Effort row (only when the model supports effort), and a checkmark on the current model.
- Each conversation remembers its model. The Usage sheet's Balance section applies only to the Strata connection.
- web_search / web_fetch are sent to any model whose "supports tools" flag is on; the definitions stay byte-identical.
- Plain OpenAI chat-completions only, with no provider-specific code. Both `reasoning_content` and `reasoning` delta fields are treated as thinking.

## Server work needed

- Expose the model context length (e.g. in `/v1/models`) for the context ring.
- A small balance/spend endpoint authenticated by API key (e.g. `/v1/balance`) for the Usage sheet.

## Open

- Real-device install: free Apple ID (re-sign every 7 days) or a paid developer account (TestFlight).
