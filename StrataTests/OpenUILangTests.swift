import Testing
import Foundation
@testable import Strata

/// The library of OpenUI's conformance fixtures (spec/fixtures/1.0/library.json), so their expected trees apply as is.
private extension OUILibrary {
    static let fixture = OUILibrary(components: [
        "Stack": .init(props: ["children", "direction"]),
        "Card": .init(props: ["title", "children"]),
        "Text": .init(props: ["text", "variant"]),
        "Tag": .init(props: ["text", "color"]),
        "Metric": .init(props: ["label", "value"]),
        "Button": .init(props: ["label", "action", "variant", "share"]),
        "Form": .init(props: ["name", "children"]),
        "Input": .init(props: ["name", "placeholder", "value", "rules"]),
        "Select": .init(props: ["name", "items", "value"]),
        "SelectItem": .init(props: ["value", "label"]),
        "Table": .init(props: ["columns"]),
        "Col": .init(props: ["label", "data"]),
    ], roots: ["Stack"])
}

/// A rendered value in the fixtures' JSON shape: components as {type, props}, unknown components dropped.
private func json(_ value: OUIValue?) -> Any {
    switch value {
    case nil, .null?: return NSNull()
    case .bool(let b)?: return b
    case .number(let d)?: return d
    case .string(let s)?: return s
    case .array(let items)?:
        return items.compactMap { item -> Any? in
            if case .component(let c) = item, !c.known { return nil }
            return json(item)
        }
    case .object(let o)?: return Dictionary(uniqueKeysWithValues: o.values.map { ($0.key, json($0.value)) })
    case .component(let c)?:
        return ["type": c.type, "props": Dictionary(uniqueKeysWithValues: c.props.map { ($0.key, json($0.value)) })]
    case .action?: return "<action>"
    }
}

private func render(_ source: String, library: OUILibrary = .fixture) -> OUIRendered {
    OUIRendered.make(OUIStreamParser.parse(source), library: library)
}

private func matches(_ rendered: OUIRendered, _ expectedRoot: String) throws -> Bool {
    let expected = try JSONSerialization.jsonObject(with: Data(expectedRoot.utf8)) as? NSDictionary
    let actual = json(rendered.root.map(OUIValue.component)) as? NSDictionary
    if expected != actual { print("expected", expected ?? "nil", "\nactual", actual ?? "nil") }
    return expected == actual
}

// MARK: - Lexer and grammar

