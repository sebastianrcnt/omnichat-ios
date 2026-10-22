# Known issues

Open findings from the October 2026 reviews (two Opus passes and a GPT-6.1 Sol pass), left after commit 6301ffa
(CR-only SSE, the `cancelOnServer` give-up, location waiters and the edit highlight were fixed later).
Everything else those reviews reported was fixed in that commit. Each entry: where, what goes wrong, a fix direction.

## Security and privacy

- **One cookie store for every web view and every chat** (`Tools/HiddenWebView.swift` `BrowserData`, `WebViewPool`,
  `Tools/BrowserTools.swift`). Search, fetch, plugins and the model's browser all use one persistent store, so a
  sign-in or a solved robot check (`cf_clearance`, Google's) works everywhere and survives relaunches. The cost: a site
  signed in through `browser_show` in chat A is signed in for every `web_fetch`, `browser_open` and `browser_eval` in
  every other chat too, so a page that injects instructions in chat B can drive that session (read the account, post,
  buy); and search/fetch now leave cookies, storage and caches on disk where they used to vanish at quit, so sites can
  link the model's visits across chats and launches. Kept on purpose (one app-wide store, no per-site switches); the
  user can see cookies by site and clear everything in Settings > Tools > Browsing data. If it matters: ask before
  `browser_eval` runs on a host with stored cookies, or scope sessions per chat.
- **DNS rebinding** (`Tools/URLGuard.swift`). The guard resolves the host itself, then WebKit or URLSession resolves
  again; a TTL-0 domain can answer public then private. Literal private IPs are now blocked inside pages
  (`LocalNetworkRules`) and redirects are checked, but a rebinding name is not. Fix: connect to the checked IP (pin it),
  or check `URLSessionTaskMetrics.remoteAddress` before using a response.
- **Page subresources to names that resolve privately** (`Tools/HiddenWebView.swift` `LocalNetworkRules`). Content
  rules see URLs, not addresses: they block private literals, single-label hosts (`http://nas/`) and local suffixes
  (`.local`, `.lan`, `.internal`, …), and navigations and artifact iframes are resolved by `URLGuard`, but an image,
  script, `fetch` or XHR in the hidden browser to a public-looking name with a private answer (`*.plex.direct`, split
  DNS) still loads. Artifact pages are narrower (no plain `http:`/`ws:` at all), so what is left there is HTTPS with a
  valid certificate. Fix: route page loads through a `WKURLSchemeHandler`-style proxy that resolves and pins, or
  deny artifact networking except an allowlist of CDNs.
- **ChatGPT refresh exposes the new access token before the ID token is verified** (`ChatGPT/ChatGPTAuth.swift`
  `performRefresh`). Saved first so a rotated refresh token is never lost. Fix: keep the new tokens quarantined until
  verification passes.

## Robustness

- **A script stuck in a synchronous loop blocks its page** (`Tools/HiddenWebView.swift` `discardAbortedScript`). A
  timed-out or stopped script call now has its document replaced with `about:blank` before the session's slot is
  released, so its timers and promises can't act later. A script that never yields (`while(true){}`) keeps the
  WebContent process busy and the blank load gives up after 5 s; nothing it scheduled can run meanwhile, but the page
  stays stuck until the session is closed. Fix: close the session when the replacement fails.
- **Malformed chunks are skipped silently** (`ChatChunkDecoder.decode`, Responses and Anthropic decoders). An event that
  fails to decode becomes an empty delta, so a piece of text or tool arguments can go missing. Lenient on purpose
  (unknown event shapes); could fail only for events that carry content.
- **Non-resumable connections lose the streamed text if the app is killed** (`Engine/ChatController.swift`). ChatGPT,
  OpenCode and plain servers have no checkpoint; the text lives in memory until the turn ends. Fix: save partial
  text/reasoning to the message every few seconds.
- **Background task identifiers pile up** (`Engine/ReplyBackgroundExecution.swift`). Each reply registers a new
  `BGContinuedProcessingTask` handler, and the API has no way to unregister one. Small per reply. Fix: reuse a small
  pool of identifiers.
- **Compaction can build a replacement bigger than a small window** (`Compaction/CompactionCore.swift` `replacement`).
  Up to 20k tokens of kept user text plus the notes are not checked against the model's window (an 8k model overflows
  right after compacting). Fix: budget the whole replacement against the window.
- **`BrowserSessions.dispose` cancels only the queue's tail task** (`Tools/BrowserTools.swift`). The sweep skips busy
  sessions, so this matters only for `closeAll` during a call.
- **Pages kept for the user cost memory** (`Tools/KeptPages.swift`). Up to three failed web views, each with its own
  WebContent process, stay alive until five minutes after the reply that kept them (a memory warning drops them).
- **Take over holds only later browser calls** (`BrowserSessions.takeOver`). A call already running when the user taps
  Take over finishes in the page while they use it. Fix: cancel it with a "the user took over" result.
- **Malformed `content_block_start` input** and other Anthropic edge cases beyond block-start text are untested
  against real gateways.

## UX not done

- `run_plugin` pages are not checked for robot checks (search, fetch and the browser tools are); a plugin that hits
  one just fails.
- iPad hardware-keyboard shortcuts: the app targets iPhone only (`TARGETED_DEVICE_FAMILY: "1"`).
- Opening Settings from the model picker is still two sheets in a row (picker closes, Settings opens).
- Search results say "Found in messages" but show no snippet of the match.
- No swipe actions in the iPhone sidebar (pin, delete).
