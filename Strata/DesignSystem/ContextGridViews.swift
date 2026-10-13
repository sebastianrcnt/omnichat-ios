import SwiftUI

// The Context sheet's pieces (reference/mockups/context-grid.html): the animated cell grid, the counting total, the
// zoom bar and the legend rows. The numbers come from `ContextGrid` and `ContextEstimator`.

/// The 20 × 10 grid. Filled cells take their category's color, free cells a dim fill; cells from the summarize point on
/// carry a thin warning outline. It pops in on appear (filled cells one after another, then free cells in a row-wise
/// wave), refills with the same wave when `range` changes, and pulses cells that fill while it is shown. With Reduce
/// Motion it only fades.
struct ContextGridCanvas: View {
    @Environment(\.theme) private var theme
    @Environment(\.self) private var environment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The category (`ContextCategory.rawValue`) of each filled cell, in order.
    let owners: [Int]
    /// The tokens the grid spans; a change refills it.
    let range: Int
    let summarizeCell: Int?
    /// The highlighted category: the other cells dim.
    let focus: Int?

    @State private var motion = ContextGridMotion()
    @State private var running = false
    @State private var width: CGFloat = 0

    static let gap: CGFloat = 3
    static let radius: CGFloat = 3

    static func cellSize(width: CGFloat) -> CGFloat {
        max(0, (width - gap * CGFloat(ContextGrid.columns - 1)) / CGFloat(ContextGrid.columns))
    }

    static func height(width: CGFloat) -> CGFloat {
        cellSize(width: width) * CGFloat(ContextGrid.rows) + gap * CGFloat(ContextGrid.rows - 1)
    }

    private struct Layout: Equatable { var owners: [Int]; var range: Int }

