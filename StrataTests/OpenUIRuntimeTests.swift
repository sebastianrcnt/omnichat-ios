import Testing
import Foundation
import SwiftData
@testable import Strata

// MARK: - Actions to messages

@MainActor
struct OpenUIActionTests {
    private func page(_ source: String) -> OUIRendered { OUIRendered.make(source: source) }

    /// The first component of `type` in the tree.
    private func find(_ type: String, in rendered: OUIRendered, where match: (OUIComponent) -> Bool = { _ in true }) -> OUIComponent? {
        var found: OUIComponent?
        if let root = rendered.root {
            OUITree.walk(root) { c in if found == nil, c.type == type, match(c) { found = c } }
        }
        return found
    }

    private func press(_ label: String, in rendered: OUIRendered, runtime: OUIRuntime, form: String? = nil,
                       opened: ((URL) -> Void)? = nil) -> OUISubmission? {
        let button = find("Button", in: rendered) { $0.string("label") == label }
        return runtime.perform(button?["action"]?.actionValue, label: label, form: form, rendered: rendered, open: opened ?? { _ in })
    }

    @Test func aButtonWithoutAnActionSendsItsLabel() throws {
        let r = page("root = Card([Buttons([Button(\"Basic\"), Button(\"Pro\")])])")
        let runtime = OUIRuntime()
        let sent = try #require(press("Pro", in: r, runtime: runtime))
        #expect(sent.text == "Pro")
        #expect(runtime.saved?.label == "Pro" && runtime.saved?.form == nil)
    }

    @Test func toAssistantSendsItsTextAndContext() throws {
        let r = page("""
        root = Card([b])
        b = Buttons([Button("Book", @ToAssistant("Book the table", {time: "19:30", guests: 4})), Button("List", @ToAssistant("Go", ["a", null, "b"]))])
        """)
        #expect(press("Book", in: r, runtime: OUIRuntime())?.text == "Book the table\n- time: 19:30\n- guests: 4")
        #expect(press("List", in: r, runtime: OUIRuntime())?.text == "Go\n- a\n- b")
    }

