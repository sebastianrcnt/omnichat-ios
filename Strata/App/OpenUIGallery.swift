#if DEBUG
import SwiftUI

/// `-StrataOpenUIGallery 1`: instead of the app, sample interactive views (OpenUI Lang blocks) as an answer shows them,
/// for simulator screenshots in light and dark. `1` is a comparison with a chart and buttons, `2` a dashboard, `3` a
/// form, `4` choices and a locked view, `5` a view streaming in line by line (it loops), `6` tabs, lists and broken
/// programs. Buttons don't send anything: what would be sent shows under the view.
struct OpenUIGallery: View {
    @Environment(\.theme) private var theme

    static var isRequested: Bool { UserDefaults.standard.integer(forKey: "StrataOpenUIGallery") > 0 }
    private var page: Int { UserDefaults.standard.integer(forKey: "StrataOpenUIGallery") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                switch page {
                case 2:
                    sample("Dashboard", Self.dashboard)
                case 3:
                    sample("Form", Self.form)
                case 4:
                    sample("Choice (sends on pick)", Self.choice)
                    sample("Follow-ups", Self.followUps)
                    LockedSample()
                case 5:
                    StreamingSample()
                case 6:
                    sample("Tabs, steps, lists", Self.tabs)
                    sample("Partly broken", Self.broken)
                    sample("Broken", "root = Card([\n  x = = (\n")
                default:
                    sample("Comparison", Self.plans)
                }
            }
            .padding(.horizontal, DS.Spacing.page)
            .padding(.vertical, DS.Spacing.xl)
        }
        .defaultScrollAnchor(UserDefaults.standard.bool(forKey: "StrataOpenUIGalleryBottom") ? .bottom : .top)
        .background(theme.background)
        .task { await Self.snapshotIfRequested() }
        // `-StrataOpenUIGalleryDark 1`: dark without changing the (shared) simulator's appearance.
        .preferredColorScheme(UserDefaults.standard.bool(forKey: "StrataOpenUIGalleryDark") ? .dark : nil)
    }

    /// `-StrataOpenUIGallerySnapshot name`: after a moment, draws the window into `tmp/name.png` in the app's container.
    /// The window is drawn by the app itself, so a system alert over a shared simulator doesn't end up in the picture.
    private static func snapshotIfRequested() async {
        #if canImport(UIKit)
        guard let name = UserDefaults.standard.string(forKey: "StrataOpenUIGallerySnapshot") else { return }
        let delay = UserDefaults.standard.double(forKey: "StrataOpenUIGallerySnapshotDelay")
        try? await Task.sleep(for: .seconds(delay > 0 ? delay : 3))
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.windows.first }).first else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("\(name).png"))
        #endif
    }

    private func sample(_ title: String, _ program: String) -> some View {
        GallerySample(title: title, program: program)
    }

    static let plans = """
    root = Card([header, chart, table, choose])
    header = CardHeader("Which plan fits?", "Monthly price for a team of 5")
    chart = BarChart(["Basic", "Pro", "Team"], [Series("Price", [40, 100, 225]), Series("With add-ons", [55, 120, 260])], null, null, "USD")
    table = Table([Col("Plan", ["Basic", "Pro", "Team"]), Col("Storage", ["10 GB", "1 TB", "Unlimited"]), Col("Seats", [5, 20, 100], "number"), Col("Status", [Tag("Stable", null, "sm", "neutral"), Tag("Popular", null, "sm", "success"), Tag("New", null, "sm", "info")])])
    choose = Buttons([Button("Basic", null, "secondary"), Button("Pro"), Button("Team", null, "secondary")])
    """

    static let dashboard = """
    root = Card([title, kpis, trend, split, goal, tags, note])
    title = CardHeader("Store this week")
    kpis = Stack([revenue, orders], "row")
    revenue = Metric("Revenue", "$48.2k", "+12%", "vs last week")
    orders = Metric("Orders", "1,284", "-3%")
    trend = LineChart(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], [Series("This week", [5.1, 6.2, 5.8, 7.4, 8.1, 9.6, 6.0]), Series("Last week", [4.8, 5.0, 5.9, 6.1, 7.0, 8.2, 5.5])], "natural")
    split = PieChart(["Online", "In store", "Wholesale"], [62, 28, 10], "donut")
    goal = Progress("Monthly goal", 68)
    tags = TagBlock(["Shoes", "Bags", "Outerwear"])
    note = Callout("warning", "Low stock", "**3 items** sell out within a week at this rate.")
    """

    static let form = """
    root = Card([header, trip])
    header = CardHeader("Plan a trip", "I'll build an itinerary from this.")
    trip = Form("trip", Buttons([Button("Make my plan"), Button("Surprise me", @ToAssistant("Pick everything for me"), "tertiary")]), [city, dates, pace, budget, likes, notes])
    city = FormControl("Destination", Input("city", "Lisbon, Kyoto, …", "text", {required: true}))
    dates = FormControl("Dates", DatePicker("dates", "range"))
    pace = FormControl("Pace", RadioGroup("pace", [RadioItem("Relaxed", "Two things a day", "relaxed"), RadioItem("Packed", "See as much as possible", "packed")], "relaxed"))
    budget = FormControl("Budget per day", Slider("budget", "discrete", 50, 500, 25, [150]))
    likes = FormControl("Into", Chips("likes", "multiple", [ChipItem("food", "Food"), ChipItem("museums", "Museums"), ChipItem("nature", "Nature"), ChipItem("night", "Nightlife")]))
    notes = FormControl("Anything else", TextArea("notes", "Allergies, must-sees…", 2), "Optional")
    """

    static let choice = """
    root = Card([q, pick])
    q = InlineHeader("Which version should I write?", "Pick one and I'll continue.")
    pick = RadioGroup("version", [RadioItem("Short", "A paragraph", "short"), RadioItem("Detailed", "With examples and code", "long")])
    """

    static let followUps = """
    root = Stack([more])
    more = FollowUpBlock([FollowUpItem("Compare it with Rust"), FollowUpItem("Show a benchmark")])
    """

    static let tabs = """
    root = Card([tabs, steps, facts, list])
    tabs = Tabs([TabItem("a", "Overview", [TextContent("Swift Charts draws **bar**, line, area and pie charts.")]), TabItem("b", "Code", [CodeBlock("swift", "Chart(data) { BarMark(x: .value(\\"Day\\", $0.day)) }")])])
    steps = Steps([StepsItem("Install", "Add the package."), StepsItem("Configure", "Set the API key in Settings.")])
    facts = EntityList([{left: "Population", right: "10.4M"}, {left: "Area", right: "605 km²"}, {left: "Founded", right: "1394"}])
    list = ListBlock([ListItem("Gyeongbokgung", "Palace · 1.2 km", null, "Go"), ListItem("Bukchon", "Village · 2.0 km", null, "Go")], "number")
    """

    static let broken = """
    root = Card([ok, missing, odd])
    ok = TextContent("This line parsed.")
    odd = Sparkline([1, 2, 3])
    bad = Stack([ok,, )) ]
    nonsense here (
    """
}

