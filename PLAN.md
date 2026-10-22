# Strata iOS app: plan (2026-10-11)

UI mockups: `reference/mockups/`.

## Decided

- **Platform**: SwiftUI, iOS 26+, Liquid Glass (`glassEffect`, `.buttonStyle(.glass)`, `GlassEffectContainer`). Glass goes on controls only; body text never sits on glass.
- **Branding**: no logo. The accent color is user-selectable (presets plus a custom ColorPicker); the default is purple.
- **Language**: English only, localization-ready. Every user-facing string goes through a String Catalog (`Localizable.xcstrings`). No Korean (or other) translations yet.
- **Backend**: any OpenAI-compatible server the user adds, with a pasted API key stored in the Keychain (none is built in).
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
- The composer "+" opens a sheet: a camera tile, a recent-photos strip (PhotosPicker), and "Add photo".
- Images go out as OpenAI `content` parts: `{type:"image_url", image_url:{url:"data:image/jpeg;base64,..."}}`. Downscale to about 1568 px on the long side, JPEG at about 0.8 quality.
- Thumbnails show in the composer before sending and in the user bubble afterwards. They persist in SwiftData with external storage.
- Each model has a "supports images" flag. If the selected model doesn't support images, attaching is disabled with an explanation.
- Info.plist carries camera and photo-library usage strings (localizable via InfoPlist.strings / String Catalog).

### Multiple OpenAI-compatible connections
- Settings has a "Connections" list. Each connection has a name, base URL, API key (Keychain, one item per connection), optional custom headers, and a model list fetched from `/models` (manual model entry as fallback).
- Per model: context length, supports images, supports reasoning effort (whether `reasoning_effort` is sent), supports tools (default on).
- No connection ships with the app. First run shows "Add a connection" with presets (OpenAI, OpenRouter, Groq, Ollama, LM Studio, ChatGPT, OpenCode, other server); `openchat://add-connection?name=…&url=…` links add one after a confirmation. The connection that used to be built in stays as an ordinary one on existing installs.
- The model picker is back: the composer chip shows model + effort. Tapping it opens a sheet with models grouped by connection, an Effort row (only when the model supports effort), and a checkmark on the current model.
- Each conversation remembers its model. The Usage sheet's Balance section has no provider yet.
- web_search / web_fetch are sent to any model whose "supports tools" flag is on; the definitions stay byte-identical.
- Plain OpenAI chat-completions only, with no provider-specific code. Both `reasoning_content` and `reasoning` delta fields are treated as thinking.

## Server work needed

- Expose the model context length (e.g. in `/v1/models`) for the context ring.
- A small balance/spend endpoint authenticated by API key (e.g. `/v1/balance`) for the Usage sheet.

## Open

- Real-device install: free Apple ID (re-sign every 7 days) or a paid developer account (TestFlight).

## macOS app (2026-10-13)

A native Mac target, `StrataMac` (macOS 26, SwiftUI lifecycle, bundle id `cc.coolservices.strata.mac`), builds from the same `Strata/` sources. It is a separate app from the iPhone one (and from the "Designed for iPhone" run): its own sandbox container, its own SwiftData store, its own Keychain items.

- **Build and run**: `xcodebuild -scheme StrataMac -destination 'platform=macOS' -allowProvisioningUpdates build`, or run the `StrataMac` scheme in Xcode. Entitlements: App Sandbox, `network.client`, `files.user-selected.read-only` (image attachments).
- **Shims**: `DesignSystem/Platform.swift` holds the platform differences (`PlatformImage`, `PlatformColor`, pasteboard, app activation, ImageIO encoding, modifiers that exist on one platform only). Code that only makes sense on iOS (drawer pan, background tasks and the continued-processing lease, memory warnings, in-app Safari, camera and photo strip, trait override) is `#if os(iOS)`; Mac-only code lives in `Strata/Mac/`.
- **UI**: one `Window` with a `NavigationSplitView` (searchable List sidebar, chat in a 760 pt column, toolbar with context usage and the chat menu), a `Settings` scene, and menu commands (New Chat, Stop Generating, sidebar toggle, Find). The composer is an NSTextView (Return sends, Shift+Return newline, input methods get Return first). Images attach from a file panel, drag and drop, or paste.
- **Web tools**: the hidden WKWebView lives in a transparent borderless window parked off screen.
- **Keychain**: the file-based keychain, which works for a sandboxed, development-signed app with no provisioning profile. The data-protection keychain would need a `keychain-access-groups` entitlement and therefore a profile.
- **Not on the Mac**: the in-app text size section (there is no Dynamic Type), the in-app Safari browser (links open in the default browser), camera and the recent-photos strip, background continuation.
- **Checks without UI tests** (Debug builds): `-StrataKeychainSelfTest 1`, `-StrataWebSelfTest 1`, `-StrataKeyTest send|newline|marked` print their outcome to stderr; `Tools/sync_strings.py` also reads `build-mac/`.

