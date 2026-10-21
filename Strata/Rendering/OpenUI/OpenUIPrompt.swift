import Foundation

/// ```` ```openui ```` blocks in an answer (`openui-lang`, OpenUI's own tag, works too).
enum OpenUIFence {
    static let languages: Set<String> = ["openui", "openui-lang"]

    /// The language word of a fenced block's opening line.
    static func language(blockText: String) -> String {
        let firstLine = blockText.prefix { $0 != "\n" }
        let info = firstLine.drop { $0 == " " || $0 == "`" || $0 == "~" }
        return String(info.prefix { !$0.isWhitespace && $0 != "{" }).lowercased()
    }

    static func isOpenUI(blockText: String) -> Bool { languages.contains(language(blockText: blockText)) }

    /// `markdown` with every OpenUI block replaced by `replacement(source)`. Other fences are left alone;
    /// an unclosed OpenUI block runs to the end.
    static func replacingBlocks(in markdown: String, with replacement: (String) -> String) -> String {
        guard markdown.contains("openui") else { return markdown }
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [Substring] = []
        var i = 0
        while i < lines.count {
            let line = BlockScanner.Line(lines[i])
            guard let fence = line.fenceAnyIndent else { out.append(lines[i]); i += 1; continue }
            var j = i + 1
            while j < lines.count, !BlockScanner.Line(lines[j]).closesFence(char: fence.char, count: fence.count, anyIndent: true) { j += 1 }
            let end = min(j, lines.count - 1)
            if isOpenUI(blockText: String(lines[i])) {
                let body = lines[(i + 1)..<max(i + 1, min(j, lines.count))].joined(separator: "\n")
                out.append(Substring(replacement(body)))
            } else {
                out.append(contentsOf: lines[i...end])
            }
            i = end + 1
        }
        return out.joined(separator: "\n")
    }
}

extension AppPrompt {
    /// Interactive views (`ToolGroup.views`): OpenUI Lang in a fenced block, rendered natively. The component list is
    /// a subset of OpenUI's default library with its prop order; kept short: about 3.5k characters, roughly 900-1,000 tokens.
    static let views = """
    Interactive views: for small structured or interactive parts of an answer (a table, chart, comparison, key figures, a choice, a quick form), you can write an OpenUI Lang program in a ```openui fenced block inside your Markdown reply; the app draws it as native UI. Keep explanations outside the block. Use show_html for full pages, apps or games, not this. Don't use a view where plain Markdown is enough.

    OpenUI Lang: one statement per line, `name = Expression`. The first line is `root = Card([...])` (or `Stack`); define each child on a later line and refer to it by name. Arguments are positional, in the order below; leave out optional ones at the end, write null to skip one. Strings in double quotes; also numbers, true/false, null, [lists], {key: value}.

    Components (? optional):
    Card(children, variant?: "card"|"sunk"|"clear") · Stack(children, direction?: "row"|"column", gap?: "s"|"m"|"l") · Separator()
    CardHeader(title, subtitle?) · InlineHeader(heading, description?) · TextContent(text, size?: "small"|"default"|"large"|"large-heavy") (Markdown and links work)
    Callout(variant: "info"|"success"|"warning"|"error"|"neutral", title, description) · Tag(text, icon?, size?, variant?: "neutral"|"info"|"success"|"warning"|"danger") · TagBlock(tags) · Image(alt, src)
    Table(columns) with Col(label, values, type?: "string"|"number"): column-oriented, each Col holds its values · EntityList(rows: [{left, right}]): label/value rows
    ListBlock(items, variant?: "number") with ListItem(title, subtitle?, image?, actionLabel?, action?) · Steps(items) with StepsItem(title, details)
    Metric(label, value, change?, caption?) e.g. Metric("Revenue", "$1.2M", "+8%") · Progress(label, value, max?)
    BarChart|LineChart|AreaChart|HorizontalBarChart(labels, series, variant?, xLabel?, yLabel?) with Series(name, values) · PieChart(labels, values, variant?: "pie"|"donut")
    Tabs(items) with TabItem(value, label, children) · Accordion(items) with AccordionItem(value, title, children)
    Button(label, action?, variant?: "primary"|"secondary"|"tertiary") · Buttons(buttons, direction?) · Link(label, url) · FollowUpBlock(items) with FollowUpItem(text)
    Form(name, Buttons([...]), fields) with FormControl(label, input, hint?). Inputs, name first: Input(name, placeholder?, type?: "text"|"email"|"number"|"url", rules?) · TextArea(name, placeholder?, rows?) · Select(name, items, placeholder?) with SelectItem(value, label) · RadioGroup(name, items, defaultValue?) with RadioItem(label, description, value) · Chips(name, "single"|"multiple", items) with ChipItem(value, label) · CheckBoxGroup(name, items) with CheckBoxItem(label, description, name, defaultChecked?) · Slider(name, "continuous"|"discrete", min, max, step?, defaultValue?: [n]) · DatePicker(name)
    rules: {required: true, email: true, min: 1, max: 10, minLength: 2, maxLength: 80}

    Actions: a Button without an action sends its label as the user's next message; in a Form it also sends the form's values (checked against the rules first). @ToAssistant("text") sends that text instead; @OpenUrl("https://...") opens a link. A FollowUpItem sends its text; a ListItem with an action sends too. The view locks once the user acts, and their choice comes back to you as a message.

    Example:
    ```openui
    root = Card([header, chart, picker])
    header = CardHeader("Plans", "Monthly price")
    chart = BarChart(["Basic", "Pro", "Team"], [Series("USD", [8, 20, 45])])
    picker = Buttons([Button("Basic"), Button("Pro", null, "secondary"), Button("Team", null, "secondary")])
    ```
    """
}
