import SwiftUI

/// A chat title. While the model is naming the chat (`isTitling`), the placeholder stays readable but dimmed, and a soft
/// highlight sweeps across it about every 1.5 s (with Reduce Motion, the opacity pulses gently instead). When the new
/// title arrives it crossfades in. Style it like a `Text` (font, color, line limit): the effect works through the
/// text's alpha, so it keeps whatever color the place it sits in gives it (a selected sidebar row included).
struct TitlingText: View {
    let title: String
    var isTitling: Bool

    init(_ title: String, isTitling: Bool) {
        self.title = title
        self.isTitling = isTitling
    }

    var body: some View {
        Text(title)
            .contentTransition(.opacity)
            .animation(TitlingEffect.crossfade, value: title)
            .modifier(TitlingEffect(active: isTitling))
            .accessibilityValue(isTitling ? Text("Naming chat") : Text(""))
    }
}

/// The dim-and-shimmer treatment of `TitlingText`, as a modifier for titles that are not a plain `Text`.
struct TitlingEffect: ViewModifier {
    static let period: Double = 1.5
    static let crossfade = Animation.easeInOut(duration: 0.35)
    /// Alpha of the dimmed text outside the highlight.
    static let dim: Double = 0.45

    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // The text keeps its identity whether or not the effect is on, so a title change still crossfades.
        content.mask {
            if active {
                TimelineView(.animation) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
                    if reduceMotion {
                        Color.black.opacity(Self.pulse(phase))
                    } else {
                        GeometryReader { geo in Self.sweep(phase: phase, width: geo.size.width) }
                    }
                }
                .transition(.opacity.animation(Self.crossfade))
            } else {
                Color.black
            }
        }
    }

    /// 0.45 ... 0.75 and back, once per period.
    static func pulse(_ phase: Double) -> Double {
        dim + 0.3 * (0.5 - 0.5 * cos(2 * .pi * phase))
    }

    /// A band of full alpha over the dimmed text, crossing it in the first 80% of the period (eased), then a short rest.
    @ViewBuilder
    static func sweep(phase: Double, width: CGFloat) -> some View {
        let band = max(width * 0.45, 48)
        let t = min(phase / 0.8, 1)
        let eased = t * t * (3 - 2 * t)
        let x = -band + eased * (width + band)
        ZStack(alignment: .leading) {
            Color.black.opacity(dim)
            LinearGradient(colors: [.black.opacity(0), .black, .black.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .offset(x: x)
        }
        .frame(width: width, alignment: .leading)
    }
}

#Preview("Titling") {
    @Previewable @State var titling = true
    @Previewable @State var title = "How do I center a div inside a flex…"
    VStack(alignment: .leading, spacing: 24) {
        TitlingText(title, isTitling: titling).font(.headline)
        TitlingText(title, isTitling: titling).font(.body).foregroundStyle(.white)
            .padding(8).background(.blue, in: RoundedRectangle(cornerRadius: 8))
        Button(titling ? "Title arrives" : "Start again") {
            if titling { title = "Centering a div with flexbox" } else { title = "How do I center a div inside a flex…" }
            titling.toggle()
        }
    }
    .padding()
}
