import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

/// A fenced code block split into language and body, plus the collapse rules.
struct CodeBlockContent: Equatable, Sendable {
    var language: String
    var code: String

    /// Blocks longer than this many lines collapse...
    static let collapseThreshold = 18
    /// ...to this many lines.
    static let previewLines = 12
    /// Visible lines while a block is still streaming.
    static let streamingLines = 12
    /// A streaming block renders only this many of its last lines (the box shows 12 and follows its bottom).
    static let streamingTailLines = 40

    /// Lines of the whole block. For a streaming block `code` holds only the tail, so this is kept separately.
    private(set) var lineCount: Int

    init(language: String = "", code: String) {
        self.language = language
        self.code = code
        self.lineCount = Self.countLines(code)
    }

    private init(language: String, tail: String, lineCount: Int) {
        self.language = language
        self.code = tail
        self.lineCount = lineCount
    }

    /// Number of lines in `text`: newlines plus one, 0 when empty. A byte scan; nothing is allocated.
    static func countLines(_ text: String) -> Int {
        if text.isEmpty { return 0 }
        var text = text
        let newlines = text.withUTF8 { buffer in buffer.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } }
        return newlines + 1
    }

    /// The cheap form used while a block is still being written: the language from the opening fence, the line count
    /// from a byte scan, and only the last `streamingTailLines` lines as text. No per-line strings are made, so a
    /// token costs about as much as the scan, however long the block has grown.
    static func streaming(blockText text: String, tailLines: Int = streamingTailLines) -> CodeBlockContent {
        var text = text
        var result = text.withUTF8 { bytes -> CodeBlockContent in
            let newline = UInt8(ascii: "\n")
            guard let firstEnd = bytes.firstIndex(of: newline) else {
                return CodeBlockContent(language: Self.info(String(decoding: bytes, as: UTF8.self)), tail: "", lineCount: 0)
            }
            let language = Self.info(String(decoding: bytes[..<firstEnd], as: UTF8.self))
            let bodyStart = firstEnd + 1
            guard bodyStart < bytes.endIndex else { return CodeBlockContent(language: language, tail: "", lineCount: 0) }
            var lines = 1
            var tailStart = bodyStart
            var i = bytes.endIndex - 1
            while i >= bodyStart {
                if bytes[i] == newline {
                    lines += 1
                    if lines == tailLines + 1 { tailStart = i + 1 }
                }
                i -= 1
            }
            if lines <= tailLines { tailStart = bodyStart }
            return CodeBlockContent(language: language, tail: String(decoding: bytes[tailStart...], as: UTF8.self), lineCount: lines)
        }
        // A closing fence on the last line is not code.
        let lastLine = result.code.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let trimmed = lastLine.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 3, trimmed.allSatisfy({ $0 == "`" }) || trimmed.allSatisfy({ $0 == "~" }) {
            result.code = String(result.code.dropLast(lastLine.count + (result.lineCount > 1 ? 1 : 0)))
            result.lineCount = max(0, result.lineCount - 1)
        }
        return result
    }

    /// The language word of an opening fence line.
    private static func info(_ line: String) -> String {
        let s = line.drop(while: { $0 == " " })
        guard let fence = s.first, fence == "`" || fence == "~" else { return "" }
        let info = s.drop(while: { $0 == fence }).trimmingCharacters(in: .whitespaces)
        return info.split(separator: " ").first.map(String.init) ?? ""
    }

    /// From the raw block text: the opening fence's info string and the body without fences.
    init(blockText text: String) {
        let lines = BlockScanner.lines(of: text).map(String.init)
        guard let first = lines.first, let f = BlockScanner.Line(Substring(first)).fence else {
            self.init(language: "", code: text)
            return
        }
        let info = first.drop(while: { $0 == " " }).drop(while: { $0 == f.char }).trimmingCharacters(in: .whitespaces)
        var body = Array(lines.dropFirst())
        if let last = body.last, BlockScanner.Line(Substring(last)).closesFence(char: f.char, count: f.count) { body.removeLast() }
        self.init(language: info.split(separator: " ").first.map(String.init) ?? "", code: body.joined(separator: "\n"))
    }

    var lines: [String] { code.isEmpty ? [] : code.components(separatedBy: "\n") }
    var isCollapsible: Bool { lineCount > Self.collapseThreshold }
    var preview: String { lines.prefix(Self.previewLines).joined(separator: "\n") }
    var displayLanguage: String { language.isEmpty ? String(localized: "Code") : language.lowercased() }

    /// File extension for sharing.
    var fileExtension: String {
        switch language.lowercased() {
        case "swift": "swift"
        case "python", "py": "py"
        case "javascript", "js", "jsx": "js"
        case "typescript", "ts", "tsx": "ts"
        case "json": "json"
        case "bash", "sh", "shell", "zsh", "console": "sh"
        case "html": "html"
        case "css": "css"
        case "kotlin", "kt": "kt"
        case "java": "java"
        case "c": "c"
        case "cpp", "c++": "cpp"
        case "rust", "rs": "rs"
        case "go": "go"
        case "ruby", "rb": "rb"
        case "yaml", "yml": "yml"
        case "markdown", "md": "md"
        case "sql": "sql"
        default: "txt"
        }
    }
}