/// One sample, rendered the way an answer renders its blocks.
private struct GallerySample: View {
    @Environment(\.theme) private var theme
    let title: String
    let program: String
    @State private var sent: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(verbatim: title.uppercased()).font(DS.Typography.feedMeta).foregroundStyle(theme.textTertiary)
            NoteText(text: "```openui\n\(program)\n```")
            if let sent {
                Text(verbatim: "Would send:\n\(sent)")
                    .font(DS.Typography.monoSmall)
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .environment(\.openUIHost, OpenUIHost(send: { _, submission in sent = submission.text }))
    }
}

/// A form after the person sent it, with a newer message below: disabled, showing what was chosen.
private struct LockedSample: View {
    @Environment(\.theme) private var theme
    private let id = UUID()

    var body: some View {
        let saved = OUISavedState(label: "Book it", form: "booking", fields: ["booking": [
            "time": .string("19:30"), "guests": .array([.number(4)]), "seating": .string("terrace"),
        ]])
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(verbatim: "LOCKED (NEWER MESSAGE EXISTS)").font(DS.Typography.feedMeta).foregroundStyle(theme.textTertiary)
            NoteText(text: """
            ```openui
            root = Card([form])
            form = Form("booking", Buttons([Button("Book it"), Button("Other dates", null, "secondary")]), [time, guests, seating])
            time = FormControl("Time", Select("time", [SelectItem("18:00", "6:00 PM"), SelectItem("19:30", "7:30 PM")]))
            guests = FormControl("Guests", Slider("guests", "discrete", 1, 8, 1, [2]))
            seating = FormControl("Seating", Chips("seating", "single", [ChipItem("inside", "Inside"), ChipItem("terrace", "Terrace")]))
            ```
            """)
        }
        .environment(\.openUIHost, OpenUIHost(messageID: id, isInteractive: false, saved: [0: saved]))
    }
}

/// The dashboard arriving a few characters at a time, then again from the start.
private struct StreamingSample: View {
    @Environment(\.theme) private var theme
    @State private var shown = 0
    private let program = OpenUIGallery.dashboard

    var body: some View {
        let done = shown >= program.count
        let text = "```openui\n" + String(program.prefix(shown)) + (done ? "\n```" : "")
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(verbatim: done ? "STREAMED" : "STREAMING \(shown)/\(program.count)")
                .font(DS.Typography.feedMeta).foregroundStyle(theme.textTertiary)
            OpenUIBlockView(blockText: text, blockID: 0, isClosed: done)
                .environment(\.openUIHost, OpenUIHost(isStreaming: !done))
        }
        .task {
            let step = UserDefaults.standard.integer(forKey: "StrataOpenUIGalleryStep")
            // `-StrataOpenUIGalleryStop n` holds at n characters, for a screenshot mid-stream.
            let stop = UserDefaults.standard.integer(forKey: "StrataOpenUIGalleryStop")
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                if stop > 0, shown >= stop { continue }
                if shown >= program.count {
                    try? await Task.sleep(for: .seconds(3))
                    shown = 0
                } else {
                    shown = min(program.count, stop > 0 ? stop : Int.max, shown + (step > 0 ? step : 6))
                }
            }
        }
    }
}
#endif
