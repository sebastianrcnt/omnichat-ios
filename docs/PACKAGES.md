# OpenChat packages: design

Status: MVP implemented on branch `packages` (2026-10-22); see "MVP as built" at the end of section 11 for what
differs from this proposal and what is left. Phases 2 and 3 are still proposals.

Packages extend OpenChat without new app releases. A package is a signed or unsigned bundle of data and sandboxed JavaScript
that adds tools, prompt text, skills, views, commands, connection presets, policies and declarative hooks. The idea comes
from pi (badlogic/pi-mono): keep a small core, put everything else in extensions, and let agents write their own. For
OpenChat that means a company, or the company's agent, writes the "Jira tool" or the "use our gateway, never SSH" policy as
a package. We don't build per-customer features.

This document is grounded in the code at `65c1c1a` plus the `main` merge with App Intents, Share, OnDevice and Live
Activities. File paths are relative to the repo root.

---

## 0. Decisions in one screen

- **Format**: a zip with the `.ocpkg` extension, or a folder in developer mode. `manifest.json` sits at the root, with `CHECKSUMS` and
  `SIGNATURE` (Ed25519) beside it. Content is data (JSON and Markdown) plus optional JS files.
- **Content types**: skills (today's format, unchanged), declarative HTTP tools (no code), JS tools (sandboxed WKWebView
  with a narrow `openchat.*` host API), page tools (today's site plugins), prompt fragments, OpenUI view templates,
  commands, connection presets, policies, and declarative hooks.
- **Cache safety**: a chat freezes the packages it offers at its first send, as it already freezes tool groups
  (`Conversation.offeredTools`). It also snapshots the exact bytes of their tool definitions and prompt sections into
  the conversation. Package tools are appended after the built-in tools, sorted by package id. A chat without packages
  sends byte-identical requests to today.
- **Trust**: there are four levels: OpenChat-known publisher, company key (MDM or policy), user-trusted key (TOFU), and unsigned
  personal. What a package may declare depends on its level. Everything a package can reach is listed at install time.
  Writes and sensitive reads ask again on first use or on every use.
- **Secrets** live in the Keychain and are referenced by name. The host injects them into requests. The model and the
  package's JS never see the value.
- **App Store**: this falls under 4.7 (plug-ins, mini apps and chatbots in WebKit/JavaScriptCore). There is no native code, no
  `eval` of fetched text, and no bridging of native platform APIs (HealthKit, location, Contacts) to package code
  (4.7.2). There is no in-app package directory until we can meet 4.7.1, 4.7.4 and 4.7.5.
- **Licensing**: the app is GPLv3 with a CLA. `OpenChatPackageKit`, the spec, the JS SDK shim and the examples are MIT,
  with a GPL section 7 exception saying that packages are separate works. Enterprise servers stay closed. See section 10.
- **MVP**: package format v1, skills, prompt fragments and declarative HTTP tools, Keychain secrets, install from a link or
  a file, per-chat frozen enablement, approval cards, and a local audit log. JS tools, agent authoring and enterprise
  policy come in phases 2 and 3.

---

## 1. Goals, non-goals, authors

### Goals

1. **Small core.** New capabilities ship as packages. The app keeps a fixed set of runtimes (HTTP, JS sandbox, page
   scripts, Pyodide) and UI primitives (feed cards, approval cards, OpenUI views).
2. **Companies extend the app themselves.** A company dev, or their agent, can write and sign a package that calls
   internal APIs through declared domains with Keychain-held tokens. It ships through MDM, with no work from us.
3. **Agents write packages.** "Save as skill" grows into "Save as package". The model drafts a tool, the user reviews
   the full contents and permissions, and the tool can be used in new chats.
4. **Keep the prompt cache.** Nothing a package does may change the request prefix of a running chat, except when the
   user explicitly enables something mid-chat. That costs one cache miss, as tool groups already do.
5. **Enterprise controls.** Admins can allow-list packages and tools, block connections, force a policy, and collect an
   audit log. It works offline.
6. **App Store compliant** in the same binary for B2C and B2B, Custom Apps included. Custom Apps in Apple Business
   Manager are still reviewed.

### Non-goals (v1)

- Native code, dynamic frameworks, or WASM in packages.
- Packages reading the conversation history or other chats. A package sees only its own call's arguments.
- Background execution: timers, schedules, push wake-ups, on-launch hooks. See section 4.9.
- Package-defined App Shortcuts, widgets or Live Activities. These are compiled into the binary. See section 5.8.
- Packages that change the system prompt or the tool list of a running chat.
- An in-app public package store. Install is by link, file, MDM or agent until the 4.7.4 index exists (phase 3).
- Custom LLM providers that need code, such as request signing. Connection presets cover the declarative cases.
- Paying for packages in the app (3.1).

### Who writes packages

| Author | Typical content | Trust | Notes |
| --- | --- | --- | --- |
| Power users and self-hosters | Skills, HTTP tools for their home-lab APIs (Home Assistant, Immich, Paperless), presets for their own server | Unsigned personal, or a self-generated key (TOFU) | They edit in the Mac developer folder, or ask the model to draft. |
| Company developers | HTTP and JS tools for internal APIs, org prompt, connection presets, policy, DLP hooks | Company key | Built with the MIT `openchat-pkg` CLI (validate, sign, test). Distributed by MDM or a link. |
| The model | Skills and HTTP tools first, JS tools later | Always unsigned personal, created through the review sheet | It can never declare policy, hooks, private-network access or `exposeToScript` secrets. |
| OpenChat (us) | Built-in packages: today's `naver-places` skill and `wikipedia_summary` plugin, examples | OpenChat-known publisher | Shipped in the bundle, MIT-licensed, forkable. |

### Mapping from pi's extension types

| pi | OpenChat package content |
| --- | --- |
| tools | `http`, `js` and `page` tools (sections 3.3 to 3.5) |
| commands | `commands`: composer prompt templates (section 3.9) |
| providers | `connections`: presets on top of `AddConnectionLink` (section 3.10). Code-level providers are a non-goal. |
| renderers | `views`: OpenUI Lang templates, and tool results rendered as feed cards (section 3.8) |
| hooks / events | Declarative hooks: DLP, result redaction, audit (section 3.12). JS hooks only in phase 3, company trust only. |
| self-extending agent | `save_package` with a review sheet (section 6) |

---

## 2. What exists today, and what packages build on

| Area | Code | What packages reuse or generalize |
| --- | --- | --- |
| Skills | `Strata/Tools/Skills.swift`: `Skill` (front matter `name` and `description`, body, named `js script=NAME` fences), `SkillStore` (bundle `Resources/Skills` plus `Application Support/Skills/<name>.md`), `SkillIndex`, `LoadSkillTool`, `RunSkillScriptTool` (runs in the chat's browser page via `BrowserEvalTool`), `SaveSkillTool`, `SkillApprovals` | The skill format becomes a package content type as is. Existing saved skills keep working (section 3.2). The `SkillApprovals` queue pattern becomes the package review queue. |
| Save as skill | `Strata/Engine/SkillOffer.swift` (`isOffered`, `instruction`), `AppPrompt.skillOffer` | It is extended to offer a package when the work was an API call (section 6). |
| Site plugins | `Strata/Tools/PluginCore.swift` (`PluginManifest`, URL template building with `unreserved` percent-encoding, `hostAllowed`, `resolveArguments`, `PluginRegistry.promptSection`), `PluginRunner.swift` (`PluginPipeline`), `Resources/Plugins/wikipedia_summary.plugin.*`, `AppSettings.enabledPlugins` | They become the `page` tool kind. The URL builder and host matcher move into `OpenChatPackageKit`. **Existing cache leak:** `ChatController.apiHistory` builds the plugin prompt section from `AppSettings.currentEnabledPlugins` on every request, so toggling a plugin in Settings changes the system message of running chats. Packages freeze it (section 4.3). |
| Tool groups and freezing | `Strata/Engine/ChatTools.swift` (`ToolGroup`, `note`, `encode`/`decode`, which ignores unknown values), `Conversation.offeredToolsRaw`, `toolSwitchesRaw`, `announcedToolsRaw`, `frozenTools`, `frozenSkillIndex`, `ChatController.offeredTools(_:freeze:)`, `applyToolSwitches`, `OfferedTools` (refuses calls at execution), `StrataTests/ToolSwitchTests.swift` | Packages join the same three fields as `pkg:<id>` entries. Old builds drop them in `decode`. A package snapshot sits next to `skillIndexSnapshot`. |
| Tool list | `ToolDefinition` in `Strata/Networking/ChatAPI.swift` (typed `Parameters`, encoded with `ChatRequest.encoder` using `.sortedKeys`), `ToolDefinition.available(groups:images:)` | Package tools are appended after `available(...)`. `ToolDefinition` needs a raw-schema variant (section 4.3). `ResponsesAPI.swift` and `OpenCode/AnthropicMessages.swift` convert the same list. |
| System prompt | `AppPrompt` (`Strata/Engine/Sources.swift`), `AppPrompt.views` (`Rendering/OpenUI/OpenUIPrompt.swift`), `ConversationDate.systemPrompt(base:day:plugins:)` (`Models/Conversation.swift`), assembled in `ChatController.apiHistory` | Package prompt sections go between the skill index and the user's preferences. Empty sections are filtered out, so chats without packages keep their bytes. |
| Dispatch | `ToolRouter.execute` (`Strata/Tools/WebTools.swift`), `ToolExecuting`, `ToolOutput`, `ToolRound.execute`, `ToolExecutionRecovery` (retries `ToolNames.isSafeToRetry` after backgrounding), `ToolContext` task-locals (`conversationID`, `callID`, `progressSink`) | A `PackageToolRouter` sits in front of `ToolRouter`. `readOnly` tools become safe to retry. |
| Feed | `ActivityFeed.cards` (`Engine/ActivityFeed.swift`), `FeedCard.Kind`, `ToolNames.hasOwnCard`, `ToolCallRecord.primaryArgument`, `displayOnly`, `ToolProgress` | A new `.package` card kind. The manifest says which argument to show and whether to keep the result. |
| Approvals | `SSHRequests` / `SSHApprovalPolicy` (`Strata/SSH/SSHRequests.swift`): cards tied to (chat, call id), cancel means deny, "Always" persisted, and a notification when the app is in the background (`SSHRequestNotifier`). Live Activity "Needs you": `ReplyLiveActivities.approval(for:)` maps to `ReplyActivityInput.Approval` | They are generalized into `ToolApprovals`, with a `.packageTool` approval case for the Live Activity. |
| Secrets | `KeychainKeyStore` (`Security/KeyStore.swift`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), `KeychainSSHVault` (`SSH/SSHStore.swift`), `SSHMask`, `DebugRedaction` (`Diagnostics/Redaction.swift`) | A `PackageSecretStore` follows the `SSHVault` pattern. `DebugRedaction` gets an exact-value registry. |
| Sandboxes | Python: `PythonWebHost` with a custom scheme, `PyodideServer` CSP `default-src 'none'; script-src strata-py: 'wasm-unsafe-eval'; connect-src strata-py:`, `.nonPersistent()` store. Artifacts: `ArtifactNavigation.makeWebView` (no message handlers, no base URL, `LocalNetworkRules`). Agent world: `HiddenWebView.agentWorld` | The JS tool host copies the Pyodide pattern: a custom scheme, a strict CSP, no network from JS, and a host bridge as the only way out. |
| Links | `AddConnectionLink` (`Models/ConnectionPresets.swift`) drops `key`. `ConnectionLinks` and `ConnectionLinkHandler` (`UI/ConnectionSetup.swift`) show a confirmation sheet. `openchat` URL scheme in `project.yml` | `openchat://add-package` follows the same pattern, and connection presets reuse `AddConnectionLink`. |
| Multi-chat | `ChatRun`, `RunSlots`/`FairSlots`, call ids keyed by chat (`ToolProgress.Key`) | Per-package concurrency slots, and approvals keyed by chat and call. |
| On-device model | `OnDevicePromptBuilder.toolSpecs` offers only `web_search` and `web_fetch` to the ~3B model with a 4K window, and replaces the app prompt | Package tools are **not** offered on device unless the package marks a tool `onDevice: true` with a short description (section 5.8). |
| App Intents | `Strata/Intents/` (`AskOpenChatIntent`, `IntentChat.conversation(... requiredTools:)` turns off `.views`) | Intent chats get packages that are "on in new chats", except those that need approvals the intent can't show (section 5.8). |
| Share / App Group | `Strata/Share/`, App Group `group.cc.coolservices.strata` (`SharePayload.identifier`) | `.ocpkg` files shared into the app are routed to the install sheet (section 5.2). |

---

## 3. Package format

### 3.1 Layout

```
acme-jira-1.4.0.ocpkg            zip (deflate or store); also a plain folder in developer mode
├── manifest.json                required
├── CHECKSUMS                    required for signed packages: "sha256  path" per file, sorted by path, LF
├── SIGNATURE                    optional: Ed25519 over the bytes of CHECKSUMS (JSON, see 3.13)
├── icon.png                     optional, square, ≤ 64 KB, ≤ 256 px
├── prompt.md                    optional prompt fragment
├── skills/
│   ├── triage.md                today's skill format (front matter name/description + body)
│   └── release-notes/SKILL.md   Agent Skills layout also accepted (scripts other than js fences are ignored)
├── tools/
│   └── sprint.js                JS tool code (ES module, default export)
├── views/
│   └── issue.openui             OpenUI Lang template
├── policy.json                  only honored at company trust
└── README.md                    shown in the package detail page (rendered Markdown)
```

Limits: 5 MB zipped, 15 MB unzipped, 200 files. Paths must be relative, UTF-8, without `..`, without absolute paths and without
symlinks, which zip-slip protection rejects. Text files must be UTF-8 and are normalized to LF and NFC at install. The
normalized bytes are what the checksums cover, so the author's tool (`openchat-pkg pack`) normalizes before hashing.

### 3.2 `manifest.json`

```jsonc
{
  "format": 1,                                  // spec version; the app supports a range, refuses newer
  "id": "com.acme.jira",                        // reverse-DNS, lowercase, [a-z0-9.-], 3–80 chars, unique per device
  "name": "Acme Jira",                          // display name, ≤ 40
  "namespace": "jira",                          // tool-name prefix: [a-z][a-z0-9]{1,15}; see 4.3
  "version": "1.4.0",                           // SemVer 2.0; updates must increase it
  "description": "Search, read and create Acme Jira issues.",   // one line, ≤ 200, shown in UI (not to the model)
  "publisher": { "name": "Acme Corp", "key": "ed25519:Q2hhbmdlTWUu..." },  // key optional (unsigned)
  "license": "Proprietary",                     // SPDX id or free text; informational
  "homepage": "https://wiki.acme.internal/openchat",
  "requires": {
    "app": ">=1.3.0",                           // OpenChat version range (SemVer range subset: >=, <, ^, ~)
    "hostAPI": 1,                               // JS host API major version (only when js tools exist)
    "groups": []                                // built-in tool groups this package needs on, e.g. ["browser"] for skills with scripts
  },
  "permissions": {
    "network": [                                // hosts the package's HTTP/JS tools may reach; exact host or "*.suffix"
      "acme.atlassian.net"
    ],
    "privateNetwork": false,                    // true: network entries may be private/LAN hosts (company or home-lab); see 4.6
    "secrets": [
      { "name": "token", "label": "Jira API token", "help": "Create one at id.atlassian.com › Security.",
        "inject": "bearer" }                    // bearer | basic | header:<Name> | query:<param>
    ],
    "storage": 1048576,                         // bytes of per-package key-value storage (JS tools), default 0
    "exclusive": [],                            // built-in groups that may NOT be on in the same chat, e.g. ["web","browser"]
    "data": []                                  // reserved: sensitive app data (see 4.6); none in format 1
  },
  "contents": {
    "prompt": "prompt.md",
    "skills": ["skills/triage.md", "skills/release-notes/SKILL.md"],
    "tools": [ /* 3.3–3.5 */ ],
    "views": [ { "name": "issue", "file": "views/issue.openui" } ],
    "commands": [ /* 3.9 */ ],
    "connections": [ /* 3.10 */ ],
    "policy": "policy.json",
    "hooks": [ /* 3.12 */ ]
  },
  "update": { "url": "https://pkgs.acme.internal/com.acme.jira/latest.json" }   // optional, see 5.4
}
```

Validation lives in `OpenChatPackageKit.PackageManifest.validate()`, which follows `PluginManifest.validate()`. It throws
one error naming the first problem, worded for whoever fixes it. These errors are also read by the model when it drafts a
package, so each says what to do instead, in the style of `Skill.Problem`.

**Versioning and compatibility**

- `format` is an integer. A newer format than the app knows is refused with "Update OpenChat to install this package".
  Unknown top-level keys and unknown keys inside known objects are ignored, with a warning in the review sheet. An unknown
  content kind or tool `kind` is refused unless the entry says `"optional": true`.
- `requires.app` is checked at install and at launch. If the app falls below the minimum after a downgrade, the package
  is disabled with a reason.
- `requires.hostAPI` is a major version. The host keeps old majors for at least a year, and minor additions are feature-detected
  (`openchat.version`).
- Package `version` is SemVer. Updates must increase it. A downgrade happens only through an explicit Revert, or when MDM
  pins a version.
- Each tool may carry `"schemaVersion"` (integer, default 1). Bump it when the parameters or meaning change
  incompatibly. Frozen chats refuse calls whose snapshot `schemaVersion` differs from the installed one (section 4.3).

### 3.3 Skills (backwards compatible)

- The format is exactly `Skill.parse`: `---` front matter with `name` and `description`, then the body. `js script=NAME`
  fences stay runnable through `run_skill_script`.
- **Existing saved skills** in `Application Support/Skills` are not migrated on disk. `SkillStore` keeps reading them, and the
  Packages screen shows them as a built-in pseudo-package "My skills" (`local.skills`, personal trust). `save_skill` keeps
  writing there, so nothing changes for current users. The bundled `naver-places` becomes the built-in package
  `app.openchat.naver-places`.
- **Package skills** are named `<namespace>:<name>`, for example `jira:triage`. `Skill.isValidName` gets a second
  accepted form: one `:` between a namespace and a name, each valid on its own. Plain names stay reserved for personal
  and built-in skills, so packages can't shadow them.
- `SkillStore.all` gains package skills, but only from packages **enabled in the chat**. The skill index therefore becomes
  per chat: `SkillIndex.text(for: personal + builtIn + skills of the chat's offered packages)`. It is still frozen by
  `Conversation.frozenSkillIndex` at the first send.
- Today `load_skill` is a browser-group tool, and skills are only listed when `.browser` is offered (`apiHistory`). A
  package whose skills don't need scripts (`requires.groups` doesn't include `browser`) gets `load_skill` offered through
  the package tool block. The tool is `load_skill` itself, with the same definition bytes, added once in the package block
  if the browser group isn't offered. Skills with scripts declare `requires.groups: ["browser"]`, and enabling the package
  turns the browser group on for the chat.

### 3.4 Declarative HTTP tools (`kind: "http"`)

These need no code. The host builds the request, injects the secret, projects the response, and returns text plus
optional sources.

```jsonc
{
  "name": "search",                              // [a-z][a-z0-9_]{0,39}; full tool name "jira__search"
  "kind": "http",
  "title": "Search issues",                      // feed card title
  "description": "Search Acme Jira issues with a JQL query. Returns key, summary, status and assignee.",  // to the model, ≤ 1024
  "parameters": {                                // JSON Schema subset, see below
    "type": "object",
    "properties": {
      "jql":   { "type": "string",  "description": "JQL, e.g. project = OPS AND status != Done" },
      "limit": { "type": "integer", "description": "Max results, 1-50. Defaults to 20.", "minimum": 1, "maximum": 50 }
    },
    "required": ["jql"]
  },
  "request": {
    "method": "GET",                             // GET | POST | PUT | PATCH | DELETE
    "url": "https://acme.atlassian.net/rest/api/3/search",   // scheme+host+port fixed; {arg} only in path segments
    "query":   { "jql": "{jql}", "maxResults": "{limit|20}", "fields": "summary,status,assignee" },
    "headers": { "Accept": "application/json" }, // no Authorization/Cookie here: use auth
    "auth":    { "secret": "token" },            // injection mode comes from permissions.secrets[].inject
    "body":    null                              // or { "json": {...template...} } | { "form": {...} }
  },
  "response": {
    "each": "/issues",                           // JSON Pointer (RFC 6901) to an array; omit for a single object
    "fields": { "key": "/key", "summary": "/fields/summary", "status": "/fields/status/name",
                "assignee": "/fields/assignee/displayName" },
    "sources": { "title": "{summary}", "url": "https://acme.atlassian.net/browse/{key}", "content": "{summary} ({status})" },
    "maxCharacters": 12000
  },
  "readOnly": true,                              // GET defaults true, others false; readOnly tools are safe to retry
  "confirm": "never",                            // never | first | always ; default: never for readOnly, always otherwise
  "timeout": 20,                                 // seconds, 1–120, default 30
  "display": { "argument": "jql" },              // which argument the feed shows (ToolCallRecord.primaryArgument)
  "onDevice": false                              // offer to the on-device model (5.8)
}
```

Rules:

- **URL building** reuses `PluginManifest.build`, moved to `OpenChatPackageKit.URLTemplate`. Values are
  percent-encoded with `unreserved`, so a value can't add a path, query, port or user. Placeholders are allowed only in
  path segments, never in the scheme, host or port. The host must match `permissions.network`
  (`PluginManifest.hostAllowed` semantics). `{arg|default}` supplies a default. An optional argument without a default
  drops its query item.
- **Body templates**: a JSON string value that is exactly `"{arg}"` is replaced by the typed argument value (number,
  bool, object or array, after schema validation). Any other string is interpolated as text. `form` bodies are URL-encoded.
- **Argument validation** happens against the schema before anything runs. Unknown keys and missing required keys produce
  `PluginError.badArguments`-style text that tells the model what the tool takes.
- **Schema subset**, chosen for portability to local models and chat templates (Qwen, Llama): `type` (object, string,
  integer, number, boolean, array), `description`, `enum`, `properties`, `required`, `items`, `minimum`, `maximum`,
  `maxLength`, `default`. There is no `$ref`, `oneOf`, `anyOf` or `patternProperties`. The maximum depth is 4, and the
  schema is at most 4 KB per tool.
- **`capture`** (optional, HTTP tools only): a top-level `string` parameter may declare `"capture": "<regex>"`, a regular
  expression with at least one capture group. After validation the host matches it against the value and replaces the
  value with the first group that matched, so a tool can accept a full link and use the id inside it
  (`"capture": "status/(\\d+)"` turns `https://x.com/a/status/123` into `123`). A value that doesn't match fails with
  `"<name>" doesn't have the expected form.` `capture` is removed from the schema the model sees, is rejected on nested
  or non-string parameters, and a pattern that doesn't compile or has no group fails validation.
- **Redirects**: up to 3, each target rechecked against `network`. https never downgrades to http. A redirect to an undeclared host
  fails with `Blocked: <host> is not a host the Acme Jira package may reach.`
- **Response**: the body is capped at 2 MB before parsing. JSON responses go through `each`/`fields`. Without
  `response`, the raw body is returned, truncated to `maxCharacters` (default 12,000, hard cap 60,000) with the same
  truncation note style as `PluginScript.format`. The output to the model is compact JSON with sorted keys, or the text body.
  `sources` turns each item into a `SourceCandidate`, so results get `<source id=…>` blocks and citations work.
- **Errors**: non-2xx statuses map to model-readable text by class:
  - 401/403: "the token may be wrong or expired: ask the user to check Settings › Packages › Acme Jira".
  - 404: "not found".
  - 429: "rate limited: wait or narrow the request".
  - 5xx: "the server failed".

  Each message is followed by the first 500 characters of the body after secret scrubbing (section 4.7).
- **Network stack**: a `URLSession` with an ephemeral configuration, without cookies, and with `httpShouldSetCookies = false`.
  `URLGuard` blocks private addresses unless `privateNetwork` is set and the host is declared (section 4.6).

### 3.5 JS tools (`kind: "js"`)

These are for logic a declarative tool can't express: pagination, joining two calls, reshaping, computing.

```jsonc
{ "name": "sprint_summary", "kind": "js", "script": "tools/sprint.js", "title": "Sprint summary",
  "description": "Summarize the current sprint of a board: done, in progress, blocked.",
  "parameters": { "type": "object", "properties": { "board": { "type": "string", "description": "Board id" } }, "required": ["board"] },
  "readOnly": true, "timeout": 30, "display": { "argument": "board" } }
```

```js
// tools/sprint.js — ES module. The only globals beyond standard JS are `openchat` (host API) and `console`.
export default async function run(args, ctx) {
  const res = await openchat.fetch(`https://acme.atlassian.net/rest/agile/1.0/board/${encodeURIComponent(args.board)}/sprint?state=active`,
                                   { auth: "token" });
  if (!res.ok) throw new Error(`Jira said ${res.status}`);
  const sprint = (await res.json()).values[0];
  openchat.progress(0.5, "Reading issues");
  // ...
  return { text: "...", data: { done, inProgress, blocked }, sources: [{ title, url, content }], view: { template: "issue", data: {...} } };
}
```

Host API v1. The full TypeScript declaration ships as MIT `@openchat/package-sdk/host.d.ts`.

| Call | Behavior |
| --- | --- |
| `openchat.fetch(url, {method, headers, body, auth, timeout})` | Performed by the app (`URLSession`), not by WebKit. The host must be in `permissions.network`. `auth: "<secret name>"` injects the secret as declared, and the JS never sees the value. Responses are capped at 2 MB, and secret values are scrubbed from them. It returns `{ok, status, headers, text(), json()}`. Set-Cookie is dropped. |
| `openchat.storage.get/set/delete/keys(scope?)` | A JSON key-value store per package, up to `permissions.storage` bytes. `scope: "package"` (default) or `"chat"`, which is keyed by `ToolContext.conversationID` and deleted with the chat. |
| `openchat.progress(value, label?)` | Feeds `ToolProgress` for the call's card. |
| `openchat.confirm(summary)` | Shows an approval card under the call (section 4.5) and resolves to a boolean. A cancelled turn resolves false. |
| `openchat.ask({title, fields})` | Shows an input card rendered as a native OpenUI `Form` and resolves to answers or `null`. This is phase 2. |
| `openchat.log(...)` / `console.*` | Writes to the package's debug log (Settings › Packages › Log, at most 200 lines). It is never sent to the model. |
| `ctx` | `{ callID, tool, packageVersion, locale }`. It has no chat id, no messages and no user identity. |

The return value is `string | { text, data?, sources?, view? }`. `text`, or the JSON of `data` when there is no text, is what the
model reads, capped as for HTTP tools. `view` is shown in the feed card (section 3.8). A thrown error becomes
`Error: <message>` with `isError: true`.

There are no DOM pages, no `XMLHttpRequest` and no WebSocket. WebKit's own `fetch` is blocked by CSP. There are no remote
scripts, no `eval` and no `new Function` (CSP without `unsafe-eval`), and no `import()` outside the package. Section 4.2
describes the sandbox.

### 3.6 Page tools (`kind: "page"`): today's site plugins

A `PluginManifest` is embedded as a tool: `url`, `hosts`, `settle`, `waitFor` and `script` (defines `window.strataPlugin`).
It runs exactly as `RunPluginTool` does today, in the shared hidden web views. It is the right kind for a site
without an API. `hosts` must be a subset of `permissions.network`. The bundled `wikipedia_summary` becomes the built-in package
`app.openchat.wikipedia` with one page tool.

After migration (phase 2), `run_plugin` stays in `ToolDefinition.standard` for old chats, since its definition is part of
their cached prefix. Calls by plugin name are routed to the page tool. New chats get page tools as package tools.
`AppSettings.enabledPlugins` maps to "On in new chats" for those packages.

### 3.7 Prompt fragments

- `prompt.md` is at most 4,000 characters. It is plain instructions about when and how to use the package's tools, plus the
  org's conventions.
- Rendering is fixed:

  ```
  Package "Acme Jira" (tools jira_*):
  <prompt.md, trimmed>
  ```
- The install sheet shows its token estimate (`ContextMeter` estimator): "Adds about 350 tokens to every chat that turns
  it on."
- A fragment can't contain `<userPreferences>`, `</source`, or any line that starts with `Current date:`. These are
  escaped the way `SourceFormatter.block` escapes `</source`, so a package can't forge the app's structure.

### 3.8 Views (OpenUI templates) and rendered results

OpenUI Lang (`Strata/Rendering/OpenUI/`) renders native SwiftUI from a fixed component library, `OUILibrary.openChat`.
Packages can't add components, because there is no native code. They can:

1. **Render tool results as cards.** A tool returns `view: { template, data }`, or `{ program }` holding raw OpenUI Lang.
   The feed card renders it with `OpenUIBlockView` in a locked, non-sending mode. Actions other than `Link`/`@OpenUrl`
   are disabled in feed cards. The model never sees the view. It reads `text`.
2. **Provide templates** (phase 3). A template is an OpenUI Lang program with `$data` references, for example
   `views/issue.openui`. The evaluator binds `data` as a read-only `$data` state. Later, templates may be exposed to
   the model as macros such as `JiraIssue(key, summary, status)` that expand to built-in components. That needs
   `OUIEvaluator` support for library extension by expansion, and it adds prompt text, so it is off by default.

Interactive actions from package views, such as `@ToAssistant`, are never auto-sent. They follow today's rules: only on the
latest message, and only when no reply is running.

### 3.9 Commands

These are composer prompt templates, pi's commands without code.

```jsonc
{ "name": "triage", "title": "Triage an issue", "template": "Triage {{issue}}: read it with jira__get, find duplicates with jira__search, and propose priority and owner.",
  "args": [ { "name": "issue", "label": "Issue key", "placeholder": "OPS-123" } ] }
