import SwiftUI

// Buttons, links, follow-ups, forms and inputs. A control sends only while its message is the latest; afterwards it
// is disabled and shows what was chosen (`OUIRuntime.saved`).

struct OUIControlNode: View {
    @Environment(\.theme) private var theme
    let component: OUIComponent
    let scope: OUIScope

    var body: some View {
        let c = component
        switch c.type {
        case "Button":
            OUIButton(label: c.string("label") ?? "", action: c["action"]?.actionValue, variant: c.string("variant"),
                      destructive: c.string("type") == "destructive", scope: scope)
        case "IconButton":
            OUIButton(label: c.string("name") ?? "", action: c["action"]?.actionValue, variant: c.string("variant") ?? "secondary",
                      icon: c["icon"]?.componentValue?.string("name") ?? c.string("icon"), scope: scope)
        case "Buttons":
            OUIButtons(buttons: c.list("buttons"), column: c.string("direction") == "column", scope: scope)
        case "Link":
            Button {
                if let url = c.string("url").flatMap(URL.init(string:)) { scope.open(url) }
            } label: {
                HStack(spacing: DS.Spacing.xxs) {
                    Text(c.string("label") ?? c.string("url") ?? "")
                    Image(systemName: "arrow.up.right").imageScale(.small)
                }
                .font(DS.Typography.ui)
                .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
        case "FollowUpBlock":
            OUIFollowUps(items: c.components("items"), scope: scope)
        case "Form":
            OUIForm(component: c, scope: scope.inForm(c.string("name") ?? ""))
        case "FormControl":
            VStack(alignment: .leading, spacing: DS.Spacing.xs + 2) {
                Text(c.string("label") ?? "").font(DS.Typography.uiSmall.weight(.medium)).foregroundStyle(theme.textSecondary)
                if let input = c["input"] { OUIValueView(value: input, scope: scope) }
                if let hint = c.string("hint") {
                    Text(hint).font(DS.Typography.uiCaption).foregroundStyle(theme.textTertiary)
                }
            }
        default:
            OUIInput(component: c, scope: scope)
        }
    }
}

// MARK: - Buttons

/// Capsule buttons: primary (accent), secondary (filled), tertiary (text).
struct OUIButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    var variant: String?
    var destructive = false
    var chosen = false
    var dimmed = false

    func makeBody(configuration: Configuration) -> some View {
        let tone = destructive ? theme.destructive : theme.accent
        let label = configuration.label
            .font(DS.Typography.uiSmall.weight(.semibold))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.sm + 2)
            .frame(minHeight: 40)
        Group {
            switch variant {
            case "secondary":
                label.foregroundStyle(destructive ? tone : theme.textPrimary)
                    .background(chosen ? theme.accentMuted : theme.fillTertiary, in: Capsule())
                    .overlay { if chosen { Capsule().stroke(theme.accent, lineWidth: 1.5) } }
            case "tertiary", "ghost":
                label.foregroundStyle(tone).background(chosen ? theme.accentMuted : .clear, in: Capsule())
            default:
                label.foregroundStyle(theme.onAccent).background(tone, in: Capsule())
            }
        }
        .opacity(configuration.isPressed ? 0.75 : dimmed ? 0.4 : 1)
        .contentShape(Capsule())
    }
}

struct OUIButton: View {
    @Environment(\.theme) private var theme
    let label: String
    let action: OUIAction?
    var variant: String?
    var destructive = false
    var icon: String?
    var fullWidth = false
    let scope: OUIScope

    private var opensOnly: Bool {
        guard let action, !action.steps.isEmpty else { return false }
        return action.steps.allSatisfy { if case .openURL = $0 { true } else { false } }
    }

