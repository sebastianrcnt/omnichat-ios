import Foundation

// Evaluation of a parsed OpenUI Lang program into a tree of components (spec 1.0, language.md sections 2, 3 and 6).
// No tools here: `Query` shows its defaults and `Mutation` stays idle.

// MARK: - Values

struct OUIObject: Equatable, Sendable {
    var keys: [String] = []
    var values: [String: OUIValue] = [:]

    subscript(key: String) -> OUIValue? { values[key] }

    mutating func set(_ key: String, _ value: OUIValue) {
        if values[key] == nil { keys.append(key) }
        values[key] = value
    }
}

/// A component instance: its type and props mapped by name from the library's positional order.
struct OUIComponent: Equatable, Sendable {
    var type: String
    var props: [String: OUIValue]
    /// Props passed a `$variable`: two-way bound to that state.
    var bindings: [String: String] = [:]
    /// Not in the library: rendered as its text and component arguments (`args`).
    var known = true
    var args: [OUIValue] = []

    subscript(_ prop: String) -> OUIValue? { props[prop] }
    func string(_ prop: String) -> String? { props[prop]?.text }
    /// Nil for NaN and infinity too (0/0, 1e400): sizes, ranges and counts made from them would trap.
    func number(_ prop: String) -> Double? { props[prop]?.numberValue.flatMap { $0.isFinite ? $0 : nil } }
    func list(_ prop: String) -> [OUIValue] { props[prop]?.arrayValue ?? [] }
    func components(_ prop: String) -> [OUIComponent] { props[prop].map(OUIValue.components) ?? [] }
}

/// One step of an action. `@Set` keeps its expression, evaluated when the action runs.
enum OUIStep: Equatable, Sendable {
    case toAssistant(message: String?, context: OUIValue?)
    case openURL(String)
    case set(String, OUIExpr, locals: [String: OUIValue])
    case reset([String])
    case run(String)
    /// A library action: none are defined, so the host ignores it.
    case custom(String, [OUIValue])
}

struct OUIAction: Equatable, Sendable {
    var steps: [OUIStep]
}

indirect enum OUIValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([OUIValue])
    case object(OUIObject)
    case component(OUIComponent)
    case action(OUIAction)

    var isNull: Bool { self == .null }

    /// Text for display: strings as is, numbers without a needless ".0", booleans as words.
    var text: String? {
        switch self {
        case .string(let s): s
        case .number(let d): Self.format(d)
        case .bool(let b): b ? "true" : "false"
        default: nil
        }
    }

    var numberValue: Double? {
        switch self {
        case .number(let d): d
        case .string(let s): Double(s.trimmingCharacters(in: .whitespaces))
        case .bool(let b): b ? 1 : 0
        default: nil
        }
    }

    var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    var arrayValue: [OUIValue]? { if case .array(let a) = self { a } else { nil } }
    var objectValue: OUIObject? { if case .object(let o) = self { o } else { nil } }
    var componentValue: OUIComponent? { if case .component(let c) = self { c } else { nil } }
    var actionValue: OUIAction? { if case .action(let a) = self { a } else { nil } }

    /// The components in a value: itself, or the components of an array (nested arrays flattened).
    static func components(_ value: OUIValue) -> [OUIComponent] {
        switch value {
        case .component(let c): [c]
        case .array(let items): items.flatMap(components)
        default: []
        }
    }

    /// ECMAScript `Number::toString` for the values models write: integers without a fraction.
    static func format(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
        if d == d.rounded(), abs(d) < 1e21 { return String(format: "%.0f", d) }
        var s = String(d)
        if s.hasSuffix(".0") { s.removeLast(2) }
        return s
    }

    // ECMAScript coercions (spec 3.1).

    var toNumber: Double {
        switch self {
        case .number(let d): d
        case .bool(let b): b ? 1 : 0
        case .string(let s):
            s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : (Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        default: 0
        }
    }

    var truthy: Bool {
        switch self {
        case .null: false
        case .bool(let b): b
        case .number(let d): d != 0 && !d.isNaN
        case .string(let s): !s.isEmpty
        default: true
        }
    }

    /// String form for `+` and comparisons of strings.
    var stringForm: String {
        switch self {
        case .null: ""
        case .string(let s): s
        case .number(let d): Self.format(d)
        case .bool(let b): b ? "true" : "false"
        case .array(let a): a.map(\.stringForm).joined(separator: ",")
        case .object, .component, .action: "[object Object]"
        }
    }

    /// `IsLooselyEqual` for the value kinds the language has.
    static func looselyEqual(_ a: OUIValue, _ b: OUIValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.null, _), (_, .null): return false
        case (.string(let x), .string(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.bool, _), (_, .bool), (.number, .string), (.string, .number):
            if case .bool = a { return looselyEqual(.number(a.toNumber), b) }
            if case .bool = b { return looselyEqual(a, .number(b.toNumber)) }
            return a.toNumber == b.toNumber
        default: return a == b
        }
    }
}

