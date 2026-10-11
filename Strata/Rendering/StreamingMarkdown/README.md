# StreamingMarkdown

Renders Markdown that arrives token by token without re-parsing or re-laying-out the whole document on
every delta (which is O(n^2) over a reply).

## Pipeline

```
network delta -> RevealController (smoothing) -> IncrementalBlockParser (background) -> StreamingMarkdownModel (main) -> views
```

1. **RevealController** (`RevealController.swift`) decouples arrival from display. Received text queues
   as a backlog; each ~33 ms tick reveals `max(minStep, backlog * dt / targetLag)` characters
   (`targetLag` = 200 ms). Cuts prefer word boundaries and never split a grapheme cluster. On stream end,
   stop, or when the user scrolls away, everything is flushed at once. Settings has a "Smooth streaming"
   switch; off reveals everything that has arrived on each tick.
2. **BlockScanner** is a cheap line-based splitter into top-level blocks (paragraph, heading, list,
   blockquote, fenced/indented code, table, thematic break). It does not build an AST. It was written
   instead of using apple/swift-markdown because that package pulls in a second cmark-gfm that clashes
   with the one MarkdownUI links, and block boundaries are all we need.
3. **IncrementalBlockParser** keeps `finalized` blocks (immutable, id = index) and a `tail` of the last
   two blocks, which stay mutable (setext headings, lazy continuation, list tightness). Each `append`
   re-scans only the tail text. `finish()` does one full parse to reconcile; tests assert it equals a
   one-shot parse and that finalized ids/text never change while streaming.
4. **StreamingMarkdownModel** (`@Observable`, main actor) coalesces deltas, runs the parser on a
   background task in order, and publishes `finalized` (append-only) and `tail` separately. Finalized and
   tail are read by different views, so tail updates never invalidate finalized blocks. `OSSignposter`
   intervals ("apply") wrap each publish.
5. **Views** (`StreamingMarkdownViews.swift`): finalized blocks and closed tail blocks render with
   MarkdownUI through an `Equatable` `MarkdownBlockView`, so unchanged blocks are never re-evaluated. The
   one open (last) block uses a cheap path: inline Markdown into `AttributedString`, open fences as plain
   monospaced text, unfinished tables as raw rows. The newly revealed span fades in over ~150 ms (tail
   only, off with Reduce Motion).

## Details

- **Optimistic closing** (`OptimisticCloser`): unmatched `**`, `*`, `~~`, `` ` `` and `[` at the end of the
  open block are temporarily closed so raw markers do not flicker.
- **CJK emphasis** (`CJKEmphasisFixer`): CommonMark rejects `**"강조"**는` because the closing run is
  preceded by punctuation and followed by a letter. A hair space (U+200A, Unicode whitespace) is
  inserted on the CJK side of such runs so every CommonMark parser accepts them.
- **Reasoning** (`ReasoningChunkModel`): the raw chain is split by paragraph; finalized paragraphs are
  cached equatable views, only the tail paragraph changes. Same reveal controller, plain text, no fade.
- Not done: syntax highlighting (code blocks are plain monospaced), nested block parsing in the tail.