```

Typing `/` in the composer lists the commands of the packages enabled in the chat. Picking one fills the composer with the
expanded text, which the user sees, edits and sends. Commands don't touch the request prefix, so they are cache-neutral.

### 3.10 Connection presets

```jsonc
{ "name": "Acme LLM", "url": "https://llm.acme.com/v1", "api": "openai", "images": true, "effort": false, "resumable": true,
  "headers": { "X-Acme-Team": "{secret:team}" }, "managed": false }
```

- These map onto `AddConnectionLink` and `makeConnection()`. Installing a package never adds a connection silently. Its presets
  appear in the add-connection screen (`ConnectionSetupSheet .presets`) under the package name. Picking one goes
  through the same editor, which asks for the key. Keys are never in packages.
- At company trust with `managed: true`, MDM or policy may install the connection directly. It is shown locked, with "Managed
  by Acme" on it.

### 3.11 Policy

`policy.json` is honored only from a company-trust package or from MDM (section 7). From any lower trust, installation fails
with a clear reason. A policy-only package is how admins without MDM distribute policy.

### 3.12 Hooks

Hooks are declarative in format 1. They run in-process, synchronously and quickly, and only while a turn runs.

| Event | Declarative actions | Cache impact | iOS safety |
| --- | --- | --- | --- |
| `message.beforeSend` | `{match: regex, action: "block" \| "redact" \| "warn", message}`, applied to the user's text before it is stored and sent (DLP) | None: it changes the newest user message, the tail | Runs on the main actor at send time |
| `tool.afterResult` | `{tools: ["jira_*" \| "web_fetch"...], match, action: "redact"}`, applied to a result before it enters the context | None: new content | Runs inside the tool call |
| `turn.end` | `{audit: true}`, which appends a turn summary to the audit log | None | Writes a local file and uploads opportunistically |

Not supported, with reasons:

- **Timers, schedules, `onLaunch`, push-triggered code.** BGTaskScheduler gives no timing guarantees. WebKit content
  processes are suspended in the background, as `BackgroundLoadingSound` already works around. 2.5.4 limits background
  modes.
- **Hooks that change the system prompt or tools.** These would break the cache.
- **Hooks that read history.** That breaks privacy and isolation.

JS hooks (`message.beforeSend` with a 300 ms budget, company trust only) are a phase 3 open question.

### 3.13 Signature file

```jsonc
// SIGNATURE
{ "alg": "ed25519", "key": "ed25519:<base64url public key>", "sig": "<base64url signature over CHECKSUMS bytes>",
  "chain": [ /* optional rotation: { "key": "ed25519:new", "sig": "<old key signs 'openchat-key-rotation:v1\n'+new key>" } */ ] }