// MARK: - Inline block

/// Code block with a header (language, line count, copy, expand). Long blocks collapse with a fade; a
/// block that is still streaming is capped to ~12 lines and follows its own bottom.
struct CodeBlockView: View, Equatable {
    let content: CodeBlockContent
    var isStreaming = false

    var body: some View { CodeBlockBody(content: content, isStreaming: isStreaming) }
}

private struct CodeBlockBody: View {
    @Environment(\.theme) private var theme
    let content: CodeBlockContent
    let isStreaming: Bool

    @State private var expanded = false
    @State private var copied = false
    @State private var showViewer = false
    /// Colours arrive after the block has closed; the coloured text fades in over the plain one.
    @State private var highlighted: HighlightedCode?
    @State private var fade = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct HighlightTrigger: Equatable { var content: CodeBlockContent; var streaming: Bool }

    private var collapsed: Bool { !isStreaming && content.isCollapsible && !expanded }
    private var lineHeight: CGFloat { 18 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            codeArea
            if !isStreaming && content.isCollapsible { footer }
        }
        .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onLongPressGesture(minimumDuration: 0.6) { if !isStreaming { showViewer = true } }
        .fullScreenCoverOrSheet(isPresented: $showViewer) { CodeViewer(content: content).inAppLinks() }
        .task(id: HighlightTrigger(content: content, streaming: isStreaming)) { await loadHighlight() }
    }

    /// Only after the fence has closed: a block being written stays plain.
    private func loadHighlight() async {
        guard !isStreaming else {
            if highlighted != nil { highlighted = nil; fade = 0 }
            return
        }
        if let cached = HighlightService.cachedValue(language: content.language, code: content.code) {
            highlighted = cached
            fade = 1
            return
        }
        highlighted = nil
        fade = 0
        guard let result = await HighlightService.highlighted(language: content.language, code: content.code),
              !Task.isCancelled else { return }
        highlighted = result
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { fade = 1 }
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text(content.displayLanguage).font(DS.Typography.uiCaption.weight(.medium)).foregroundStyle(theme.textSecondary)
            Text(content.lineCount == 1 ? String(localized: "1 line") : String(localized: "\(content.lineCount) lines")).font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
            Spacer(minLength: 0)
            Button { copy() } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(DS.Typography.uiCaption.weight(.medium))
                    .labelStyle(.titleAndIcon)
                    .frame(minHeight: DS.IconSize.minHitTarget - 8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.textSecondary)
            .accessibilityLabel(Text("Copy code"))
            if !isStreaming {
                Button { showViewer = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: DS.IconSize.sm, weight: .medium))
                        .frame(width: DS.IconSize.minHitTarget - 8, height: DS.IconSize.minHitTarget - 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textSecondary)
                .accessibilityLabel(Text("Open full screen"))
            }
        }
        .padding(.leading, DS.Spacing.md)
        .padding(.trailing, DS.Spacing.xs)
        .frame(minHeight: 32)
        .background(theme.surfaceRaised.opacity(0.6))
    }

    @ViewBuilder
    private var codeArea: some View {
        if isStreaming {
            StreamingCodeText(code: content.code, lines: CodeBlockContent.streamingLines, lineHeight: lineHeight)
        } else {
            let shown = collapsed ? content.preview : content.code
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    if fade < 1 || highlighted == nil {
                        Text(shown)
                            .font(DS.Typography.monoSmall)
                            .foregroundStyle(theme.textPrimary)
                            .fixedSize(horizontal: true, vertical: true)
                            .opacity(1 - fade)
                    }
                    if let highlighted {
                        Text(collapsed ? highlighted.preview : highlighted.full)
                            .font(DS.Typography.monoSmall)
                            .foregroundStyle(theme.textPrimary)
                            .fixedSize(horizontal: true, vertical: true)
                            .opacity(fade)
                    }
                }
                .padding(DS.Spacing.md)
            }
            .scrollBounceBehavior(.basedOnSize)
            .overlay(alignment: .bottom) {
                if collapsed {
                    LinearGradient(colors: [theme.surface.opacity(0), theme.surface], startPoint: .top, endPoint: .bottom)
                        .frame(height: 44)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                withAnimation(DS.Motion.snappy) { expanded.toggle() }
            } label: {
                Text(expanded ? LocalizedStringKey("Show less") : LocalizedStringKey("Show all (\(content.lineCount) lines)"))
                    .font(DS.Typography.uiSmall.weight(.medium))
                    .foregroundStyle(theme.accent)
                    .frame(minHeight: DS.IconSize.minHitTarget - 8)
            }
            .buttonStyle(.plain)
            Spacer()
            if expanded {
                // Long expanded block: a second Copy at the bottom (the header scrolls away).
                Button { copy() } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(DS.Typography.uiCaption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.horizontal, DS.Spacing.md)
    }

    private func copy() {
        Pasteboard.copy(content.code)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
}

/// Fixed-height streaming code area that follows its own bottom.
private struct StreamingCodeText: View {
    @Environment(\.theme) private var theme
    let code: String
    let lines: Int
    let lineHeight: CGFloat

    @State private var position = ScrollPosition(edge: .bottom)

    var body: some View {
        let height = CGFloat(lines) * lineHeight + DS.Spacing.md * 2
        // `scrollTo(edge: .bottom)` only moves along the vertical axis, so a horizontal offset the user set
        // is kept (an anchor-based scrollTo would re-center or snap x on every token).
        ScrollView([.vertical, .horizontal]) {
            Text(code.isEmpty ? " " : code)
                .font(DS.Typography.monoSmall)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: true, vertical: true)
                .padding(DS.Spacing.md)
        }
        .scrollPosition($position)
        .scrollBounceBehavior(.basedOnSize)
        .onChange(of: code) { _, _ in position.scrollTo(edge: .bottom) }
        .frame(height: height)
    }
}

