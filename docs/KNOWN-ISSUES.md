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
- **ChatGPT refresh exposes the new access token before the ID token is verified** (`ChatGPT/ChatGPTAuth.swift`
  `performRefresh`). Saved first so a rotated refresh token is never lost. Fix: keep the new tokens quarantined until
  verification passes.

## Robustness

- **A timed-out `browser_eval` script keeps running** (`Tools/HiddenWebView.swift` evaluate/callAsync). `stopLoading()`
  doesn't stop a running promise; a delayed click can land after the timeout or after Stop. Fix: reload or replace the
  page on timeout (the model loses that page's state).
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

## v1 App Store feature gates

- **Apple Health is Debug-only.** `STRATA_HEALTH` in the iOS Debug configuration is the compile-time feature switch:
  it enables the HealthKit adapter and makes Health visible in Settings and the tool picker. Release (iOS and Mac)
  does not link HealthKit or carry its entitlement/usage descriptions. Debug uses `Strata-Debug.entitlements` and
  Debug-only usage descriptions. Restore the switch and the corresponding signing/privacy metadata together when
  shipping Health in a later update. Platform-neutral Health history/redaction code stays compiled for old chats.
- **Privacy manifest scope.** The iOS and Mac apps share the app manifest: own-container preferences (CA92.1),
  own-container/App Group file timestamps for cache expiry and skill sync (C617.1), and uptime for UI animation and
  checkpoint intervals (35F9.1). The share extension only reads App Group timestamps (C617.1); it does not use
  UserDefaults. App Group sharing is file-based, so 1C8F.1 is not declared. No disk-capacity APIs are used. The widget's
  sources use none of the required-reason APIs, so it needs no manifest. No tracking or collected data is declared.
- **Background browsing pauses normally.** The audio keep-alive and `audio` background mode have been removed. New
  hidden-page calls wait for foreground. A read-only call that fails across backgrounding retries once on return;
  scripts/plugins are never replayed automatically (they may already have clicked or posted). Existing WebKit load
  and script deadlines return a readable error if suspension/termination interrupts them. Continued-processing
  execution remains for eligible reply work, not as a guarantee that WebKit will keep running.
- **Python packages are bundle-only in every configuration.** Pyodide 314.0.7 supports numpy, pandas and matplotlib
  plus their dependency closure: 13 wheels, **17,444,678 bytes (16.64 MiB)** added, plus a tiny package-name index.
  `python3 Tools/bundle_python_packages.py` reproduces them from the pinned jsDelivr release and verifies each SHA-256
  against the unchanged upstream lock. The server verifies bundled wheel hashes, never reads old package caches and
  never downloads missing wheels; PyPI/package-source requests are refused. Unknown imports (including dynamic imports
  and micropip) report “This package isn't available in OmniChat”. Standard-library networking remains available for
  data, not a package installation feature. The run_python description was deliberately corrected to remove claims
  that scipy/sympy/PyPI installation are supported; its package-cache golden digest changes for that reason only.
- **Intel/universal Release builds need an x86_64 SSH library.** The checked-in `Vendor/CLibSSH2.xcframework` has only
  arm64 slices for Mac and iOS Simulator. Default Release builds also attempt x86_64 and fail with undefined libssh2
  symbols; arm64 Release and the normal native Debug build work. Before offering an Intel Mac binary, rebuild the
  vendored library with an x86_64 macOS slice. Release validation/string extraction here uses `ARCHS=arm64
  ONLY_ACTIVE_ARCH=YES`; this does not claim universal/Intel support.
