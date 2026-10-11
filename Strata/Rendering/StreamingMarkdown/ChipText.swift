import SwiftUI

/// Shortens a host for chip labels: no `www.`, the registrable domain (`wikipedia.org`), and a middle
/// ellipsis if it is still long.
enum DomainFormatter {
    /// Second-level public suffixes that need three labels (`bbc.co.uk`, `naver.co.kr`).
    private static let secondLevel: Set<String> = ["co", "com", "ne", "or", "go", "ac", "org", "net", "gov", "edu"]

    static func short(_ host: String, maxLength: Int = 22) -> String {
        var h = host.lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        let labels = h.split(separator: ".").map(String.init)
        var registrable = h
        if labels.count > 2 {
            let tld = labels[labels.count - 1], sld = labels[labels.count - 2]
            let keep = (tld.count == 2 && secondLevel.contains(sld)) ? 3 : 2
            registrable = labels.suffix(keep).joined(separator: ".")
        }
        guard registrable.count > maxLength else { return registrable }
        let head = (maxLength - 1) / 2 + 1, tail = maxLength - 1 - head
        return String(registrable.prefix(head)) + "…" + String(registrable.suffix(tail))
    }
}

/// Marks the runs of a `Text` that should be drawn as a capsule chip.
struct ChipTextAttribute: TextAttribute {}

/// Draws a capsule behind every run tagged with `ChipTextAttribute`, then the text on top.
struct ChipTextRenderer: TextRenderer {
    var fill: Color
    var height: CGFloat = 20

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                if run[ChipTextAttribute.self] != nil {
                    let b = run.typographicBounds.rect
                    let rect = CGRect(x: b.minX, y: b.midY - height / 2, width: b.width, height: height)
                    context.fill(Capsule().path(in: rect), with: .color(fill))
                }
                context.draw(run)
            }
        }
    }
}

extension InlineMarkdownText {
    /// Builds a `Text` from the attributed string. Citation chips become tagged runs so `ChipTextRenderer`
    /// can draw capsules behind them; text without chips takes the plain path.
    static func composed(_ attributed: AttributedString) -> (text: Text, hasChips: Bool) {
        var pieces: [(range: Range<AttributedString.Index>, chip: Bool)] = []
        for run in attributed.runs {
            let chip = run.link?.scheme == CitationParser.scheme
            if let last = pieces.last, last.chip == chip {
                pieces[pieces.count - 1].range = last.range.lowerBound..<run.range.upperBound
            } else {
                pieces.append((run.range, chip))
            }
        }
        guard pieces.contains(where: \.chip) else { return (Text(attributed), false) }
        var text = Text("")
        for piece in pieces {
            let t = Text(AttributedString(attributed[piece.range]))
            let part = piece.chip ? t.customAttribute(ChipTextAttribute()) : t
            text = Text("\(text)\(part)")
        }
        return (text, true)
    }
}