    var body: some View {
        let chosen = scope.wasChosen(label)
        Button { scope.act(action, label: label) } label: {
            HStack(spacing: DS.Spacing.xs + 2) {
                if chosen {
                    Image(systemName: "checkmark").font(.system(size: DS.IconSize.sm - 1, weight: .bold))
                } else if let symbol = OUIStyle.symbol(icon) {
                    Image(systemName: symbol)
                }
                if icon == nil || chosen || variant != "secondary" || !label.isEmpty { Text(label) }
                if opensOnly { Image(systemName: "arrow.up.right").imageScale(.small) }
            }
            .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(OUIButtonStyle(variant: variant, destructive: destructive, chosen: chosen,
                                    dimmed: scope.locked && !chosen && !opensOnly))
        .disabled(scope.locked && !opensOnly)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

private struct OUIButtons: View {
    let buttons: [OUIValue]
    let column: Bool
    let scope: OUIScope

    var body: some View {
        let list = buttons.flatMap(OUIValue.components)
        if column {
            VStack(spacing: DS.Spacing.sm) {
                ForEach(Array(list.enumerated()), id: \.offset) { _, b in button(b, fullWidth: true) }
            }
        } else {
            FlowLayout(spacing: DS.Spacing.sm) {
                ForEach(Array(list.enumerated()), id: \.offset) { _, b in button(b, fullWidth: false) }
            }
        }
    }

    @ViewBuilder private func button(_ b: OUIComponent, fullWidth: Bool) -> some View {
        if b.type == "Button" {
            OUIButton(label: b.string("label") ?? "", action: b["action"]?.actionValue, variant: b.string("variant"),
                      destructive: b.string("type") == "destructive", fullWidth: fullWidth, scope: scope)
        } else {
            OUINode(component: b, scope: scope)
        }
    }
}

/// Follow-up suggestions at the end of an answer: each sends its text.
private struct OUIFollowUps: View {
    @Environment(\.theme) private var theme
    let items: [OUIComponent]
    let scope: OUIScope

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let text = item.string("text") ?? ""
                let chosen = scope.wasChosen(text)
                if i > 0 { Rectangle().fill(theme.separator).frame(height: 1).padding(.leading, DS.Feed.textInset) }
                Button { scope.act(nil, label: text) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
                        Image(systemName: chosen ? "checkmark" : "arrow.turn.down.right")
                            .font(.system(size: DS.IconSize.sm - 1, weight: .semibold))
                            .foregroundStyle(chosen ? theme.accent : theme.textTertiary)
                            .frame(width: DS.Feed.iconColumn)
                        Text(text)
                            .font(DS.Typography.ui)
                            .foregroundStyle(scope.locked && !chosen ? theme.textTertiary : theme.textPrimary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, DS.Spacing.sm + 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(scope.locked)
            }
        }
    }
}

// MARK: - Forms

private struct OUIForm: View {
    let component: OUIComponent
    let scope: OUIScope

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            OUIChildren(values: component.list("fields"), scope: scope, spacing: DS.Spacing.lg)
            if let buttons = component["buttons"] {
                OUIValueView(value: buttons, scope: scope)
            }
        }
    }
}

/// One input. Its value lives in the runtime under its form and name (and in its `$variable` when bound).
struct OUIInput: View {
    @Environment(\.theme) private var theme
    let component: OUIComponent
    let scope: OUIScope

    private var name: String { component.string("name") ?? "" }
    private var field: OUIField { OUIField(name: name, label: component.string("label") ?? name, component: component) }
    private var binding: String? { component.bindings["value"] }

    /// The current value: the bound state, what the person set, or the default.
    private var current: OUIValue? {
        if binding != nil, let v = component["value"] { return scope.runtime.state[binding!] ?? v }
        return scope.runtime.value(form: scope.form, name: name) ?? field.defaultValue
    }

    private func set(_ value: OUIValue) {
        scope.runtime.setValue(value, form: scope.form, name: name, binding: binding)
    }

    /// A pick that sends at once: outside any form, on a page with nothing else to press.
    private func pick(_ value: OUIValue, label: String) {
        guard scope.interactive else { return }
        if scope.form == nil && scope.autoSendChoices {
            scope.send(scope.runtime.choose(label, field: field, value: value, binding: binding))
        } else {
            set(value)
        }
    }