// MARK: - Library

/// A component's props in positional order.
struct OUIComponentSpec: Sendable {
    var props: [String]
    /// Props that take a `$variable` two ways (`$binding<type>` in OpenUI signatures).
    var bindable: Set<String> = []
}

struct OUILibrary: Sendable {
    var components: [String: OUIComponentSpec]
    /// Components a program without a `root` statement may start from.
    var roots: [String]
    /// Other names models write for a component.
    var aliases: [String: String] = [:]

    func spec(_ name: String) -> OUIComponentSpec? { components[aliases[name] ?? name] }
    func canonical(_ name: String) -> String { aliases[name] ?? name }
}

extension OUILibrary {
    /// The components OpenChat renders, with the prop order of OpenUI's default library (`@openuidev/react-ui`) where
    /// it has them, so programs written from its docs work. `Metric`, `Progress` and `Link` are OpenChat's own.
    static let openChat = OUILibrary(components: [
        // Layout
        "Stack": .init(props: ["children", "direction", "gap", "align", "justify", "wrap"]),
        "Card": .init(props: ["children", "variant", "direction", "gap", "align", "justify", "wrap"]),
        "CardHeader": .init(props: ["title", "subtitle"]),
        "InlineHeader": .init(props: ["heading", "description"]),
        "Separator": .init(props: ["orientation", "decorative"]),
        "Tabs": .init(props: ["items"]),
        "TabItem": .init(props: ["value", "trigger", "content"]),
        "Accordion": .init(props: ["items"]),
        "AccordionItem": .init(props: ["value", "trigger", "content"]),
        "SectionBlock": .init(props: ["sections", "isFoldable"]),
        "SectionItem": .init(props: ["value", "trigger", "content"]),
        "Steps": .init(props: ["items"]),
        "StepsItem": .init(props: ["title", "details"]),
        "Carousel": .init(props: ["children"]),
        // Text
        "TextContent": .init(props: ["text", "size"]),
        "MarkDownRenderer": .init(props: ["textMarkdown", "variant"]),
        "Callout": .init(props: ["variant", "title", "description", "visible"], bindable: ["visible"]),
        "TextCallout": .init(props: ["variant", "title", "description"]),
        "Tag": .init(props: ["text", "icon", "size", "variant"]),
        "TagBlock": .init(props: ["tags", "size"]),
        "Label": .init(props: ["text"]),
        "CodeBlock": .init(props: ["language", "codeString"]),
        "Icon": .init(props: ["name", "category"]),
        // Data
        "Table": .init(props: ["columns"]),
        "Col": .init(props: ["label", "data", "type"]),
        "EntityList": .init(props: ["rows", "size", "header", "footer"]),
        "ListBlock": .init(props: ["items", "variant", "size"]),
        "ListItem": .init(props: ["title", "subtitle", "image", "actionLabel", "action"]),
        "MetricIndicatorInline": .init(props: ["value", "subtext", "trend"]),
        "MetricIndicatorWithStrikethrough": .init(props: ["value", "subtext", "previousValue", "trend"]),
        "Metric": .init(props: ["label", "value", "change", "caption"]),
        "Progress": .init(props: ["label", "value", "max"]),
        // Charts
        "BarChart": .init(props: ["labels", "series", "variant", "xLabel", "yLabel", "height"]),
        "LineChart": .init(props: ["labels", "series", "variant", "xLabel", "yLabel", "height"]),
        "AreaChart": .init(props: ["labels", "series", "variant", "xLabel", "yLabel", "height"]),
        "HorizontalBarChart": .init(props: ["labels", "series", "variant", "xLabel", "yLabel"]),
        "RadarChart": .init(props: ["labels", "series"]),
        "Series": .init(props: ["category", "values"]),
        "PieChart": .init(props: ["labels", "values", "variant", "appearance"]),
        "RadialChart": .init(props: ["labels", "values"]),
        "SingleStackedBarChart": .init(props: ["labels", "values"]),
        "Slice": .init(props: ["category", "value"]),
        "ScatterChart": .init(props: ["datasets", "xLabel", "yLabel"]),
        "ScatterSeries": .init(props: ["name", "points"]),
        "Point": .init(props: ["x", "y", "z"]),
        // Media
        "Image": .init(props: ["alt", "src"]),
        "ImageBlock": .init(props: ["src", "alt"]),
        "ImageGallery": .init(props: ["images"]),
        // Interactive
        "Button": .init(props: ["label", "action", "variant", "type", "size"]),
        "Buttons": .init(props: ["buttons", "direction"]),
        "IconButton": .init(props: ["name", "icon", "action", "variant", "size", "shape"]),
        "Link": .init(props: ["label", "url"]),
        "FollowUpBlock": .init(props: ["items"]),
        "FollowUpItem": .init(props: ["text"]),
        "Form": .init(props: ["name", "buttons", "fields"]),
        "FormControl": .init(props: ["label", "input", "hint"]),
        "Input": .init(props: ["name", "placeholder", "type", "rules", "value"], bindable: ["value"]),
        "TextArea": .init(props: ["name", "placeholder", "rows", "rules", "value"], bindable: ["value"]),
        "Select": .init(props: ["name", "items", "placeholder", "rules", "value", "size"], bindable: ["value"]),
        "SelectItem": .init(props: ["value", "label"]),
        "DatePicker": .init(props: ["name", "mode", "rules", "value"], bindable: ["value"]),
        "Slider": .init(props: ["name", "variant", "min", "max", "step", "defaultValue", "label", "rules", "value"], bindable: ["value"]),
        "CheckBoxGroup": .init(props: ["name", "items", "rules", "value"], bindable: ["value"]),
        "CheckBoxItem": .init(props: ["label", "description", "name", "defaultChecked"]),
        "RadioGroup": .init(props: ["name", "items", "defaultValue", "rules", "value"], bindable: ["value"]),
        "RadioItem": .init(props: ["label", "description", "value"]),
        "SwitchGroup": .init(props: ["name", "items", "variant", "value"], bindable: ["value"]),
        "SwitchItem": .init(props: ["label", "description", "name", "defaultChecked"]),
        "Chips": .init(props: ["name", "type", "items", "rules", "defaultValue"]),
        "ChipItem": .init(props: ["value", "label", "icon", "disabled"]),
    ], roots: ["Card", "Stack"], aliases: ["Header": "CardHeader", "Divider": "Separator", "Badge": "Tag"])

