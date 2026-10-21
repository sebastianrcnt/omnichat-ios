#if DEBUG
import Foundation
import SwiftData

/// Debug-only launch arguments used for simulator smoke runs against a local mock server.
///   -StrataMockBaseURL http://127.0.0.1:8765/v1   add (or update) a connection named "Mock" at the mock
///   -StrataMockKey test-key                        store a fake key in the Keychain
///   -StrataFakeTools 1                             canned web_search/web_fetch results (no network)
///   -StrataAutoSend "hello"                        send a message right after launch
///   -StrataAutoSendRepeat 8                        send it that many times (a long chat)
///   -StrataDebugJump 1                             after the sends: scroll to the top, then press "Jump to bottom"
///   -StrataDebugBranch switch|editbar               after the first answer: edit + regenerate, or open edit mode
///   -StrataOpenSheet usage|model|settings|connection|attach|details|diagnostics   open a sheet right after launch
///   -StrataDraft "text"                            put text in the composer after launch (expanded composer)
///   -StrataOpenMenu 2                              then open the n-th pull-down menu on screen (top to bottom)
///   -StrataOpenSidebar 1                           open the chat list drawer after launch
///   -StrataOpenSheet artifacts                     open the Artifacts gallery after launch
///   -StrataSeedArtifacts 1                         with it: first add three sample chats with artifacts (once)
///   -StrataGalleryOpen 1                           with it: open the gallery's second artifact in the viewer
///   -StrataActivityGallery 1                       show the activity feed states instead of the app (`ActivityGallery`)
///   -StrataOpenUIGallery 1...6                     show sample interactive views instead of the app (`OpenUIGallery`)
///   -StrataVideoSelfTest 1                         real video_transcript calls, reported to stderr (`runVideoSelfTest`)
///   -StrataMultiChatDemo 1                         sample chats shown replying / queued / with an unread reply, and
///                                                  the "Reply ready" banner (`ChatController.debugMultiChatDemo`)
/// Canned tool results so the UI can be exercised without the network.
struct FakeWebTools: ToolExecuting {
    func execute(name: String, arguments: String) async -> ToolOutput {
        // Artifacts are stored on the device anyway: show the real card.
        if name == ToolNames.showHTML { return await ToolRouter().execute(name: name, arguments: arguments) }
        let args = (arguments.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        if name == ToolNames.webFetch, let id = ToolContext.callID {
            // Walks the progress fill the way a real fetch would: loading, settling, extracting. Feed-sample pages take
            // different times, like parallel reads.
            let url = args["url"] as? String ?? ""
            let base = Double(DebugHooks.value("StrataFakeFetchSeconds") ?? "") ?? 1.4
            let seconds = FeedSample.page(for: url) == nil ? base : base * (1 + Double(url.count % 3) * 0.45)
            let steps = 20
            for i in 1...steps {
                try? await Task.sleep(for: .seconds(seconds / Double(steps)))
                let value = Double(i) / Double(steps)
                await MainActor.run { ToolProgress.shared.report(id, value) }
            }
        } else {
            try? await Task.sleep(for: .seconds(1.4))
        }
        if name == ToolNames.webSearch {
            if let query = args["query"] as? String, let sample = FeedSample.search(query) { return sample }
            return ToolOutput(text: "fake", sources: [
                SourceCandidate(title: "Applying Liquid Glass to custom views", url: "https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views", content: "Configure, combine, and morph views using Liquid Glass effects in SwiftUI."),
                SourceCandidate(title: "SwiftUI quick start", url: "https://www.hackingwithswift.com/quick-start/swiftui", content: "Learn SwiftUI and build apps with glass effects."),
                SourceCandidate(title: "Streaming Markdown in Swift", url: "https://github.com/example/streaming-markdown", content: "An incremental Markdown renderer."),
            ])
        }
        if let url = args["url"] as? String, let page = FeedSample.page(for: url) { return page }
        return ToolOutput(text: "fake", sources: [
            SourceCandidate(title: "Applying Liquid Glass to custom views", url: "https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views", content: "Use glassEffect on controls, group them in a GlassEffectContainer, and morph with glassEffectID. Body text should never sit on glass."),
        ])
    }
}

/// Canned results for the mock server's `feedsample` run (the chat-feed mockup): Korean queries answer from "Naver",
/// others from "Bing"; one page is blocked and one has little content.
enum FeedSample {
    static let korean: [(String, String)] = [
        ("2024년 출생통계(확정) 보도자료", "https://kostat.go.kr/board.es?act=view&bid=203&list_no=433"),
        ("출산율 9년 만에 반등… 원인은 혼인 증가", "https://www.hani.co.kr/arti/society/1185021.html"),
        ("합계출산율 0.75명, 바닥 찍었나", "https://www.chosun.com/national/2025/02/26/fertility/"),
        ("저출산 원인 분석 - 위키백과", "https://ko.wikipedia.org/wiki/대한민국의_저출산"),
        ("2024 출생아 수 그래프 한눈에 보기", "https://news.naver.com/main/read.naver?oid=001&aid=0015234567"),
        ("합계출산율 국가별 비교", "https://www.oecd.org/en/data/indicators/fertility-rates.html"),
        ("출산 지원금 2025 총정리", "https://blog.naver.com/moneyinfo/223771234567"),
        ("인구 절벽은 끝났나 [칼럼]", "https://www.joongang.co.kr/article/25316543"),
    ]
    static let english: [(String, String)] = [
        ("South Korea's birth rate rises for first time in nine years", "https://www.reuters.com/world/asia-pacific/south-korea-birth-rate-rises-2025-02-26/"),
        ("Why South Korea's fertility rate finally ticked up", "https://www.bbc.com/news/articles/korea-fertility"),
        ("South Korea: Fertility rate 1960–2024", "https://www.statista.com/statistics/1033837/south-korea-fertility-rate/"),
        ("Marriage boom after pandemic lifts births in Korea", "https://www.theguardian.com/world/2025/feb/26/south-korea-births"),
        ("Korea's demographic crisis explained", "https://asia.nikkei.com/Spotlight/Society/Korea-demographic-crisis"),
        ("Aging of South Korea - Wikipedia", "https://en.wikipedia.org/wiki/Aging_of_South_Korea"),
    ]

