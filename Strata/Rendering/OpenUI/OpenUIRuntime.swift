import Foundation
import Observation

// The live side of an OpenUI view: user state, form fields, validation, actions turned into the next user message,
// what is saved with the message, and the plain text a copied answer gets.

// MARK: - Rendering a program

/// A program evaluated once: the tree to draw and what went wrong.
struct OUIRendered {
    var root: OUIComponent?
    var program: OUIProgram
    /// Statements that didn't parse and names that aren't components or functions.
    var problems: [String]
    var unresolved: Set<String>

    static func make(_ statements: [OUIStatement], problems: [String] = [], state: [String: OUIValue] = [:],
                     library: OUILibrary = .omniChat) -> OUIRendered {
        let program = OUIProgram(statements)
        var evaluator = OUIEvaluator(program: program, library: library, state: state)
        let root = evaluator.root()
        var found = problems
        found += evaluator.unknownComponents.sorted().map { "Unknown component \($0)" }
        found += evaluator.unknownFunctions.sorted().map { "Unknown function @\($0)" }
        if evaluator.overBudget { found.append("Too large to show") }
        return OUIRendered(root: root, program: program, problems: found, unresolved: evaluator.unresolved)
    }

    /// A finished program's source, parsed and evaluated.
    static func make(source: String, state: [String: OUIValue] = [:]) -> OUIRendered {
        var parser = OUIStreamParser()
        parser.update(source)
        return make(parser.statements(final: true), problems: parser.problems(final: true), state: state)
    }
}

// MARK: - Tree

enum OUITree {
    /// The components directly inside `c` (through lists and nested lists), in prop order.
    static func children(_ c: OUIComponent, library: OUILibrary = .omniChat) -> [OUIComponent] {
        if !c.known { return c.args.flatMap(OUIValue.components) }
        let order = library.spec(c.type)?.props ?? []
        return order.compactMap { c.props[$0] }.flatMap(OUIValue.components)
    }

    /// Every component under `c` (itself included), depth first. `stop` prunes a subtree after visiting its top.
    static func walk(_ c: OUIComponent, stop: (OUIComponent) -> Bool = { _ in false }, _ visit: (OUIComponent) -> Void) {
        visit(c)
        guard !stop(c) else { return }
        for child in children(c) { walk(child, stop: stop, visit) }
    }

    /// Nothing to see yet: only cards and stacks with no text inside (a root whose children haven't arrived or failed).
    static func isBlank(_ root: OUIComponent) -> Bool {
        var blank = true
        walk(root) { c in
            guard ["Card", "Stack"].contains(c.type) else { blank = false; return }
            // Text passed straight in as a child renders as text.
            if case .array(let items)? = c["children"], items.contains(where: { $0.componentValue == nil && $0.text != nil }) {
                blank = false
            }
        }
        return blank
    }

    /// Whether the part of the page outside forms has anything that acts on its own (a button, a follow-up, a list
    /// item with an action). Without one, a choice there sends as soon as it's picked.
    static func pageHasActions(_ root: OUIComponent) -> Bool {
        var found = false
        walk(root, stop: { $0.type == "Form" }) { c in
            switch c.type {
            case "Button", "IconButton", "FollowUpItem": found = true
            case "ListItem": if c["action"] != nil { found = true }
            default: break
            }
        }
        return found
    }

    /// The fields of a form (`form` is its name), or of the page outside forms (nil), with their labels.
    static func fields(in root: OUIComponent, form: String?) -> [OUIField] {
        var out: [OUIField] = []
        func collect(_ c: OUIComponent, label: String?, inForm: String?) {
            if c.type == "Form" {
                let name = c.string("name") ?? ""
                for child in children(c) { collect(child, label: nil, inForm: name) }
                return
            }
            if c.type == "FormControl" {
                for child in children(c) { collect(child, label: c.string("label"), inForm: inForm) }
                return
            }
            if OUILibrary.fieldTypes.contains(c.type), inForm == form, let name = c.string("name") {
                if !out.contains(where: { $0.name == name }) {
                    out.append(OUIField(name: name, label: label ?? c.string("label") ?? name, component: c))
                }
                return
            }
            for child in children(c) { collect(child, label: label, inForm: inForm) }
        }
        collect(root, label: nil, inForm: nil)
        return out
    }
}

/// An input in a form or on the page, as the person sees it.
struct OUIField {
    var name: String
    var label: String
    var component: OUIComponent

