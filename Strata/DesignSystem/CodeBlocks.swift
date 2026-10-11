import SwiftUI

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

    init(language: String = "", code: String) {
        self.language = language
        self.code = code
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
    var lineCount: Int { lines.count }
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
        .fullScreenCover(isPresented: $showViewer) { CodeViewer(content: content).inAppLinks() }
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text(content.displayLanguage).font(DS.Typography.uiCaption.weight(.medium)).foregroundStyle(theme.textSecondary)
            Text(String(localized: "\(content.lineCount) lines")).font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
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
                Text(shown)
                    .font(DS.Typography.monoSmall)
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: true, vertical: true)
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
        UIPasteboard.general.string = content.code
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
    @State private var pinchBase: Double?

    private static let sizes = 9.0...28.0

    var body: some View {
        VStack(spacing: 0) {
            bar
            viewer
        }
        .background(theme.background.ignoresSafeArea())
    }

    private var bar: some View {
        HStack(spacing: DS.Spacing.sm) {
            GlassIconButton(systemName: "xmark", label: "Close") { dismiss() }
            VStack(alignment: .leading, spacing: 0) {
                Text(content.displayLanguage).font(DS.Typography.title).foregroundStyle(theme.textPrimary)
                Text(String(localized: "\(content.lineCount) lines")).font(DS.Typography.uiCaption).foregroundStyle(theme.textSecondary)
            }
            Spacer(minLength: 0)
            GlassIconButton(systemName: "minus", label: "Smaller text") { fontSize = max(Self.sizes.lowerBound, fontSize - 1) }
            GlassIconButton(systemName: "plus", label: "Larger text") { fontSize = min(Self.sizes.upperBound, fontSize + 1) }
            GlassIconButton(systemName: wrap ? "text.alignleft" : "arrow.left.and.right.text.vertical", label: "Wrap lines") { wrap.toggle() }
            GlassIconButton(systemName: copied ? "checkmark" : "doc.on.doc", label: "Copy") {
                UIPasteboard.general.string = content.code
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            }
            ShareLink(item: shareURL) {
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
                        .frame(width: CGFloat(digits) * fontSize * 0.62, alignment: .trailing)
                    if wrap {
                        Text(line.isEmpty ? " " : line).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(line.isEmpty ? " " : line).fixedSize(horizontal: true, vertical: false)
                    }
                    if wrap { Spacer(minLength: 0) }
                }
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
            }
        }
        .padding(DS.Spacing.md)
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
                fontSize = min(Self.sizes.upperBound, max(Self.sizes.lowerBound, (pinchBase ?? fontSize) * value.magnification))
            }
            .onEnded { _ in pinchBase = nil })
    }

    /// The code written to a temporary file with the right extension.
    private var shareURL: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("code.\(content.fileExtension)")
        try? content.code.write(to: url, atomically: true, encoding: .utf8)
        return url
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
