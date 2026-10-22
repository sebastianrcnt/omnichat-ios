import SwiftUI

/// What a view in an answer needs from the chat around it: which message it is in, whether it may still act, what
/// was saved, and how to send. Set per assistant row by `ChatView`; the default (no message) is the gallery's.
struct OpenUIHost: Equatable {
    var messageID: UUID?
    /// Controls work: the message is the latest and no reply is running.
    var isInteractive = true
    /// The message is still being written.
    var isStreaming = false
    /// Saved states by block (`Message.openUIStates`).
    var saved: [Int: OUISavedState] = [:]
    /// Saves the state on the message and sends the follow-up (block id, submission).
    var send: (@MainActor (Int, OUISubmission) -> Void)?

    static func == (a: Self, b: Self) -> Bool {
        a.messageID == b.messageID && a.isInteractive == b.isInteractive && a.isStreaming == b.isStreaming
            && a.saved == b.saved && (a.send == nil) == (b.send == nil)
    }
}

private struct OpenUIHostKey: EnvironmentKey { static var defaultValue: OpenUIHost { OpenUIHost() } }

extension EnvironmentValues {
    var openUIHost: OpenUIHost {
        get { self[OpenUIHostKey.self] }
        set { self[OpenUIHostKey.self] = newValue }
    }
}

/// A ```` ```openui ```` block drawn as native UI in place of a code block. While the block streams, a component
/// appears once its line is complete; at the end the rest is parsed too. What doesn't parse is left out, with a quiet
/// note and the source one tap away.
struct OpenUIBlockView: View {
    @Environment(\.theme) private var theme
    @Environment(\.openUIHost) private var host
    @Environment(\.openURL) private var openURL
    /// The fenced block, fences included.
    let blockText: String
    /// The block's position in the answer: the key its state is saved under.
    let blockID: Int
    let isClosed: Bool
    @State private var localRuntime = OUIRuntime()
    @State private var showingSource = false

    private var runtime: OUIRuntime {
        guard let id = host.messageID else { return localRuntime }
        return OUIRuntimeStore.shared.runtime(for: "\(id)#\(blockID)", saved: host.saved[blockID])
    }

    var body: some View {
        let runtime = runtime
        // An unclosed fence in a message that is no longer being written (stopped, cut off) is as finished as it gets.
        let final = isClosed || !host.isStreaming
        let source = OpenBlockView.codeBody(blockText)
        let parsed = runtime.statements(source: source, final: final)
        let rendered = OUIRendered.make(parsed.statements, problems: parsed.problems, state: runtime.state)
        let interactive = final && host.isInteractive && runtime.saved == nil
        // A root with nothing in it yet (or nothing that worked) shows the placeholder, not an empty card.
        let root = rendered.root.flatMap { OUITree.isBlank($0) ? nil : $0 }
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if let root {
                let scope = OUIScope(runtime: runtime, rendered: rendered, interactive: interactive,
                                     autoSendChoices: !OUITree.pageHasActions(root),
                                     send: { submission in host.send?(blockID, submission) },
                                     open: { openURL($0) })
                OUINode(component: root, scope: scope)
            } else if !final {
                placeholder
            }
            if final && (root == nil || !rendered.problems.isEmpty) {
                failureNote(nothingShown: root == nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showingSource) { OpenUISourceSheet(source: source) }
    }

    /// Before the first component's line is complete.
    private var placeholder: some View {
        HStack(spacing: DS.Spacing.sm) {
            ProgressView().controlSize(.small)
            Text("Preparing view…").font(DS.Typography.uiSmall).foregroundStyle(theme.textTertiary)
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
    }

    private func failureNote(nothingShown: Bool) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: "exclamationmark.circle")
            Text(nothingShown ? "Couldn't show this view." : "Part of this view couldn't be shown.")
            Button("View source") { showingSource = true }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
        }
        .font(DS.Typography.uiCaption)
        .foregroundStyle(theme.textTertiary)
    }
}

/// The program behind a view, for when it couldn't be shown.
struct OpenUISourceSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let source: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("View source").font(DS.Typography.uiEmphasis).foregroundStyle(theme.textPrimary)
                Spacer()
                Button("Done") { dismiss() }.fontWeight(.semibold)
            }
            .padding(DS.Spacing.lg)
            ScrollView {
                CodeBlockView(content: CodeBlockContent(language: "openui", code: source))
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.bottom, DS.Spacing.xl)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(theme.background)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }
}