    /// Input components: their first prop is the field name.
    static let fieldTypes: Set<String> = ["Input", "TextArea", "Select", "DatePicker", "Slider", "CheckBoxGroup",
                                          "RadioGroup", "SwitchGroup", "Chips"]
}

// MARK: - Program

/// The statements of a program by name (a later definition wins), and its entry.
struct OUIProgram: Sendable {
    var statements: [String: OUIStatement] = [:]
    /// Names in order of first definition.
    var order: [String] = []

    init(_ list: [OUIStatement]) {
        for s in list {
            if statements[s.name] == nil { order.append(s.name) }
            statements[s.name] = s
        }
    }

    /// `root`, or the first value statement that calls one of the library's root components.
    func entry(library: OUILibrary) -> String? {
        if statements["root"] != nil { return "root" }
        return order.first { name in
            guard let s = statements[name], s.kind == .value, case .call(let type, _) = s.expr else { return false }
            return library.roots.contains(library.canonical(type))
        }
    }

    var stateDefaults: [String: OUIExpr] {
        statements.values.filter { $0.kind == .state }.reduce(into: [:]) { $0[$1.name] = $1.expr }
    }
}

// MARK: - Evaluator

/// Evaluates expressions against a program and the user's state. A reference to a missing statement is nil
/// ("not yet"), left out of arrays and rendered as nothing.
struct OUIEvaluator {
    let program: OUIProgram
    let library: OUILibrary
    /// `$variables` the user or an action set. Others read their declared default.
    var state: [String: OUIValue] = [:]

