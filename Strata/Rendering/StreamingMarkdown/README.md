# StreamingMarkdown

Renders Markdown that arrives token by token without re-parsing or re-laying-out the whole document on
every delta (which is O(n^2) over a reply).

## Pipeline

```
network delta -> RevealController (smoothing) -> IncrementalBlockParser (background) -> StreamingMarkdownModel (main) -> views
```

1. **RevealController** (`RevealController.swift`) decouples arrival from display. Received text queues
   as a backlog. A live answer is paced evenly (`RevealPacing`): it is shown at 0.85 x the measured incoming
   rate (last second of arrivals), but at least `backlog / 0.35 s`, so the display never trails by more than
   about 0.35 s; cuts fall on whole words and never split a grapheme cluster. Reasoning keeps the older step,
   `max(minStep, backlog * dt / targetLag)` per ~33 ms tick (`targetLag` = 200 ms). On stream end or stop
   everything is flushed at once. Settings has a "Smooth streaming" switch; off reveals everything that has
   arrived on each tick.
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
   monospaced text, unfinished tables as raw rows. The newly revealed span fades in over 0.45 s, easing out
   (one opacity ramp per recent span on the tail's text, not a view per token; off with Reduce Motion).

## Details

- **Optimistic closing** (`OptimisticCloser`): unmatched `**`, `*`, `` ` `` and `[` at the end of the
  open block are temporarily closed so raw markers do not flicker. Strikethrough is off: `~~` is never
  interpreted, and `TildeEscaper` keeps ranges like `2~3` and `~~x~~` literal.
- **CJK emphasis** (`CJKEmphasisFixer`): CommonMark rejects `**"강조"**는` because the closing run is
  preceded by punctuation and followed by a letter. A hair space (U+200A, Unicode whitespace) is
  inserted on the CJK side of such runs so every CommonMark parser accepts them.
- **Lenient emphasis** (`LenientEmphasis`): models often emit `**bold**` hugging quotes, brackets or
  CJK text in ways strict CommonMark rejects. `normalize` repairs the delimiter runs (zero-width
  separators, stripped again after parsing) so bold and italic render, for streaming and finished text
  alike. `MarkdownPlain.text` produces the plain-text copy (Copy raw Markdown keeps the source).
- **Citations and chips** (`CitationParser`, `ChipText`): `[1][2]` markers become `strata-cite:` links
  that render as capsule chips with the short domain ("apple.com +2"). The chip text uses non-breaking
  characters (figure-space padding, U+2011 hyphen, NBSP before "+N") so a chip never wraps or splits
  from its padding; `ChipTextRenderer` (a `TextRenderer`) draws the capsule behind runs tagged with
  `ChipTextAttribute`, and `InlineMarkdownText.composed` builds one concatenated `Text`, so chips are
  baseline-aligned with the surrounding words. Markers whose ids are not known sources are hidden.
- **Partial-marker hold-back**: while a block is open, an unfinished citation marker at the end (for
  example `[`, `[1` or the start of a second marker after `[1]`) is dropped from the rendered text
  (`holdBack: true`) instead of flashing as raw brackets; the chip appears once the marker is complete.
  Finished text never holds anything back.
- **Inline renderer** (`InlineMarkdownText.attributed`): `TildeEscaper` -> `CitationParser` ->
  `CJKEmphasisFixer` -> `OptimisticCloser` (open blocks only) -> `LenientEmphasis.normalize` ->
  `AttributedString(markdown:)` (inline only) -> `stripZeroWidth`. Paragraphs, headings, quotes and
  list items use it, and so do the cells of a closed top-level table (`MarkdownTable` splits the rows,
  `MarkdownTableView` lays them out in a `Grid`: header band, natural-width columns that wrap at a cap,
  horizontal scrolling, compact chips via `TableCellText`). Other complex finished blocks (a table nested
  in a list or quote) fall back to MarkdownUI (`markdownUIText`), which loses chips but keeps everything else.
- **Code blocks** (`DesignSystem/CodeBlocks.swift`): an open fence streams into a fixed-height,
  bottom-following plain monospaced box; the finished block has a header (language, Copy), collapses
  past 18 lines, and opens a full-screen viewer. No syntax highlighting.
- **Reasoning** (`ReasoningChunkModel`): the raw chain is split by paragraph; finalized paragraphs are
  cached equatable views, only the tail paragraph changes. Same reveal controller and the same ~150 ms
  fade on the newly revealed span (`freshSpans`, off with Reduce Motion). `thought` (the sentence being written, from `ThoughtSentences.latest`) drives the live
  one-line preview: tail-truncated, replaced only when a new sentence begins and at most every 1.2 s
  (`ThoughtPreviewGate`, clock-free), crossfaded. The Timeline sheet renders finalized chunks plus a separate tail view and
  follows the bottom only while the user is at the bottom.
- **Performance check**: `StrataTests/StreamingPerfTests` replays a markdown answer at 100 tok/s into a
  `UIHostingController` and logs apply, layout and run-loop-turn p95 (10k tokens on the Simulator:
  apply p95 0.02 ms, layout p95 5 ms, turn p95 7.8 ms).
- Not done: syntax highlighting (code blocks are plain monospaced), nested block parsing in the tail, a
  sticky code header (a second Copy sits at the bottom of long blocks).