```

- CryptoKit `Curve25519.Signing` verifies the signature.
- `CHECKSUMS` must list every file except `SIGNATURE`, with nothing more and nothing less. `manifest.json`'s `publisher.key` must
  equal `key`, or the last key of `chain`.
- Ed25519 is used because it is small, deterministic, and verifiable with CryptoKit on iOS 13+. X.509 or CMS
  signing is not needed. Companies keep the key in their CI, or in the admin console's HSM in phase 3.

---

## 4. Runtime

### 4.1 Components (new files)

| Type | File | Role |
| --- | --- | --- |
| `PackageManifest`, `PackageTool`, `JSONSchemaSubset`, `URLTemplate`, `ResponseProjection`, `PackageSignature`, `CanonicalJSON` | `Packages/OpenChatPackageKit/Sources/...` (MIT, Foundation and CryptoKit only) | Parse, validate, verify, build requests, project responses, render prompt and tool definitions. Shared with the `openchat-pkg` CLI. `Tools/plugin-check` is the precedent. |
| `PackageStore` | `Strata/Packages/PackageStore.swift` | Installed packages on disk, the registry, active and previous versions, enablement defaults. Thread-safe in the style of `SkillStore`, with an observable `PackagesVersion` for UI. |
| `PackageInstaller` | `Strata/Packages/PackageInstaller.swift` | Download or import, unzip (with zip-slip checks), normalize, verify, diff against the installed version, and hand off to the review sheet. |
| `PackageSecretStore` | `Strata/Packages/PackageSecrets.swift` | Keychain service `cc.coolservices.strata.package`, account `<id>/<secret>`. Includes `scrub(_:)`. |
| `PackageToolRouter` | `Strata/Packages/PackageToolRouter.swift` | A `ToolExecuting` that handles `<namespace>__<tool>` names and delegates everything else to `ToolRouter`. |
| `HTTPToolRunner` | `Strata/Packages/HTTPToolRunner.swift` | Declarative tools. |
| `PackageJSHost` | `Strata/Packages/PackageJSHost.swift` + `Resources/PackageHost/host.html`, `bootstrap.js` (MIT) | The JS sandbox (phase 2). |
| `ToolApprovals` | `Strata/Engine/ToolApprovals.swift` | `SSHRequests` generalized: (chat, call) cards, "Always" policies, background notification, Live Activity input. |
| `AuditLog` | `Strata/Packages/AuditLog.swift` | Append-only JSONL. |
| `PolicyEngine` | `Strata/Packages/Policy.swift` (phase 3) | Merges MDM and policy packages and answers `allows(...)`. |
| UI | `Strata/UI/PackagesView.swift`, `Strata/DesignSystem/PackageViews.swift` | Settings list and detail, install and review sheet, feed card, approval card. |

### 4.2 Sandboxing

**HTTP tools** run no package code. The only inputs are validated arguments and manifest templates. The host does the request.

**JS tools** (phase 2) run in a `PackageJSHost`, one `WKWebView` per package, created lazily. At most 2 hosts are alive, with
LRU disposal. This mirrors `PythonWebHost`:

- `WKWebViewConfiguration.websiteDataStore = .nonPersistent()`, so there are no cookies or storage across calls. Persistence
  goes only through `openchat.storage`.
- A `WKURLSchemeHandler` for `ocpkg:` serves only `host.html`, `bootstrap.js` and the package's own files from its
  installed, verified directory. Every response carries the CSP
  `default-src 'none'; script-src ocpkg:; connect-src 'none'; img-src 'none'; style-src 'none'; frame-src 'none'; worker-src 'none'`.
- A `WKContentRuleList` blocks every `http(s)` and `ws(s)` load, and `LocalNetworkRules` is installed as well. The navigation
  delegate cancels every navigation except the initial `ocpkg://<id>/host.html`.
