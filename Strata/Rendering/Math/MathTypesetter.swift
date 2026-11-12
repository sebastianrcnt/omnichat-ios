import CoreGraphics
import Foundation
@preconcurrency import MathJaxSwift
import SwiftDraw

/// What to typeset: one formula at one size.
struct MathRequest: Hashable, Sendable {
    var latex: String
    var display: Bool
    /// Font size of the surrounding text, in points.
    var pointSize: CGFloat
    /// Pixels per point of the screen it is drawn on.
    var scale: CGFloat

    init(latex: String, display: Bool, pointSize: CGFloat, scale: CGFloat) {
        self.latex = latex
        self.display = display
        // Whole steps, so sizes that differ by a rounding error share one image.
        self.pointSize = (pointSize * 4).rounded() / 4
        self.scale = max(1, scale.rounded())
    }
}

/// A typeset formula: black on clear (drawn as a template, so it takes the text colour), with its baseline.
struct MathImage: @unchecked Sendable {
    let image: CGImage
    let scale: CGFloat
    /// Size in points.
    let size: CGSize
    /// How far the image reaches below the text baseline, in points.
    let descent: CGFloat
}

/// LaTeX to image: MathJax (in JavaScriptCore, through MathJaxSwift) writes an SVG, SwiftDraw draws it.
///
/// An actor because the JavaScript context is not safe to share and a formula takes a few milliseconds (more on
/// iOS, where JavaScriptCore has no JIT): callers wait off the main thread. The engine (about 40 MB) is created on
/// the first formula and dropped again by `unload()`.
actor MathTypesetter {
    static let shared = MathTypesetter()

    /// MathJax draws at the text's em; its x-height is smaller than Pretendard's, so formulas are scaled to match.
    static let emScale: CGFloat = 1.12
    /// Clear pixels around the drawing, so antialiased edges are not cut.
    private static let padding = 1

    private var engine: MathJax?
    private var engineFailed = false

    /// Short names models use that MathJax does not define (they come from other LaTeX packages).
    private static let prelude = #"\def\R{\mathbb{R}}\def\N{\mathbb{N}}\def\Z{\mathbb{Z}}\def\Q{\mathbb{Q}}\def\C{\mathbb{C}}"#
        + #"\def\bm#1{\boldsymbol{#1}}\def\emph#1{\textit{#1}}\def\dd{\mathrm{d}}"#

    private let input: TeXInputProcessorOptions = {
        let p = TeXInputProcessorOptions.Packages.self
        return TeXInputProcessorOptions(
            loadPackages: [p.base, p.ams, p.boldsymbol, p.cancel, p.color, p.mhchem, p.newcommand, p.textmacros, p.mathtools,
                           p.gensymb, p.textcomp, p.unicode, p.cases, p.braket, p.upgreek, p.enclose, p.bbox, p.noundefined],
            // MathJaxSwift's default lost its backslashes ("." for "\."), which reads "=1}" as a number.
            digits: #"^(?:[0-9]+(?:\{,\}[0-9]{3})*(?:\.[0-9]*)?|\.[0-9]+)"#)
    }()

    /// Rewrites what the SVG path cannot draw: an equation number becomes text at the end of its row, and the
    /// commands that only manage numbering go.
    nonisolated static func prepared(_ latex: String) -> String {
        guard latex.contains("\\tag") || latex.contains("\\label") || latex.contains("\\nonumber") || latex.contains("\\notag") else { return latex }
        var s = latex
        s = s.replacingOccurrences(of: #"\\tag\*\{([^{}]*)\}"#, with: #"\\qquad\\text{$1}"#, options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\tag\{([^{}]*)\}"#, with: #"\\qquad\\text{($1)}"#, options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\label\{[^{}]*\}"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\(nonumber|notag)(?![A-Za-z])"#, with: "", options: .regularExpression)
        return s
    }

    func render(_ requests: [MathRequest]) -> [MathImage?] { requests.map(render) }

    func render(_ request: MathRequest) -> MathImage? {
        guard let svg = svg(request.latex, display: request.display) else { return nil }
        return Self.rasterize(svg, em: request.pointSize * Self.emScale, scale: request.scale)
    }

    /// Frees the JavaScript engine. The next formula creates it again.
    func unload() { engine = nil }

    private func svg(_ latex: String, display: Bool) -> String? {
        if engine == nil, !engineFailed {
            engine = try? MathJax(preferredOutputFormat: .svg)
            engineFailed = engine == nil
        }
        guard let engine else { return nil }
        let svg = try? engine.tex2svg(Self.prelude + Self.prepared(latex), styles: false,
                                      conversionOptions: ConversionOptions(display: display), inputOptions: input)
        // A formula MathJax could not read comes back as an error box.
        guard let svg, !svg.contains("data-mjx-error") else { return nil }
        return svg
    }

    /// Draws MathJax's SVG. Its view box is in thousandths of an em with the baseline at y = 0.
    nonisolated static func rasterize(_ svg: String, em: CGFloat, scale: CGFloat) -> MathImage? {
        guard let box = viewBox(svg), box.width > 0, box.height > 0, let parsed = SVG(xml: svg) else { return nil }
        let unit = em * scale / 1000
        let width = Int((box.width * unit).rounded(.up)), height = Int((box.height * unit).rounded(.up))
        // A formula this large is a mistake (or an attack on memory): leave it as text.
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { return nil }
        let pad = padding
        guard let context = CGContext(data: nil, width: width + 2 * pad, height: height + 2 * pad, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(height + 2 * pad))
        context.scaleBy(x: 1, y: -1)
        context.draw(parsed, in: CGRect(x: pad, y: pad, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        let below = (box.minY + box.height) * unit // below the baseline, in pixels
        return MathImage(image: image, scale: scale,
                         size: CGSize(width: CGFloat(width + 2 * pad) / scale, height: CGFloat(height + 2 * pad) / scale),
                         descent: (below + CGFloat(pad)) / scale)
    }

    nonisolated static func viewBox(_ svg: String) -> CGRect? {
        // Only the root element's: a nested <svg> (numbered equations) has its own.
        guard let tagEnd = svg.firstIndex(of: ">"),
              let r = svg[..<tagEnd].range(of: #"viewBox="[^"]*""#, options: .regularExpression) else { return nil }
        let v = svg[r].dropFirst(9).dropLast().split(separator: " ").compactMap { Double($0) }
        guard v.count == 4 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }
}