/// What every component view gets: the runtime, the evaluated program, the form it is in, and whether it may act.
@MainActor
struct OUIScope {
    let runtime: OUIRuntime
    let rendered: OUIRendered
    var form: String?
    /// Controls that send or change state work.
    var interactive: Bool
    /// A choice outside forms sends at once (the page has nothing else to press).
    var autoSendChoices: Bool
    /// Inside a card: nested tiles and fields take the page colour instead of the card's.
    var onSurface = false
    /// The enclosing FormControl's label and hint, for VoiceOver on the input itself.
    var fieldLabel: String?
    var fieldHint: String?
    let send: @MainActor (OUISubmission) -> Void
    let open: @MainActor (URL) -> Void

    var locked: Bool { !interactive }

    /// The control with this label in this form is the one that sent.
    func wasChosen(_ label: String) -> Bool {
        guard let saved = runtime.saved else { return false }
        return saved.label == label && saved.form == form
    }

    func act(_ action: OUIAction?, label: String) {
        // Links still open in a locked view; everything else waits for the latest message.
        let opensOnly = action.map { !$0.steps.isEmpty && $0.steps.allSatisfy { if case .openURL = $0 { true } else { false } } } ?? false
        guard interactive || opensOnly else { return }
        if let submission = runtime.perform(action, label: label, form: form, rendered: rendered, open: open) {
            send(submission)
        }
    }

    func inForm(_ name: String) -> OUIScope {
        var s = self
        s.form = name
        return s
    }

    func labeled(_ label: String?, hint: String?) -> OUIScope {
        var s = self
        s.fieldLabel = label
        s.fieldHint = hint
        return s
    }

    func surface(_ on: Bool) -> OUIScope {
        var s = self
        s.onSurface = on
        return s
    }

    /// Fill for a nested tile or a field.
    func fill(_ theme: DSTheme) -> Color { onSurface ? theme.background : theme.surface }
}

/// One component, by type. Unknown components show their text and the components passed to them.
struct OUINode: View {
    let component: OUIComponent
    let scope: OUIScope

    var body: some View {
        switch component.type {
        case "Stack", "Card", "Separator", "Tabs", "Accordion", "SectionBlock", "Steps", "Carousel", "TabItem",
             "AccordionItem", "SectionItem":
            OUILayoutNode(component: component, scope: scope)
        case "CardHeader", "InlineHeader", "TextContent", "MarkDownRenderer", "Callout", "TextCallout", "Tag",
             "TagBlock", "Label", "CodeBlock", "Icon", "Image", "ImageBlock", "ImageGallery":
            OUITextNode(component: component, scope: scope)
        case "Table", "EntityList", "ListBlock", "Metric", "MetricIndicatorInline", "MetricIndicatorWithStrikethrough",
             "Progress":
            OUIDataNode(component: component, scope: scope)
        case "BarChart", "LineChart", "AreaChart", "HorizontalBarChart", "RadarChart", "PieChart", "RadialChart",
             "SingleStackedBarChart", "ScatterChart":
            OUIChart(component: component, scope: scope)
        case "Button", "Buttons", "IconButton", "Link", "FollowUpBlock", "Form", "FormControl", "Input", "TextArea",
             "Select", "DatePicker", "Slider", "CheckBoxGroup", "RadioGroup", "SwitchGroup", "Chips":
            OUIControlNode(component: component, scope: scope)
        default:
            OUIUnknownNode(component: component, scope: scope)
        }
    }
}

/// A list of values drawn in order: components as themselves, text as text.
struct OUIChildren: View {
    let values: [OUIValue]
    let scope: OUIScope
    var spacing: CGFloat = DS.Spacing.md

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                OUIValueView(value: value, scope: scope)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A value where a component is expected: strings and numbers render as text, null as nothing (spec 3.2).
struct OUIValueView: View {
    @Environment(\.theme) private var theme
    let value: OUIValue
    let scope: OUIScope

    var body: some View {
        switch value {
        case .component(let c): OUINode(component: c, scope: scope)
        case .array(let items): OUIChildren(values: items, scope: scope)
        case .string, .number, .bool:
            InlineMarkdownText(source: value.text ?? "", font: DS.Typography.answer, color: theme.textPrimary)
        default: EmptyView()
        }
    }
}

private struct OUIUnknownNode: View {
    let component: OUIComponent
    let scope: OUIScope

    var body: some View {
        if component.known {
            EmptyView() // a library component with no view here (`Series`, `Col`, ...) is drawn by its parent
        } else {
            // Its first text (later strings are usually options like a variant), then any components it holds.
            let text = component.args.first { $0.text != nil }.map { [$0] } ?? []
            let nested = component.args.filter { !OUIValue.components($0).isEmpty }.flatMap(OUIValue.components).map(OUIValue.component)
            OUIChildren(values: text + nested, scope: scope, spacing: DS.Spacing.sm)
        }
    }
}
