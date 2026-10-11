import Foundation

/// A top-level Markdown block, as split by `BlockScanner`.
struct MarkdownBlock: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case paragraph
        case heading(level: Int)
        case list
        case blockquote
        case code
        case table
        case thematicBreak
    }

    /// Position in the document. Stable for finalized blocks.
    var id: Int
    var kind: Kind
    /// Raw source of the block (no trailing blank lines).
    var text: String
    /// False while the block may still grow at its end (open fence, table not yet followed by anything).
    var isClosed: Bool
    /// `text` with the CJK emphasis fix applied, ready to hand to a Markdown renderer.
    var renderText: String
}