- Messaging uses one `WKScriptMessageHandlerWithReply` named `openchat`, in the page world. `bootstrap.js` wraps it as the
  `openchat` global and freezes it. Every message is validated on the Swift side: the method name comes from a fixed
  set, and the arguments have a schema. Each call carries the call token the host issued for that run, so stale or
  forged replies from an earlier run are ignored.
- **Isolation between calls and chats**: the page is reloaded before each call, which is cheap because it is local. JS
  memory can't carry state from one chat's call to another chat's. Calls of one package are serialized per host, and at
  most 2 hosts run in parallel overall, through a `FairSlots(capacity: 2)` keyed by conversation as in `RunSlots`. That
  keeps a busy chat from starving the others.
- **Time and memory**: the host deadline uses `Deadline.swift`. When it passes, the host is torn down
  (`webView.stopLoading()`, removed, released), which kills the work in the web content process. The result is
  `Error: the tool sprint_summary timed out after 30 s.` A terminated web content process (memory) disposes the host and
  returns an error, the same as `PythonWebHost.onTerminate`.
- WebKit gives process isolation, so a crash or an infinite loop never takes down the app. That is why JavaScriptCore's
  in-process `JSContext` is not used: it has no public way to interrupt a runaway script.

**Page tools** run where today's plugins run (`HiddenWebView` pool), with `hosts` enforced by `PluginManifest.hostAllowed`.

### 4.3 Per-chat enablement and cache-safe ordering

Today a chat freezes `offeredTools` at its first request (`Conversation.frozenTools`). A switch turned off later stays in
the request, and its calls are refused by `OfferedTools`. A switch turned on later joins the offered set, which costs
one cache miss (`applyToolSwitches`). Packages follow exactly these rules.

**Storage**

- `Conversation.toolSwitchesRaw`, `offeredToolsRaw` and `announcedToolsRaw` also hold `pkg:<id>` entries. `ToolGroup.decode`
  already ignores unknown values, so older builds read the same fields safely.
- A new `ToolSwitch` enum (`.group(ToolGroup)`, `.package(String)`) does the encoding. Groups come first in `allCases`
  order, then packages sorted by id.
- New field: `Conversation.packageSnapshotData: Data?`. It is optional with a nil default, so the SwiftData migration is
  lightweight. It holds the frozen bytes:

  ```swift
  struct PackageSnapshot: Codable {
      struct Entry: Codable {
          var id: String; var version: String; var digest: String          // sha256 of CHECKSUMS
          var namespace: String                                           // after any local alias
          var tools: [FrozenTool]                                         // name, schemaVersion, canonical definition JSON
          var promptSection: String                                       // rendered 3.7 text ("" if none)
          var skillNames: [String]
      }
      var entries: [Entry]                                                // sorted by id
  }
  ```

**Request assembly.** In `ChatController.apiHistory` and `requestTools`, and in `TurnRunner.toolList`:

1. **Tools**: `ToolDefinition.available(groups:images:)`, unchanged, comes first. Then `load_skill`, if a package skill needs
   it and `.browser` isn't offered. Then, for each snapshot entry in id order (UTF-8 byte order), its tools in manifest
   order, as the stored canonical JSON. `ToolDefinition` gains
   `enum Body { case typed(Function), raw(CanonicalJSON) }` with a custom `encode(to:)`. The built-in encoding stays
   byte-identical, and a golden test proves it.
2. **System message**: `[AppPrompt.text(...), skillIndex, packageSections, preferences]` is joined with `\n\n` after
   filtering out empty parts, then passed to `ConversationDate.systemPrompt(base:day:plugins:)` as today.
   `packageSections` is the snapshot's `promptSection`s in id order, joined with `\n\n`. Package fragments come before
   the user's preferences, so "they take precedence over the defaults above" keeps holding for the user.
3. **Plugins**: the existing live `PluginRegistry.bundled.promptSection(enabled: AppSettings.currentEnabledPlugins)` is
   frozen into the conversation too (`pluginSectionSnapshot`). This fixes today's leak.

**Rules.** Each one is a test in `PackageCacheTests`.

- R1. A chat with no packages produces byte-identical request bodies before and after this change. This is a golden test
  over `ChatRequest.encoded()` for all `ToolGroup` combinations.
- R2. Enabling packages {A, B} in any order gives identical bytes.
- R3. Installing, updating, uninstalling or changing the Settings defaults for a package never changes the bytes of a
  chat that has already sent.
- R4. A package switched off mid-chat stays in the tools and the prompt. Its calls are refused with
  `The user turned off the Acme Jira package for this chat. Answer without it, or ask them to turn it on.`
  The change is announced as `[Package Acme Jira: off]` in `Message.apiNote` (`ToolGroup.note` extended). A package
  switched on mid-chat joins the snapshot at the next turn's first request. That is one cache miss, and the switch row
  says so ("Turning this on restarts the chat's cache once").
- R5. Rendered bytes contain no timestamps, counters, random ids, locale-dependent text or secret values. All strings are
  NFC and LF. Canonical JSON uses sorted keys, no insignificant whitespace, and numbers printed as given (integers only in
  schemas, enforced by the validator).
- R6. If the installed package is newer than the snapshot, calls run the installed implementation when the tool still
  exists with the same `schemaVersion`. Otherwise they are refused with: `This tool changed since the chat started
  (Acme Jira 1.4.0 → 2.0.0). Answer without it, or ask the user to start a new chat.` If the package was uninstalled, the
  refusal is `The Acme Jira package was removed.`
- R7. Policy always wins at execution time. A tool blocked by policy is refused even if it is frozen into the chat.
  `purgeFromChats: true` in the policy rebuilds the snapshot without the package. That breaks the cache once, and it is
  meant for security incidents.

**Names**

- A tool's full name is `<namespace>__<tool>`, at most 64 characters, matching the OpenAI `^[a-zA-Z0-9_-]{1,64}$` rule.
- Reserved namespaces: `web`, `browser`, `run`, `view`, `load`, `save`, `show`, `current`, `video`, `ssh`, `python`,
  `openchat`, `app`, `test`, `pkg`. A full name may not equal anything in `ToolNames` or `SSHToolNames.all`.
- If two installed packages want the same namespace, the second install asks for a local alias (`jira2`). The alias is
  stored in the registry and in snapshots.

**Budgets**

- At most 24 tools per package, and at most 64 package tools per chat. The OpenAI limit is 128, and the built-ins use
  about 35.
- The composer warns when the enabled packages' prompt and tools exceed 6k tokens.
- `ContextGrid` gets a "Packages" category so the context grid shows their cost.

### 4.4 Execution path

`ChatController.startTurn` builds `TurnRunner(streamer:tools:)`, where `tools` becomes `PackageToolRouter(base: ToolRouter(),
snapshot:, store:, policy:)`. `OfferedTools` keeps checking that the name was offered and that the switch is on.
`ToolGroup.group(of:)` is complemented by `PackageToolRouter.package(of:)`. Then:

1. Policy check (R7) and snapshot compatibility check (R6).
2. Argument validation against the schema. Errors are model-readable.
3. Approval check (section 4.5).
4. Run: `HTTPToolRunner`, `PackageJSHost` or `PluginPipeline`, under `ToolContext` (chat, call, progress).
5. Post-processing:
   - `tool.afterResult` hooks.
   - Secret scrub.
   - Truncation.
   - `ToolOutput(sources:)`, numbered by `SourceStore` as for the web tools.
6. Audit event.

`usesWebKit` is true only for js and page tools. HTTP tools keep running while the app goes to the background, within the
reply's continued-processing lease (`ReplyBackgroundExecution`). `ToolNames.isSafeToRetry` returns true for package tools
marked `readOnly`. `ToolNames.usesWebPage` covers page tools, which play the background sound as today.

### 4.5 Approvals, feed and errors

**Approval policy** per tool, as the manifest's `confirm`, possibly tightened by trust level and policy:

| Effective | Behavior |
| --- | --- |
| `never` | Runs. Only for `readOnly` tools of trust ≥ user-trusted key, or when an admin allows it. |
| `first` | The first call in each chat shows a card with "Allow in this chat", "Always" and "Deny". |
| `always` | Every call shows a card with "Run" and "Deny", plus "Always for this tool" unless policy forbids it. |

Unsigned personal packages can't use `never` for non-readOnly tools. `confirm` is raised to at least `first`.

**Card**

- The card follows the SSH approval card (`DesignSystem/SSHViews.swift`), placed under the call's line in the chat's
  feed and keyed by (conversation, call id), as `SSHRequests.request(forCall:conversation:)` is today.
- It shows the package icon and name, the trust badge, the tool title, the target host, and the arguments, pretty-printed
  with secrets masked. For body templates it shows the resolved request (method, URL, JSON body), so the user approves
  exactly what will be sent.
- A cancelled turn denies. While the app is in the background, `SSHRequestNotifier` becomes `ToolApprovalNotifier` and posts
  "Approve Acme Jira › Create issue?".
- The Live Activity gets `ReplyActivityInput.Approval.packageTool(package:tool:)`, and `ReplyActivityPhase` shows "Needs
  you · Acme Jira wants to create an issue".
- "Always" choices are stored in the Keychain-backed approval store under `pkg:<id>/<tool>`, like
  `SSHStore.setAlwaysAllowed`. They are listed and revocable in the package detail page.

**Feed**

- Add the card kind `FeedCard.Kind.package(packageID: String, tool: String, argument: String)` in `ActivityFeed.cards`.
- `ToolNames.hasOwnCard` returns true for package tools. The card shows the icon, `title`, `display.argument` and a status mark.
  Expanding it shows the result text, the rendered `view` if any, and sources as chips.
- `ToolCallRecord.displayOnly` keeps the result for package tools only if the manifest says `display.keepResult: true`,
  capped like `run_python` output. Otherwise only the first line is kept.
- The process title ("Used Acme Jira", "Searched the web, used Acme Jira") extends `ProcessSegmentModel`.

**Errors** are always `ToolOutput(isError: true)` text that tells the model what to do next, following `PluginError`
and `Skill.Problem`. Examples: a missing secret gives `The Acme Jira package has no API token yet. Ask the user to add it
in Settings › Packages › Acme Jira.`, and the feed card shows a "Add token" button that deep-links to the detail page.

### 4.6 Permissions, enforced

| Permission | Enforced where | Install sheet wording |
| --- | --- | --- |
| `network` | `HTTPToolRunner`, `openchat.fetch`, page tool `hosts`, and every redirect | "Can send data to: acme.atlassian.net" |
| `privateNetwork` | `URLGuard` bypass only for declared hosts. Trust ≥ user key, or personal with explicit user toggle | "Can reach devices on your local or company network: nas.local" |
| `secrets` | `PackageSecretStore`, used only by injection | "Uses a Jira API token that you enter. The model never sees it." |
| `storage` | `openchat.storage` quota | "Stores up to 1 MB on this device" |
| `exclusive` | `ChatController.setTool` and package enablement: turning on one side turns off the other, with a note in the menu | "Can't be used in the same chat as web search or the browser" (protects company data from exfiltration through web tools) |
| `requires.groups` | Enabling the package turns them on | "Turns on: Browser" |
| `data` (reserved) | Not in format 1. HealthKit, location, contacts and photos are never exposed to package code in App Store builds (4.7.2). Packages get that data only if the model passes it in arguments, from built-in tools the user turned on and calls the user can see. | n/a |

Permission prompts:

