# Memory and disk I/O

What a long chat costs, how it is bounded, and the numbers behind it.
`StrataTests/MemoryTests.swift` and `CheckpointPersisterTests.swift` hold the tests.

## Checkpoint writes

A resumable turn is checkpointed so it can be recovered after a kill. The checkpoint is split in two:

| Half | Contents | When it is written |
| --- | --- | --- |
| Static (`Message.resumeData`) | the exact request body of the current round (it already contains the whole history), idempotency key, round | once per round, when the request is submitted |
| Dynamic (`Message.resumeDynamicData`) | request id, SSE cursor, accumulator (partial text, reasoning, tool-call arguments), finished tool results of the turn | at most once per second, and at once when the stream completes, a tool result is appended, the app resigns active or enters the background, or the user stops |

- The encoded static bytes are cached and reused. `CheckpointPersister.staticEncodeCount` counts encodes (a test pins it to one per round).
- A round is not persisted before its request is submitted: until then the previous round's checkpoint still recovers the turn.
- Every write carries the whole dynamic half, so the cursor and the accumulator it belongs to always match. A stale pair is safe because the server replays from `lastSequence` and duplicates are dropped (`resumeFromAStalePersistedPair...`).
- `Message.text` and `Message.reasoning` are updated at the same throttled write, not per event. The transcript renders from the streaming models.
- Older whole-checkpoint saves still restore (`TurnCheckpoint.restore`).

Before this change every SSE event JSON-encoded the whole checkpoint (history, request body and its duplicate) and saved the context.

## Images

- History images are base64-encoded once per attachment (`ImageDataURLCache`, NSCache, 96 MB cost limit, keyed by attachment id). A rebuilt entry is byte-identical, so the request prefix and the server prompt cache are unaffected.
- Each `Attachment` stores `thumbnailData` (240 px long side, JPEG 0.7, about 10-30 KB, made with ImageIO at attach time; old attachments are backfilled once, lazily). Bubbles read only the thumbnail. The full JPEG is read for sending only.

## Sidebar

The list never touches `messages`. Search matches titles in memory and message text with a store predicate (`ConversationSearch`, capped at 200 matches), debounced 250 ms.

## Memory warnings

`MemoryPurge` (installed at launch) drops `PageCache`, `ImageDataURLCache` and the favicon image cache. Other caches register with `MemoryPurge.register`. Running-turn state is not touched.

## Long-session measurement

`LongSessionTests`: 40 turns in one conversation, six 300 KB images in the first message, a tool round with a 42 KB fetch result and a 400-event answer per turn, resumable checkpointing on. Simulator, Debug build.

| Measure | Before the split | After |
| --- | --- | --- |
| Checkpoint bytes written per turn, turns 3-6 | 26.5 MB | 6.7 MB |
| Checkpoint bytes written per turn, turns 37-40 | 42.3 MB | 10.7 MB |
| Process footprint at start / after 40 turns | 60 / 132 MB | 58 / 110 MB |
| After the memory-warning purge | 130 MB | 108 MB |

Asserted bounds: bytes per turn at the end below 4x the early value and below 16 MB; footprint growth below 300 MB.

What remains linear: each round writes its request body once, so a round costs about one copy of the history. Per-token cost is constant (the dynamic half only). Storing only this turn's additions and rebuilding the prefix from the saved messages would remove the history term; it is not done because the retry body must stay byte-exact.

## Diagnostics and the debug bundle

- Per conversation: `...` menu, Conversation details. App-wide: Settings, Developer mode on, Diagnostics. Both are measured only while open.
- Always running: the request ring (the last 6 request bodies per conversation, deflated in the background, 2 MB total; the newest request is kept even if alone over the cap) and a few counters (`DiagnosticCounters`).
- Save debug bundle writes `Documents/Debug/<yyyyMMdd-HHmmss>/` with `report.json`, `index.txt`, `memstats.txt` and `requests/<conv>-<n>.json`. Authorization values and API keys are always removed; inline images become `<image N bytes>` unless "Strip images" is off.
- Pull it from a device: `xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier cc.coolservices.strata --source Documents/Debug --destination ./debug`.

## P2 performance items

- Streaming code blocks render only their last 40 lines and count lines with a byte scan (`CodeBlockContent.streaming`); the full parse happens once, when the fence closes.
- The code viewer shares through `Transferable` (the file is written when the share sheet asks) and keeps the pinch size in view state, writing the setting when the gesture ends.
- Recovery: a reply gives up reconnecting after 10 minutes without data (`StreamRecoveryPolicy.maxOutage`); `RecoverySignals.wait` is a timer plus a signal (no polling); the server-cancel retry stops after 10 minutes and leaves `cancelPending` set for the next foreground; waiting for the foreground uses the same signal.
- The system's progress object for the background task is written at most once a second (`RateLimiter`). The background task identifier is registered once per turn (never per delta).
- In the background no display timer runs: streamed text is revealed when the app is visible again (or at once when the turn ends).
- Camera photos are resized off the main thread, and thumbnails are made in the background when a photo is added (the send path no longer does image work).
