# Known issues

Open findings from the October 2026 reviews (two Opus passes and a GPT-6.1 Sol pass), left after commit 6301ffa
(CR-only SSE, the `cancelOnServer` give-up, location waiters and the edit highlight were fixed later).
Everything else those reviews reported was fixed in that commit. Each entry: where, what goes wrong, a fix direction.

## Security and privacy

- **One browser login store for every chat** (`Tools/HiddenWebView.swift` `BrowserData`, `Tools/BrowserTools.swift`).
  A site signed in through `browser_show` in chat A stays signed in for `browser_open`/`browser_eval` in chat B, so a
  page that injects instructions in B can drive that session. Kept on purpose (one app-wide store, no per-site switches).
  If it matters: ask before `browser_eval` runs on a host with stored cookies, or scope sessions per chat.
- **Search/fetch web views share cookies across chats for the app session** (`SharedWebData`, `WebViewPool`). Kept on
  purpose; could clear the non-persistent store when the chat changes.
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
- **Malformed `content_block_start` input** and other Anthropic edge cases beyond block-start text are untested
  against real gateways.

## UX not done

- iPad hardware-keyboard shortcuts: the app targets iPhone only (`TARGETED_DEVICE_FAMILY: "1"`).
- Opening Settings from the model picker is still two sheets in a row (picker closes, Settings opens).
- Search results say "Found in messages" but show no snippet of the match.
- No swipe actions in the iPhone sidebar (pin, delete).