    @Test func aFormSendsItsValuesByLabelAfterValidating() throws {
        let r = page("""
        root = Card([trip])
        trip = Form("trip", Buttons([Button("Plan it")]), [city, pace, likes, budget, notes])
        city = FormControl("Destination", Input("city", "Where?", "text", {required: true}))
        pace = FormControl("Pace", RadioGroup("pace", [RadioItem("Relaxed", "", "relaxed"), RadioItem("Packed", "", "packed")], "relaxed"))
        likes = FormControl("Into", Chips("likes", "multiple", [ChipItem("food", "Food"), ChipItem("art", "Museums")]))
        budget = FormControl("Budget", Slider("budget", "discrete", 50, 500, 25, [150]))
        notes = FormControl("Notes", TextArea("notes"))
        """)
        let runtime = OUIRuntime()
        #expect(press("Plan it", in: r, runtime: runtime, form: "trip") == nil, "the destination is required")
        #expect(runtime.errors["trip"]?["city"] == "Required")
        #expect(runtime.saved == nil, "nothing sent, nothing locked")

        runtime.setValue(.string("Lisbon"), form: "trip", name: "city", binding: nil)
        #expect(runtime.errors["trip"]?["city"] == nil, "typing clears the message")
        runtime.setValue(.array([.string("food"), .string("art")]), form: "trip", name: "likes", binding: nil)
        let sent = try #require(press("Plan it", in: r, runtime: runtime, form: "trip"))
        #expect(sent.text == "Plan it\n- Destination: Lisbon\n- Pace: Relaxed\n- Into: Food, Museums\n- Budget: 150",
                "option labels rather than values; empty fields left out; defaults count")
        #expect(sent.saved.form == "trip" && sent.saved.fields["trip"]?["pace"] == .string("relaxed"),
                "defaults are saved so the locked view shows them")
    }

    @Test func validationRules() {
        func rules(_ pairs: [String: OUIValue]) -> OUIObject { OUIObject(keys: Array(pairs.keys), values: pairs) }
        #expect(OUIValidation.error(.string("a@b.co"), rules: rules(["email": .bool(true)])) == nil)
        #expect(OUIValidation.error(.string("nope"), rules: rules(["email": .bool(true)])) == "Enter a valid email address")
        #expect(OUIValidation.error(.string(""), rules: rules(["email": .bool(true)])) == nil, "only required checks empty fields")
        #expect(OUIValidation.error(.string("a"), rules: rules(["minLength": .number(2)])) == "Use at least 2 characters")
        #expect(OUIValidation.error(.array([.number(12)]), rules: rules(["max": .number(10)])) == "Must be at most 10")
        #expect(OUIValidation.error(.string("abc"), rules: rules(["numeric": .bool(true)])) == "Enter a number")
        #expect(OUIValidation.error(.object(OUIObject(keys: ["a"], values: ["a": .bool(false)])), rules: rules(["required": .bool(true)])) == "Required",
                "a checkbox group with nothing checked is empty")
    }

    @Test func aChoiceOnAPageWithNothingToPressSendsAtOnce() throws {
        let r = page("""
        root = Card([q, pick])
        q = InlineHeader("Which version?")
        pick = RadioGroup("version", [RadioItem("Short", "A paragraph", "short"), RadioItem("Detailed", "With code", "long")])
        """)
        let root = try #require(r.root)
        #expect(!OUITree.pageHasActions(root))
        let field = try #require(OUITree.fields(in: root, form: nil).first)
        let runtime = OUIRuntime()
        let sent = runtime.choose("Detailed", field: field, value: .string("long"), binding: nil)
        #expect(sent.text == "Detailed")
        #expect(sent.saved.label == "Detailed" && sent.saved.fields[""]?["version"] == .string("long"))
        #expect(OUITree.pageHasActions(try #require(page("root = Card([RadioGroup(\"v\", []), Buttons([Button(\"Go\")])])").root)))
        #expect(!OUITree.pageHasActions(try #require(page("root = Card([Form(\"f\", Buttons([Button(\"Go\")]), [])])").root)),
                "a form's own buttons don't count for the page")
    }

    @Test func setResetAndOpenUrlDontSend() throws {
        let r = page("""
        $count = 0
        root = Card([TextContent("" + $count), Buttons([Button("More", Action([@Set($count, $count + 1)])), Button("Clear", Action([@Reset($count)])), Button("Docs", @OpenUrl("https://example.com/docs"))])])
        """)
        let runtime = OUIRuntime()
        #expect(press("More", in: r, runtime: runtime) == nil)
        #expect(runtime.state["$count"] == .number(1) || runtime.state["count"] == .number(1))
        let again = OUIRendered.make(OUIStreamParser.parse("""
        $count = 0
        root = Card([TextContent("" + $count)])
        """), state: runtime.state)
        #expect(again.root?.components("children").first?.string("text") == "1", "state feeds back into the view")
        #expect(press("Clear", in: r, runtime: runtime) == nil && runtime.state.isEmpty)
        var opened: URL?
        #expect(press("Docs", in: r, runtime: runtime, opened: { opened = $0 }) == nil)
        #expect(opened == URL(string: "https://example.com/docs"))
        #expect(runtime.saved == nil, "links and state changes don't lock the view")
    }

    @Test func aListItemAndFollowUpTextAreMessages() {
        #expect(OUISubmission.text(message: "  Show a benchmark \n", values: []) == "Show a benchmark")
        #expect(OUISubmission.text(message: "Go", values: [("Time", "7:30 PM")], context: .string("ctx")) == "Go\n- Time: 7:30 PM\n- ctx")
    }

    @Test func fieldsShowTheirValuesInWords() throws {
        let r = page("""
        root = Card([f])
        f = Form("f", Buttons([Button("Send")]), [FormControl("Extras", CheckBoxGroup("x", [CheckBoxItem("Wi-Fi", "", "wifi", true), CheckBoxItem("Parking", "", "park")])), FormControl("When", DatePicker("d", "range", null, ["2026-10-22", "2026-10-25"])), FormControl("Time", Select("t", [SelectItem("19:30", "7:30 PM")]))])
        """)
        let fields = OUITree.fields(in: try #require(r.root), form: "f")
        #expect(fields.map(\.label) == ["Extras", "When", "Time"])
        #expect(fields[0].display(fields[0].defaultValue) == "Wi-Fi")
        #expect(fields[1].display(fields[1].defaultValue) == "2026-10-22 to 2026-10-25")
        #expect(fields[2].display(.string("19:30")) == "7:30 PM")
        #expect(fields[2].display(nil) == nil)
    }
}

// MARK: - Saved state

@MainActor
struct OpenUIStateTests {
    @Test func savedStatesRoundTripThroughTheStore() throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let message = Message(role: .assistant, text: "```openui\nroot = Card([])\n```", sortIndex: 0)
        container.mainContext.insert(message)
        #expect(message.openUIStateData == nil && message.openUIStates.isEmpty, "no state until a view sends")
        let saved = OUISavedState(label: "Book it", form: "booking",
                                  fields: ["booking": ["time": .string("19:30"), "guests": .array([.number(4)]),
                                                       "extras": .object(OUIObject(keys: ["wifi"], values: ["wifi": .bool(true)]))]],
                                  state: ["$tab": .string("b")])
        message.openUIStates[2] = saved
        try container.mainContext.save()

