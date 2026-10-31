#if os(macOS)
import SwiftUI
import AppKit

/// The composer's text field on a Mac: an NSTextView, because SwiftUI's vertical `TextField` gives no control over
/// Return. Return sends, Shift+Return (and Option+Return) inserts a newline, and while an input method (Korean,
/// Japanese, ...) holds uncommitted text it gets Return first, so a composition is never cut short by a send.
struct MacComposerField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var textColor: Color
    var onReturn: () -> Void
    /// Called when the pasteboard holds images and no text.
    var onPasteImages: (([Data]) -> Void)?
    var maxLines = 6

    @Environment(\.dynamicTypeSize) private var typeSize

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager() // TextKit 1: usedRect gives the height the field needs
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let view = ComposerTextView(frame: .zero, textContainer: container)
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.textContainerInset = .zero
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.setAccessibilityLabel(String(localized: "Message"))
        view.unregisterDraggedTypes() // files dropped on the chat attach as images; they must not paste as paths
        view.onFocusChange = { [weak coordinator = context.coordinator] focused in coordinator?.focusChanged(focused) }

        let scroll = ComposerScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ComposerTextView else { return }
        view.onPasteImages = onPasteImages

        let size = 17 * DS.typeScale(typeSize)
        let font = NSFont(name: DS.Typography.regularFontName, size: size) ?? .systemFont(ofSize: size)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = DS.Leading.spacing(multiple: DS.Leading.ui.multiple, size: size)
        let resolved = textColor.resolve(in: context.environment)
        let color = NSColor(srgbRed: CGFloat(resolved.red), green: CGFloat(resolved.green), blue: CGFloat(resolved.blue), alpha: 1)
        view.font = font
        view.textColor = color
        view.insertionPointColor = color
        view.defaultParagraphStyle = style
        view.typingAttributes = [.font: font, .foregroundColor: color, .paragraphStyle: style]

        if view.string != text && !view.hasMarkedText() {
            view.string = text
            view.textStorage?.addAttributes([.font: font, .foregroundColor: color, .paragraphStyle: style],
                                            range: NSRange(location: 0, length: (text as NSString).length))
        }
        // Only a change of `isFocused` moves focus. Comparing levels on every update would let a stale `false` (the
        // binding catches up asynchronously) take focus straight back from a click, leaving nothing to type into.
        if context.coordinator.requestedFocus != isFocused {
            context.coordinator.requestedFocus = isFocused
            view.wantsFocus = isFocused
            if isFocused, let window = view.window, window.firstResponder !== view {
                window.makeFirstResponder(view)
            } else if !isFocused, let window = view.window, window.firstResponder === view {
                window.makeFirstResponder(nil)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let view = scroll.documentView as? NSTextView, let layout = view.layoutManager else { return nil }
        let width = max(proposal.width ?? 400, 1)
        let font = view.font ?? .systemFont(ofSize: 17)
        let spacing = view.defaultParagraphStyle?.lineSpacing ?? 0
        let line = layout.defaultLineHeight(for: font) + spacing
        // Measured on a copy of the text, so the real container keeps the width the view gave it.
        let used = view.attributedString().boundingRect(with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
                                                        options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        // A trailing newline starts a line the bounding box does not count.
        let extra = view.string.hasSuffix("\n") ? line : 0
        return CGSize(width: width, height: min(max(used + extra, line), line * CGFloat(maxLines)).rounded(.up))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacComposerField
        /// The focus last asked for or reached, so an update acts only when `isFocused` changes.
        var requestedFocus: Bool?

        init(_ parent: MacComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if parent.text != view.string { parent.text = view.string }
        }

        func focusChanged(_ focused: Bool) {
            requestedFocus = focused
            DispatchQueue.main.async { [self] in
                if parent.isFocused != focused { parent.isFocused = focused }
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // An input method with uncommitted text takes Return before it gets here; if one ever does not, leave
                // the Return to the text view rather than send half a composition.
                if textView.hasMarkedText() { return false }
                let modifiers = (textView as? ComposerTextView)?.keyModifiers ?? []
                if modifiers.contains(.shift) || modifiers.contains(.option) || modifiers.contains(.control) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onReturn()
                }
                return true
            case #selector(NSResponder.insertLineBreak(_:)): // Shift+Return in some configurations
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            default:
                return false
            }
        }
    }
}

/// Keeps the text view as wide as the visible area, so the text wraps there and is drawn in full.
final class ComposerScrollView: NSScrollView {
    override func layout() {
        super.layout()
        if let document = documentView, document.frame.width != contentSize.width {
            document.frame.size.width = contentSize.width
        }
    }
}

final class ComposerTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    var onPasteImages: (([Data]) -> Void)?
    /// Focus the SwiftUI side asked for before the view had a window.
    var wantsFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocus, let window, window.firstResponder !== self { window.makeFirstResponder(self) }
    }

    /// Modifiers held for the key being handled, which the delegate asks about when a command arrives.
    private(set) var keyModifiers: NSEvent.ModifierFlags = []

    override func keyDown(with event: NSEvent) {
        keyModifiers = event.modifierFlags
        super.keyDown(with: event)
        keyModifiers = []
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if let onPasteImages, board.string(forType: .string) == nil,
           let images = board.readObjects(forClasses: [NSImage.self]) as? [NSImage], !images.isEmpty {
            let data = images.compactMap { $0.tiffRepresentation }
            if !data.isEmpty { onPasteImages(data); return }
        }
        pasteAsPlainText(sender)
    }
}
#endif