1. **At install**, a full list on the review sheet.
2. **At first use**, through `confirm` (section 4.5).
3. **On update**, only the new permissions are shown again (section 5.4).

The consent record (permissions, version, date) is stored in the registry and the audit log. This covers 4.7.3 and 5.1.2(i)
(section 8).

### 4.7 Secret handling

- Values are entered in the package detail page with a `SecureField`. They are stored as Keychain generic passwords with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never synced. The Mac uses the file keychain as today, per PLAN.md.
- Secrets are injected only at request build time, inside `HTTPToolRunner` and the `openchat.fetch` bridge. They never
  appear in the model's context, tool arguments, results, feed, checkpoints (`TurnCheckpoint`) or the audit log.
- **Scrub**: before a result reaches the model, the feed or the logs, every occurrence of any secret value of that package
  is replaced with `[secret]`. Base64 and URL-encoded forms are replaced too. This catches APIs that echo the token back.
- `DebugRedaction` gets `registerExact(values:)`, fed by `PackageSecretStore`, so debug bundles
  (`Diagnostics/DebugBundle.swift`) can't leak them. `RequestRing` already records request bodies, and those never hold
  secrets because injection happens below the ring.
- `exposeToScript: true` on a secret declaration hands the raw value to JS, for odd signing schemes. It is allowed only at
  company trust, and the review sheet shows it in red. OAuth via `ASWebAuthenticationSession` comes in phase 3, with a declared
  `oauth` block (authorize and token URLs on declared hosts, PKCE) and the refresh token in the Keychain.

### 4.8 Multi-chat isolation

- Approvals, progress and live state are keyed by (conversation, call id). Call ids repeat across chats (`call_0`), as
  `ToolProgress.Key` already handles.
- The JS realm is reloaded per call, so nothing is shared in memory. `openchat.storage` scope `chat` is keyed by
  conversation and deleted in `ChatController`'s chat deletion path. Scope `package` is shared on purpose, for caches and
  settings, and the review sheet says so.
- Concurrency uses `FairSlots`-style per-host slots. A package declares `"concurrency": 1–4` (default 2) for HTTP tools so
  it doesn't hammer an internal API. A shared token-bucket rate limit per package defaults to 10 calls per 10 s, and
  `RateLimiter.swift` exists for this.
- A run that is discarded (`ChatRun.discarded`) cancels its package calls. HTTP tasks are cancelled, and a JS host running
  for that chat is torn down.

### 4.9 iOS background limits

- A reply already keeps running in the background under `ReplyBackgroundExecution`, a continued-processing lease. HTTP
  tools work there. JS and page tools are WebKit, which iOS suspends, so they behave like `browser_*` today. They may wait
  for the scene (`ToolExecuting.usesWebKit`), and only `readOnly` ones are retried by `ToolExecutionRecovery`.
- An approval card in the background posts a notification and sets the Live Activity to "Needs you", as SSH does.
- No package code runs outside a turn. Update checks and audit uploads run in the foreground, or opportunistically in a
  `BGAppRefreshTask` with no package code involved.

---

## 5. Install, update, trust

### 5.1 Link: `openchat://add-package?url=…&sha256=…`

- `AddPackageLink` parses the link, as `AddConnectionLink` does. `url` must be https, without user info, and at most 2 KB.
  `sha256` is optional, and when present the download must match it. Any other parameter is ignored.
- `PackageLinks` and `PackageLinkHandler` mirror `ConnectionLinks` and `ConnectionLinkHandler`. They share the root
  `.onOpenURL`, so each `receive` claims only its own host. A sheet that is already open is closed first, with the same
  600 ms dance.
- Download: an ephemeral `URLSession`, no cookies, a 5 MB cap (`LimitedDownload.swift`), and a 60 s timeout.
- The confirmation sheet is the review sheet from section 5.3. Nothing is written into the package store before the user
  taps Install.
- Universal links of the form `https://openchat.app/p/<id>` resolve to the same flow. They are needed for the 4.7.4 index
  in phase 3.

### 5.2 File import

- Declare an exported UTType `cc.coolservices.openchat.package` with the `.ocpkg` extension, conforming to
  `public.zip-archive`. Add `CFBundleDocumentTypes` to `project.yml`, and `LSSupportsOpeningDocumentsInPlace = NO`.
  Opening the file from Files, Mail or AirDrop launches the import.
- Share extension (`Strata/Share/`): `ShareItemLoader` recognizes `.ocpkg` file URLs. It writes the file to the App Group
  inbox as a new `SharePayload` kind, `.package`, and opens the app, where `ShareImporter` hands it to `PackageInstaller`
  instead of making a chat. The extension itself never installs.
- On the Mac, the user can drag a file onto the window or use Settings › Packages › Import.
- Developer mode, on the Mac or in Debug builds, adds a folder with live reload. Unsigned folder packages are marked
  "Development", reload on file change, and new chats pick up the new snapshot.

### 5.3 Review sheet (install, update, agent drafts)

The sheet has one layout for all three cases (`PackageReviewSheet`):

1. **Header**: icon, name, version, publisher, and trust badge.
   - Known publisher: green.
   - Company: "Acme Corp", managed.
   - User-trusted key: key fingerprint. On the first install of that key, "Trust this publisher's key?"
   - Unsigned: orange, "Not signed. Only install packages you or your assistant made, or from people you trust."
2. **What it adds**:
   - tools (title and description, with "asks before running" marks)
   - skills
   - prompt (token estimate, expandable text)
   - commands, views and presets
3. **What it can reach**: the permission list from section 4.6. Hosts are shown as registrable domains with full hosts
   underneath.
4. **Files**: a browsable list. Code and JSON are rendered with `SyntaxHighlighter`, Markdown is rendered.
5. **For updates**: a diff view showing changed files and new or removed permissions, with new permissions highlighted.
6. **Actions**: Install, plus a toggle "On in new chats" that is on by default for company trust and off otherwise. Then
   Cancel.

Agent drafts add "Try a tool", which runs a tool with sample arguments in a dry run that skips the audit and keeps
approval cards (section 6).

### 5.4 Updates and rollback

- `update.url` returns `{ "version": "1.5.0", "url": "https://…/com.acme.jira-1.5.0.ocpkg", "sha256": "…", "notes": "…" }`.
  It is checked at most once a day, in the foreground, on Wi-Fi or any network for company packages, and when MDM config
  changes.
- **Same-key rule**: an update must be signed by the installed version's key, or by a key reached through a valid
  `chain`. Unsigned packages never update automatically. They show "Update available" and the full review sheet.
- **Silent updates** happen only for signed packages whose permissions are equal or narrower. Otherwise the user gets a
  badge and the review sheet. MDM-required packages update silently if the policy says so.
- Storage is `Application Support/Packages/<id>/<version>/` (verified, normalized files) plus `registry.json` (active
  version, previous version, trust, consent records, enablement defaults, aliases). The previous version is kept
  until a newer one has been in use for 7 days. "Revert to 1.4.0" is in the detail page.
- Frozen chats are unaffected by updates (R3/R6). Old version directories are not needed by frozen chats, because
  snapshots carry the definitions and the installed implementation runs.
- **Uninstall** removes the files and deletes secrets, storage, approvals and the defaults entry. Frozen chats refuse calls
  (R6), and the audit log keeps its records. MDM-required packages can't be uninstalled by the user.

### 5.5 Trust levels

