import SwiftUI

// Layout, text and data components of OpenUI's default library, drawn with the app's tokens.

enum OUIStyle {
    static func gap(_ name: String?) -> CGFloat {
        switch name {
        case "none": 0
        case "xs": DS.Spacing.xs
        case "s": DS.Spacing.sm
        case "l": DS.Spacing.lg
        case "xl": DS.Spacing.xl
        case "2xl": DS.Spacing.xxl
        default: DS.Spacing.md
        }
    }

    /// Status colours for callouts, tags and trends.
    static func tone(_ variant: String?, theme: DSTheme) -> Color {
        switch variant {
        case "info": theme.accent
        case "success": theme.success
        case "warning": theme.warning
        case "error", "danger", "destructive": theme.destructive
        default: theme.textSecondary
        }
    }

    static func toneIcon(_ variant: String?) -> String {
        switch variant {
        case "success": "checkmark.circle.fill"
        case "warning": "exclamationmark.triangle.fill"
        case "error", "danger": "xmark.octagon.fill"
        case "info": "info.circle.fill"
        default: "text.bubble.fill"
        }
    }

    /// A Lucide icon name (OpenUI's icon set) as an SF Symbol, for the common ones; an SF Symbol name works as is.
    static func symbol(_ name: String?) -> String? {
        guard let raw = name?.lowercased(), !raw.isEmpty else { return nil }
        let map: [String: String] = [
            "check": "checkmark", "circle-check": "checkmark.circle", "check-circle": "checkmark.circle", "x": "xmark",
            "circle-x": "xmark.circle", "star": "star", "heart": "heart", "info": "info.circle", "alert-triangle": "exclamationmark.triangle",
            "triangle-alert": "exclamationmark.triangle", "alert-circle": "exclamationmark.circle", "calendar": "calendar",
            "clock": "clock", "map-pin": "mappin", "map": "map", "user": "person", "users": "person.2", "mail": "envelope",
            "phone": "phone", "dollar-sign": "dollarsign", "trending-up": "chart.line.uptrend.xyaxis",
            "trending-down": "chart.line.downtrend.xyaxis", "settings": "gearshape", "search": "magnifyingglass",
            "home": "house", "house": "house", "shopping-cart": "cart", "zap": "bolt", "sun": "sun.max", "moon": "moon",
            "cloud": "cloud", "cloud-rain": "cloud.rain", "download": "arrow.down.circle", "external-link": "arrow.up.right.square",
            "plus": "plus", "minus": "minus", "thumbs-up": "hand.thumbsup", "thumbs-down": "hand.thumbsdown",
            "bookmark": "bookmark", "tag": "tag", "globe": "globe", "lock": "lock", "sparkles": "sparkles", "flame": "flame",
            "coffee": "cup.and.saucer", "book": "book", "music": "music.note", "camera": "camera", "image": "photo",
            "file": "doc", "file-text": "doc.text", "folder": "folder", "car": "car", "plane": "airplane", "gift": "gift",
            "award": "rosette", "trophy": "trophy", "rocket": "paperplane", "bell": "bell", "link": "link", "code": "chevron.left.forwardslash.chevron.right",
            "chart": "chart.bar", "bar-chart": "chart.bar", "pie-chart": "chart.pie", "lightbulb": "lightbulb", "leaf": "leaf",
            "utensils": "fork.knife", "train": "tram", "bike": "bicycle", "wifi": "wifi", "battery": "battery.100",
        ]
        if let mapped = map[raw] { return mapped }
        #if canImport(UIKit)
        return UIImage(systemName: raw) != nil ? raw : nil
        #else
        return NSImage(systemSymbolName: raw, accessibilityDescription: nil) != nil ? raw : nil
        #endif
    }
}

// MARK: - Layout

struct OUILayoutNode: View {
    @Environment(\.theme) private var theme
    @Environment(\.ouiStretchesTiles) private var stretches
    let component: OUIComponent
    let scope: OUIScope