struct OpenUILexerTests {
    @Test func stringsTakeTheirEscapes() {
        let tokens = OUILexer.lex(#"a = "q\"d\\b\ttA" 'it\'s' 'x\ny'"#).tokens
        #expect(tokens.contains(.string("q\"d\\b\ttA")))
        #expect(tokens.contains(.string("it's")))
        #expect(tokens.contains(.string("x\ny")))
    }

    @Test func aMinusIsANumberOnlyWhereAValueCannotEnd() {
        let tokens = OUILexer.lex("[1 -2, -5, x-1]").tokens
        #expect(tokens.contains(.number(-5)))
        #expect(tokens.filter { $0 == .op("-") }.count == 2, "`1 -2` and `x-1` subtract")
    }

    @Test func anUnterminatedStringIsIncompleteNotAnError() {
        let r = OUILexer.lex(#"t = Text("abc"#)
        #expect(r.incomplete)
        #expect(r.tokens.contains(.string("abc")))
    }

    @Test func commentsAreSkippedOutsideStrings() {
        let tokens = OUILexer.lex("a = 1 // note\n# whole line\nb = \"// kept\"").tokens
        #expect(tokens.contains(.string("// kept")))
        #expect(!tokens.contains(.ident("note")) && !tokens.contains(.ident("whole")))
    }
}

struct OpenUIGrammarFixtureTests {
    @Test func commentStrip() throws {
        let source = """
        root = Stack([t, u, v]) // the page
        # a note line
        t = Text("a // not a comment")
        u = Text('b # not a comment either')
        v = Text("line one
        // still inside the string")
        """
        #expect(try matches(render(source), #"""
        {"type":"Stack","props":{"children":[{"type":"Text","props":{"text":"a // not a comment"}},
        {"type":"Text","props":{"text":"b # not a comment either"}},
        {"type":"Text","props":{"text":"line one\n// still inside the string"}}]}}
        """#))
    }

    @Test func lexEscapes() throws {
        let source = #"""
        root = Stack([a, b, c])
        a = Text("q\"d\\b\ttA")
        b = Text('it\'s')
        c = Text('x\ny')
        """#
        #expect(try matches(render(source), #"""
        {"type":"Stack","props":{"children":[{"type":"Text","props":{"text":"q\"d\\b\ttA"}},
        {"type":"Text","props":{"text":"it's"}},{"type":"Text","props":{"text":"x\ny"}}]}}
        """#))
    }

    @Test func lexMinusAndSkip() throws {
        let source = """
        root = Stack([Table([c])]);
        c = Col("n", [1 -2, 3, 4 - 1, -5])
        """
        #expect(try matches(render(source), """
        {"type":"Stack","props":{"children":[{"type":"Table","props":{"columns":[
        {"type":"Col","props":{"label":"n","data":[-1,3,3,-5]}}]}}]}}
        """))
    }

    @Test func precedenceAndKeys() throws {
        let source = """
        root = Stack([Table([c, o]) Text("end"),])
        c = Col("v", [1 + 2 * 3 - 4 / 2, -2 * -3, 7 % 4, 10 - 2 - 3, 2 > 1 == true, !!"x" && "ok", 1 || 2 && 0, (1 + 2) * 3])
        o = Col("o", [{name: "x", "quoted key": 1, 2: "two", $s: 3, Card: 4}])
        """
        #expect(try matches(render(source), """
        {"type":"Stack","props":{"children":[{"type":"Table","props":{"columns":[
        {"type":"Col","props":{"label":"v","data":[5,6,3,5,true,"ok",1,9]}},
        {"type":"Col","props":{"label":"o","data":[{"2":"two","name":"x","quoted key":1,"s":3,"Card":4}]}}]}},
        {"type":"Text","props":{"text":"end"}}]}}
        """))
    }

    @Test func memberDigitsField() throws {
        let source = """
        root = Stack([Table([c])])
        m = [[1, 2], [3, 4]]
        o = {0: "zero"}
        c = Col("d", [m[1][0], o.0, m.0])
        """
        #expect(try matches(render(source), """
        {"type":"Stack","props":{"children":[{"type":"Table","props":{"columns":[
        {"type":"Col","props":{"label":"d","data":[3,"zero",[1,3]]}}]}}]}}
        """))
    }
}

struct OpenUIEvaluationFixtureTests {
    @Test func operatorsCoerceValues() throws {
        let source = """
        root = Stack([Table([c, o])])
        c = Col("coerce", ["5" * 2, "abc" * 2, true + 1, null + 1, "a" + null, 5 == "5", "" == 0, null == 0])
        o = Col("op", [7 / 0, 7 % 0, "a" + 1, 1 + 2 + "x", $u || "fallback", 0 && "no", !0, -"3", 3 >= "3"])
        """
        #expect(try matches(render(source), """
        {"type":"Stack","props":{"children":[{"type":"Table","props":{"columns":[
        {"type":"Col","props":{"label":"coerce","data":[10,0,2,1,"a",true,true,false]}},
        {"type":"Col","props":{"label":"op","data":[0,0,"a1","3x","fallback",0,true,-3,true]}}]}}]}}
        """))
    }

    @Test func memberPluckAndNull() throws {
        let source = """
        root = Stack([Table([names, ns, misc])])
        rows = [{name: "a", n: 1}, {name: "b"}]
        o = {k: "v"}
        nothing = null
        names = Col("names", rows.name)
        ns = Col("ns", rows.n)
        misc = Col("misc", [rows.length, rows[1].name, o["k"], nothing.field, o[nothing]])
        """
        #expect(try matches(render(source), """
        {"type":"Stack","props":{"children":[{"type":"Table","props":{"columns":[
        {"type":"Col","props":{"label":"names","data":["a","b"]}},
        {"type":"Col","props":{"label":"ns","data":[1,null]}},
        {"type":"Col","props":{"label":"misc","data":[2,"b","v",null,null]}}]}}]}}
        """))
    }

    @Test func builtinsCountFilterAndQueryDefaults() throws {
        let source = """
        root = Stack([Metric("Open", @Count(@Filter(t.rows, "status", "==", "open"))), Metric("Sum", @Sum([1, 2, 3.5]))])
        t = Query("listTickets", {}, {rows: [{status: "open"}, {status: "closed"}, {status: "open"}]})
        """
        #expect(try matches(render(source), """
        {"type":"Stack","props":{"children":[{"type":"Metric","props":{"label":"Open","value":2}},
        {"type":"Metric","props":{"label":"Sum","value":6.5}}]}}
        """))
    }
}

// MARK: - Reference resolution

struct OpenUIReferenceTests {
    @Test func referencesResolveInAnyOrder() throws {
        let r = render("root = Stack([b, a])\na = Text(\"A\")\nb = Text(\"B\")")
        #expect(try matches(r, #"{"type":"Stack","props":{"children":[{"type":"Text","props":{"text":"B"}},{"type":"Text","props":{"text":"A"}}]}}"#))
    }

    @Test func aMissingReferenceIsLeftOutAndNoted() throws {
        let r = render("root = Stack([a, later])\na = Text(\"A\")")
        #expect(try matches(r, #"{"type":"Stack","props":{"children":[{"type":"Text","props":{"text":"A"}}]}}"#))
        #expect(r.unresolved == ["later"])
    }

    @Test func aCycleEndsInsteadOfLooping() throws {
        let r = render("root = Stack([a])\na = Card(\"A\", [b])\nb = Card(\"B\", [a])")
        #expect(try matches(r, """
        {"type":"Stack","props":{"children":[{"type":"Card","props":{"title":"A","children":[
        {"type":"Card","props":{"title":"B","children":[]}}]}}]}}
        """))
    }

    @Test func aLaterDefinitionWins() throws {
        let r = render("root = Stack([t])\nt = Text(\"first\")\nt = Text(\"second\")")
        #expect(try matches(r, #"{"type":"Stack","props":{"children":[{"type":"Text","props":{"text":"second"}}]}}"#))
    }

    @Test func withoutRootTheFirstRootComponentIsTheEntry() throws {
        #expect(try matches(render("page = Stack([title])\ntitle = Text(\"Orders\")"),
                            #"{"type":"Stack","props":{"children":[{"type":"Text","props":{"text":"Orders"}}]}}"#))
        #expect(try matches(render("$tab = \"a\"\nx = Text(\"no\")\npage = Stack([Text(\"A\")])"),
                            #"{"type":"Stack","props":{"children":[{"type":"Text","props":{"text":"A"}}]}}"#))
        #expect(render("x = Text(\"no root component\")").root == nil)
    }

    @Test func stateReadsItsDefaultUntilSet() throws {
        let source = "$n = 2\nroot = Stack([Text($n > 1 ? \"many\" : \"few\")])"
        #expect(try matches(render(source), #"{"type":"Stack","props":{"children":[{"type":"Text","props":{"text":"many"}}]}}"#))
        let set = OUIRendered.make(OUIStreamParser.parse(source), state: ["$n": .number(0)], library: .fixture)
        #expect(try matches(set, #"{"type":"Stack","props":{"children":[{"type":"Text","props":{"text":"few"}}]}}"#))
    }

    @Test func eachMapsATemplate() throws {
        let source = "root = Stack(@Each([\"a\", \"b\"], \"x\", Text(x)))"
        #expect(try matches(render(source), #"{"type":"Stack","props":{"children":[{"type":"Text","props":{"text":"a"}},{"type":"Text","props":{"text":"b"}}]}}"#))
    }
}

// MARK: - Errors and unknowns

struct OpenUIErrorTests {
    @Test func anUnknownComponentKeepsItsTextAndIsReported() throws {
        let r = render("root = Stack([Text(\"a\"), chart])\nchart = Chart(\"Sales\", [Text(\"inner\")])")
        #expect(try matches(r, #"{"type":"Stack","props":{"children":[{"type":"Text","props":{"text":"a"}}]}}"#),
                "dropped from the spec's tree")
        let unknown = try #require(r.root?.list("children").compactMap(\.componentValue).first { !$0.known })
        #expect(unknown.type == "Chart" && unknown.args.first == .string("Sales"), "but kept for its text")
        #expect(r.problems.contains("Unknown component Chart"))
    }

    @Test func anUnknownFunctionIsNull() throws {
        let r = render("root = Stack([t])\nt = Text(@Nope(1) == null ? \"was null\" : \"not null\")")
        #expect(try matches(r, #"{"type":"Stack","props":{"children":[{"type":"Text","props":{"text":"was null"}}]}}"#))
        #expect(r.problems.contains("Unknown function @Nope"))
    }

    @Test func extraArgumentsAreDroppedAndNullSkips() throws {
        let r = render("root = Stack([Text(\"a\", null, \"extra\", 4)], \"row\")")
        #expect(try matches(r, #"{"type":"Stack","props":{"children":[{"type":"Text","props":{"text":"a"}}],"direction":"row"}}"#))
    }

    @Test func garbageIsSkippedAndTheRestRenders() throws {
        let source = """
        root = Stack([ok, missing])
        ok = Text("This line parsed.")
        bad = Stack([ok,, )) ]
        just some prose the model wrote by mistake
        nonsense here (
        x = = (
        """
        var parser = OUIStreamParser()
        parser.update(source)
        let r = OUIRendered.make(parser.statements(final: true), problems: parser.problems(final: true), library: .fixture)
        #expect(try matches(r, #"{"type":"Stack","props":{"children":[{"type":"Text","props":{"text":"This line parsed."}}]}}"#))
        #expect(r.problems.contains { $0.hasPrefix("Skipped: nonsense here") })
        #expect(!r.problems.contains { $0.contains("prose") }, "a line of prose isn't counted as broken code")
    }

    @Test func nothingParsesMeansNoRoot() {
        for source in ["", "root = ", "root = Card([\n  x = = (\n", "((((", "\"unterminated", "]]]]", "= = =", "@@@"] {
            #expect(render(source, library: .openChat).root.map(OUITree.isBlank) ?? true, "\(source)")
        }
    }

    @Test func namedArgumentsAreAccepted() throws {
        #expect(try matches(render("root = Stack(direction: \"row\", children: [Text(text: \"a\")])"),
                            #"{"type":"Stack","props":{"children":[{"type":"Text","props":{"text":"a"}}],"direction":"row"}}"#))
    }
}

// MARK: - Streaming

struct OpenUIStreamingTests {
    private func stream(_ chunks: [String]) -> OUIStreamParser {
        var parser = OUIStreamParser()
        var text = ""
        for chunk in chunks {
            text += chunk
            parser.update(text)
        }
        return parser
    }

    @Test func workedExample() throws {
        let chunks = [
            "root = Stack([header, kpis])\nheader = Te",
            "xt(\"Tickets\", \"heading\")\nkpis = Stack([open",
            ", closed])\nopen = Metric(\"Open\", @Count(@Filter(tickets.rows, \"status\", \"==\", \"open\")))\n",
            "closed = Metric(\"Closed\", 8)\ntickets = Query(\"listTickets\", {}, { rows: [] })\n",
        ]
        var parser = OUIStreamParser()
        parser.update(chunks[0])
        #expect(parser.statements(final: false).map(\.name) == ["root"], "header's line isn't complete yet")
        parser.update(chunks[0] + chunks[1])
        #expect(parser.statements(final: false).map(\.name) == ["root", "header"])
        let partial = OUIRendered.make(parser.statements(final: false), library: .fixture)
        #expect(try matches(partial, #"{"type":"Stack","props":{"children":[{"type":"Text","props":{"text":"Tickets","variant":"heading"}}]}}"#),
                "what isn't there yet is left out")
        let done = stream(chunks)
        #expect(try matches(OUIRendered.make(done.statements(final: true), library: .fixture), """
        {"type":"Stack","props":{"children":[{"type":"Text","props":{"text":"Tickets","variant":"heading"}},
        {"type":"Stack","props":{"children":[{"type":"Metric","props":{"label":"Open","value":0}},
        {"type":"Metric","props":{"label":"Closed","value":8}}]}}]}}
        """))
    }

    @Test func aTernaryOverSeveralLinesWaitsForItsEnd() throws {
        var parser = OUIStreamParser()
        let first = "$n = 0\nroot = Stack([Text(s)])\ns = $n > 0\n"
        parser.update(first)
        #expect(!parser.statements(final: false).map(\.name).contains("s"), "the next line may continue it")
        parser.update(first + "  ? \"some\"\n")
        #expect(!parser.statements(final: false).map(\.name).contains("s"))
        parser.update(first + "  ? \"some\"\n  : \"none\"\n")
        #expect(try matches(OUIRendered.make(parser.statements(final: true), library: .fixture),
                            #"{"type":"Stack","props":{"children":[{"type":"Text","props":{"text":"none"}}]}}"#))
    }

    @Test func aTruncatedEscapeEndsTheString() throws {
        let parser = stream(["root = Stack([t])\nt = Text(\"a", "\\"])
        #expect(try matches(OUIRendered.make(parser.statements(final: true), library: .fixture),
                            #"{"type":"Stack","props":{"children":[{"type":"Text","props":{"text":"a\\"}}]}}"#))
    }

    @Test func aChangedPrefixStartsOver() {
        var parser = OUIStreamParser()
        parser.update("a = Text(\"x\")\nb = Text(\"y\")\nc")
        #expect(parser.statements(final: false).map(\.name) == ["a", "b"])
        parser.update("z = Text(\"x\")\n")
        #expect(parser.statements(final: true).map(\.name) == ["z"])
    }

    /// Every program cut at every character: nothing crashes, a cut never shows a statement the whole program doesn't
    /// have, completed statements only grow, and the end equals parsing the whole program at once.
    @Test(arguments: OpenUISamples.all)
    func everyCutPoint(_ sample: String) {
        let whole = OUIStreamParser.parse(sample)
        var incremental = OUIStreamParser()
        var previous: [OUIStatement] = []
        let characters = Array(sample)
        for cut in 0...characters.count {
            let prefix = String(characters[..<cut])
            incremental.update(prefix)
            var fresh = OUIStreamParser()
            fresh.update(prefix)
            let completed = incremental.statements(final: false)
            #expect(completed == fresh.statements(final: false), "incremental and fresh agree at \(cut)")
            #expect(Array(whole.prefix(completed.count)) == completed, "a completed statement is final at \(cut)")
            #expect(completed.starts(with: previous), "completed statements only grow at \(cut)")
            previous = completed
            // Drawing either state doesn't trap.
            _ = OUIRendered.make(completed)
            _ = OUIRendered.make(incremental.statements(final: true), problems: incremental.problems(final: true))
        }
        #expect(incremental.statements(final: true) == whole)
        #expect(OUIRendered.make(whole).root != nil)
    }
}

/// Programs like the ones a model writes, for the cut-point test.
enum OpenUISamples {
    static let plans = """
    root = Card([header, chart, table, choose])
    header = CardHeader("Which plan fits?", "Monthly price for a team of 5")
    chart = BarChart(["Basic", "Pro", "Team"], [Series("Price", [40, 100, 225]), Series("With add-ons", [55, 120, 260])], null, null, "USD")
    table = Table([Col("Plan", ["Basic", "Pro", "Team"]), Col("Storage", ["10 GB", "1 TB", "Unlimited"]), Col("Seats", [5, 20, 100], "number")])
    choose = Buttons([Button("Basic", null, "secondary"), Button("Pro"), Button("Team", null, "secondary")])
    """

    static let form = """
    root = Card([header, trip])
    header = CardHeader("Plan a trip", "I'll build an itinerary from this.")
    trip = Form("trip", Buttons([Button("Make my plan"), Button("Surprise me", @ToAssistant("Pick everything for me"), "tertiary")]), [city, pace, budget])
    city = FormControl("Destination", Input("city", "Lisbon, Kyoto, …", "text", {required: true}))
    pace = FormControl("Pace", RadioGroup("pace", [RadioItem("Relaxed", "Two things a day", "relaxed"), RadioItem("Packed", "See as much as possible", "packed")], "relaxed"))
    budget = FormControl("Budget per day", Slider("budget", "discrete", 50, 500, 25, [150]))
    """

    static let stateful = """
    $view = "week"
    root = Card([tabs, $view == "week" ? week : month, more])
    tabs = Buttons([Button("Week", Action([@Set($view, "week")])), Button("Month", Action([@Set($view, "month")]))])
    week = TextContent('Seven days: "busy" \\'ish\\'', "small")
    month = TextContent("Thirty days // not a comment")
    // a comment line
    more = FollowUpBlock([FollowUpItem("Show me more")])
    """

    static let all = [plans, form, stateful, AppPrompt.viewsExample]
}

extension AppPrompt {
    /// The program in the prompt's example block.
    static var viewsExample: String {
        let parts = views.components(separatedBy: "```openui\n")
        guard parts.count > 1 else { return "" }
        return parts[1].components(separatedBy: "\n```").first ?? ""
    }
}
