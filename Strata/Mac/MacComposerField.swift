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

        // This runs on every keystroke (the binding changes). Setting the font or colour restyles and lays out the
        // whole text again, so it is done only when the size or colour actually changed.
        let size = 17 * DS.typeScale(typeSize)
        let resolved = textColor.resolve(in: context.environment)
        let look = Coordinator.Look(size: size, red: resolved.red, green: resolved.green, blue: resolved.blue)
        let coordinator = context.coordinator
        if coordinator.look != look {
            coordinator.look = look
            let font = NSFont(name: DS.Typography.regularFontName, size: size) ?? .systemFont(ofSize: size)
            let style = NSMutableParagraphStyle()
            style.lineSpacing = DS.Leading.spacing(multiple: DS.Leading.ui.multiple, size: size)
            let color = NSColor(srgbRed: CGFloat(resolved.red), green: CGFloat(resolved.green), blue: CGFloat(resolved.blue), alpha: 1)
            coordinator.attributes = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            view.font = font
            view.textColor = color
            view.insertionPointColor = color
            view.defaultParagraphStyle = style
            view.typingAttributes = coordinator.attributes
            coordinator.measured = nil
        }

        // The view's own edits reach `text` through the delegate, so they compare equal here; only an outside change
        // (sent, cleared, restored draft) replaces the text.
        if !view.hasMarkedText(), view.string != text {
            view.string = text
            view.textStorage?.setAttributes(coordinator.attributes, range: NSRange(location: 0, length: (text as NSString).length))
            coordinator.measured = nil
        }
        // AppKit focus notifications reach the binding asynchronously. Until that delivery, the binding is stale:
        // do not interpret it as a new request to undo a click. Otherwise only a binding edge moves focus.
        if context.coordinator.pendingFocus == nil, context.coordinator.requestedFocus != isFocused {
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
        guard let view = scroll.documentView as? NSTextView, let layout = view.layoutManager,
              let container = view.textContainer else { return nil }
        let width = max(proposal.width ?? 400, 1)
        let coordinator = context.coordinator
        let string = view.string
        // SwiftUI asks several times per layout pass, often for the same width and text.
        if let m = coordinator.measured, m.width == width, m.text == string { return m.size }
        let font = view.font ?? .systemFont(ofSize: 17)
        let spacing = view.defaultParagraphStyle?.lineSpacing ?? 0
        let line = layout.defaultLineHeight(for: font) + spacing
        let used: CGFloat
        if abs(container.size.width - width) < 0.5 {
            // The usual case: the field already has this width, and the layout the text view keeps for drawing (done
            // incrementally as the text changes) gives the height. A trailing newline's empty line is included.
            layout.ensureLayout(for: container)
            used = layout.usedRect(for: container).height
        } else {
            // Another width is proposed: measured on a copy, so the real container keeps the width the view gave it.
            let box = view.attributedString().boundingRect(with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
                                                           options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            // A trailing newline starts a line the bounding box does not count.
            used = box + (string.hasSuffix("\n") ? line : 0)
        }
        let size = CGSize(width: width, height: min(max(used, line), line * CGFloat(maxLines)).rounded(.up))
        coordinator.measured = (width, string, size)
        return size
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacComposerField
        /// The focus last delivered to SwiftUI or requested by it.
        var requestedFocus: Bool?
        var pendingFocus: Bool?

        /// Font size and colour last applied to the text view.
        struct Look: Equatable { var size: CGFloat; var red: Float; var green: Float; var blue: Float }
        var look: Look?
        var attributes: [NSAttributedString.Key: Any] = [:]
        /// The last height measured, for the width and text it was measured at.
        var measured: (width: CGFloat, text: String, size: CGSize)?

        init(_ parent: MacComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if parent.text != view.string { parent.text = view.string }
        }

        func focusChanged(_ focused: Bool) {
            pendingFocus = focused
            DispatchQueue.main.async { [self] in
                guard pendingFocus == focused else { return }
                requestedFocus = focused
                if parent.isFocused != focused { parent.isFocused = focused }
                pendingFocus = nil
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