    var body: some View {
        let c = component
        switch c.type {
        case "Stack":
            OUIStack(items: c.list("children"), direction: c.string("direction"), gap: c.string("gap"),
                     align: c.string("align"), wrap: c["wrap"]?.truthy == true, scope: scope)
        case "Card":
            let variant = c.string("variant") ?? "card"
            OUIStack(items: c.list("children"), direction: c.string("direction"), gap: c.string("gap"),
                     align: c.string("align"), wrap: c["wrap"]?.truthy == true, scope: scope.surface(variant == "card" || variant == "sunk"))
                .environment(\.ouiStretchesTiles, false)
                .frame(maxHeight: stretches ? .infinity : nil, alignment: .top)
                .padding(variant == "clear" ? 0 : DS.Spacing.lg)
                .background {
                    switch variant {
                    case "clear": Color.clear
                    case "sunk": RoundedRectangle(cornerRadius: DS.Radius.md).fill(theme.quoteFill)
                    default: RoundedRectangle(cornerRadius: DS.Radius.md).fill(scope.onSurface ? theme.background : theme.surface)
                    }
                }
        case "Separator":
            if c.string("orientation") == "vertical" {
                Rectangle().fill(theme.separator).frame(width: 1).frame(maxHeight: .infinity)
            } else {
                Rectangle().fill(theme.separator).frame(height: 1).frame(maxWidth: .infinity)
            }
        case "Tabs":
            OUITabs(items: c.components("items"), scope: scope)
        case "Accordion":
            OUIAccordion(items: c.components("items"), scope: scope)
        case "SectionBlock":
            OUIAccordion(items: c.components("sections"), scope: scope, startsOpen: c["isFoldable"]?.boolValue == false)
        case "TabItem", "AccordionItem", "SectionItem":
            OUIChildren(values: c.list("content"), scope: scope)
        case "Steps":
            OUISteps(items: c.components("items"))
        case "Carousel":
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: DS.Spacing.md) {
                    ForEach(Array(c.list("children").enumerated()), id: \.offset) { _, v in
                        OUIValueView(value: v, scope: scope).frame(width: 260, alignment: .topLeading)
                    }
                }
            }
            .scrollIndicators(.hidden)
        default:
            EmptyView()
        }
    }
}

/// `Stack` and the inside of `Card`: a column, a row that shares its width, or a wrapping row.
struct OUIStack: View {
    let items: [OUIValue]
    var direction: String?
    var gap: String?
    var align: String?
    var wrap = false
    let scope: OUIScope

    var body: some View {
        let spacing = OUIStyle.gap(gap)
        let values = items.filter { !$0.isNull }
        if direction == "row" {
            if wrap {
                FlowLayout(spacing: spacing) { cells(values) }
            } else {
                // Children share the row equally, like flex items; tall ones set the height.
                // Tiles in a row stretch to the tallest one.
                HStack(alignment: align == "center" ? .center : .top, spacing: spacing) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                        OUIValueView(value: v, scope: scope)
                            .environment(\.ouiStretchesTiles, true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: align == "center" ? .center : align == "end" ? .trailing : .leading, spacing: spacing) {
                cells(values)
            }
            .frame(maxWidth: .infinity, alignment: align == "center" ? .center : .leading)
        }
    }

    @ViewBuilder private func cells(_ values: [OUIValue]) -> some View {
        ForEach(Array(values.enumerated()), id: \.offset) { _, v in OUIValueView(value: v, scope: scope) }
    }
}

private struct OUITabs: View {
    @Environment(\.theme) private var theme
    let items: [OUIComponent]
    let scope: OUIScope
    @State private var selected = 0