    private(set) var unresolved: Set<String> = []
    private(set) var unknownComponents: Set<String> = []
    private(set) var unknownFunctions: Set<String> = []
    private var memo: [String: OUIValue?] = [:]
    private var visiting: Set<String> = []

    init(program: OUIProgram, library: OUILibrary = .openChat, state: [String: OUIValue] = [:]) {
        self.program = program
        self.library = library
        self.state = state
    }

    /// The rendered tree: the entry statement's value, when it is a component.
    mutating func root() -> OUIComponent? {
        guard let entry = program.entry(library: library) else { return nil }
        return reference(entry)?.componentValue
    }

    /// A `$variable`'s value: what the user set, else its declared default, else null.
    mutating func stateValue(_ name: String) -> OUIValue {
        if let v = state[name] { return v }
        if let s = program.statements[name], s.kind == .state {
            return memoized(name) { $0.eval(s.expr, locals: [:]) ?? .null } ?? .null
        }
        return .null
    }

    mutating func reference(_ name: String) -> OUIValue? {
        guard let s = program.statements[name] else {
            unresolved.insert(name)
            return nil
        }
        if s.kind == .state { return stateValue(name) }
        return memoized(name) { me -> OUIValue? in
            switch s.kind {
            case .query:
                return me.queryDefaults(s.expr)
            case .mutation:
                return .object(OUIObject(keys: ["status", "data", "error"],
                                         values: ["status": .string("idle"), "data": .null, "error": .null]))
            default:
                return me.eval(s.expr, locals: [:])
            }
        }
    }

    private mutating func memoized(_ name: String, _ make: (inout OUIEvaluator) -> OUIValue?) -> OUIValue? {
        if let cached = memo[name] { return cached }
        guard !visiting.contains(name) else { return nil } // a cycle: unresolved here
        visiting.insert(name)
        let value = make(&self)
        visiting.remove(name)
        memo[name] = value
        return value
    }

    /// `Query(tool, args, defaults)`: no tools in a chat, so the defaults.
    private mutating func queryDefaults(_ expr: OUIExpr) -> OUIValue {
        guard case .call(_, let args) = expr, args.count >= 3 else { return .null }
        return eval(args[2].value, locals: [:]) ?? .null
    }

    /// The value of `expr`, or nil for nothing (an unresolved reference, a cycle, an inline `Query`).
    mutating func eval(_ expr: OUIExpr, locals: [String: OUIValue]) -> OUIValue? {
        switch expr {
        case .string(let s): return .string(s)
        case .number(let d): return .number(d)
        case .bool(let b): return .bool(b)
        case .null: return .null
        case .array(let items):
            return .array(items.compactMap { item in
                // Unresolved references and dropped components are left out of arrays.
                eval(item, locals: locals)
            })
        case .object(let entries):
            var o = OUIObject()
            for e in entries { o.set(e.key, eval(e.value, locals: locals) ?? .null) }
            return .object(o)
        case .ref(let name):
            if let local = locals[name] { return local }
            return reference(name)
        case .state(let name):
            return stateValue(name)
        case .assign(_, let value):
            return eval(value, locals: locals)
        case .call(let name, let args):
            return call(name, args, locals: locals)
        case .function(let name, let args):
            return function(name, args, locals: locals)
        case .unary(let op, let e):
            let v = eval(e, locals: locals) ?? .null
            return op == "!" ? .bool(!v.truthy) : .number(-v.toNumber)
        case .binary(let op, let l, let r):
            return binary(op, l, r, locals: locals)
        case .ternary(let c, let a, let b):
            return (eval(c, locals: locals) ?? .null).truthy ? eval(a, locals: locals) : eval(b, locals: locals)
        case .member(let e, let field):
            return member(eval(e, locals: locals) ?? .null, field)
        case .index(let e, let i):
            let base = eval(e, locals: locals) ?? .null
            let key = eval(i, locals: locals) ?? .null
            switch base {
            case .array(let a):
                // `Int(exactly:)`: NaN, infinities and numbers past Int ("[1e100]") index nothing instead of trapping.
                guard let n = Int(exactly: key.toNumber.rounded(.towardZero)) else { return .null }
                return a.indices.contains(n) ? a[n] : .null
            case .object(let o):
                return key.isNull ? .null : (o[key.stringForm] ?? .null)
            default:
                return .null
            }
        }
    }

