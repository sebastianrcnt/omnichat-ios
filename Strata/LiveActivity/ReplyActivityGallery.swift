#if DEBUG && os(iOS)
import SwiftUI

/// `-StrataLiveActivityGallery 1`: instead of the app, the Live Activity's layouts as plain views (Xcode previews can't
/// be screenshotted): the Lock Screen card on a light and a dark backdrop, and the Dynamic Island's compact, minimal
/// and expanded pieces on black capsules sized like an iPhone's. `n` starts at the n-th sample.
struct ReplyActivityGallery: View {
    static var isRequested: Bool { UserDefaults.standard.integer(forKey: "StrataLiveActivityGallery") > 0 }
    private var page: Int { UserDefaults.standard.integer(forKey: "StrataLiveActivityGallery") }
    private let accent = ReplyActivityStyle.accent(AccentPreset.defaultHex)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(Self.samples.dropFirst(max(0, page - 1))), id: \.name) { sample in
                    Text(sample.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    island(sample.state, stale: sample.stale)
                    lockScreen(sample.state, stale: sample.stale, scheme: .light)
                    lockScreen(sample.state, stale: sample.stale, scheme: .dark)
                }
            }
            .padding(16)
        }
        .background(Color(white: 0.55))
    }

    private func lockScreen(_ state: ReplyActivityAttributes.ContentState, stale: Bool, scheme: ColorScheme) -> some View {
        ReplyActivityLockScreen(state: state, accent: accent, isStale: stale)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .environment(\.colorScheme, scheme)
    }

    private func island(_ state: ReplyActivityAttributes.ContentState, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                // Compact: leading and trailing around the camera.
                HStack(spacing: 0) {
                    ReplyActivityIsland.CompactLeading(state: state, accent: accent)
                        .frame(width: 52, alignment: .leading)
                    Color.clear.frame(width: 120)
                    ReplyActivityIsland.CompactTrailing(state: state, accent: accent)
                        .frame(width: 52, alignment: .trailing)
                }
                .padding(.horizontal, 10)
                .frame(height: 37)
                .background(Capsule().fill(.black))
                // Minimal.
                ReplyActivityIsland.Minimal(state: state, accent: accent)
                    .frame(width: 37, height: 37)
                    .background(Circle().fill(.black))
            }
            // Expanded.
            VStack(spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    ReplyActivityIsland.ExpandedLeading(state: state, accent: accent)
                    ReplyActivityIsland.ExpandedCenter(state: state, accent: accent, isStale: stale)
                    ReplyActivityIsland.ExpandedTrailing(state: state, accent: accent)
                }
                ReplyActivityIsland.ExpandedBottom(state: state, accent: accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: 371)
            .background(RoundedRectangle(cornerRadius: 44, style: .continuous).fill(.black))
            .environment(\.colorScheme, .dark)
        }
    }

    private struct Sample {
        var name: String
        var state: ReplyActivityAttributes.ContentState
        var stale = false
    }

    private static let ids = (0..<5).map { _ in UUID() }

    private static func chat(_ i: Int, _ title: String, _ input: (inout ReplyActivityInput) -> Void) -> ReplyActivityChat {
        var value = ReplyActivityInput(id: ids[i], title: title, phase: .thinking, steps: 0, started: .now - Double(30 + i * 50))
        input(&value)
        return ReplyActivityPhase.chat(value)
    }

    private static let browsing = chat(0, "성수동 조용한 카페 3곳") {
        $0.phase = .tool(name: ToolNames.browserOpen, argument: "https://map.naver.com/p/search/성수동 카페")
        $0.steps = 4
    }
    private static let ssh = chat(1, "Restart the nginx container") {
        $0.phase = .tool(name: SSHToolNames.exec, argument: "docker restart nginx")
        $0.approval = .sshCommand(server: "homelab")
        $0.steps = 2
    }
    private static let python = chat(2, "Plot Seoul rainfall by month") {
        $0.phase = .tool(name: ToolNames.runPython, argument: "import pandas")
        $0.steps = 3
    }
    private static let queued = chat(3, "Summarize the WWDC session") { $0.phase = .queued }
    private static let ready = ReplyActivityPhase.ended(
        id: ids[4], title: "2024 fertility rate in Korea",
        outcome: .ready(answer: "## Summary\nKorea's total fertility rate rose to **0.75** in 2024, the first increase in nine years, mostly because marriages delayed by the pandemic caught up."),
        steps: 6, started: .now - 154)

    private static let samples: [Sample] = [
        Sample(name: "One chat, browsing", state: ReplyActivityPhase.state(running: [browsing], ended: [])),
        Sample(name: "Needs you (SSH approval)", state: ReplyActivityPhase.state(running: [ssh], ended: [])),
        Sample(name: "Several chats", state: ReplyActivityPhase.state(running: [browsing, ssh, python, queued], ended: [ready])),
        Sample(name: "Reply ready", state: ReplyActivityPhase.state(running: [], ended: [ready])),
        Sample(name: "Two chats, one done", state: ReplyActivityPhase.state(running: [python], ended: [ready])),
        Sample(name: "App suspended (stale)", state: ReplyActivityPhase.state(running: [browsing], ended: []), stale: true),
    ]
}
#endif