    var body: some View {
        let index = min(selected, max(0, items.count - 1))
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            ScrollView(.horizontal) {
                HStack(spacing: DS.Spacing.xs) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        Button { selected = i } label: {
                            Text(item.string("trigger") ?? item.string("value") ?? "\(i + 1)")
                                .font(DS.Typography.uiSmall.weight(i == index ? .semibold : .regular))
                                .foregroundStyle(i == index ? theme.textPrimary : theme.textSecondary)
                                .padding(.horizontal, DS.Spacing.md)
                                .padding(.vertical, DS.Spacing.xs + 2)
                                .background(i == index ? theme.fillTertiary : .clear, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
            if items.indices.contains(index) {
                OUIChildren(values: items[index].list("content"), scope: scope)
            }
        }
    }
}

private struct OUIAccordion: View {
    @Environment(\.theme) private var theme
    let items: [OUIComponent]
    let scope: OUIScope
    var startsOpen = false
    @State private var toggled: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let open = toggled.contains(i) != startsOpen
                if i > 0 { Rectangle().fill(theme.separator).frame(height: 1) }
                Button {
                    if toggled.contains(i) { toggled.remove(i) } else { toggled.insert(i) }
                } label: {
                    HStack {
                        Text(item.string("trigger") ?? item.string("value") ?? "")
                            .font(DS.Typography.uiEmphasis)
                            .foregroundStyle(theme.textPrimary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: DS.Spacing.sm)
                        Image(systemName: "chevron.down")
                            .font(.system(size: DS.IconSize.sm, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    .padding(.vertical, DS.Spacing.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open {
                    OUIChildren(values: item.list("content"), scope: scope)
                        .padding(.bottom, DS.Spacing.md)
                }
            }
        }
        .animation(DS.Motion.snappy, value: toggled)
    }
}

private struct OUISteps: View {
    @Environment(\.theme) private var theme
    let items: [OUIComponent]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.md) {
                    Text("\(i + 1)")
                        .font(DS.Typography.uiCaption.weight(.semibold))
                        .foregroundStyle(theme.accentOnTint)
                        .frame(width: 22, height: 22)
                        .background(theme.accentMuted, in: Circle())
                    VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                        Text(item.string("title") ?? "").font(DS.Typography.uiEmphasis).foregroundStyle(theme.textPrimary)
                        if let details = item.string("details") {
                            InlineMarkdownText(source: details, font: DS.Typography.uiSmall, color: theme.textSecondary, leading: .ui,
                                               semiboldStrong: false)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Text and media

struct OUITextNode: View {
    @Environment(\.theme) private var theme
    let component: OUIComponent
    let scope: OUIScope

    var body: some View {
        let c = component
        switch c.type {
        case "CardHeader":
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                if let title = c.string("title") {
                    Text(title).font(DS.Typography.heading(3)).foregroundStyle(theme.textPrimary)
                }
                if let subtitle = c.string("subtitle") {
                    Text(subtitle).font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case "InlineHeader":
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(c.string("heading") ?? "").font(DS.Typography.uiEmphasis).foregroundStyle(theme.textPrimary)
                if let d = c.string("description") {
                    Text(d).font(DS.Typography.uiCaption).foregroundStyle(theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case "TextContent":
            OUIText(text: c.string("text") ?? "", size: c.string("size"))
        case "MarkDownRenderer":
            NoteText(text: c.string("textMarkdown") ?? "")
        case "Callout", "TextCallout":
            OUICallout(variant: c.string("variant"), title: c.string("title"), description: c.string("description"))
        case "Tag":
            OUITag(text: c.string("text") ?? "", icon: c["icon"]?.componentValue?.string("name") ?? c.string("icon"),
                   variant: c.string("variant"), size: c.string("size"))
        case "TagBlock":
            FlowLayout(spacing: DS.Spacing.xs) {
                ForEach(Array(c.list("tags").enumerated()), id: \.offset) { _, t in
                    if let tag = t.componentValue {
                        OUITag(text: tag.string("text") ?? "", icon: tag.string("icon"), variant: tag.string("variant"), size: c.string("size"))
                    } else {
                        OUITag(text: t.stringForm, icon: nil, variant: nil, size: c.string("size"))
                    }
                }
            }
        case "Label":
            Text(c.string("text") ?? "").font(DS.Typography.uiSmall.weight(.medium)).foregroundStyle(theme.textSecondary)
        case "CodeBlock":
            CodeBlockView(content: CodeBlockContent(language: c.string("language") ?? "", code: c.string("codeString") ?? ""))
        case "Icon":
            if let symbol = OUIStyle.symbol(c.string("name")) {
                Image(systemName: symbol).foregroundStyle(theme.textSecondary)
            }
        case "Image", "ImageBlock":
            OUIImage(src: c.string("src"), alt: c.string("alt"))
        case "ImageGallery":
            ScrollView(.horizontal) {
                HStack(spacing: DS.Spacing.sm) {
                    ForEach(Array(c.list("images").enumerated()), id: \.offset) { _, v in
                        OUIImage(src: v.objectValue?["src"]?.text, alt: v.objectValue?["alt"]?.text, width: 180)
                    }
                }
            }
            .scrollIndicators(.hidden)
        default:
            EmptyView()
        }
    }
}

/// `TextContent`: inline Markdown (bold, italics, code, links into the in-app browser) at one of OpenUI's sizes.
struct OUIText: View {
    @Environment(\.theme) private var theme
    let text: String
    var size: String?

    var body: some View {
        switch size {
        case "small":
            InlineMarkdownText(source: text, font: DS.Typography.uiSmall, color: theme.textSecondary, leading: .ui,
                               semiboldStrong: false)
        case "small-heavy":
            InlineMarkdownText(source: text, font: DS.Typography.uiSmall.weight(.semibold), color: theme.textPrimary, leading: .ui,
                               semiboldStrong: false)
        case "large":
            InlineMarkdownText(source: text, font: DS.Typography.heading(2).weight(.regular), color: theme.textPrimary, leading: .heading(2),
                               semiboldStrong: false)
        case "large-heavy":
            InlineMarkdownText(source: text, font: DS.Typography.heading(1), color: theme.textPrimary, leading: .heading(1),
                               semiboldStrong: false)
        default:
            InlineMarkdownText(source: text, font: DS.Typography.answer, color: theme.textPrimary)
        }
    }
}

struct OUICallout: View {
    @Environment(\.theme) private var theme
    var variant: String?
    var title: String?
    var description: String?

    var body: some View {
        let tone = OUIStyle.tone(variant, theme: theme)
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
            Image(systemName: OUIStyle.toneIcon(variant)).foregroundStyle(tone).font(.system(size: DS.IconSize.sm))
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                if let title, !title.isEmpty {
                    Text(title).font(DS.Typography.uiSmall.weight(.semibold)).foregroundStyle(theme.textPrimary)
                }
                if let description, !description.isEmpty {
                    InlineMarkdownText(source: description, font: DS.Typography.uiSmall, color: theme.textPrimary, leading: .ui,
                                       semiboldStrong: false)
                }
            }
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.sm + 2))
    }
}

struct OUITag: View {
    @Environment(\.theme) private var theme
    let text: String
    var icon: String?
    var variant: String?
    var size: String?

    var body: some View {
        let neutral = variant == nil || variant == "neutral"
        let tone = OUIStyle.tone(variant, theme: theme)
        HStack(spacing: DS.Spacing.xxs + 1) {
            if let symbol = OUIStyle.symbol(icon) { Image(systemName: symbol).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(size == "lg" ? DS.Typography.uiSmall.weight(.medium) : DS.Typography.feedBadge.weight(.medium))
        .foregroundStyle(neutral ? theme.textSecondary : tone)
        .padding(.horizontal, size == "lg" ? DS.Spacing.sm + 2 : DS.Spacing.sm)
        .padding(.vertical, size == "lg" ? DS.Spacing.xs : DS.Spacing.xxs + 1)
        .background(neutral ? theme.fillTertiary : tone.opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

struct OUIImage: View {
    @Environment(\.theme) private var theme
    let src: String?
    let alt: String?
    var width: CGFloat?

    var body: some View {
        let url = src.flatMap { URL(string: $0) }.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            default:
                ZStack {
                    theme.surface
                    if case .empty = phase, url != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(alt ?? String(localized: "Image"), systemImage: "photo")
                            .font(DS.Typography.uiCaption)
                            .foregroundStyle(theme.textTertiary)
                            .padding(DS.Spacing.sm)
                    }
                }
                .frame(height: 140)
            }
        }
        .frame(maxWidth: width ?? .infinity, maxHeight: 280)
        .frame(width: width)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .accessibilityLabel(Text(alt ?? ""))
    }
}

// MARK: - Data

struct OUIDataNode: View {
    @Environment(\.theme) private var theme
    let component: OUIComponent
    let scope: OUIScope

    var body: some View {
        let c = component
        switch c.type {
        case "Table":
            OUITable(columns: c.components("columns"), scope: scope)
        case "EntityList":
            OUIEntityList(rows: c.list("rows"), header: c["header"], footer: c["footer"], compact: c.string("size") == "small")
        case "ListBlock":
            OUIListBlock(items: c.components("items"), numbered: c.string("variant") == "number", scope: scope)
        case "Metric":
            OUIMetric(label: c.string("label"), value: c.string("value") ?? "", change: c.string("change"),
                      caption: c.string("caption"), scope: scope)
        case "MetricIndicatorInline", "MetricIndicatorWithStrikethrough":
            let trend = c["trend"]?.objectValue
            let change = trend.map { t -> String in
                let v = OUIValue.format(abs(t["value"]?.toNumber ?? 0))
                return (t["direction"]?.text == "down" ? "−" : "+") + v + "%"
            }
            OUIMetric(label: nil, value: c.string("value") ?? "", change: change, caption: c.string("subtext"),
                      previous: c.string("previousValue"), scope: scope, tile: false)
        case "Progress":
            OUIProgress(label: c.string("label"), value: c.number("value") ?? 0, max: c.number("max") ?? 100)
        default:
            EmptyView()
        }
    }
}

/// `Table([Col(label, data, type)])`: column-oriented. Numeric columns align right; cells may hold components (tags).
private struct OUITable: View {
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    let columns: [OUIComponent]
    let scope: OUIScope

    var body: some View {
        let data = columns.map { $0.list("data") }
        let rows = data.map(\.count).max() ?? 0
        let numeric = columns.indices.map { i in
            columns[i].string("type") == "number"
                || (!data[i].isEmpty && data[i].allSatisfy { if case .number = $0 { true } else { $0.isNull } })
        }
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(columns.indices, id: \.self) { i in
                        cell(.string(columns[i].string("label") ?? ""), numeric: numeric[i], header: true)
                            .gridColumnAlignment(numeric[i] ? .trailing : .leading)
                    }
                }
                ForEach(0..<rows, id: \.self) { r in
                    Rectangle().fill(theme.separator).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow(alignment: .firstTextBaseline) {
                        ForEach(columns.indices, id: \.self) { i in
                            cell(r < data[i].count ? data[i][r] : .null, numeric: numeric[i], header: false)
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            // The outline hugs the columns, so a narrow table doesn't end in an empty band.
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
            .overlay { RoundedRectangle(cornerRadius: DS.Radius.md).stroke(theme.separator, lineWidth: 1) }
            .padding(1)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell(_ value: OUIValue, numeric: Bool, header: Bool) -> some View {
        Group {
            if let c = value.componentValue {
                OUINode(component: c, scope: scope)
            } else {
                CappedWidth(maxWidth: 240 * DS.typeScale(typeSize)) {
                    Text(value.text ?? "")
                        .font(header ? DS.Typography.tableHeader : DS.Typography.tableCell)
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary)
                        .multilineTextAlignment(numeric ? .trailing : .leading)
                        .textSelection(.enabled)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, DS.Spacing.sm)
        .padding(.horizontal, DS.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: numeric ? .topTrailing : .topLeading)
        .background(header ? theme.fillTertiary : Color.clear)
    }
}

/// `EntityList`: label and value rows.
private struct OUIEntityList: View {
    @Environment(\.theme) private var theme
    let rows: [OUIValue]
    var header: OUIValue?
    var footer: OUIValue?
    var compact = false

    var body: some View {
        VStack(spacing: 0) {
            if let header { row(header, emphasis: true) }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                if i > 0 || header != nil { Rectangle().fill(theme.separator).frame(height: 1) }
                row(r, emphasis: false)
            }
            if let footer {
                Rectangle().fill(theme.separator).frame(height: 1)
                row(footer, emphasis: true)
            }
        }
    }

    private func row(_ value: OUIValue, emphasis: Bool) -> some View {
        let o = value.objectValue
        let left = o?["left"]?.text ?? o?["label"]?.text ?? o?["key"]?.text ?? ""
        let right = o?["right"]?.text ?? o?["value"]?.text ?? ""
        return HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.md) {
            Text(left)
                .foregroundStyle(emphasis ? theme.textPrimary : theme.textSecondary)
                .fontWeight(emphasis ? .semibold : .regular)
            Spacer(minLength: DS.Spacing.md)
            Text(right)
                .foregroundStyle(theme.textPrimary)
                .fontWeight(emphasis ? .semibold : .medium)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(compact ? DS.Typography.uiSmall : DS.Typography.tableCell)
        .padding(.vertical, compact ? DS.Spacing.xs + 2 : DS.Spacing.sm + 2)
        .textSelection(.enabled)
    }
}

/// `ListBlock` of `ListItem`s: numbered or with images; an item with an action is a row to tap.
private struct OUIListBlock: View {
    @Environment(\.theme) private var theme
    let items: [OUIComponent]
    let numbered: Bool
    let scope: OUIScope

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                if i > 0 { Rectangle().fill(theme.separator).frame(height: 1).padding(.leading, numbered ? 34 : 0) }
                let action = item["action"]?.actionValue
                if action != nil || item["actionLabel"] != nil {
                    Button { scope.act(action, label: item.string("title") ?? "") } label: { row(item, index: i, tappable: true) }
                        .buttonStyle(.plain)
                        .disabled(scope.locked && !scope.wasChosen(item.string("title") ?? ""))
                } else {
                    row(item, index: i, tappable: false)
                }
            }
        }
    }

    private func row(_ item: OUIComponent, index: Int, tappable: Bool) -> some View {
        let chosen = scope.wasChosen(item.string("title") ?? "")
        return HStack(spacing: DS.Spacing.md) {
            if numbered {
                Text("\(index + 1)")
                    .font(DS.Typography.uiCaption.weight(.semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(theme.fillTertiary, in: Circle())
            } else if let image = item["image"]?.objectValue?["src"]?.text {
                OUIImage(src: image, alt: item["image"]?.objectValue?["alt"]?.text, width: 44)
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                Text(item.string("title") ?? "").font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                if let subtitle = item.string("subtitle") {
                    Text(subtitle).font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
                }
            }
            Spacer(minLength: DS.Spacing.sm)
            if tappable {
                if chosen {
                    Image(systemName: "checkmark").foregroundStyle(theme.accent)
                } else if let label = item.string("actionLabel") {
                    Text(label).font(DS.Typography.uiSmall.weight(.medium)).foregroundStyle(scope.locked ? theme.textTertiary : theme.accent)
                } else {
                    Image(systemName: "chevron.right").font(.system(size: DS.IconSize.sm, weight: .semibold)).foregroundStyle(theme.textTertiary)
                }
            }
        }
        .padding(.vertical, DS.Spacing.sm + 2)
        .contentShape(Rectangle())
    }
}

/// `Metric` (OpenChat's) and OpenUI's metric indicators: a big value, a label, and a coloured change.
private struct OUIMetric: View {
    @Environment(\.theme) private var theme
    @Environment(\.ouiStretchesTiles) private var stretches
    let label: String?
    let value: String
    var change: String?
    var caption: String?
    var previous: String?
    let scope: OUIScope
    var tile = true

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            if let label { Text(label).font(DS.Typography.uiCaption.weight(.medium)).foregroundStyle(theme.textSecondary) }
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
                Text(value)
                    .font(DS.Typography.contextTotal.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let previous {
                    Text(previous).font(DS.Typography.uiSmall).strikethrough().foregroundStyle(theme.textTertiary)
                }
                if let change, !change.isEmpty {
                    Text(change).font(DS.Typography.uiSmall.weight(.semibold)).foregroundStyle(changeColor(change))
                }
            }
            if let caption { Text(caption).font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary) }
        }
        .frame(maxWidth: .infinity, maxHeight: stretches ? .infinity : nil, alignment: .topLeading)
        .padding(tile ? DS.Spacing.md : 0)
        .background(tile ? scope.fill(theme) : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.sm + 2))
        .accessibilityElement(children: .combine)
    }

    private func changeColor(_ change: String) -> Color {
        let t = change.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("+") || t.hasPrefix("▲") || t.hasPrefix("↑") { return theme.success }
        if t.hasPrefix("-") || t.hasPrefix("−") || t.hasPrefix("▼") || t.hasPrefix("↓") { return theme.destructive }
        return theme.textSecondary
    }
}

private struct OUIProgress: View {
    @Environment(\.theme) private var theme
    let label: String?
    let value: Double
    let max: Double

    var body: some View {
        let total = max > 0 ? max : 100
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                if let label { Text(label).foregroundStyle(theme.textPrimary) }
                Spacer()
                Text(total == 100 ? "\(OUIValue.format((value).rounded()))%" : "\(OUIValue.format(value)) / \(OUIValue.format(total))")
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
            }
            .font(DS.Typography.uiSmall)
            ProgressView(value: Swift.min(Swift.max(value, 0), total), total: total)
                .tint(theme.accent)
        }
    }
}

extension EnvironmentValues {
    /// Set on the children of a row: a tile fills the row's height so tiles side by side line up.
    @Entry var ouiStretchesTiles = false
}