    var body: some View {
        let palette = ContextCategory.allCases.map { theme.contextCategory($0).resolve(in: environment) }
        let free = theme.contextFree.resolve(in: environment)
        let warn = theme.warning.opacity(0.55)
        let motion = motion
        let summarizeCell = summarizeCell
        TimelineView(.animation(minimumInterval: nil, paused: !running)) { timeline in
            Canvas { context, size in
                let now = timeline.date
                let cell = Self.cellSize(width: size.width)
                for i in 0..<ContextGrid.cells {
                    let look = motion.look(of: i, at: now, palette: palette, free: free)
                    guard look.opacity > 0.001 else { continue }
                    let col = i % ContextGrid.columns, row = i / ContextGrid.columns
                    let x = CGFloat(col) * (cell + Self.gap), y = CGFloat(row) * (cell + Self.gap)
                    let side = cell * look.scale
                    let rect = CGRect(x: x + (cell - side) / 2, y: y + (cell - side) / 2, width: side, height: side)
                    let shape = Path(roundedRect: rect, cornerRadius: Self.radius * look.scale)
                    var layer = context
                    layer.opacity = look.opacity
                    layer.fill(shape, with: .color(Color(look.color)))
                    if let summarizeCell, i >= summarizeCell {
                        let inset = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: max(0, Self.radius * look.scale - 0.5))
                        layer.stroke(inset, with: .color(warn), lineWidth: 1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height(width: width))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear {
            self.motion.open(owners: owners, range: range, now: .now, reduceMotion: reduceMotion)
        }
        .onChange(of: Layout(owners: owners, range: range)) { old, new in
            if new.range != old.range {
                self.motion.rescale(owners: new.owners, range: new.range, now: .now, reduceMotion: reduceMotion)
            } else {
                self.motion.update(owners: new.owners, now: .now, reduceMotion: reduceMotion)
            }
        }
        .onChange(of: focus) { _, f in self.motion.setFocus(f, now: .now) }
        .task(id: motion.endsAt) {
            // The timeline runs only while something moves.
            let left = motion.endsAt.timeIntervalSinceNow
            guard left > 0 else { running = false; return }
            running = true
            try? await Task.sleep(for: .seconds(left + 0.05))
            if !Task.isCancelled { running = false }
        }
        .accessibilityHidden(true)
    }
}

/// Per-cell animation state for `ContextGridCanvas`, evaluated at any time (no per-frame bookkeeping). Timings follow the
/// mockup's CSS: a 0.42 s overshooting pop from scale 0.2, a 0.3 s fade, a 0.35 s color change, a 0.25 s dim and a
/// 0.9 s pulse from scale 1.5 and brightness 1.8.
struct ContextGridMotion {
    struct Cell {
        var owner: Int?
        /// The color the cell changes from, starting at `colorAt`.
        var from: Int?
        var colorAt = Date.distantPast
        /// When the cell starts to shrink away (a refill); `.distantPast` means hidden until `appearAt`.
        var hideAt: Date?
        var appearAt = Date.distantPast
        /// Scale and opacity at `appearAt`, where the pop starts from.
        var popScale = 1.0
        var popOpacity = 1.0
        var pulseAt: Date?
    }

    struct Look {
        var scale: Double
        var opacity: Double
        var color: Color.Resolved
    }

    var cells = Array(repeating: Cell(), count: ContextGrid.cells)
    var reduced = false
    var focusFrom: Int?
    var focusTo: Int?
    var focusAt = Date.distantPast
    var endsAt = Date.distantPast

    static let popDuration = 0.42
    static let fadeDuration = 0.3
    static let colorDuration = 0.35
    static let dimDuration = 0.25
    static let pulseDuration = 0.9
    static let minScale = 0.2
    /// The pop's overshoot: CSS cubic-bezier(.2, 1.4, .4, 1).
    static let pop = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.2, y: 1.4), endControlPoint: UnitPoint(x: 0.4, y: 1))
    /// CSS `ease`.
    static let ease = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.25, y: 0.1), endControlPoint: UnitPoint(x: 0.25, y: 1))
    static let easeOut = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0, y: 0), endControlPoint: UnitPoint(x: 0.58, y: 1))

    /// The wave: filled cells one after another, free cells after them row by row.
    static func delay(_ i: Int, filled: Bool) -> Double {
        filled ? Double(i) * 0.004 : 0.28 + Double(i % ContextGrid.columns) * 0.006 + Double(i / ContextGrid.columns) * 0.010
    }

    private static func progress(_ t: Date, from start: Date, over duration: Double) -> Double {
        min(1, max(0, t.timeIntervalSince(start) / duration))
    }

    mutating func open(owners: [Int], range: Int, now: Date, reduceMotion: Bool) {
        reduced = reduceMotion
        for i in cells.indices {
            let owner = i < owners.count ? owners[i] : nil
            cells[i] = Cell(owner: owner, from: owner, hideAt: .distantPast,
                            appearAt: reduced ? now : now + Self.delay(i, filled: owner != nil),
                            popScale: reduced ? 1 : Self.minScale, popOpacity: 0)
        }
        refreshEnd()
    }

    mutating func rescale(owners: [Int], range: Int, now: Date, reduceMotion: Bool) {
        reduced = reduceMotion
        for i in cells.indices {
            let owner = i < owners.count ? owners[i] : nil
            var c = cells[i]
            if reduced {
                if c.owner != owner { c.from = c.owner; c.colorAt = now }
                c.owner = owner
            } else {
                let appear = now + Self.delay(i, filled: owner != nil) + 0.12
                var hiding = c
                hiding.hideAt = now
                hiding.appearAt = .distantFuture
                let (scale, opacity) = hiding.scaleAndOpacity(at: appear)
                c.from = c.owner
                c.owner = owner
                c.colorAt = appear
                c.hideAt = now
                c.appearAt = appear
                c.popScale = scale
                c.popOpacity = opacity
                c.pulseAt = nil
            }
            cells[i] = c
        }
        refreshEnd()
    }

    mutating func update(owners: [Int], now: Date, reduceMotion: Bool) {
        reduced = reduceMotion
        let filledBefore = cells.prefix { $0.owner != nil }.count
        for i in cells.indices {
            let owner = i < owners.count ? owners[i] : nil
            guard cells[i].owner != owner else { continue }
            cells[i].from = cells[i].owner
            cells[i].colorAt = now
            cells[i].owner = owner
            if !reduced, owner != nil, i >= filledBefore { cells[i].pulseAt = now }
        }
        refreshEnd()
    }

    mutating func setFocus(_ focus: Int?, now: Date) {
        focusFrom = focusTo
        focusTo = focus
        focusAt = now
        refreshEnd()
    }

    private mutating func refreshEnd() {
        var end = focusAt + Self.dimDuration
        for c in cells {
            if c.appearAt != .distantFuture { end = max(end, c.appearAt + Self.popDuration) }
            end = max(end, c.colorAt + Self.colorDuration)
            if let p = c.pulseAt { end = max(end, p + Self.pulseDuration) }
        }
        endsAt = end
    }

    func look(of i: Int, at t: Date, palette: [Color.Resolved], free: Color.Resolved) -> Look {
        let c = cells[i]
        func color(_ owner: Int?) -> Color.Resolved { owner.map { palette[$0] } ?? free }
        var (scale, opacity) = reduced ? c.fadeOnly(at: t) : c.scaleAndOpacity(at: t)
        var rgb = color(c.owner).mixed(from: color(c.from), Self.ease.value(at: Self.progress(t, from: c.colorAt, over: Self.colorDuration)))
        // Dimmed when another category is highlighted (free cells too).
        func dim(_ f: Int?) -> Double { f != nil && c.owner != f ? 1 : 0 }
        let d = dim(focusFrom) + (dim(focusTo) - dim(focusFrom)) * Self.ease.value(at: Self.progress(t, from: focusAt, over: Self.dimDuration))
        if d > 0 { rgb = rgb.filtered(saturation: 1 - 0.8 * d, brightness: 1 - 0.55 * d) }
        if !reduced, let p = c.pulseAt, t >= p, t < p + Self.pulseDuration {
            let k = Self.easeOut.value(at: Self.progress(t, from: p, over: Self.pulseDuration))
            scale *= 1.5 - 0.5 * k
            rgb = rgb.filtered(saturation: 1, brightness: 1.8 - 0.8 * k)
        }
        opacity = min(1, max(0, opacity))
        return Look(scale: max(0, scale), opacity: opacity, color: rgb)
    }
}

