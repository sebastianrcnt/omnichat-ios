import Foundation

/// What changed after feeding more text.
struct BlockUpdate: Equatable, Sendable {
    /// Blocks that were just promoted to finalized (immutable from now on).
    var newlyFinalized: [MarkdownBlock]
    /// The current mutable tail (at most `tailWindow` blocks).
    var tail: [MarkdownBlock]
}

/// Incremental top-level block parser for streamed Markdown.
///
/// Only the open tail is re-scanned on each `append`. Blocks before the last `tailWindow` blocks are
/// finalized: they never change again, so their ids and contents are stable.
struct IncrementalBlockParser: Sendable {
    /// Number of trailing blocks that stay mutable (setext headings, lazy continuation, list tightness).
    static let tailWindow = 2

    private(set) var finalized: [MarkdownBlock] = []
    private(set) var tail: [MarkdownBlock] = []
    /// Raw text from the start of the first tail block.
    private var tailText = ""
    private(set) var raw = ""

    init() {}

    var blocks: [MarkdownBlock] { finalized + tail }

    /// One-shot parse of a complete document.
    static func parse(_ text: String) -> [MarkdownBlock] {
        build(text: text, idOffset: 0)
    }

    private static func build(text: String, idOffset: Int) -> [MarkdownBlock] {
        let lines = BlockScanner.lines(of: text)
        return BlockScanner.scan(lines: lines).enumerated().map { index, s in
            let body = lines[s.startLine...s.endLine].joined(separator: "\n")
            let render = s.kind == .code ? body : CJKEmphasisFixer.fix(body)
            return MarkdownBlock(id: idOffset + index, kind: s.kind, text: body, isClosed: s.isClosed, renderText: render)
        }
    }

    mutating func append(_ delta: String) -> BlockUpdate {
        raw += delta
        tailText += delta
        let lines = BlockScanner.lines(of: tailText)
        let scanned = BlockScanner.scan(lines: lines)
        let promote = max(0, scanned.count - Self.tailWindow)
        var promoted: [MarkdownBlock] = []
        if promote > 0 {
            let all = Self.build(text: tailText, idOffset: finalized.count)
            promoted = Array(all[..<promote])
            finalized.append(contentsOf: promoted)
            tail = Array(all[promote...])
            let cut = scanned[promote].startLine
            tailText = lines[cut...].joined(separator: "\n")
        } else {
            tail = Self.build(text: tailText, idOffset: finalized.count)
        }
        return BlockUpdate(newlyFinalized: promoted, tail: tail)
    }

    /// Final reconciliation: one full parse of everything received. All blocks become finalized.
    mutating func finish() -> [MarkdownBlock] {
        let all = Self.parse(raw)
        finalized = all
        tail = []
        tailText = ""
        return all
    }

    /// Replace the whole document (used for finished messages).
    mutating func reset(text: String = "") {
        self = IncrementalBlockParser()
        if !text.isEmpty { _ = append(text); _ = finish() }
    }
}