    /// The default a field starts with, before the person touches it.
    var defaultValue: OUIValue? {
        let c = component
        switch c.type {
        case "RadioGroup": return c["defaultValue"] ?? c["value"]
        case "Chips": return c["defaultValue"]
        case "Slider":
            if let v = c["value"] { return v }
            return c["defaultValue"] ?? c["min"].map { .array([$0]) }
        case "CheckBoxGroup", "SwitchGroup":
            var o = OUIObject()
            for item in c.components("items") {
                if let name = item.string("name") { o.set(name, .bool(item["defaultChecked"]?.boolValue ?? false)) }
            }
            return .object(o)
        case "DatePicker":
            // A date picker always shows a date: today, unless the program gives one.
            if let v = c["value"] { return v }
            let today = OUIField.dayFormatter.string(from: .now)
            return c.string("mode") == "range" ? .array([.string(today), .string(today)]) : .string(today)
        default: return c["value"]
        }
    }

    /// Dates as fields hold them: `2026-10-22`.
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The value in words: an option's label rather than its value, checked boxes by label, a date as written.
    func display(_ value: OUIValue?) -> String? {
        guard let value, !value.isNull else { return nil }
        let c = component
        func optionLabel(_ v: OUIValue) -> String {
            let items = c.components("items")
            let key = v.stringForm
            for item in items {
                switch item.type {
                case "SelectItem", "ChipItem": if item.string("value") == key { return item.string("label") ?? key }
                case "RadioItem": if item.string("value") == key { return item.string("label") ?? key }
                default: break
                }
            }
            return key
        }
        switch c.type {
        case "Select", "RadioGroup":
            return value.stringForm.isEmpty ? nil : optionLabel(value)
        case "Chips":
            let picked = value.arrayValue ?? [value]
            let labels = picked.map(optionLabel).filter { !$0.isEmpty }
            return labels.isEmpty ? nil : labels.joined(separator: ", ")
        case "CheckBoxGroup", "SwitchGroup":
            guard let o = value.objectValue else { return nil }
            let on = c.components("items").filter { item in item.string("name").map { o[$0]?.truthy ?? false } ?? false }
            if c.type == "SwitchGroup" {
                return c.components("items").compactMap { item -> String? in
                    guard let name = item.string("name") else { return nil }
                    return "\(item.string("label") ?? name): \(o[name]?.truthy == true ? "on" : "off")"
                }.joined(separator: ", ")
            }
            return on.isEmpty ? "none" : on.map { $0.string("label") ?? $0.string("name") ?? "" }.joined(separator: ", ")
        case "Slider":
            let numbers = (value.arrayValue ?? [value]).map { OUIValue.format($0.toNumber) }
            return numbers.joined(separator: "–")
        case "DatePicker":
            return (value.arrayValue ?? [value]).map(\.stringForm).filter { !$0.isEmpty }.joined(separator: " to ")
        default:
            let text = value.stringForm.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }
}

// MARK: - Validation

enum OUIValidation {
    /// The first failing rule's message, or nil (spec 5.4). Every rule but `required` skips empty values.
    static func error(_ value: OUIValue?, rules: OUIObject?) -> String? {
        guard let rules else { return nil }
        let v = value ?? .null
        let empty: Bool = {
            switch v {
            case .null: true
            case .string(let s): s.isEmpty
            case .array(let a): a.isEmpty
            case .object(let o): o.keys.isEmpty || !o.values.values.contains { $0.truthy }
            default: false
            }
        }()
        if rules["required"]?.truthy == true, empty { return String(localized: "Required") }
        if empty { return nil }
        let text = v.stringForm
        // No address is longer than 254 bytes, and the length bound keeps the match quick.
        if rules["email"]?.truthy == true,
           text.utf8.count > 254 || text.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) == nil {
            return String(localized: "Enter a valid email address")
        }
        if rules["url"]?.truthy == true {
            let url = URL(string: text)
            if url?.scheme == nil || url?.host() == nil { return String(localized: "Enter a valid URL") }
        }
        if rules["numeric"]?.truthy == true, Double(text.trimmingCharacters(in: .whitespaces).prefix { "0123456789.-+eE".contains($0) }) == nil {
            return String(localized: "Enter a number")
        }
        // The model writes these numbers: one past Int's range is ignored rather than trapping.
        if let n = rules["minLength"]?.numberValue.flatMap({ Int(exactly: $0.rounded(.towardZero)) }), text.count < n {
            return String(localized: "Use at least \(n) characters")
        }
        if let n = rules["maxLength"]?.numberValue.flatMap({ Int(exactly: $0.rounded(.towardZero)) }), text.count > n {
            return String(localized: "Use at most \(n) characters")
        }
        let number = (v.arrayValue?.first ?? v).numberValue
        if let n = rules["min"]?.numberValue, let x = number, x < n { return String(localized: "Must be at least \(OUIValue.format(n))") }
        if let n = rules["max"]?.numberValue, let x = number, x > n { return String(localized: "Must be at most \(OUIValue.format(n))") }
        // No `pattern` rule: a regular expression from the model can backtrack for minutes on the main thread, and
        // nothing stops a match once it runs. The value goes to the model, which can check the format itself.
        return nil
    }
}