| | OpenChat-known publisher | Company key | User-trusted key (TOFU) | Unsigned personal |
| --- | --- | --- | --- | --- |
| How it gets that status | Key compiled into the app, plus a signed key list update | Key in MDM config or in an installed policy (phase 3) | The user accepted the key at first install | No signature, or an agent draft |
| Skills, prompt, commands, views | yes | yes | yes | yes |
| HTTP tools | yes | yes | yes | yes, with `confirm ≥ first` for non-readOnly |
| JS and page tools | yes | yes | yes | yes, with code shown in review and `confirm ≥ first` for all tools |
| `privateNetwork` | yes | yes | yes | only with an explicit extra toggle in review |
| Connection presets | yes | yes, plus `managed` | yes | yes (still confirmed per connection) |
| `policy`, hooks | no (we don't police users) | yes | no | no |
| `exposeToScript` secrets | no | yes | no | no |
| Silent update | permission-equal | permission-equal, or forced by policy | permission-equal | never |
| Can be blocked by | our revocation list | admin | the user | the user, and policy (`allowUnsigned: false`) |

### 5.6 Revocation

- We publish a signed revocation list of ids, digests and keys. The app fetches it daily, alongside the known-publisher
  list. A revoked package is disabled immediately, with a reason, and its calls are refused under R7.
- Company policy can block ids or digests locally.

### 5.7 Settings UI

- Settings › Packages lists packages with icon, name, version, trust badge, and an "On in new chats" toggle.
- The detail page has:
  - contents
  - permissions
  - secrets (enter, replace or clear)
  - "Always" approvals (revoke)
  - storage use, with a clear button
  - log
  - audit entries for this package
  - update and revert
  - remove
- The composer "+" menu (`Composer.swift`, `ComposerToolSwitch`) lists enabled-in-app packages below the built-in groups,
  sorted by name. `ComposerToolSwitch.id` is already a string, so `pkg:<id>` fits.

### 5.8 Interaction with App Intents, Share, on-device model, Live Activities

- **App Shortcuts are static.** `OpenChatShortcuts: AppShortcutsProvider` is compiled, and its phrases are extracted at
  build time. Packages can't add App Shortcuts, intents or Siri phrases at runtime. Instead:
  - Package commands could be exposed as `AppEntity` values of a generic "Run command" intent: `RunPackageCommandIntent`
    with a `PackageCommandEntity` parameter backed by an `EntityQuery` over installed commands. This is dynamic data,
    which the system allows, but the user must build the shortcut. It is a phase 3 option.
  - `AskOpenChatIntent` and `SummarizeIntent` chats (`IntentChat.conversation`) use the "On in new chats" packages, but
    only those whose tools need no approval (`confirm: never`). A Siri or background run can't show cards. Packages that
    need approval are left out, and the intent's answer says so if it matters.
- **On-device model** (`Strata/OnDevice/`): `OnDevicePromptBuilder` replaces the app prompt with short instructions and offers
  only `web_search` and `web_fetch` (`toolSpecs`) to fit a ~3B model and a 4K window. Package tools are excluded by
  default. A tool may opt in with `"onDevice": { "description": "<≤ 120 chars>", "parameters": ["<≤ 3 string params>"] }`.
  The builder then adds an `OnDeviceToolSpec` for it, at most 2 package tools, in snapshot order. Package prompt
  fragments are never sent on device. The request built for the API model still carries the full snapshot, so switching
  models mid-chat doesn't touch the frozen state.
- **Share extension**: it is used only to receive `.ocpkg` files (section 5.2). Shared content becomes a normal chat, with
  the default packages.
- **Live Activities and widgets**: these are compiled extensions too. Package approvals feed "Needs you" (section 4.5).
  Packages can't define activity UI.

---

## 6. Agent-authored packages

The model drafts, the user reviews, and the draft becomes a personal package.

### 6.1 Tools

There is a new tool group `ToolGroup.authoring` ("Build tools"), off by default in new chats so it costs nothing
otherwise. It sits last in `ToolGroup.allCases`. Enum order is the encoding order, so appending keeps old encodings stable.

| Tool | What it does |
| --- | --- |
| `save_package(manifest, files)` | `manifest` is the manifest JSON, and `files` is an object mapping path to text. The tool validates with `OpenChatPackageKit` and returns errors in model-readable form, so the model fixes and retries. If validation passes, it queues a `PackageReviewSheet` request through `PackageApprovals`, a `SkillApprovals` clone keyed by chat. It returns only after the user's answer: `Saved package com.user.immich 0.1.0. New chats can turn it on.`, or `Error: the user declined…`. |
| `test_package_tool(manifest, files, tool, args)` | Runs one tool of an unsaved draft once, with the same sandbox and permission checks. Each declared host needs an approval card, with "Allow for this draft". Secrets the draft declares must already exist under the same package id, or the card asks for a value for this test only, held in memory. It returns the result or the error, so the model can iterate on response projection before saving. |
| `read_package(id)` | Returns an installed personal package's manifest and files, for editing. It is refused for company and known-publisher packages unless policy allows it. |

Restrictions enforced on agent drafts:

- The id must be in `user.*`. Generated ids look like `user.<namespace>`.
- The trust level is always unsigned personal.
- Drafts may not declare `policy`, `hooks`, `exposeToScript` or `managed`.
- `privateNetwork` is allowed only if the user turns it on in review.
- The total size is at most 256 KB.

### 6.2 "Save as package" from "Save as skill"

`SkillOffer.isOffered` (`Engine/SkillOffer.swift`) keeps deciding whether to show the chip. A sibling `PackageOffer.kind`
looks at the turn's successful calls:

- If the work that succeeded was a JSON API call (`browser_eval` that called `fetch()` and returned JSON, or `web_fetch` of
  an `application/json` URL), the chip reads "Save as tool". Its hidden instruction asks for `save_package` with one
  `http` tool, and `authoring` is switched on for that turn. That is one cache miss, and the chip says nothing about it
  because it is rare and user-initiated.
- Otherwise the chip stays "Save as skill", with today's instruction.

`AppPrompt.skillOffer` is unchanged. A new `AppPrompt.authoring` section is included only when `.authoring` is offered.
It says to:

- prefer a declarative `http` tool over JS
- declare the narrowest hosts
- never put secrets in files, but declare them by name
- write descriptions for a model reader
- test with `test_package_tool` before saving

### 6.3 Review before enabling

- The sheet from section 5.3, with the "Try a tool" button and the code visible.
- A saved draft is **off in new chats** by default. The toggle is on the sheet.
- Updates by the model (`save_package` with an existing id) show the diff view. Permission increases are highlighted, and
  the model's stated reason is shown under the diff as untrusted text.

---

## 7. Enterprise

### 7.1 Policy schema (`policy.json` or MDM `OpenChatPolicy`)

```jsonc
{
  "format": 1,
  "organization": "Acme Corp",
  "packages": {
    "allow": ["com.acme.*", "app.openchat.*"],      // glob on ids; absent = all
    "block": ["user.*"],
    "allowUnsigned": false,
    "trustedKeys": ["ed25519:…"],                   // company keys
    "required": [ { "id": "com.acme.jira", "url": "https://pkgs.acme.internal/…", "sha256": "…", "on": true, "pin": "1.4.0" } ],
    "silentUpdates": true
  },
  "tools": {
    "disableGroups": ["ssh", "python"],             // ToolGroup raw values
    "disableTools": ["browser_eval", "save_skill"],
    "confirmAtLeast": { "com.acme.jira/*": "first" }
  },
  "connections": {
    "allowHosts": ["llm.acme.internal", "*.acme.com"],   // others are blocked at Endpoint resolution
    "allowUserConnections": false,
    "managed": [ { "name": "Acme LLM", "url": "https://llm.acme.internal/v1", "api": "openai" } ]
  },
  "authoring": { "savePackage": false, "saveSkill": true },
  "prompt": "You are assisting Acme employees. Never paste customer data into web_search.",   // org fragment, ≤ 4k
  "dlp": [ { "match": "\\bACME-[A-Z]{3}-\\d{6}\\b", "action": "redact", "message": "Customer ids are redacted." } ],
  "audit": { "level": "calls", "endpoint": "https://audit.acme.internal/openchat/v1/events", "retentionDays": 30 },
  "minAppVersion": "1.3.0",
  "purgeFromChats": []                              // package ids to remove from frozen chats (R7)
}
```

`PolicyEngine` merges all sources so that the strictest value wins:

- block beats allow
- the smaller set of hosts wins
- the higher confirm level wins

Precedence for non-mergeable values (`organization`, `audit.endpoint`, `prompt`): MDM, then the company policy package.
Users can't loosen policy. Settings shows "Managed by Acme" on every control it locks.

Enforcement points:

- **Tool offering**: `ChatController.toolSwitches` and `offeredTools` intersect with the allowed groups. A chat frozen
  before the policy keeps its bytes but gets refusals under R7.
- **Execution**: `OfferedTools` and `PackageToolRouter`.
- **Connections**: `ConnectionStore` endpoint resolution refuses disallowed hosts with "Blocked by Acme's policy". This
  also covers `AddConnectionLink` and presets. The on-device connection (`Strata/OnDevice/`) is a connection too, and
  policy can allow or block it with `"onDevice": false`.
- **Org prompt**: it sits right after `AppPrompt.text` as its own section, frozen per chat like the other sections.
- **DLP**: implemented as `message.beforeSend` and `tool.afterResult` hooks (section 3.12).

### 7.2 Distribution via MDM (Managed App Configuration)

- Read `UserDefaults.standard.dictionary(forKey: "com.apple.configuration.managed")` and observe
  `UserDefaults.didChangeNotification`.
- Keys:
  - `OpenChatPolicy` (inline JSON string or `https` URL + sha256)
  - `OpenChatPackages` (array of `{url, sha256}`)
  - `OpenChatTrustedKeys`
  - `OpenChatConnections`
  - `OpenChatAuditToken` (stored to the Keychain at first read)
- Report status back to MDM through `com.apple.feedback.managed`: installed package versions, policy digest, last error.
- On the Mac, managed preferences from configuration profiles appear in the same defaults domain.
- Offline: MDM-provided packages that are URLs are fetched when the network is available. Until then, the policy still
  applies, and required-but-missing packages show as "Waiting to download".

### 7.3 Company signing keys

- The company generates an Ed25519 key, either with `openchat-pkg keygen` or in the admin console in phase 3. The public key
  goes into MDM `OpenChatTrustedKeys` or a policy's `trustedKeys`. CI signs packages with `openchat-pkg sign`.
- Rotation uses `chain` (section 3.13). Revocation means removing the key from the policy. Packages signed only by a
  removed key are disabled.
- Without MDM, a company can hand out a policy-only package signed by its key, together with a fingerprint the user
  confirms on first install, once.

### 7.4 Audit log

- File: `Application Support/Audit/YYYY-MM-DD.jsonl`, append-only, rotated daily. Retention follows the policy
  (default 30 days). Each line is one event:

  ```json
  {"t":"2026-10-22T09:14:03Z","ev":"tool.call","chat":"<uuid>","pkg":"com.acme.jira","ver":"1.4.0","tool":"jira__search",
   "host":"acme.atlassian.net","status":200,"ms":412,"approved":"never","argsSha256":"…","resultChars":3810}
  ```
- Events:
  - `package.install`, `package.update`, `package.revert`, `package.remove`
  - `consent` (permissions granted)
  - `tool.call`
  - `approval` (run, always or deny)
  - `policy.apply`
  - `dlp` (rule id, action; no content)
  - `connection.blocked`
- `audit.level`:
  - `calls` (default): no arguments, only their hash.
  - `calls+args`: arguments with secrets masked by `SSHMask`-style masking.
  - `full`: results too, capped at 4k per call. Users see this level on a "This device is managed" screen.
- Upload: batches are POSTed to `audit.endpoint` with the `OpenChatAuditToken` bearer, in the foreground and through
  `BGAppRefreshTask`. Failures retry with backoff. Upload never blocks a turn. Without an endpoint, the log is local
  only and exportable through the share sheet for B2C users.
- Personal users get the log too, off by default, as a "Package activity" view.

### 7.5 Admin console, gateway, billing (closed, optional)

- **Admin console** (phase 3, closed source):
  - edits policy
  - holds the org signing key (HSM)
  - hosts the org package registry (`update.url` endpoints, an index for 4.7.4-style listing inside the org)
  - shows audit dashboards
  - produces the MDM config plist
- **Strata gateway** (existing server side, closed): an org's gateway connection can carry the org's identity. Two
  options:
  1. The console publishes the policy at the gateway, `GET /v1/openchat/policy` (signed with the org key). When a user
     adds a connection to that gateway, the app offers: "Acme publishes a policy and packages for this server. Apply?"
     It is applied only if the user accepts, and only if it is signed by a key the user confirms. This bootstraps
     without MDM. See open question Q6.
  2. Audit events go to the gateway (`POST /v1/openchat/audit`) with the connection's API key, so there is one
     credential.
- Billing: seats and package distribution are billed on the console side. The app has no billing code. Packages can't
  sell anything in-app (3.1).

All app↔server protocols (policy JSON, audit events, update manifests, registry index) are documented in the MIT spec.
The GPL client interoperates with the closed servers only over these documented network protocols (section 10).

---

## 8. App Store compliance

Text quoted from the App Review Guidelines at developer.apple.com/app-store/review/guidelines, read 2026-10-22.

**2.5.2**: "Apps should be self-contained in their bundles, and may not read or write data outside the designated
container area, nor may they download, install, or execute code which introduces or changes features or functionality
of the app, including other apps."

**4.7**: "Apps may offer certain software that is not embedded in the binary, specifically HTML5 and JavaScript mini apps
and mini games, streaming games, chatbots, and plug-ins. […] You are responsible for all such software offered in your
app, including ensuring that such software complies with these Guidelines and all applicable laws."

- **4.7.1**: software offered in apps under this rule must "follow all privacy guidelines, including but not limited to
  the rules set forth in Guideline 5.1 […]; include a method for filtering objectionable material, a mechanism to report
  content and timely responses to concerns, and the ability to block abusive users; and follow Guideline 3.1 in order to
  offer digital goods or services to end users."
- **4.7.2**: "Your app may not extend or expose native platform APIs or technologies to the software without prior
  permission from Apple."
- **4.7.3**: "Your app may not share data or privacy permissions to any individual software offered in your app without
  explicit user consent in each instance."
- **4.7.4**: "You must provide an index of software and metadata available in your app. It must include universal links
  that lead to all of the software offered in your app."
- **4.7.5**: "Your app must provide a way for users to identify software that exceeds the app's age rating, and use an
  age restriction mechanism based on verified or declared age to limit access by underage users."

**5.1.1(ii)**: "Apps that collect user or usage data must secure user consent for the collection […]".

**5.1.2(i)**: "You must clearly disclose where personal data will be shared with third parties, including with
third-party AI, and obtain explicit permission before doing so."

**5.1.3(i)** (Health): "Apps may not use or disclose to third parties data gathered in the health, fitness, and medical
research context […] for advertising, marketing, or other use-based data mining purposes […]".

**2.5.19**: "Don't include any hidden, dormant, or undocumented features in your app; your app's functionality should be
clear to end users and App Review."

**2.3.1(a)**: "All new features, functionality, and product changes must be described with specificity in the Notes for
Review section of App Store Connect […]".

**2.5.6**: "Apps that browse the web must use the appropriate WebKit framework and WebKit JavaScript."

### Analysis

| Concern | Position |
| --- | --- |
| 2.5.2: downloaded code | Packages contain data (JSON, Markdown, OpenUI Lang, which the app interprets with fixed semantics) and JavaScript run only in WebKit. That is the "HTML5 and JavaScript … plug-ins" 4.7 allows. There is no native code, dylib or WASM, and the installer refuses Mach-O, `.dylib`, `.wasm` and `.framework` by content sniffing, not by extension alone. The app's own features don't change: the tool loop, UI and permissions are fixed in the binary. Packages fill in data the binary already knows how to use. Pyodide's downloaded WASM packages already run in WebKit under the same reasoning, and that should be named in the review notes too. |
| 4.7: "you are responsible" | We don't operate a public catalog in the MVP. Users install by link, file, MDM or agent. We keep revocation (section 5.6) for anything we learn is harmful. |
| 4.7.1: filtering and reporting | Needed once we "offer" software, meaning a directory. Phase 3: the directory has a Report button and moderation, and the revocation list is the takedown mechanism. For sideloaded personal packages, "Report" in the detail page goes to us with id and digest. Open question Q1: does a link-installed third-party package count as "offered in your app"? |
| 4.7.2: native APIs | The host API is app-level only: fetch to declared hosts, own storage, progress, confirm and ask cards. **No** HealthKit, location, contacts, photos, camera, microphone, Keychain items other than the package's own, App Intents, notifications or files. Health data (the `health` branch's HealthKit work) reaches a package only if the model puts it into arguments, which the user sees in the feed and, for writes, approves. Exposing it directly would need Apple's permission. That is a phase 3 conversation, and it is absent from App Store builds until then. |
| 4.7.3: consent "in each instance" | Install-time consent covers the declared hosts, and per-tool `confirm` covers runs. For data the app holds under privacy permissions (location, health), a package never receives it directly (see 4.7.2). If we ever add `data` permissions, every call gets a card (`confirm: always` forced). Open question Q2. |
| 4.7.4: index with universal links | Needed for software we offer. Built-in packages are listed in Settings › Packages, and each gets an `https://openchat.app/p/<id>` page in phase 3. A public directory ships only with the index. |
| 4.7.5: age rating | Packages are tools, not content. The directory (phase 3) carries an age flag, and packages above the app's rating are hidden without declared age. In the MVP there is no directory, so this isn't applicable, but see Q1. |
| 5.1: privacy | The review sheet lists every host the package can send data to. That is the "clearly disclose where personal data will be shared" with explicit permission at install. The privacy policy gets a "Packages" section saying that packages you install can send the data you ask them to process to the hosts they declare, and that OpenChat receives nothing. |
| 2.5.19 / 2.3.1(a) | Describe packages in the review notes: the format, the sandbox, a demo package link, and the absence of native code. Ship at least one built-in package (Wikipedia) so the feature is visible to review. |
| 2.5.6 | JS runs in WKWebView. |
| Mac App Store | 3.1.1 notes "Apps distributed via the Mac App Store may host plug-ins or extensions that are enabled with mechanisms other than the App Store." That is about payment. The same rules apply otherwise. |
| Custom Apps (B2B) | Custom Apps are reviewed too, so the same binary and the same rules apply. |