private extension ContextGridMotion.Cell {
    func scaleAndOpacity(at t: Date) -> (Double, Double) {
        typealias M = ContextGridMotion
        if t < appearAt {
            guard let hideAt else { return (1, 1) }
            if hideAt == .distantPast { return (M.minScale, 0) }
            let s = M.pop.value(at: min(1, max(0, t.timeIntervalSince(hideAt) / M.popDuration)))
            let o = M.ease.value(at: min(1, max(0, t.timeIntervalSince(hideAt) / M.fadeDuration)))
            return (1 + (M.minScale - 1) * s, 1 - o)
        }
        let s = M.pop.value(at: min(1, t.timeIntervalSince(appearAt) / M.popDuration))
        let o = M.ease.value(at: min(1, t.timeIntervalSince(appearAt) / M.fadeDuration))
        return (popScale + (1 - popScale) * s, popOpacity + (1 - popOpacity) * o)
    }

    func fadeOnly(at t: Date) -> (Double, Double) {
        typealias M = ContextGridMotion
        if t < appearAt { return (1, hideAt == nil ? 1 : 0) }
        let o = min(1, t.timeIntervalSince(appearAt) / M.fadeDuration)
        return (1, popOpacity + (1 - popOpacity) * o)
    }
}

private extension Color.Resolved {
    /// From `other` (t = 0) to self (t = 1).
    func mixed(from other: Color.Resolved, _ t: Double) -> Color.Resolved {
        guard t < 1 else { return self }
        let f = Float(t)
        return Color.Resolved(colorSpace: .sRGB, red: other.red + (red - other.red) * f,
                              green: other.green + (green - other.green) * f, blue: other.blue + (blue - other.blue) * f,
                              opacity: other.opacity + (opacity - other.opacity) * f)
    }