    private func member(_ base: OUIValue, _ field: String) -> OUIValue {
        switch base {
        case .object(let o): return o[field] ?? .null
        case .array(let a):
            if field == "length" { return .number(Double(a.count)) }
            // Pluck: the field of each element; a digit field of a list element is its index (`rows.0`).
            return .array(a.map { element in
                switch element {
                case .object(let o): return o[field] ?? .null
                case .array(let inner): return Int(field).flatMap { inner.indices.contains($0) ? inner[$0] : nil } ?? .null
                default: return .null
                }
            })
        default: return .null
        }
    }

    private mutating func binary(_ op: String, _ l: OUIExpr, _ r: OUIExpr, locals: [String: OUIValue]) -> OUIValue {
        let a = eval(l, locals: locals) ?? .null
        switch op {
        case "&&": return a.truthy ? (eval(r, locals: locals) ?? .null) : a
        case "||": return a.truthy ? a : (eval(r, locals: locals) ?? .null)
        default: break
        }
        let b = eval(r, locals: locals) ?? .null
        switch op {
        case "+":
            if case .string = a { return .string(a.stringForm + b.stringForm) }
            if case .string = b { return .string(a.stringForm + b.stringForm) }
            return .number(a.toNumber + b.toNumber)
        case "-": return .number(a.toNumber - b.toNumber)
        case "*": return .number(a.toNumber * b.toNumber)
        case "/": return .number(b.toNumber == 0 ? 0 : a.toNumber / b.toNumber)
        case "%": return .number(b.toNumber == 0 ? 0 : a.toNumber.truncatingRemainder(dividingBy: b.toNumber))
        case "==": return .bool(OUIValue.looselyEqual(a, b))
        case "!=": return .bool(!OUIValue.looselyEqual(a, b))
        case ">": return .bool(a.toNumber > b.toNumber)
        case "<": return .bool(a.toNumber < b.toNumber)
        case ">=": return .bool(a.toNumber >= b.toNumber)
        case "<=": return .bool(a.toNumber <= b.toNumber)
        default: return .null
        }
    }

    // MARK: Components

    private mutating func call(_ rawName: String, _ args: [OUIArgument], locals: [String: OUIValue]) -> OUIValue? {
        switch rawName {
        case "Query", "Mutation": return nil // only valid as a whole statement
        case "Action":
            let steps = args.flatMap { arg -> [OUIStep] in
                Self.actionSteps(eval(arg.value, locals: locals) ?? .null)
            }
            return .action(OUIAction(steps: steps))
        default: break
        }
        let name = library.canonical(rawName)
        guard let spec = library.spec(name) else {
            unknownComponents.insert(rawName)
            let values = args.compactMap { eval($0.value, locals: locals) }
            return .component(OUIComponent(type: rawName, props: [:], known: false, args: values))
        }
        var props: [String: OUIValue] = [:]
        var bindings: [String: String] = [:]
        var position = 0
        for arg in args {
            let prop: String
            if let label = arg.label {
                guard spec.props.contains(label) else { continue }
                prop = label
            } else {
                // `null` skips an optional argument; extra arguments are dropped.
                guard position < spec.props.count else { break }
                prop = spec.props[position]
                position += 1
            }
            if case .state(let s) = arg.value, spec.bindable.contains(prop) { bindings[prop] = s }
            if let v = eval(arg.value, locals: locals), !v.isNull { props[prop] = v }
        }
        // Chat library's `Card(children, sources)`: a list where the variant goes is the sources strip, not shown.
        if name == "Card", props["variant"]?.arrayValue != nil { props["variant"] = nil }
        return .component(OUIComponent(type: name, props: props, bindings: bindings))
    }

    // MARK: Functions and actions

    static func actionSteps(_ value: OUIValue) -> [OUIStep] {
        switch value {
        case .action(let a): a.steps
        case .array(let items): items.flatMap(actionSteps)
        default: []
        }
    }

    private static func stateName(_ arg: OUIArgument?) -> String? {
        if case .state(let s)? = arg?.value { return s }
        return nil
    }