    var body: some View {
        let error = scope.runtime.errors[scope.form ?? ""]?[name]
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            input
            if let error {
                Text(error).font(DS.Typography.uiCaption).foregroundStyle(theme.destructive)
            }
        }
        .disabled(scope.locked)
    }

    @ViewBuilder private var input: some View {
        let c = component
        switch c.type {
        case "Input", "TextArea":
            textField(multiline: c.type == "TextArea")
        case "Select":
            select
        case "RadioGroup":
            options(c.components("items").map { ($0.string("value") ?? $0.string("label") ?? "", $0.string("label") ?? "", $0.string("description")) },
                    multiple: false)
        case "Chips":
            chips
        case "CheckBoxGroup", "SwitchGroup":
            toggles(switches: c.type == "SwitchGroup")
        case "Slider":
            slider
        case "DatePicker":
            datePicker
        default:
            EmptyView()
        }
    }

    private func fieldBox<Content: View>(_ content: Content) -> some View {
        content
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm + 2)
            .background(scope.fill(theme), in: RoundedRectangle(cornerRadius: DS.Radius.sm + 2))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.sm + 2)
                    .stroke(scope.runtime.errors[scope.form ?? ""]?[name] != nil ? theme.destructive : theme.separator, lineWidth: 1)
            }
    }

    @ViewBuilder private func textField(multiline: Bool) -> some View {
        let text = Binding<String>(get: { current?.text ?? "" }, set: { set(.string($0)) })
        let placeholder = component.string("placeholder") ?? ""
        let type = component.string("type")
        fieldBox(
            Group {
                if multiline {
                    let rows = max(2, Int(component.number("rows") ?? 3))
                    TextField(placeholder, text: text, axis: .vertical).lineLimit(rows...max(rows, 8))
                } else if type == "password" {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .font(DS.Typography.ui)
            .foregroundStyle(theme.textPrimary)
            .textFieldStyle(.plain)
            #if os(iOS)
            .keyboardType(type == "email" ? .emailAddress : type == "number" ? .decimalPad : type == "url" ? .URL : .default)
            .textInputAutocapitalization(type == "email" || type == "url" ? .never : .sentences)
            #endif
            .autocorrectionDisabled(type == "email" || type == "url")
        )
    }

    private var select: some View {
        let items = component.components("items")
        let selected = current?.stringForm
        let label = items.first { $0.string("value") == selected }?.string("label")
        return Menu {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let value = item.string("value") ?? item.string("label") ?? ""
                Button {
                    pick(.string(value), label: item.string("label") ?? value)
                } label: {
                    if value == selected { Label(item.string("label") ?? value, systemImage: "checkmark") } else { Text(item.string("label") ?? value) }
                }
            }
        } label: {
            fieldBox(
                HStack {
                    Text(label ?? component.string("placeholder") ?? String(localized: "Choose"))
                        .foregroundStyle(label == nil ? theme.textTertiary : theme.textPrimary)
                    Spacer(minLength: DS.Spacing.sm)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: DS.IconSize.sm - 2, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                }
                .font(DS.Typography.ui)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    /// Radio rows (one choice).
    private func options(_ items: [(value: String, label: String, description: String?)], multiple: Bool) -> some View {
        let selected = current?.stringForm
        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let on = item.value == selected
                Button { pick(.string(item.value), label: item.label) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm + 2) {
                        Image(systemName: on ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(on ? theme.accent : theme.textTertiary)
                        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                            Text(item.label).font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                            if let d = item.description, !d.isEmpty {
                                Text(d).font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, DS.Spacing.xs)
                    .contentShape(Rectangle())
                    .opacity(scope.locked && !on ? 0.5 : 1)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var chips: some View {
        let multiple = component.string("type") == "multiple"
        let picked: [String] = (current?.arrayValue ?? current.map { [$0] } ?? []).map(\.stringForm)
        return FlowLayout(spacing: DS.Spacing.sm) {
            ForEach(Array(component.components("items").enumerated()), id: \.offset) { _, item in
                let value = item.string("value") ?? item.string("label") ?? ""
                let label = item.string("label") ?? value
                let on = picked.contains(value)
                Button {
                    if multiple {
                        var next = picked
                        if on { next.removeAll { $0 == value } } else { next.append(value) }
                        set(.array(next.map(OUIValue.string)))
                    } else {
                        pick(.string(value), label: label)
                    }
                } label: {
                    HStack(spacing: DS.Spacing.xxs + 1) {
                        if on { Image(systemName: "checkmark").font(.system(size: DS.IconSize.sm - 3, weight: .bold)) }
                        Text(label)
                    }
                    .font(DS.Typography.uiSmall.weight(.medium))
                    .foregroundStyle(on ? theme.accentOnTint : theme.textPrimary)
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.xs + 2)
                    .background(on ? theme.accentMuted : scope.fill(theme), in: Capsule())
                    .overlay { Capsule().stroke(on ? theme.accent.opacity(0.6) : theme.separator, lineWidth: 1) }
                    .opacity(scope.locked && !on ? 0.5 : 1)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(item["disabled"]?.truthy == true)
            }
        }
    }

    private func toggles(switches: Bool) -> some View {
        let values = current?.objectValue ?? OUIObject()
        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            ForEach(Array(component.components("items").enumerated()), id: \.offset) { _, item in
                let key = item.string("name") ?? item.string("label") ?? ""
                let on = values[key]?.truthy ?? false
                let toggle = {
                    var next = values
                    next.set(key, .bool(!on))
                    set(.object(next))
                }
                if switches {
                    Toggle(isOn: Binding(get: { on }, set: { _ in toggle() })) { itemLabel(item) }
                        .tint(theme.accent)
                } else {
                    Button(action: toggle) {
                        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm + 2) {
                            Image(systemName: on ? "checkmark.square.fill" : "square")
                                .foregroundStyle(on ? theme.accent : theme.textTertiary)
                            itemLabel(item)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, DS.Spacing.xs)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func itemLabel(_ item: OUIComponent) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            Text(item.string("label") ?? item.string("name") ?? "").font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
            if let d = item.string("description"), !d.isEmpty {
                Text(d).font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
            }
        }
    }

    private var slider: some View {
        let lower = component.number("min") ?? 0
        let upper = max(component.number("max") ?? 100, lower + 1)
        let step = component.number("step") ?? (component.string("variant") == "discrete" ? 1 : nil)
        let value = Binding<Double>(
            get: { min(max((current?.arrayValue?.first ?? current)?.toNumber ?? lower, lower), upper) },
            set: { set(.array([.number(step == nil ? ($0 * 100).rounded() / 100 : $0)])) })
        let shown = Text(OUIValue.format(value.wrappedValue)).font(DS.Typography.uiSmall.weight(.semibold)).monospacedDigit()
            .foregroundStyle(theme.textPrimary)
        let bar = Group {
            if let step {
                Slider(value: value, in: lower...upper, step: step).tint(theme.accent)
            } else {
                Slider(value: value, in: lower...upper).tint(theme.accent)
            }
        }
        // With its own label the value sits on the label's line; otherwise beside the bar (the field label is above).
        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            if let label = component.string("label") {
                HStack {
                    Text(label).font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
                    Spacer()
                    shown
                }
                bar
            } else {
                HStack(spacing: DS.Spacing.md) {
                    bar
                    shown.frame(minWidth: 28, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder private var datePicker: some View {
        let format = OUIField.dayFormatter
        if component.string("mode") == "range" {
            let parts = current?.arrayValue ?? []
            let date = { (i: Int) in parts.indices.contains(i) ? format.date(from: parts[i].stringForm) ?? .now : .now }
            HStack(spacing: DS.Spacing.sm) {
                DatePicker("", selection: Binding(get: { date(0) }, set: { set(.array([.string(format.string(from: $0)), .string(format.string(from: max($0, date(1))))])) }),
                           displayedComponents: .date).labelsHidden()
                Text("to").font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
                DatePicker("", selection: Binding(get: { date(1) }, set: { set(.array([.string(format.string(from: min($0, date(0)))), .string(format.string(from: $0))])) }),
                           displayedComponents: .date).labelsHidden()
            }
            .tint(theme.accent)
        } else {
            DatePicker("", selection: Binding(get: { current.flatMap { format.date(from: $0.stringForm) } ?? .now },
                                              set: { set(.string(format.string(from: $0))) }),
                       displayedComponents: .date)
                .labelsHidden()
                .tint(theme.accent)
        }
    }
}