// MARK: - Saved state

/// What the person did in a view, saved with the message (`Message.openUIStates`): the view shows it, locked, once a
/// newer message exists, and after a relaunch.
struct OUISavedState: Codable, Equatable, Sendable {
    /// The button, item or choice that sent.
    var label: String?
    /// The form it was in; nil for the page.
    var form: String?
    /// Field values by form name ("" is the page), then field name.
    var fields: [String: [String: OUIValue]] = [:]
    /// `$variables` as they were.
    var state: [String: OUIValue] = [:]
}

/// The follow-up a view sends: the message text and what to save.
struct OUISubmission: Equatable, Sendable {
    var text: String
    var saved: OUISavedState

    /// "Message" then one "- Label: value" line per filled field and per context entry.
    static func text(message: String, values: [(label: String, value: String)], context: OUIValue? = nil) -> String {
        var lines = [message.trimmingCharacters(in: .whitespacesAndNewlines)]
        lines += values.map { "- \($0.label): \($0.value)" }
        switch context {
        case .object(let o)?:
            lines += o.keys.compactMap { key in o[key].flatMap { v in v.isNull ? nil : "- \(key): \(v.stringForm)" } }
        case .array(let a)?:
            lines += a.filter { !$0.isNull }.map { "- \($0.stringForm)" }
        case let v? where !v.isNull:
            lines.append("- \(v.stringForm)")
        default:
            break
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

extension OUIValue: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([OUIValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: OUIValue].self) {
            self = .object(OUIObject(keys: o.keys.sorted(), values: o))
        } else { self = .null }
    }

    /// Plain values only: components and actions are not data and save as null.
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null, .component, .action: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o.values)
        }
    }
}

extension Message {
    /// The views' saved states by block (the fenced block's position in the answer).
    var openUIStates: [Int: OUISavedState] {
        get {
            guard let data = openUIStateData,
                  let map = try? JSONDecoder().decode([String: OUISavedState].self, from: data) else { return [:] }
            return map.reduce(into: [:]) { out, pair in if let k = Int(pair.key) { out[k] = pair.value } }
        }
        set {
            let map = Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), $0.value) })
            openUIStateData = map.isEmpty ? nil : try? JSONEncoder().encode(map)
        }
    }
}

// MARK: - Runtime

/// One view's live state. Kept per message and block (`OUIRuntimeStore`), so it survives the block moving between the
/// streaming tail and the finished document.
@MainActor @Observable
final class OUIRuntime {
    /// `$variables` the person or an action set.
    var state: [String: OUIValue] = [:]
    /// Field values by form name ("" is the page), then field name.
    var fields: [String: [String: OUIValue]] = [:]
    /// Validation messages, same keys.
    var errors: [String: [String: String]] = [:]
    /// Set once the view sent; locks the pressed control's look.
    var saved: OUISavedState?

    @ObservationIgnored private var parser = OUIStreamParser()

    init(saved: OUISavedState? = nil) {
        if let saved { restore(saved) }
    }

    func restore(_ saved: OUISavedState) {
        self.saved = saved
        fields = saved.fields
        state = saved.state
    }

    /// The program so far: completed statements while streaming (a component appears once its line is complete),
    /// everything once the block or the message has ended. Parsing is incremental; nothing observed changes here,
    /// so it is safe to call from a view's body.
    func statements(source: String, final: Bool) -> (statements: [OUIStatement], problems: [String]) {
        parser.update(source)
        return (parser.statements(final: final), parser.problems(final: final))
    }

    func value(form: String?, name: String) -> OUIValue? { fields[form ?? ""]?[name] }

    /// What a field holds now, the same for what it shows, what is checked, what is sent and what is saved. A field
    /// bound to a `$variable` reads it (`@Set` and `@Reset` change only the variable), else its declared default;
    /// any other field reads what the person set, else its default.
    func current(_ field: OUIField, form: String?, program: OUIProgram) -> OUIValue? {
        guard let binding = field.component.bindings["value"] else { return value(form: form, name: field.name) ?? field.defaultValue }
        var evaluator = OUIEvaluator(program: program, state: state)
        let bound = evaluator.stateValue(binding)
        if !bound.isNull { return bound }
        // The component's own `value` is the variable as it was when drawn, which a `@Reset` just before may have cleared.
        var unset = field
        unset.component.props["value"] = nil
        return unset.defaultValue
    }

