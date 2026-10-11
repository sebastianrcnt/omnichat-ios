# Seamless reply recovery

## Connections and networking

`Connection.supportsResumable` is saved with connection settings. The Strata
preset defaults to true (including previously saved presets); other providers
default to false. Settings exposes an explicit capability toggle. Deploy the
resumable gateway before distributing an app with this flag enabled.

Opted-in model rounds POST `X-Strata-Resumable: 1`. `ChatClient` captures
`X-Billing-Request-Id` before consuming SSE and reconnects with authenticated
`GET /v1/streams/{id}?after={lastSequence}`. SSE ids include id-only keepalives;
duplicate events are ignored, gaps trigger replay from the previous cursor.
EOF without `[DONE]` is a dropped connection, not a successful completion.
Network failures, HTTP 429 and 5xx retry with capped exponential backoff.
`NWPathMonitor` and foreground notifications wake that backoff. Terminal HTTP
errors (including expired/evicted 404), protocol errors and server error events
are surfaced; transient reconnecting does not end the streaming UI.

Plain providers use the original `ChatStreaming.stream` implementation.

## Durable turn state

`Message.resumeData` is an additive optional SwiftData field containing the
request id, last applied cursor, partial content/reasoning, usage, fragmented
tool-call accumulator, round history, completed tool results and submission
state. `cancelPending` persists an offline Stop. The key remains in Keychain;
no credentials enter the checkpoint.

The controller saves a snapshot synchronously at each applied SSE boundary and
after each completed tool result. Text, reasoning, sources and snapshot are
saved together with `ModelContext.save`. A relaunched app restores the same
assistant message, selects its conversation, replays only subsequent events,
runs pending tools, skips already persisted tool results, and starts the next
model round automatically. One active turn is supported, as before.

Stop cancels the local turn, POSTs the server cancel endpoint, and retries that
cancel independently of the stopped streaming UI. Pending cancellation is
retried on relaunch. Cancel acknowledgements or an expired 404 clear the pending
state. No new generation is started for a stopped turn.

## Background execution

`ReplyBackgroundExecution` submits a user-started iOS 26
`BGContinuedProcessingTaskRequest` spanning the entire turn/tool loop. Dynamic
identifiers match `cc.coolservices.strata.reply.*`; submission uses `.fail` so
obsolete work is not queued. The task reports real work units as deltas/tools
are processed; generation length is unknown, so the progress horizon grows.
Fallback is a finite `UIApplication.beginBackgroundTask` lease.

The installed iOS 27 SDK exposes this framework through Objective-C headers
(`BGTask.h`, `BGTaskRequest.h`, `BGTaskScheduler.h`), not a textual Swift
interface. The imported Swift APIs were validated by the simulator build.
Info.plist declares the permitted identifier wildcard and `processing` mode.
No GPU resource or entitlement is requested.

WebKit tools are attempted in the background only with a continued-processing
lease. Without it, they await an active scene. An error from a read-only WebKit
tool spanning a background transition is retried in the foreground rather than
being persisted as a background-only failure. Successful results are persisted
before proceeding to the next model request.

A background completion queues a local "Reply ready" notification. If permission
is already granted, it is posted immediately. The first background completion
triggers a lazy permission request at the next active scene: iOS cannot present
a permission sheet while the app is suspended. Notification text never includes
reply content.

## Verification

Simulator only, Xcode 27 / iOS 27:

```
xcodebuild -project Strata.xcodeproj -scheme Strata \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath build test
```

`ResumeTests` covers persisted cursor/partial text/tool arguments, duplicate
suppression, missing-event detection, id-only events, restored tool execution,
already-completed tool results, Stop during recovery, safe capability defaults,
the plain-provider path, and ambiguous POST protection. Existing encoding and
tool-loop tests remain regression coverage for non-resumable providers.

Run the isolated E2E test on an explicitly selected simulator (this clears ONLY
the Strata app data on that simulator, so use a scratch device):

```
python3 Tools/resume_smoke.py \
  --device <simulator-UUID> \
  --app build/Build/Products/Debug-iphonesimulator/Strata.app
```

It runs its own loopback mock on an ephemeral port, forces an early disconnect
in every model round, kills the app after a durable cursor, and relaunches it.
It asserts exact final text, two successful tool rounds, exactly three model
POSTs and replay GETs using the original request id. The simulator screenshot
is `/tmp/strata-resume-smoke.png`. Debug checkpoint/completion diagnostics are
opt-in and restricted to loopback mock endpoints.

For manual smoke runs: `python3 Tools/mock_server.py 8765 --resumable`.
`MOCK_DROP_AFTER=5` forces initial-POST disconnection while the producer keeps
running. Plain mock mode remains available without `--resumable`; disable the
connection's resumable toggle when testing plain mode.

## Limits: not an absolute "never lost" guarantee

- The gateway has one worker and in-memory buffers. Its restart/crash loses
  replay; retention is 30 minutes and finished buffers can be evicted sooner
  under global capacity pressure. A per-request size limit emits an error.
- An app/network failure **before the initial response headers arrive** leaves
  an unidentified generation. A persisted submitted-but-unidentified POST is
  deliberately NOT retried because that could double-generate/double-bill.
  Closing this gap requires client-assigned idempotency keys on the gateway.
- iOS may refuse/revoke continued execution or suspend/kill the app. Server
  generation continues, but client-side search/fetch and subsequent model
  rounds cannot execute while the process is suspended. They resume when iOS
  permits execution or on foreground. Real-device background scheduling and
  system progress UI are not verified by Simulator tests.
- BGTask expiration does not expose whether the system or the progress UI user
  revoked execution. Revocation releases the lease but intentionally does NOT
  cancel server generation (to avoid losing replies on system expiration).
  The app's Stop button is the explicit server cancel in every local state;
  dismissing/cancelling the system execution UI is not a server Stop.
- Stop while offline takes effect locally immediately, but the server cannot
  receive cancellation until connectivity returns. Already generated tokens
  remain billable; the server may finish first.
- A user changing/deleting a connection or revoking its key can prevent replay
  or cancellation; credentials and endpoint are resolved from current settings.
- Checkpoint saves use the existing best-effort SwiftData error handling.
  Storage failure or protected-data unavailability cannot be guaranteed away.
  Persisting full snapshots per event also adds I/O cost, especially with image
  history. Durable server orchestration is needed for an unconditional promise.

No manual SwiftData migration is required for these additive optional/defaulted
fields. Preserve the existing automatic lightweight migration behavior.