    private mutating func function(_ name: String, _ args: [OUIArgument], locals: [String: OUIValue]) -> OUIValue? {
        switch name {
        case "ToAssistant":
            let message = args.first.flatMap { eval($0.value, locals: locals) }?.text
            let context = args.count > 1 ? eval(args[1].value, locals: locals) : nil
            return .action(OUIAction(steps: [.toAssistant(message: message, context: context)]))
        case "OpenUrl":
            let url = args.first.flatMap { eval($0.value, locals: locals) }?.text ?? ""
            return .action(OUIAction(steps: [.openURL(url)]))
        case "Set":
            guard let target = Self.stateName(args.first) else { return .action(OUIAction(steps: [])) }
            let value = args.count > 1 ? args[1].value : .null
            return .action(OUIAction(steps: [.set(target, value, locals: locals)]))
        case "Reset":
            return .action(OUIAction(steps: [.reset(args.compactMap { Self.stateName($0) })]))
        case "Run":
            if case .ref(let target)? = args.first?.value { return .action(OUIAction(steps: [.run(target)])) }
            return .action(OUIAction(steps: []))
        case "Each":
            guard args.count >= 3, case .array(let items) = eval(args[0].value, locals: locals) ?? .null,
                  let variable = eval(args[1].value, locals: locals)?.text else { return .array([]) }
            return .array(items.compactMap { item in
                var scope = locals
                scope[variable] = item
                return eval(args[2].value, locals: scope)
            })
        default:
            break
        }
        let values = args.map { eval($0.value, locals: locals) ?? .null }
        if let result = Self.builtin(name, values) { return result }
        unknownFunctions.insert(name)
        return .null
    }

    /// The built-in functions of spec 3.4 (except `@Each`, which defers its template).
    static func builtin(_ name: String, _ args: [OUIValue]) -> OUIValue? {
        let first = args.first ?? .null
        let list = first.arrayValue
        func numbers() -> [Double] { (list ?? []).map(\.toNumber) }
        switch name {
        case "Count": return .number(Double(list?.count ?? 0))
        case "First": return list?.first ?? .null
        case "Last": return list?.last ?? .null
        case "Sum": return .number(numbers().reduce(0, +))
        case "Avg": let n = numbers(); return .number(n.isEmpty ? 0 : n.reduce(0, +) / Double(n.count))
        case "Min": return .number(numbers().min() ?? 0)
        case "Max": return .number(numbers().max() ?? 0)
        case "Round":
            let places = args.count > 1 ? args[1].toNumber : 0
            let factor = pow(10, places)
            return .number((first.toNumber * factor + 0.5).rounded(.down) / factor)
        case "Abs": return .number(abs(first.toNumber))
        case "Floor": return .number(first.toNumber.rounded(.down))
        case "Ceil": return .number(first.toNumber.rounded(.up))
        case "Filter":
            guard let list else { return .array([]) }
            let field = args.count > 1 ? args[1].stringForm : ""
            let op = args.count > 2 ? args[2].stringForm : "=="
            let target = args.count > 3 ? args[3] : .null
            return .array(list.filter { item in
                let v = field.isEmpty ? item : path(item, field)
                switch op {
                case "==": return OUIValue.looselyEqual(v, target)
                case "!=": return !OUIValue.looselyEqual(v, target)
                case ">": return v.toNumber > target.toNumber
                case "<": return v.toNumber < target.toNumber
                case ">=": return v.toNumber >= target.toNumber
                case "<=": return v.toNumber <= target.toNumber
                case "contains": return v.stringForm.contains(target.stringForm)
                default: return false
                }
            })
        case "Sort":
            guard let list else { return first }
            let field = args.count > 1 ? args[1].stringForm : ""
            let descending = args.count > 2 && args[2].stringForm == "desc"
            let keyed = list.enumerated().map { (offset: $0.offset, item: $0.element, key: field.isEmpty ? $0.element : path($0.element, field)) }
            let sorted = keyed.sorted { a, b in
                let order = compare(a.key, b.key)
                if order == .orderedSame { return a.offset < b.offset }
                return descending ? order == .orderedDescending : order == .orderedAscending
            }
            return .array(sorted.map(\.item))
        default:
            return nil
        }
    }

    /// Dot paths for `@Filter` and `@Sort` fields (`"customer.name"`).
    private static func path(_ value: OUIValue, _ field: String) -> OUIValue {
        field.split(separator: ".").reduce(value) { v, key in v.objectValue?[String(key)] ?? .null }
    }

    private static func compare(_ a: OUIValue, _ b: OUIValue) -> ComparisonResult {
        if let x = a.numberValue, let y = b.numberValue, !(a.isNull || b.isNull) {
            return x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
        }
        return a.stringForm.localizedStandardCompare(b.stringForm)
    }
}