    func setValue(_ value: OUIValue, form: String?, name: String, binding: String?) {
        fields[form ?? "", default: [:]][name] = value
        if let binding { state[binding] = value }
        errors[form ?? ""]?[name] = nil
    }

    /// Checks the fields of a form (or of the page). Shows the messages; true when all pass.
    func validate(_ fieldsToCheck: [OUIField], form: String?, program: OUIProgram) -> Bool {
        var found: [String: String] = [:]
        for field in fieldsToCheck {
            let current = current(field, form: form, program: program)
            if let message = OUIValidation.error(current, rules: field.component["rules"]?.objectValue) { found[field.name] = message }
        }
        errors[form ?? ""] = found
        return found.isEmpty
    }

    /// Runs an action from a control. `label` is the control's text: a button without an action sends it (OpenUI's
    /// default). Returns the follow-up to send, if a step sends one; `open` receives `@OpenUrl` links.
    func perform(_ action: OUIAction?, label: String, form: String?, rendered: OUIRendered,
                 open: (URL) -> Void) -> OUISubmission? {
        let steps = action?.steps ?? [.toAssistant(message: nil, context: nil)]
        guard let root = rendered.root else { return nil }
        let fieldList = OUITree.fields(in: root, form: form)
        var submission: OUISubmission?
        for step in steps {
            switch step {
            case .set(let name, let expr, let locals):
                var evaluator = OUIEvaluator(program: rendered.program, state: state)
                // Within the budget, so pressing `@Set($x, [$x, $x])` again and again can't grow it without end.
                let value = evaluator.eval(expr, locals: locals)
                state[name] = value.flatMap { $0.weight(limit: OUIEvaluator.Budget.weight) == nil ? nil : $0 } ?? .null
            case .reset(let names):
                for name in names { state[name] = nil }
            case .openURL(let raw):
                if let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil { open(url) }
            case .toAssistant(let message, let context):
                guard submission == nil else { continue }
                if !fieldList.isEmpty, !validate(fieldList, form: form, program: rendered.program) { return nil }
                submission = makeSubmission(message: message ?? label, label: label, form: form, fields: fieldList,
                                            program: rendered.program, context: context)
            case .run, .custom:
                break // no tools or library actions in a chat
            }
        }
        if let submission { saved = submission.saved }
        return submission
    }

    /// A choice picked on a page that has nothing else to press: sends the option's label.
    func choose(_ label: String, field: OUIField, value: OUIValue, binding: String?) -> OUISubmission {
        setValue(value, form: nil, name: field.name, binding: binding)
        let submission = OUISubmission(text: label, saved: snapshot(label: label, form: nil))
        saved = submission.saved
        return submission
    }

    private func makeSubmission(message: String, label: String, form: String?, fields fieldList: [OUIField],
                                program: OUIProgram, context: OUIValue?) -> OUISubmission {
        let currents = fieldList.map { current($0, form: form, program: program) }
        let values = zip(fieldList, currents).compactMap { field, current -> (label: String, value: String)? in
            field.display(current).map { (field.label, $0) }
        }
        // Defaults count as chosen, and bound fields save what they show: the locked view shows what was sent.
        for (field, current) in zip(fieldList, currents) {
            if let current { fields[form ?? "", default: [:]][field.name] = current }
        }
        return OUISubmission(text: OUISubmission.text(message: message, values: values, context: context),
                             saved: snapshot(label: label, form: form))
    }

    private func snapshot(label: String, form: String?) -> OUISavedState {
        OUISavedState(label: label, form: form, fields: fields, state: state)
    }
}

/// The runtimes of the views on screen, by message and block. A plain cache, not observed.
@MainActor
final class OUIRuntimeStore {
    static let shared = OUIRuntimeStore()
    private var runtimes: [String: OUIRuntime] = [:]
    private var order: [String] = []
    private let limit = 64

    func runtime(for key: String, saved: OUISavedState?) -> OUIRuntime {
        if let r = runtimes[key] {
            // Saved elsewhere (another device's copy, a relaunch): the stored choice wins.
            if let saved, r.saved != saved { r.restore(saved) }
            return r
        }
        let r = OUIRuntime(saved: saved)
        runtimes[key] = r
        order.append(key)
        if order.count > limit { runtimes[order.removeFirst()] = nil }
        return r
    }
}

// MARK: - Plain text