// MARK: - Full-screen viewer

struct CodeViewer: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let content: CodeBlockContent

    @AppStorage("codeViewerFontSize") private var fontSize = 14.0
    @AppStorage("codeViewerWrap") private var wrap = false
    @State private var copied = false
    /// Font size while a pinch is in progress. Kept in view state so the stored setting is written once, when the
    /// gesture ends, not on every frame.
    @State private var pinchSize: Double?
    @State private var pinchBase: Double?
    /// Shared with the inline block through `HighlightService`'s cache.
    @State private var highlighted: HighlightedCode?

    private static let sizes = 9.0...28.0
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The chosen size (stored and pinched in base points) times the app's text size.
    private var shownSize: Double { (pinchSize ?? fontSize) * Double(DS.typeScale(typeSize)) }

    var body: some View {
        VStack(spacing: 0) {
            bar
            viewer
        }
        .background(theme.background.ignoresSafeArea())
        .task(id: content) {
            highlighted = HighlightService.cachedValue(language: content.language, code: content.code)
            if highlighted == nil {
                let result = await HighlightService.highlighted(language: content.language, code: content.code)
                if !Task.isCancelled { withAnimation(.easeInOut(duration: 0.15)) { highlighted = result } }
            }
        }
    }

    private var bar: some View {
        HStack(spacing: DS.Spacing.sm) {
            GlassIconButton(systemName: "xmark", label: "Close") { dismiss() }
            VStack(alignment: .leading, spacing: 0) {
                Text(content.displayLanguage).font(DS.Typography.title).foregroundStyle(theme.textPrimary)
                Text(content.lineCount == 1 ? String(localized: "1 line") : String(localized: "\(content.lineCount) lines")).font(DS.Typography.uiCaption).foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: 0)
            GlassIconButton(systemName: "minus", label: "Smaller text") { fontSize = max(Self.sizes.lowerBound, fontSize - 1) }
            GlassIconButton(systemName: "plus", label: "Larger text") { fontSize = min(Self.sizes.upperBound, fontSize + 1) }
            GlassIconButton(systemName: wrap ? "text.alignleft" : "arrow.left.and.right.text.vertical", label: "Wrap lines") { wrap.toggle() }
            GlassIconButton(systemName: copied ? "checkmark" : "doc.on.doc", label: "Copy") {
                Pasteboard.copy(content.code)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            }
            ShareLink(item: CodeFile(code: content.code, fileExtension: content.fileExtension),
                      preview: SharePreview(String(localized: "Code"))) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: DS.IconSize.headerIcon, weight: .medium))
                    .frame(width: DS.IconSize.controlDiameter, height: DS.IconSize.controlDiameter)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .accessibilityLabel(Text("Share as file"))
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
    }

    private var rows: some View {
        let lines = content.lines
        let digits = String(lines.count).count
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.md) {
                    Text(String(index + 1))
                        .foregroundStyle(theme.textTertiary)
                        .frame(width: CGFloat(digits) * shownSize * 0.62, alignment: .trailing)
                    let text = lineText(line, index: index)
                    if wrap {
                        text.fixedSize(horizontal: false, vertical: true)
                    } else {
                        text.fixedSize(horizontal: true, vertical: false)
                    }
                    if wrap { Spacer(minLength: 0) }
                }
                .font(.system(size: shownSize, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
            }
        }
        .padding(DS.Spacing.md)
    }

    /// A line of code, coloured when the highlighter has run (its lines match `content.lines`).
    private func lineText(_ line: String, index: Int) -> Text {
        if let highlighted, highlighted.lines.indices.contains(index), !line.isEmpty { return Text(highlighted.lines[index]) }
        return Text(line.isEmpty ? " " : line)
    }

    @ViewBuilder
    private var viewer: some View {
        Group {
            if wrap {
                ScrollView(.vertical) { rows }
            } else {
                ScrollView([.vertical, .horizontal]) { rows }
            }
        }
        .gesture(MagnifyGesture()
            .onChanged { value in
                if pinchBase == nil { pinchBase = fontSize }
                pinchSize = min(Self.sizes.upperBound, max(Self.sizes.lowerBound, (pinchBase ?? fontSize) * value.magnification))
            }
            .onEnded { _ in
                if let pinchSize { fontSize = pinchSize }
                pinchSize = nil
                pinchBase = nil
            })
    }
}

/// The code as a file with the right extension. The file is written only when the share sheet asks for it.
struct CodeFile: Transferable {
    let code: String
    let fileExtension: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("code.\(file.fileExtension)")
            try file.code.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

#Preview("Light · Purple") { codePreview.previewStyle(.light) }
#Preview("Dark · Purple") { codePreview.previewStyle(.dark) }
#Preview("Dark · Orange") { codePreview.previewStyle(.dark, accent: Color(hex: "#F97316")) }
#Preview("Viewer · Dark") {
    CodeViewer(content: .init(language: "swift", code: (1...30).map { "let step\($0) = configure(glassEffect: .regular, id: \($0))" }.joined(separator: "\n")))
        .previewStyle(.dark)
}

@MainActor private var codePreview: some View {
    let long = (1...40).map { "let value\($0) = compute(\($0)) // a fairly long line to scroll horizontally" }.joined(separator: "\n")
    return ScrollView {
        VStack(spacing: DS.Spacing.lg) {
            CodeBlockView(content: .init(language: "swift", code: "let a = 1\nprint(a)"))
            CodeBlockView(content: .init(language: "swift", code: long))
            CodeBlockView(content: .init(language: "python", code: long), isStreaming: true)
        }
        .padding()
    }
}