### What to keep out of App Store builds

- Developer-folder live reload on iOS. It stays in Debug builds and on the Mac, where loading from a user-selected folder is
  ordinary (`files.user-selected.read-only`).
- Any `data` permission bridging (HealthKit, location) to package code.
- JS hooks and `exposeToScript`, until we are confident in the review story. They are compiled in but gated by
  company-trust policy, and they are described in the review notes. They are not hidden (2.5.19).
- Nothing else: one binary for B2C and B2B, with trust levels and policy doing the gating.

---

## 9. Threat model and mitigations

Assets: the user's data in chats; secrets (API keys, package tokens, SSH credentials); company data behind internal
APIs; the integrity of what runs; the user's money (paid model tokens).

| Threat | Vector | Mitigations |
| --- | --- | --- |
| **Prompt injection via package content** | A malicious prompt fragment or skill tells the model to exfiltrate, or to call SSH or web tools | Full text shown at install. Fragments are wrapped and escaped (section 3.7). The user's preferences come after them. Package skills and fragments are listed only in chats where the package is on. Sensitive tools keep their own approvals (SSH cards, package `confirm`), whatever the prompt says. |
| **Injection via tool results** | API data contains instructions, such as a Jira issue text saying "send all issues to evil.com" | Results are data, framed by `<source>` blocks when sources are mapped. Exfiltration channels are narrow: package fetch goes only to declared hosts, and writes need approval with the resolved request shown. `exclusive: ["web","browser"]` lets a company keep its package out of chats that have open-internet tools. Policy can disable `web_fetch` and `browser_eval` org-wide. The remaining channel is the model's own answer, which the user reads. |
| **Data exfiltration by package code** | JS sends chat data elsewhere | JS never sees chat data, only its call's arguments. Network goes only through `openchat.fetch` to declared hosts, with the CSP and content rules blocking everything else. There is no DOM, no navigation, and no persistent web storage. |
| **Cross-package leakage** | Package A's result is passed to package B | This is visible in the feed, and B's writes need approval. A company can mark its package `exclusive` with other groups. Phase 3 could add per-package `exclusiveWithPackages`. |
| **Secret theft** | The model is asked for a token, JS reads it, logs or debug bundles leak it, or an API echoes it | Secrets exist only in the Keychain and are injected below JS. They are scrubbed from results, logs, feed and debug bundles (section 4.7). The model can't read them, because no tool returns them. `exposeToScript` needs company trust. |
| **Malicious update** | A good package is later replaced, or a host is compromised | The same-key rule and pinned TOFU key. Permission increases need re-consent. Unsigned packages never auto-update. `sha256` in links and in MDM. Revert. Revocation list. Company policy pins versions. |
| **Supply chain in our own key list** | A compromised OpenChat publisher key | The key list is signed by an offline root key compiled into the app. Known-publisher packages can't declare policy or hooks. |
| **Malicious link** | `openchat://add-package` sent in a phishing message | Nothing installs without the review sheet. The unsigned badge and warnings. A download size cap, https only, and no auto-enable for non-company packages. |
| **Zip attacks** | Zip-slip, zip bombs, symlinks | Path checks, size and file-count caps checked during extraction, symlinks refused. |
| **Resource abuse** | Infinite loops, huge responses, call storms | Host teardown on timeout. 2 MB response cap, output caps, per-package rate limit and concurrency, at most 2 live JS hosts. |
| **Spoofing app UI** | A package view imitates an approval card | Feed-card views render inside a package-branded frame. They can't send messages or open anything but links. Approval cards are native and never package-drawn. |
| **Local network attacks** | A package probes the LAN or a router admin page | `URLGuard` blocks private addresses by default. `privateNetwork` must be declared, the hosts must be listed, and it is shown at install. |
| **Model-authored backdoors** | The model, steered by a web page, drafts a package that exfiltrates | Drafts are always unsigned personal, can't use policy or hooks, are off by default, and get a full review with code and hosts. `save_package` is offered only when the user turns on "Build tools". |
| **Policy bypass** | The user edits the policy or installs a blocked package | Policy comes from MDM (read-only to the app) or a signed company package. Blocks are enforced at execution (R7), not only in the UI. |

Residual risks:

- A user who approves a malicious unsigned package with broad hosts can leak whatever they ask it to process. The review
  sheet makes the hosts explicit.
- Prompt injection can't be fully prevented. Our controls limit the blast radius: approvals, narrow egress, and exclusivity.

---

## 10. Licensing

The model is open core:

- **The app** (iOS and Mac, everything in `Strata/`, `StrataMac/`, `Widgets/`) is **GPLv3**. Contributions require a
  **CLA** that grants us the right to relicense. That right is what lets us ship App Store builds, whose terms are often
  considered incompatible with the GPL for third-party copyright holders. Vendored code is compatible with GPLv3:
  libssh2 (BSD-3), OpenSSL 3 (Apache-2.0), Pyodide (MPL-2.0), MarkdownUI (MIT), Readability.js (Apache-2.0). We keep a
  check in `Strata/Resources/Licenses`.
- **The package side is MIT**:
  - `Packages/OpenChatPackageKit` (Swift: manifest, validation, signing, URL templates, response projection, canonical
    JSON)
  - the `openchat-pkg` CLI
  - the specification (this format, the host API, and the policy, audit and update protocols)
  - `@openchat/package-sdk` (TypeScript declarations and helpers)
  - the in-sandbox `Resources/PackageHost/host.html` and `bootstrap.js`
  - all example and built-in packages, including the migrated `naver-places` skill and `wikipedia_summary` plugin
- **Enterprise servers stay closed**: the admin console, the gateway, and package distribution and registry hosting.

### Where the boundary is, so that packages are not derivative works

1. **Interface, not linking.** A package is data plus JS that runs in a separate WebKit process. It talks to the app only
   through the documented **Package Interface**:
   - the manifest format and content types
   - the `openchat.*` host API, exposed as a message channel
   - the tool-call protocol (JSON arguments in, `{text, data, sources, view}` out)

   No app code is compiled into, linked with, or copied into a package.
2. **Everything a package touches is MIT.** Inside the sandbox, the package shares a JS realm only with `bootstrap.js`,
   which is MIT. Authors build against `@openchat/package-sdk`, which is MIT. Validation and signing are in
   `OpenChatPackageKit`, which is MIT and which the GPL app depends on (MIT into GPL is fine). We never move
   GPL-only code into anything a package author must include or run in the realm.
3. **Explicit exception.** The app's license notice adds a GPLv3 section 7 additional permission. Draft text for counsel:

   > Additional permission under GNU GPL version 3 section 7: A "Package" is a work that interacts with OpenChat only
   > through the OpenChat Package Interface as defined in the OpenChat Package Specification (the package format,
   > manifest schema, host API and tool-call protocol). Packages are separate works, not works based on OpenChat, and
   > you may create, use and distribute Packages under terms of your choice, including proprietary terms. This
   > permission does not apply to modifications of OpenChat itself.

   This lets companies keep internal packages closed. Downstream forks may drop the exception (section 7 allows that),
   but packages are still built only against MIT material, so they don't depend on it.
4. **Network protocols.** The app talks to the closed console and gateway only through protocols documented in the MIT
   spec (policy JSON, audit events, update manifests). These are separate programs communicating at arm's length.
5. **Model-authored packages** belong to the user like any other output of the program. The GPL doesn't cover program
   output.
6. **Spec stability.** The interface is versioned (`format`, `hostAPI`). A breaking change gets a new major version, so
   "interacts only through the Interface" stays well-defined over time.

Consistency in this design:

- The validation and signing code that the app and the CLI share lives in the MIT kit, not in `Strata/`. This is the
  `PluginCore.swift` approach, plain Foundation and compiled by `Tools/plugin-check`, made into a package.
- Host API types are defined in the spec, and Swift mirrors them.
- Built-in packages are plain package directories in `Strata/Resources/Packages/` with their own `LICENSE` (MIT).

---

## 11. Implementation plan

### MVP: packages with skills, prompts and HTTP tools (≈ 3–4 weeks for one engineer, ≈ 4.5k lines incl. tests)

Scope:

- Format v1: manifest, CHECKSUMS, SIGNATURE verification, unsigned and TOFU-key trust (no known-publisher list yet).
- Content: `prompt`, `skills`, `http` tools, `commands` (a simple `/` menu), `connections` (presets into
  `ConnectionSetupSheet`).
- Secrets in the Keychain, with scrub and redaction.
- Install via `openchat://add-package`, `.ocpkg` file import (Files, AirDrop, Mac drag), and the share extension route.
  Review sheet (without diff), update check with the same-key rule and re-consent, revert, uninstall.
- Per-chat enablement with snapshot freezing (R1–R7), composer switches, `apiNote` announcements.
- `ToolApprovals` (`SSHRequests` generalized, with SSH moved onto it), approval cards, Live Activity "Needs you",
  background notification.
- Package feed card. Local audit log (calls level), with a viewer in the package detail page.
- Fix the existing plugin-section cache leak by freezing it.
- On-device: package tools excluded, unless `onDevice` is set (supported in the MVP because it is small).

Files to add:

- `Packages/OpenChatPackageKit/` (Package.swift, `Manifest.swift`, `Validation.swift`, `JSONSchemaSubset.swift`,
  `CanonicalJSON.swift`, `URLTemplate.swift` (moved from `PluginCore`), `ResponseProjection.swift`, `Signature.swift`,
  `Render.swift` (prompt section and tool definition JSON), `LICENSE` (MIT)), wired in `project.yml` `packages:` as
  a local path package for both targets.
- `Strata/Packages/PackageStore.swift`, `PackageInstaller.swift`, `PackageLinks.swift`, `PackageSecrets.swift`,
  `PackageToolRouter.swift`, `HTTPToolRunner.swift`, `PackageSnapshot.swift`, `AuditLog.swift`.
- `Strata/Engine/ToolApprovals.swift`.
- `Strata/UI/PackagesView.swift`, `Strata/DesignSystem/PackageViews.swift` (review sheet, feed card, approval card,
  detail page).