    static func search(_ query: String) -> ToolOutput? {
        let rows: [(String, String)]
        let engine: String
        if query.contains("출산") { rows = korean; engine = "Naver" }
        else if query.lowercased().contains("fertility") { rows = english; engine = "Bing" }
        else { return nil }
        return ToolOutput(text: "fake", sources: rows.map { SourceCandidate(title: $0.0, url: $0.1, content: "Snippet for \($0.0).") },
                          engine: engine)
    }

    static func page(for url: String) -> ToolOutput? {
        let known = korean + english + [("정부, 저출생 대응 기획부 신설 추진", "https://www.korea.kr/briefing/policyBriefingView.do?newsId=156677")]
        guard let match = known.first(where: { FeedURL.key($0.1) == FeedURL.key(url) }) else { return nil }
        if url.contains("chosun.com") { return ToolOutput(text: "Error: Blocked: the site refused the request.", isError: true) }
        let length = url.contains("bbc.com") ? 180 : 2_400 + url.count * 23
        let body = String(String(repeating: match.0 + ". ", count: length / max(1, match.0.count) + 1).prefix(length))
        let content = body + "\n\n[End of page, \(length) characters total.]"
        return ToolOutput(text: "Title: \(match.0)\nURL: \(match.1)\n\n" + content,
                          sources: [SourceCandidate(title: match.0, url: match.1, content: content)])
    }
}

/// Stands in for the system translator in simulator runs: marks each block so structure and protected spans show.
struct FakeTranslator: TextTranslating {
    func translate(_ texts: [String]) async throws -> [String] {
        try await Task.sleep(for: .seconds(Double(DebugHooks.value("StrataFakeTranslateSeconds") ?? "") ?? 1.5))
        return texts.map { "(fr) " + $0 }
    }
}

enum DebugHooks {
    /// `-StrataWebSelfTest 1`: one real web_search per engine (each on its own, no fallback: Bing and DuckDuckGo with an
    /// English query, Naver with a Korean one), two searches through the router (Auto: Korean, English), and two real web_fetch calls
    /// through the on-device tools (hidden WKWebView, Readability), reported to stderr.
    ///   -StrataWebSelfTestSkipFetch 1   searches only
    ///   -StrataWebSelfTestDump <dir>    also saves each results page's HTML as <dir>/<engine>.html (to refresh fixtures)
    @MainActor
    static func runWebSelfTest() {
        guard UserDefaults.standard.bool(forKey: "StrataWebSelfTest") else { return }
        func say(_ text: String) { FileHandle.standardError.write(Data("[web-selftest] \(text)\n".utf8)) }
        Task { @MainActor in
            let dumpDirectory = value("StrataWebSelfTestDump")
            let dumping: EngineSearcher = { engine, url in
                let page = HiddenWebView()
                defer { page.dispose() }
                try await page.load(url)
                if let dumpDirectory {
                    let html = try await page.evaluateString("document.documentElement.outerHTML")
                    try? FileManager.default.createDirectory(atPath: dumpDirectory, withIntermediateDirectories: true)
                    try? html.write(toFile: dumpDirectory + "/" + engine.id + ".html", atomically: true, encoding: .utf8)
                }
                return try await SearchExtractor.extract(engine: engine, from: page)
            }
            let cases = [("bing", "swift concurrency actors"), ("naver", "스위프트 동시성 액터"), ("duckduckgo", "swift concurrency actors")]
            for (id, query) in cases {
                guard let engine = SearchEngines.bundled().first(where: { $0.id == id }) else { say("\(id): not bundled"); continue }
                let started = ContinuousClock.now
                let out = await WebSearchTool(engines: [engine], searcher: dumping).run(query: query)
                say("search \(engine.name) \"\(query)\": error=\(out.isError) results=\(out.sources.count) in \(ContinuousClock.now - started)")
                for source in out.sources.prefix(3) { say("  \(source.title.prefix(60)) | \(source.url.prefix(80))") }
                if out.isError || out.sources.isEmpty { say("  text: \(out.text.prefix(200))") }
            }
            var started = ContinuousClock.now
            let tools = ToolRouter()
            for query in ["서울 날씨", "weather in Seoul"] {
                started = ContinuousClock.now
                let out = await tools.execute(name: ToolNames.webSearch, arguments: #"{"query":"\#(query)"}"#)
                say("router (preference \(AppSettings.currentSearchEngine.rawValue)) \"\(query)\": error=\(out.isError) results=\(out.sources.count) engine=\(out.engine ?? "-") in \(ContinuousClock.now - started)")
                say("  \(out.text.prefix(120).replacingOccurrences(of: "\n", with: " "))")
            }
            guard !UserDefaults.standard.bool(forKey: "StrataWebSelfTestSkipFetch") else { say("done"); return }
            for url in ["https://example.com/", "https://en.wikipedia.org/wiki/Swift_(programming_language)"] {
                started = ContinuousClock.now
                let fetch = await tools.execute(name: ToolNames.webFetch, arguments: #"{"url":"\#(url)"}"#)
                say("fetch \(url): error=\(fetch.isError) chars=\(fetch.text.count) in \(ContinuousClock.now - started)")
                say("  \(fetch.text.prefix(160).replacingOccurrences(of: "\n", with: " "))")
            }
            say("done")
        }
    }

    /// `-StrataVideoSelfTest 1`: real `video_transcript` calls (a Korean video, an English one with uploaded captions, a
    /// Short, a Korean one with only auto-generated captions and dubbed audio, Korean asked of an English video, a video
    /// without captions, a non-YouTube link),
    /// reported to stderr with the result's head. `-StrataVideoSelfTestURLs "a b|ko"` reads those links instead (`|ko`: with lang).
    ///   -StrataVideoSelfTestPage 1   skips the direct requests and reads every video from a page in the hidden browser
    @MainActor
    static func runVideoSelfTest() {
        guard UserDefaults.standard.bool(forKey: "StrataVideoSelfTest") else { return }
        func say(_ text: String) { FileHandle.standardError.write(Data("[video-selftest] \(text)\n".utf8)) }
        Task { @MainActor in
            let cases: [(url: String, lang: String?)] = value("StrataVideoSelfTestURLs").map { list in
                list.split(separator: " ").map { item in
                    let parts = item.split(separator: "|", maxSplits: 1).map(String.init)
                    return (parts[0], parts.count > 1 ? parts[1] : nil)
                }
            } ?? [
                ("https://youtu.be/qpu_kIMdo0k?si=abc", nil),
                ("https://www.youtube.com/watch?v=LKrwhjOI8Nc&t=42s", nil),
                ("https://www.youtube.com/shorts/IXasas568yY", nil),
                ("music.youtube.com/watch?v=eApr0i4hUlw&list=RD", nil),
                ("https://m.youtube.com/watch?v=dQw4w9WgXcQ", "ko"),
                ("https://www.youtube.com/watch?v=uWJ-XmhAUX8", nil),
                ("https://vimeo.com/76979871", nil),
            ]
            var source = YouTubeTranscriptSource()
            if UserDefaults.standard.bool(forKey: "StrataVideoSelfTestPage") {
                source.transport = FailingYouTubeTransport()
            }
            for (url, lang) in cases {
                let started = ContinuousClock.now
                TranscriptCache.shared.removeAll()
                let out = await VideoTranscriptTool(sources: [source]).run(urlString: url, language: lang)
                say("\(url) lang=\(lang ?? "-"): error=\(out.isError) chars=\(out.text.count) source=\(out.sources.first?.title ?? "-") in \(ContinuousClock.now - started)")
                say("  " + out.text.prefix(420).replacingOccurrences(of: "\n", with: " | "))
            }
            say("done")
        }
    }

    /// Fails every direct request like a bot check, so the self-test goes to the hidden browser.
    struct FailingYouTubeTransport: YouTubeTransport {
        func player(videoID: String, client: InnerTubeClient) async throws -> Data { throw YouTubeError.botCheck }
        func track(_ url: URL) async throws -> Data { throw YouTubeError.botCheck }
    }

    /// `-StrataKeychainSelfTest 1`: saves, reads back, replaces and deletes a throwaway key through the same store the
    /// connections use, and prints the outcome (never the value) to stderr.
    static func runKeychainSelfTest() {
        guard UserDefaults.standard.bool(forKey: "StrataKeychainSelfTest") else { return }
        func say(_ text: String) { FileHandle.standardError.write(Data("[keychain-selftest] \(text)\n".utf8)) }
        let store = KeychainKeyStore(service: "cc.coolservices.strata.selftest")
        let id = UUID()
        do {
            try store.setKey("self-test-value-1", for: id)
            say("saved: \(store.key(for: id) == "self-test-value-1" ? "read back ok" : "READ BACK FAILED")")
            try store.setKey("self-test-value-2", for: id)
            say("replaced: \(store.key(for: id) == "self-test-value-2" ? "read back ok" : "READ BACK FAILED")")
            try store.setKey(nil, for: id)
            say("deleted: \(store.key(for: id) == nil ? "gone" : "STILL THERE")")
        } catch {
            say("FAILED: \(error.localizedDescription)")
        }
    }

    /// `-StrataPreferredLanguage fr` makes the reader's language French; `-StrataFakeTranslation 1` translates with
    /// `FakeTranslator` (the simulator has no languages installed).
    @MainActor
    static func configure(_ translation: TranslationService) {
        if let language = value("StrataPreferredLanguage") { translation.preferredLanguage = { language } }
        if UserDefaults.standard.bool(forKey: "StrataFakeTranslation") {
            translation.availability = { _, _ in .installed }
            translation.installedTranslator = { _, _ in FakeTranslator() }
        }
    }

    /// `-StrataAutoPickRecent 1`: the attach sheet's strip picks its first photo by itself.
    static var autoPickRecent: Bool { UserDefaults.standard.bool(forKey: "StrataAutoPickRecent") }

    static var fakeTools: Bool { UserDefaults.standard.bool(forKey: "StrataFakeTools") }

    static func value(_ name: String) -> String? {
        UserDefaults.standard.string(forKey: name)
    }

    /// The connection `-StrataMockBaseURL` sets up, the same one on every launch.
    static let mockConnectionID = UUID(uuidString: "0C0FFEE0-0000-4000-8000-00000000000D")!

    /// `-StrataMockBaseURL <url>` (with `-StrataMockKey <key>`): a connection named "Mock" at that address, made like
    /// the user would add one, with images, effort and resumable replies on (`-StrataMockNotResumable 1` turns the
    /// last off, for smoke runs of paths a resumable gateway skips, like the Responses API fallback). New chats use it.
    @MainActor
    static func applyLaunchConfiguration(connections: ConnectionStore, settings: AppSettings) {
        guard let base = value("StrataMockBaseURL") else { return }
        var mock = connections.connection(mockConnectionID)
            ?? Connection(id: mockConnectionID, name: "Mock", baseURL: base, supportsResumable: true)
        mock.baseURL = base
        mock.imagesByDefault = true
        mock.effortByDefault = true
        mock.supportsResumable = !UserDefaults.standard.bool(forKey: "StrataMockNotResumable")
        connections.upsert(mock)
        if let key = value("StrataMockKey") { try? connections.setAPIKey(key, for: mockConnectionID) }
        if settings.lastConnectionID != mockConnectionID {
            settings.lastConnectionID = mockConnectionID
            settings.lastModelID = nil
        }
    }

    /// Opt-in simulator smoke artifacts. Never enabled for non-loopback endpoints.
    @MainActor
    static func recordResumeSmoke(_ message: Message, checkpoint: TurnCheckpoint? = nil) {
        guard UserDefaults.standard.bool(forKey: "StrataResumeReport"),
              let base = value("StrataMockBaseURL"),
              ["127.0.0.1", "localhost"].contains(URL(string: base)?.host ?? ""),
              let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        var fields: [String: Any] = ["text": message.text, "reasoning": message.reasoning,
                                    "stopped": message.stoppedByUser, "steps": message.steps.count,
                                    "error": message.errorText ?? "", "pending": message.resumeData != nil]
        if let checkpoint {
            fields["request_id"] = checkpoint.requestID ?? ""
            fields["seq"] = checkpoint.lastSequence
            fields["idempotency_key"] = checkpoint.idempotencyKey ?? ""
            fields["submission_started"] = checkpoint.submissionStarted
        }
        let name = checkpoint == nil ? "resume-completion.json" : "resume-checkpoint.json"
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }

    /// Three sample chats with a few artifacts each, for gallery screenshots. Runs once: skipped when the first chat exists.
    @MainActor
    static func seedArtifacts(context: ModelContext) {
        let samples: [(chat: String, pages: [(String, String, String)])] = [
            ("Budget planning", [("Mortgage calculator", "#4f46e5", "Monthly payment"), ("Savings tracker", "#0f766e", "Saved this year")]),
            ("Weekend trip to Busan", [("Trip itinerary", "#e08e1b", "Day 1 · Haeundae"), ("Packing checklist", "#9b5df0", "12 of 18 packed"),
                                       ("Weather chart", "#1fa987", "Sat 24° · Sun 22°")]),
            ("Learning Swift", [("Concurrency quiz", "#d92d20", "Question 3 of 10")]),
        ]
        let existing = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        guard !existing.contains(where: { $0.title == samples[0].chat }) else { return }
        var day = 0
        for sample in samples {
            let chat = Conversation(title: sample.chat)
            chat.updatedAt = .now.addingTimeInterval(TimeInterval(-86_400 * day))
            context.insert(chat)
            for (title, color, line) in sample.pages {
                day += 1
                let html = """
                <!doctype html><html><head><meta name="color-scheme" content="light dark"><style>
                body{font:16px -apple-system,sans-serif;margin:0;padding:24px;background:Canvas;color:CanvasText}
                .hero{background:\(color);color:#fff;border-radius:18px;padding:22px}
                h1{margin:0 0 6px;font-size:26px} .bar{height:12px;border-radius:6px;background:\(color);opacity:.35;margin:14px 0}
                </style></head><body><div class="hero"><h1>\(title)</h1><div>\(line)</div></div>
                <div class="bar" style="width:80%"></div><div class="bar" style="width:55%"></div><div class="bar" style="width:68%"></div>
                </body></html>
                """
                try? ArtifactStore.shared.save(title: title, html: html, conversationID: chat.id,
                                               now: .now.addingTimeInterval(TimeInterval(-3_600 * 7 * day)))
            }
        }
        try? context.save()
    }

    /// `-StrataMultiChatDemo 1`: four sample chats (made once), two shown replying, one queued and one with a reply not
    /// seen yet, for screenshots of the sidebar marks and the banner. Nothing is sent.
    @MainActor
    static func multiChatDemo(context: ModelContext, controller: ChatController) async {
        guard value("StrataMultiChatDemo") != nil else { return }
        let titles = ["Weekend trip to Busan", "Compare three laptops", "Learning Swift concurrency", "Budget planning"]
        var chats = ((try? context.fetch(FetchDescriptor<Conversation>())) ?? []).filter { titles.contains($0.title) }
        for title in titles where !chats.contains(where: { $0.title == title }) {
            let chat = Conversation(title: title)
            context.insert(chat)
            chats.append(chat)
        }
        // At the top of the list, the unread one first.
        for chat in chats {
            let place = chat.title == titles[3] ? 0 : (titles.firstIndex(of: chat.title) ?? 0) + 1
            chat.updatedAt = .now.addingTimeInterval(TimeInterval(-60 * place))
        }
        try? context.save()
        let byTitle = Dictionary(chats.map { ($0.title, $0.id) }, uniquingKeysWith: { a, _ in a })
        try? await Task.sleep(for: .seconds(1.5)) // after the chat on screen is known
        guard let trip = byTitle[titles[0]], let laptops = byTitle[titles[1]], let swift = byTitle[titles[2]],
              let budget = byTitle[titles[3]] else { return }
        controller.debugMultiChatDemo(running: [trip, laptops], queued: swift, unread: budget, title: titles[3])
    }

    static var autoSend: String? { value("StrataAutoSend") }
    @MainActor static var autoSendFired = false
    static var openSheet: String? { value("StrataOpenSheet") }
}

#if os(iOS)
import UIKit
import ObjectiveC

extension DebugHooks {
    /// Opens the `index`-th context-menu-backed control on screen (sorted top to bottom, then left to right), the
    /// way a tap would, so screenshots can show an open SwiftUI `Menu`. Debug builds only; uses a private UIKit entry.
    @MainActor
    static func presentMenu(index: Int) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var found: [(frame: CGRect, interaction: UIContextMenuInteraction)] = []
        func walk(_ view: UIView, in window: UIWindow) {
            guard !view.isHidden, view.alpha > 0 else { return }
            for case let m as UIContextMenuInteraction in view.interactions {
                found.append((view.convert(view.bounds, to: window), m))
            }
            view.subviews.forEach { walk($0, in: window) }
        }
        windows.forEach { walk($0, in: $0) }
        found.sort { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        for (i, f) in found.enumerated() { NSLog("StrataOpenMenu %d: %@", i, NSCoder.string(for: f.frame)) }
        guard index < found.count else { return }
        let target = found[index]
        let selector = NSSelectorFromString("_presentMenuAtLocation:")
        guard let method = class_getInstanceMethod(type(of: target.interaction), selector) else { return }
        typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
        let present = unsafeBitCast(method_getImplementation(method), to: Present.self)
        let view = target.interaction.view
        present(target.interaction, selector, CGPoint(x: view?.bounds.midX ?? 0, y: view?.bounds.midY ?? 0))
    }
}
#endif
#endif
