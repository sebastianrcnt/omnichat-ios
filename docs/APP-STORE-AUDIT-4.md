# Audit 4 verification (fix-c)

Reviewed `/Volumes/t5/strata-audit/report4.md` against the executable paths, not just the cited lines.

| Finding | Verdict | Verified path and fix |
| --- | --- | --- |
| Share recipient differs from display (HIGH) | CONFIRMED | `ShareImportHandler.writeContext` → `ShareContext` → `ShareComposeModel`/`modelLine` → payload → importer → `ChatController.generate`/`ConnectionStore.endpoint`. The old display always named the new-chat model while existing chats used their own endpoint. Each destination now has its own recipient snapshot; import rechecks connection, model and route digest immediately before sending. Changed, legacy, busy, missing or unusable destinations require explicit in-app confirmation; the inbox survives postponement/relaunch. `ShareTests` cover display/payload selection, route changes, legacy shares, busy destinations and stale confirmations after postponement. |
| Missing privacy manifests (HIGH) | CONFIRMED | App settings/UserDefaults, reveal/checkpoint/animation uptime, inbox/cache expiry and skill-file sync timestamps are compiled into the apps. The extension independently compiles inbox timestamp cleanup, but no UserDefaults or uptime use. Separate app and share manifests declare just these reasons; the Mac target includes the same app manifest. Widget source closure uses none of these APIs. No capacity APIs, tracking or collected data types. `ShippingReadinessTests` validate both embedded manifests and the absence of the audio mode. See `KNOWN-ISSUES.md` for reason scope. |
| Extension-unavailable launcher (HIGH) | CONFIRMED | Send → inbox commit → responder-chain Objective-C invocation bypassed availability. Removed the launcher entirely, kept saved/manual-open UI and already-authorized local notifications, enabled `APPLICATION_EXTENSION_API_ONLY`. |
| Audio execution exemption (HIGH) | CONFIRMED | Tool execution → audio work counter → every registered hidden view → generated looping audio; enabled by default. Deleted sound implementation, callers, setting, developer test and audio background mode. Hidden page calls now wait for foreground even with a continued-processing lease. Read-only interrupted calls retry on return; side-effecting calls do not. Existing deadlines bound WebKit waits and process termination now ends pending navigation with a readable error. `BrowserFreezeTests` cover the waiting/replay policy; existing WebKit deadline/cancellation tests remain. |
| Downloaded Python dependencies (HIGH) | CONFIRMED | Worker import discovery → local scheme → cache/CDN package download, plus micropip via the proxy. Bundle the exact 314.0.7 wheels and dependency closure (13 files, 16.64 MiB), verify against the upstream lock, preload locally, refuse cache/network fallback and package install sources, and explain unsupported imports. Offline runtime and fake-network server/hash/closure tests cover the change. The tool description and its golden digest deliberately change to reflect the smaller supported set. |
| No in-app privacy policy (HIGH) | CONFIRMED | Settings About only exposed Licenses; connection setup had no policy link. Added the published post-rename policy URL to both entry points without renaming the app. No UI tests; verify reachability from the two declarative views/builds. |
| Mac save entitlement (MEDIUM) | CONFIRMED | Figure Save → `NSSavePanel` → remove/copy selected file requires write access. Changed generated/configured entitlement from user-selected read-only to read-write. Verify final sandbox behavior manually on a signed Mac build. |
| Image memory/size (MEDIUM) | CONFIRMED | Provider image branch bypassed byte limits and encoded full-resolution UIImage to PNG. Prefer file representations, check size before decode, downsample directly from the callback's live file URL with ImageIO, and bound/resize UIImage fallback before JPEG encoding. `ShareTests` cover oversized providers and bounded disk downsampling. |
| Duplicate share imports (MEDIUM) | CONFIRMED | Launch, active-scene and share-link tasks can interleave at detached reads. Old code claimed only the current item of a prefiltered snapshot. Claim the whole batch before any await; retain claims for pending confirmation. The regression now queues two shares and overlaps import tasks; both are sent exactly once. |
| Health excluded from v1 (product decision) | CONFIRMED (existing Release exposure) | Health was visible on iOS, with an unconditional HealthKit entitlement and usage descriptions. `STRATA_HEALTH` exists only in iOS Debug. Release has no adapter, UI/tool availability, entitlement, usage descriptions or HealthKit linkage; platform-neutral history/redaction stays available. |

The report's “checked and fine” paths (first-run setup, DEBUG private-menu hooks, camera availability, on-device
recognition, Live Activity cleanup and chat-link validation, ChatGPT disclosure, atomic inbox publication) were left
unchanged. No SwiftData models or CloudKit schema were changed.

## Remaining submission/manual checks

- App Store Connect privacy labels and metadata must still match the published policy; a manifest does not replace them.
- Check the signed archive's entitlements, capabilities and embedded manifests when archiving with the distribution
  profile. Simulator Release bundle checks do not validate that profile.
- On physical devices, test share providers from Photos/Files/Safari, manual-open notification taps, low-memory image
  sharing and background/foreground browsing. In-flight side-effecting scripts may have run before suspension, so they
  are never automatically replayed. Full per-call checkpoint/resume is not a v1 feature.
- The supported Python package set is intentionally limited. Networking for data and model-authored Python execution
  remain features; App Review acceptance is not guaranteed by removing dependency downloads.
- Recheck the public privacy URL after the parallel product-rename branch is merged. No product rename was done here.

## Verification results

- Private simulator: `6A5BD89A-8069-486B-B529-332CDAA94159` (`fix-c-agent`, iPhone 17 Pro).
- Full unfiltered `xcodebuild test`, derived data `/Volumes/t5/strata-build/fix-c-sim`:
  `✔ Test run with 1550 tests in 291 suites passed after 115.716 seconds.` and `** TEST SUCCEEDED **`.
- Required native Mac build, derived data `/Volumes/t5/strata-build/fix-c-mac`: `** BUILD SUCCEEDED **`.
- arm64 Release iOS Simulator and Mac builds in `build` / `build-mac`: both `** BUILD SUCCEEDED **`.
  Inspected both built Info.plists (no Health usage keys or audio mode), Mach-O dependencies (no HealthKit), embedded
  privacy manifests and all 13 local wheel hashes. Verified the signed native Mac app's user-selected read-write
  entitlement and absence of HealthKit. No distribution archive/profile was created.
- Default universal Release attempts exposed the existing vendor x86_64 limitation, documented in `KNOWN-ISSUES.md`.
- The run_python golden digest is now `1e0dc114ac2dd25b1a6885c9035ba07ff01d740f0184789c403cc6e1a4997b27`,
  deliberately changed only because its package/socket-library capability description was corrected.
- Also built the standard Debug iOS and Mac configurations into worktree-local `build` / `build-mac` (both
  `** BUILD SUCCEEDED **`) and ran `python3 Tools/sync_strings.py` against their extracted strings. iOS Debug's
  simulated entitlement payload includes HealthKit; neither Release entitlement source does.