        let id = message.id
        let other = ModelContext(container)
        let fetched = try #require(try other.fetch(FetchDescriptor<Message>(predicate: #Predicate { $0.id == id })).first)
        #expect(fetched.openUIStates == [2: saved])
        message.openUIStates = [:]
        #expect(message.openUIStateData == nil)
    }

    @Test func aRuntimeRestoresWhatWasSaved() {
        let saved = OUISavedState(label: "Pro", form: nil, fields: ["": ["plan": .string("pro")]], state: ["$n": .number(2)])
        let key = "test-\(UUID())#0"
        let runtime = OUIRuntimeStore.shared.runtime(for: key, saved: nil)
        #expect(runtime.saved == nil)
        runtime.setValue(.string("basic"), form: nil, name: "plan", binding: nil)
        let same = OUIRuntimeStore.shared.runtime(for: key, saved: saved)
        #expect(same === runtime, "one runtime per message and block")
        #expect(same.saved == saved && same.value(form: nil, name: "plan") == .string("pro") && same.state["$n"] == .number(2),
                "the stored choice wins over what was on screen")
    }

    @Test func componentsAndActionsAreNotSavedAsData() throws {
        let value = OUIValue.array([.string("a"), .component(OUIComponent(type: "Tag", props: [:])), .action(OUIAction(steps: []))])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(OUIValue.self, from: data) == .array([.string("a"), .null, .null]))
    }
}

// MARK: - Copy, fences, translation

struct OpenUITextTests {
    private let answer = """
    Here are the plans:

    ```openui
    root = Card([header, table, choose])
    header = CardHeader("Which plan fits?", "For 5 people")
    table = Table([Col("Plan", ["Basic", "Pro"]), Col("Price", [40, 100])])
    choose = Buttons([Button("Basic"), Button("Pro")])
    ```

    Pick one and I'll set it up.
    """

    @Test func copyGivesWhatTheViewShows() {
        let plain = MarkdownPlain.text(from: answer)
        #expect(plain.contains("Which plan fits?\nFor 5 people\nPlan | Price\nBasic | 40\nPro | 100"))
        #expect(!plain.contains("root =") && !plain.contains("Button"))
        #expect(plain.hasPrefix("Here are the plans:") && plain.hasSuffix("Pick one and I'll set it up."))
    }

    @Test func plainTextOfKnownParts() {
        let text = OUIPlainText.text(source: """
        root = Card([Metric("Revenue", "$48k", "+12%"), Callout("warning", "Low stock", "3 items"), Steps([StepsItem("Install", "Add it")]), EntityList([{left: "Area", right: "605 km²"}]), Link("Docs", "https://example.com"), PieChart(["A", "B"], [60, 40])])
        """)
        #expect(text == "Revenue: $48k (+12%)\nLow stock: 3 items\n1. Install — Add it\nArea: 605 km²\nDocs (https://example.com)\nA: 60\nB: 40")
        #expect(OUIPlainText.text(source: "nothing (") == "")
    }

    @Test func fencesAreRecognisedByTheirTag() {
        #expect(OpenUIFence.isOpenUI(blockText: "```openui\nroot = Card([])\n```"))
        #expect(OpenUIFence.isOpenUI(blockText: "```openui-lang\nroot = Card([])\n```"))
        #expect(OpenUIFence.isOpenUI(blockText: "~~~ OpenUI {.x}\n"))
        #expect(!OpenUIFence.isOpenUI(blockText: "```swift\nlet openui = 1\n```"))
        #expect(!OpenUIFence.isOpenUI(blockText: "```\nroot = Card([])\n```"))
        let replaced = OpenUIFence.replacingBlocks(in: "a\n```js\nx\n```\n```openui\nroot\n```\nb\n```openui\nunclosed") { "[\($0)]" }
        #expect(replaced == "a\n```js\nx\n```\n[root]\nb\n[unclosed]")
    }

    @Test func translationLeavesTheViewByteForByte() async throws {
        struct Upper: TextTranslating {
            func translate(_ texts: [String]) async throws -> [String] { texts.map { $0.uppercased() } }
        }
        let translated = try await TranslationRunner.translate(answer, with: Upper())
        let block = answer.components(separatedBy: "\n\n")[1]
        #expect(translated.contains(block))
        #expect(translated.hasPrefix("HERE ARE THE PLANS:") && translated.hasSuffix("PICK ONE AND I'LL SET IT UP."))
        let lang = answer.replacingOccurrences(of: "```openui", with: "```openui-lang")
        #expect(try await TranslationRunner.translate(lang, with: Upper()).contains(block.replacingOccurrences(of: "```openui", with: "```openui-lang")))
    }

    @Test func aBlankRootShowsNothing() throws {
        #expect(OUITree.isBlank(try #require(OUIRendered.make(source: "root = Card([a, b])").root)))
        #expect(OUITree.isBlank(try #require(OUIRendered.make(source: "root = Stack([Card([])])").root)))
        #expect(!OUITree.isBlank(try #require(OUIRendered.make(source: "root = Card([\"plain text\"])").root)))
        #expect(!OUITree.isBlank(try #require(OUIRendered.make(source: "root = Card([a])\na = Separator()").root)))
    }
}
