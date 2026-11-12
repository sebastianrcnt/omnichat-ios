import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Typeset formulas, by formula and size. Views ask on every body; a formula not there yet is typeset in the
/// background (`MathTypesetter`) and the views that asked are drawn again when it arrives.
@MainActor
@Observable
final class MathStore {
    static let shared = MathStore()

    enum State {
        case ready(MathImage)
        /// Being typeset: show the source for now.
        case pending
        /// MathJax could not read it: the source stays.
        case failed
    }

    /// Goes up when formulas arrive. Only a view that got `.pending` reads it, so only those are drawn again.
    private(set) var revision = 0

    private final class Key: NSObject {
        let request: MathRequest
        init(_ request: MathRequest) { self.request = request }
        override var hash: Int { request.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? Key)?.request == request }
    }

    private final class Entry {
        let image: MathImage
        init(_ image: MathImage) { self.image = image }
    }

    private struct Formula: Hashable { var latex: String; var display: Bool }

    /// Bounded by bytes; the system also empties it under memory pressure.
    @ObservationIgnored private let images: NSCache<Key, Entry> = {
        let cache = NSCache<Key, Entry>()
        cache.totalCostLimit = 32 << 20
        return cache
    }()
    @ObservationIgnored private var failed: Set<Formula> = []
    @ObservationIgnored private var pending: Set<MathRequest> = []
    @ObservationIgnored private var queue: [MathRequest] = []
    @ObservationIgnored private var draining = false

    private init() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            Task { await MathTypesetter.shared.unload() }
        }
        #endif
    }

    func state(_ request: MathRequest) -> State {
        if let hit = images.object(forKey: Key(request)) { return .ready(hit.image) }
        if failed.contains(Formula(latex: request.latex, display: request.display)) { return .failed }
        _ = revision
        if pending.insert(request).inserted {
            queue.append(request)
            drain()
        }
        return .pending
    }

    /// Typesets the queue a few formulas at a time, so the first ones of a long answer show before the last is done.
    private func drain() {
        guard !draining else { return }
        draining = true
        Task {
            while !queue.isEmpty {
                let batch = Array(queue.prefix(6))
                queue.removeFirst(batch.count)
                let results = await MathTypesetter.shared.render(batch)
                for (request, image) in zip(batch, results) {
                    pending.remove(request)
                    if let image {
                        images.setObject(Entry(image), forKey: Key(request), cost: image.image.bytesPerRow * image.image.height)
                    } else {
                        if failed.count > 2000 { failed.removeAll() }
                        failed.insert(Formula(latex: request.latex, display: request.display))
                    }
                }
                revision += 1
            }
            draining = false
        }
    }
}

/// Size of the text a formula sits in.
struct MathStyle: Equatable {
    /// Font size in points, Dynamic Type applied.
    var pointSize: CGFloat
    var scale: CGFloat
}

extension MathImage {
    /// Drawn in the foreground colour, like the text around it. VoiceOver reads the LaTeX.
    func view(latex: String) -> Image {
        Image(image, scale: scale, label: Text(verbatim: latex)).renderingMode(.template)
    }
}

/// A display formula on its own lines: centred, and scrolling sideways when it is wider than the column.
/// While it is still being written, or if it cannot be typeset, its source is shown as typed.
struct MathBlockView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale
    /// The block's text, delimiters included.
    let source: String
    /// No closing delimiter yet.
    var isOpen = false

    var body: some View {
        let pointSize = DS.Leading.answer.size * DS.typeScale(typeSize)
        if !isOpen, let latex = MathScanner.blockLatex(source) {
            switch MathStore.shared.state(MathRequest(latex: latex, display: true, pointSize: pointSize, scale: displayScale)) {
            case .ready(let math):
                let formula = math.view(latex: latex).foregroundStyle(theme.textPrimary)
                ViewThatFits(in: .horizontal) {
                    formula.frame(maxWidth: .infinity)
                    ScrollView(.horizontal) { formula }.scrollBounceBehavior(.basedOnSize)
                }
                .padding(.vertical, DS.Spacing.xs)
            case .pending:
                // About the height of a one-line formula, so the text below moves little when it arrives.
                Color.clear.frame(height: pointSize * 2.2)
            case .failed:
                raw
            }
        } else {
            raw
        }
    }

    private var raw: some View {
        ScrollView(.horizontal) {
            Text(source)
                .font(DS.Typography.monoSmall)
                .foregroundStyle(theme.textPrimary)
                .padding(DS.Spacing.md)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
    }
}
