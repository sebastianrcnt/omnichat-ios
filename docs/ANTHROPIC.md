# Anthropic connection

A connection of kind `anthropic` talks to the Anthropic Messages API (`POST {baseURL}/messages`, default
`https://api.anthropic.com/v1`) with the user's API key in `x-api-key` and `anthropic-version: 2023-06-01`. The key
lives in the Keychain like every other connection's and goes nowhere but that header.

## Design

- The engine keeps speaking Chat Completions. `Anthropic/AnthropicMessages.swift` translates the `ChatRequest` into a
  Messages body and the SSE events back into `ChatDelta`s. The same file serves the OpenCode gateways' Claude models
  (`OpenCodeClient`). Their requests stay byte for byte what they were: no cache markers, no `thinking`. Only an
  Anthropic connection passes `MessagesRequest.Options`.
- `Anthropic/AnthropicClient.swift` sends the request, maps errors (`AnthropicErrorMapper`) and retries some 400s once
  each: refused thinking signatures (sent again with all thinking blocks left out, the API's documented recovery), a
  refused `thinking` configuration, a refused `effort`.
- `Anthropic/AnthropicModels.swift` reads `GET /v1/models` page by page (`limit=1000`, `after_id`). `display_name`,
  `max_input_tokens`, `max_tokens` and `capabilities` (image input, thinking types, effort levels) fill `ModelInfo`
  and `ModelInfo.anthropic`. A model the list doesn't describe (a proxy that leaves capabilities out, a model added by
  hand) gets what its id's family says (`AnthropicModels.family`). Aliases, hidden models and hand-added models are
  kept across fetches.
- `max_tokens` is required: the request's own cap (titles, compaction), else the model's `max_tokens` from the list,
  else its family's, else `MessagesRequest.defaultMaxTokens`.
- Not resumable: `supportsResumable` is always false, and the editor hides the recovery and "New models" settings.
- Older app versions can't decode the kind. They skip the connection in their list and in sync, and never delete it
  from iCloud (covered by `AnthropicSyncTests`).

## Prompt caching

At most 4 `cache_control: {type: "ephemeral"}` breakpoints (`MessagesRequest.placeBreakpoints`):

1. the last tool definition (the tool list is the same on every request of a chat),
2. the system prompt, sent as one text block,
3. the newest message (written so the next request can read it),
4. the message the previous request ended with (`messages[count - 3]`: a tool round or a new turn adds exactly an
   assistant message and a user message). The lookback only covers 20 blocks, and one tool round with parallel calls
   can add more, so the next request needs a breakpoint exactly where the previous one wrote.

Thinking blocks can't carry a marker, so it goes on the last block that can. A hit needs the requests to be identical
up to the breakpoint. `AnthropicRequestTests.consecutiveRequestsShareTheCachedPrefix` checks this for a tool round
and for the next turn: tools, then system, then messages, canonical JSON without the markers. Things that drop the
cached messages and are avoided on purpose:

- **Changing `tool_choice`.** The title follow-up keeps it as is on Anthropic (`AutoRename.followUp(forbidTools:)`).
  A tool call instead of a title is an empty reply, and the standalone title request takes over. A capped last tool
  round and compaction still send `none`, which costs one cache write each.
- **Leaving out earlier thinking.** See below.

Usage: `promptTokens = input_tokens + cache_read + cache_creation`, `cachedTokens = cache_read`,
`cacheWriteTokens = cache_creation`. It goes through `conversation.apply(_:)` (new optional
`Conversation.lastCacheWriteTokens`) and the diagnostics screens ("Written to cache", "written").

## Thinking and signatures

- Thinking arrives as `thinking` blocks (text, then `signature_delta`) or `redacted_thinking` blocks. Each block
  becomes a `ReasoningItem`: the text as its summary, the signature as `encryptedContent`, or `"redacted:" + data`.
  The text also streams into the reasoning UI.
- Within a turn they ride on the assistant tool-call message (`APIMessage.reasoningItems`), as Responses API reasoning
  items do, and go back verbatim before the text and the `tool_use` blocks.
- Across turns: the newer models keep earlier turns' thinking in context, and a request that leaves it out no longer
  matches the cached one. So each tool step of an Anthropic answer keeps its blocks (`ToolStep.thinking`,
  `StepThinking`, tagged with the model id), and `MessageAssembler.apiMessages(thinkingModel:)` sends them back for
  that model only. Another model, or another API, gets the messages it always had. The final answer's own thinking
  is not stored: it is consistently missing, so no signature ever depended on it.
- If the API still refuses the blocks (an edited or compacted history, an account with preserved-thinking checks),
  the request is sent once more with every thinking block left out.

## Effort mapping

`AnthropicModels.controls(for:requested:maxTokens:)`. The chat's level is first resolved to one the model offers
(`Effort.resolved`).

| Model | `thinking` | `output_config.effort` |
| --- | --- | --- |
| Adaptive (4.6 and later; listed `thinking.types.adaptive`) | `{type: adaptive, display: summarized}` | the level, from the model's listed levels (4.6: low to max without xhigh) |
| Budget (3.7, 4.0, 4.1, 4.5) | `{type: enabled, budget_tokens}`: low 1,024, medium 4,096, high 8,192, xhigh 16,384, max 32,000, clamped to `max_tokens - 1`; left out when `max_tokens` ≤ 1,024 | Opus 4.5 only (low, medium, high) |
| No thinking (Claude 3.5 and older) | — | — |

`display: summarized` because the newest models omit thinking text by default, and the reasoning UI needs text. A
title request (`reasoning_effort: "none"`) sends no `thinking` at the model's lowest level. Effort turned off for a
model sends neither field, which leaves the model's default.

OpenCode's Claude models use the same `Effort.resolved` against the levels models.dev lists. They get no `thinking`
configuration and no cache markers, as before.

## Not supported

- Server tools (web search, code execution), the Files API, citations, PDFs/documents, batches, `count_tokens`.
- Forced `tool_choice` (`any`/`tool`). The app only sends `auto` and `none`.
- The 1-hour cache TTL, and beta headers (interleaved thinking on 4.0/4.1/4.5, context management, compaction betas).
- Resuming a dropped stream. A drop is an error the user retries.
- Bedrock / Vertex / Foundry auth. A proxy that speaks the same API at another base URL works.

## Needs a real key to verify

The unit tests stub the network. Not yet checked against the live API: cache hits on real requests
(`cache_read_input_tokens` on the second request), the signature-refusal message text the retry looks for, whether
`display: summarized` is accepted on every adaptive model, and thinking order when one answer interleaves text and
thinking (blocks are sent back thinking first).