    /// CSS-like `saturate()` and `brightness()`.
    func filtered(saturation: Double, brightness: Double) -> Color.Resolved {
        let s = Float(saturation), b = Float(brightness)
        let l = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        func f(_ c: Float) -> Float { min(1, max(0, (l + (c - l) * s) * b)) }
        return Color.Resolved(colorSpace: .sRGB, red: f(red), green: f(green), blue: f(blue), opacity: opacity)
    }
}

/// A token count that counts to its value when it changes (wrap the change in an animation).
struct CountingTokens: View, Animatable {
    nonisolated var value: Double
    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View { Text(verbatim: TokenFormat.short(Int(value.rounded()))) }
}

/// The window as a thin bar: the zoomed range faint, what is used solid.
struct ContextZoomBar: View {
    @Environment(\.theme) private var theme
    let range: Int
    let used: Int
    let window: Int

    var body: some View {
        let w = Double(max(window, 1))
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.contextFree)
                Capsule().fill(theme.textPrimary.opacity(0.12))
                    .frame(width: geo.size.width * min(1, Double(range) / w))
                Capsule().fill(theme.textSecondary)
                    .frame(width: geo.size.width * min(1, max(0.008, Double(used) / w)))
            }
        }
        .frame(height: DS.Spacing.xs)
        .clipShape(Capsule())
        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.6), value: range)
        .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.6), value: used)
    }
}

/// A legend row: swatch, name, tokens, share of the window. Tapping highlights the category.
struct ContextLegendRow: View {
    @Environment(\.theme) private var theme
    let color: Color
    let title: String
    let tokens: Int
    let window: Int
    /// Replaces the token count (an empty window reads "256k", like the total).
    var tokensText: String?
    var isSelected = false
    var isDimmed = false
    var action: (() -> Void)?

    var body: some View {
        let row = HStack(spacing: DS.Spacing.md) {
            RoundedRectangle(cornerRadius: ContextGridCanvas.radius).fill(color)
                .frame(width: DS.Spacing.md - 2, height: DS.Spacing.md - 2)
            Text(verbatim: title).font(DS.Typography.uiSmall).foregroundStyle(theme.textPrimary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: tokensText ?? TokenFormat.short(tokens)).font(DS.Typography.feed).foregroundStyle(theme.textSecondary)
                .monospacedDigit()
            Text(verbatim: Self.percent(tokens, of: window)).font(DS.Typography.feedMeta).foregroundStyle(theme.textTertiary)
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, DS.Spacing.xs)
        .background(isSelected ? theme.surface : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.cardRow))
        .opacity(isDimmed ? 0.45 : 1)
        .contentShape(Rectangle())
        if let action {
            Button(action: action) { row }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            row
        }
    }

    static func percent(_ n: Int, of window: Int) -> String {
        guard window > 0 else { return "0%" }
        return (Double(n) / Double(window)).formatted(.percent.precision(.fractionLength(1)))
    }
}

#Preview("Dark · Purple") {
    let tokens = [2400, 1900, 18600, 61200, 0, 3100]
    let range = ContextGrid.range(used: tokens.reduce(0, +), window: 262_144)
    VStack(spacing: DS.Spacing.md) {
        ContextGridCanvas(owners: ContextGrid.allocate(tokens, range: range), range: range,
                          summarizeCell: ContextGrid.summarizeCell(limit: 235_929, range: range), focus: nil)
        ContextZoomBar(range: range, used: tokens.reduce(0, +), window: 262_144)
    }
    .padding()
    .previewStyle(.dark)
}