- `Tools/openchat-pkg/` (Swift CLI on the kit: `validate`, `pack`, `sign`, `keygen`, `run <tool> --args` against a real
  network for authors).
- `Strata/Resources/Packages/` with the two built-in packages, as data only in the MVP. `run_plugin` and skills keep
  working as today.

Files to change:

- `Models/Conversation.swift`: `packageSnapshotData` and `pluginSectionSnapshot`, `pkg:` entries in the switch fields, and
  a `frozenPackages(current:)` helper.
- `Engine/ChatTools.swift`: `ToolSwitch` and the extended note.
- `Engine/ChatController.swift`: `apiHistory`, `requestTools`, `applyToolSwitches`, `offeredTools`, `setTool`, and
  `startTurn` (router).
- `Engine/TurnRunner.swift`: `toolList` with the package block, and `OfferedTools` refusals for packages.
- `Networking/ChatAPI.swift`: the `ToolDefinition` raw body. Also check `ResponsesAPI.swift` and
  `OpenCode/AnthropicMessages.swift` conversions.
- `Engine/ToolTypes.swift`: `primaryArgument`, `displayOnly`, `hasOwnCard`, `isSafeToRetry` for package tools.
- `Engine/ActivityFeed.swift`, `DesignSystem/ActivityFeedViews.swift`, `ProcessSegmentModel.swift`: the card and the title.
- `Tools/Skills.swift`: namespaced names, and package skills in a per-chat index.
- `SSH/SSHRequests.swift` → on top of `ToolApprovals`. `LiveActivity/ReplyLiveActivities.swift`,
  `ReplyActivityModel.swift`: the `.packageTool` approval.
- `Diagnostics/Redaction.swift`: the exact-value registry. `Diagnostics/DebugBundle.swift`: package ids and versions,
  without secrets.
- `UI/ConnectionSetup.swift`: route `add-package` and show package presets. `Share/ShareItemLoader.swift`,
  `ShareImport.swift`: the `.ocpkg` route.
- `OnDevice/OnDevicePromptBuilder.swift`: opt-in package tool specs.
- `DesignSystem/Composer.swift`: package switches and the `/` command menu.
- `project.yml`: the local package, UTType and document type declarations.
- `Info.plist`: `UTExportedTypeDeclarations`.

Tests (Swift Testing, as in `StrataTests/`):

- `PackageManifestTests`: every validation rule, error wording, reserved names, namespace collision and alias.
- `PackageSignatureTests`: valid, tampered file, extra or missing file, wrong key, rotation chain.
- `PackageInstallTests`: link parsing (http refused, `key`-style params ignored), sha mismatch, zip-slip, size caps,
  same-key update, re-consent on wider permissions, revert.
- `HTTPToolTests`: URL building and encoding (values can't change host or path), body templates (typed substitution),
  query defaults, redirect to an undeclared host blocked, private address blocked, response projection, sources,
  truncation, error mapping, secret injection and scrubbing (including base64 echo). Uses `TestGateway.swift` and
  `Tools/mock_server.py`.
- `PackageCacheTests`: R1 golden bytes for every `ToolGroup` combination with no packages, R2 order invariance, R3
  update and uninstall leave frozen bytes, R4 off-switch refusal and note, R6 schemaVersion refusal, plugin section frozen.
- `PackageApprovalTests`: `confirm` levels, trust raising `confirm`, cancel means deny, keyed per chat and call
  (extends `MultiChatTests`), Always persisted and revoked.
- `SkillTests` additions: namespaced names, per-chat index with package skills, unchanged personal skills.
- `OnDevicePromptBuilder` tests: package tools excluded, opt-in capped at 2.

### MVP as built (branch `packages`, 2026-10-22)

Built: the kit and `openchat-pkg` CLI (`validate`, `pack`, `sign`, `keygen`, `run`), `PackageStore`, `PackageInstaller`
(file, link, same-key rule, revert, remove), `PackageSnapshot` freezing, `HTTPToolRunner`, `PackageToolRouter`,
`PackageAudit`, `ToolApprovals` with `SSHRequests` as a facade, Settings › Packages (detail, secrets, activity viewer),
the review sheet, the feed line and approval card, Live Activity "Needs you", composer switches, the `/` list,
`openchat://add-package`, `.ocpkg` document type, the share route and on-device opt-in. Three built-in packages:
`app.openchat.wikipedia` (`wiki`, the `wikipedia_summary` plugin as a page tool), `app.openchat.korea` (`kr`, the
`naver-places` skill as `kr:naver-places`, the seed of a Korea pack) and `app.openchat.connections` (the OpenAI,
OpenRouter, Groq, Ollama and LM Studio presets as data; ChatGPT, OpenCode and Apple stay in code).

Where the build differs from the text above:

- **The snapshot is the source of truth.** A chat's frozen package tool definitions and prompt sections live in
  `Conversation.packageSnapshotData` (`@Attribute(.externalStorage)`, CloudKit-safe). `pkg:<id>` entries live only in
  `toolSwitchesRaw`/`announcedToolsRaw`, not in `offeredToolsRaw`. A new chat stores the marker `pkg:*`, meaning "take
  the default packages at the first send", so a chat created before the first send doesn't pin stale defaults. Chats
  that already had a frozen system prompt before packages existed get an empty snapshot (byte-identical requests, R1).
- **Skills.** Package skills are listed in their package's prompt section, not merged into the skill index;
  `load_skill`/`run_skill_script` are added to the chat's tools when a package with skills is on. Names are `ns:name`; a
  bare legacy name (`naver-places`) still resolves to a built-in package's skill when no personal skill has it.
- **Network entries** are an exact host or `*.suffix`.
- **Prompt section header** names the tools as a pattern: `Package "Acme Jira" (tools jira__*):`.
- **Presets** gained `subtitle` and `keyHelp` fields for the connection sheet.
- **`"onDevice": false`** is accepted explicitly; true opts in (at most two tools reach the on-device model).
- **Page tools** (`kind: "page"`, `page: {url, settle, waitFor}` plus `script`) exist in the MVP but only in built-in
  packages; installed packages with page tools are refused. Their hosts come from `permissions.network`. They run
  through `RunPluginTool`, so `run_plugin` and old chats are unchanged.
- **Defaults.** A package's `requires` groups gate whether it is on by default in a new chat, and turning a package on
  turns its groups on (turning a group off drops packages that need it). Built-in defaults: Wikipedia follows whether
  the user had the `wikipedia_summary` plugin enabled; the Korea pack is on when the locale region is KR, decided at
  the first send. Installed packages follow "On in new chats" (company trust on by default, others off).
- **Plugins replaced by a package** are left out of a chat's plugin section only when that chat has the package.
- **"Allow in this chat"** is kept in memory for the app session; "Always" is persisted and revocable in the detail page.
- **App Intents** chats get only default packages whose tools never ask for approval.
- **Audit** is at the `calls` level only (JSONL in Application Support/Audit, 30 days); `full` is not exposed.
- **`LSSupportsOpeningDocumentsInPlace`** stays true (the app copies `.ocpkg` files before review).

Left from the MVP list: silent update checks (`update.url`) and re-consent on them (manual reinstall with the same-key
rule and re-consent works), the revocation list, a developer folder with live reload, the "Try a tool" button (agent
drafts are phase 2), and a diff view in the review sheet (changed files are listed). The exact-value
redaction registry is wired (`PackageSecretStore` values and their encodings); `DebugBundle` doesn't list package ids
and versions yet.

### Phase 2: code and the agent (≈ 3–4 weeks, ≈ 4k lines)

- `PackageJSHost` (scheme handler, CSP, content rules, bridge, deadline teardown, per-call reload, slots), host API v1,
  the `@openchat/package-sdk` typings, and `openchat-pkg run` executing JS under a local JavaScriptCore shim for authors
  (Mac CLI only).
- Page tools. Migrate `wikipedia_summary` and `naver-places` into built-in packages, and route `run_plugin` for old chats.
- Agent authoring: `ToolGroup.authoring`, `save_package`, `test_package_tool`, `read_package`, `PackageApprovals`, the
  review sheet with the "Try a tool" button and diff view, and `PackageOffer` ("Save as tool").
- `view` results rendered in feed cards (locked `OpenUIBlockView`) and `openchat.ask` input cards.
- Known-publisher key list and signed revocation list.
- Tests: JS sandbox escape attempts (`fetch`, `XMLHttpRequest`, `import("https://…")`, `eval`, navigation, iframe), timeout
  teardown, memory kill, cross-chat state isolation, bridge message forgery, authoring restrictions.

### Phase 3: enterprise and directory (≈ 4–6 weeks app side, plus console work)

- `PolicyEngine`, MDM managed config and feedback, company keys, policy packages, connection blocking, the org prompt,
  DLP hooks, audit upload, the "This device is managed" screen.
- OAuth secrets (`ASWebAuthenticationSession`, PKCE).
- OpenUI templates as model-facing macros (an evaluator extension).
- `RunPackageCommandIntent` with `PackageCommandEntity`, a dynamic App Intents entity.
- Public directory, only with 4.7.1 reporting and moderation, a 4.7.4 index with universal links
  (`openchat.app/p/<id>`), and 4.7.5 age gating.
- Optional JS hooks at company trust.
- Console and gateway (closed): policy editor, HSM signing, registry, audit sink, MDM plist export.

---

## 12. Open questions for the product owner

1. **4.7 scope.** Is a package installed from a third-party link "offered in your app" in Apple's sense, which would bring
   in 4.7.1 reporting, 4.7.4 index and 4.7.5 age gating? Should we ask App Review before the MVP ships? I recommend
   asking, through the review notes or an App Review appointment, with the Wikipedia built-in as the demo.
2. **"Each instance" in 4.7.3.** If HealthKit or location ever flow to packages, do we accept a card on every call, or
   seek Apple's permission under 4.7.2? Until then, no `data` permissions.
3. **Default "On in new chats"** for user-installed signed packages: on (convenient) or off (every enabled package costs
   tokens in every chat)? The current proposal is off, except for company packages.
4. **Budgets.** Are 24 tools per package, 64 package tools per chat and a 4k-character prompt fragment the right limits
   for small local models? Should the composer show the per-package token cost?
5. **Namespace scheme.** Is `jira_search` (single underscore) fine, or do we want `jira__search` to make the package
   boundary unambiguous in logs?
6. **Gateway-published policy without MDM** (section 7.5, option 1): acceptable B2B onboarding, or too easy to
   socially engineer? It would be signed, and the user would confirm the key fingerprint once.
7. **Audit level `full`** stores results on the device and uploads them. Is that acceptable for B2B privacy promises,
   or do we cap it at `calls+args`?
8. **Directory economics**: whether there is a public directory at all, who moderates it, and whether known-publisher
   status is free.
9. **CLA tooling and the section 7 exception text** need counsel review before the first external contribution. Should the
   spec be MIT, or CC-BY-4.0 for the prose and MIT for the schemas and SDK?
10. **Python tools.** Should packages also ship Pyodide tools (`kind: "python"`) in phase 2? The runtime exists
    (`PythonRuntime`), but its per-chat interpreter and package downloads complicate isolation.
11. **App Intents.** Is a user-built "Run package command" shortcut worth phase 3, given that App Shortcuts can't be
    added at runtime?

### Decisions (2026-10-22)

The product owner took the recommended answer to each question above:

1. Ask App Review about 4.7 before the MVP ships, with the Wikipedia built-in as the demo.
2. No health or location data reaches packages in the MVP (no `data` permissions).
3. Only company packages are on in new chats by default; user-installed packages start off.
4. The budgets stay: 24 tools per package, 64 package tools per chat, a 4k-character prompt fragment.
5. Tool names use a double underscore: `jira__search`.
6. A signed, gateway-published policy without MDM is allowed; the user confirms the key fingerprint once.
7. Audit level `full` is only available through a company policy.
8. A public directory comes later, not in the MVP.
9. Counsel reviews the CLA and the exception text before the first external contribution.
10. Python package tools come in phase 2.
11. "Run package command" App Shortcuts come in phase 3.