/// A view as plain text, for "Copy": headings, text, table rows, values; controls left out.
enum OUIPlainText {
    static func text(source: String) -> String {
        guard let root = OUIRendered.make(source: source).root else { return "" }
        var lines: [String] = []
        render(root, into: &lines)
        return lines.joined(separator: "\n")
    }

    private static func render(_ c: OUIComponent, into lines: inout [String]) {
        func s(_ p: String) -> String? { c.string(p).flatMap { $0.isEmpty ? nil : $0 } }
        func children() { for child in OUITree.children(c) { render(child, into: &lines) } }
        switch c.type {
        case "CardHeader": lines += [s("title"), s("subtitle")].compactMap { $0 }
        case "InlineHeader": lines += [s("heading"), s("description")].compactMap { $0 }
        case "TextContent", "Label": if let t = s("text") { lines.append(t) }
        case "MarkDownRenderer": if let t = s("textMarkdown") { lines.append(t) }
        case "Callout", "TextCallout": lines.append([s("title"), s("description")].compactMap { $0 }.joined(separator: ": "))
        case "Tag": if let t = s("text") { lines.append(t) }
        case "TagBlock": lines.append(c.list("tags").compactMap(\.text).joined(separator: " · "))
        case "CodeBlock": if let t = s("codeString") { lines.append(t) }
        case "Table":
            let cols = c.components("columns")
            lines.append(cols.map { $0.string("label") ?? "" }.joined(separator: " | "))
            let count = cols.map { $0.list("data").count }.max() ?? 0
            for row in 0..<count {
                lines.append(cols.map { col in
                    let data = col.list("data")
                    return row < data.count ? cellText(data[row]) : ""
                }.joined(separator: " | "))
            }
        case "EntityList":
            for row in [c["header"]] + c.list("rows").map(Optional.some) + [c["footer"]] {
                if let o = row?.objectValue { lines.append("\(o["left"]?.stringForm ?? ""): \(o["right"]?.stringForm ?? "")") }
            }
        case "ListBlock":
            for (i, item) in c.components("items").enumerated() {
                let text = [item.string("title"), item.string("subtitle")].compactMap { $0 }.joined(separator: " — ")
                lines.append(c.string("variant") == "number" ? "\(i + 1). \(text)" : "- \(text)")
            }
        case "Steps":
            for (i, item) in c.components("items").enumerated() {
                lines.append("\(i + 1). " + [item.string("title"), item.string("details")].compactMap { $0 }.joined(separator: " — "))
            }
        case "Metric":
            lines.append("\(s("label") ?? ""): \(s("value") ?? "")" + (s("change").map { " (\($0))" } ?? ""))
        case "MetricIndicatorInline", "MetricIndicatorWithStrikethrough":
            lines.append([s("value"), s("subtext")].compactMap { $0 }.joined(separator: " "))
        case "Progress":
            let max = c.number("max") ?? 100
            lines.append("\(s("label") ?? ""): \(OUIValue.format(c.number("value") ?? 0))/\(OUIValue.format(max))")
        case "BarChart", "LineChart", "AreaChart", "HorizontalBarChart", "RadarChart":
            let labels = c.list("labels").map(\.stringForm)
            for series in c.components("series") {
                let values = series.list("values")
                let pairs = labels.indices.map { i in "\(labels[i]) \(i < values.count ? values[i].stringForm : "")" }
                lines.append("\(series.string("category") ?? ""): " + pairs.joined(separator: ", "))
            }
        case "PieChart", "RadialChart", "SingleStackedBarChart":
            let labels = c.list("labels").map(\.stringForm)
            let values = c.list("values")
            lines += labels.indices.map { i in "\(labels[i]): \(i < values.count ? values[i].stringForm : "")" }
        case "Image", "ImageBlock": if let alt = s("alt") { lines.append(alt) }
        case "Link": lines.append([s("label"), s("url").map { "(\($0))" }].compactMap { $0 }.joined(separator: " "))
        case "TabItem", "AccordionItem", "SectionItem":
            if let t = s("trigger") { lines.append(t) }
            children()
        case "Button", "Buttons", "IconButton", "FollowUpBlock", "FollowUpItem", "Form", "Input", "TextArea", "Select",
             "DatePicker", "Slider", "CheckBoxGroup", "RadioGroup", "SwitchGroup", "Chips", "Separator", "Icon":
            break
        default:
            if !c.known { lines += c.args.compactMap(\.text) }
            children()
        }
    }

    private static func cellText(_ v: OUIValue) -> String {
        if let t = v.text { return t }
        if let c = v.componentValue { return c.string("text") ?? c.string("label") ?? c.string("value") ?? "" }
        return v.stringForm
    }
}
