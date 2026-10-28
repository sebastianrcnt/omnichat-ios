import SwiftUI
import SwiftData

extension ChatView {
    #if DEBUG
    func debugTimeline() async {
        if DebugHooks.value("StrataDebugBranch") != nil {
            if run == nil, !branchDebugDone, conversation?.leafMessage?.role == .assistant {
                branchDebugDone = true
                Task { await debugBranching() } // not tied to this task: it is cancelled when the turn starts
            }
            return
        }
        guard let sheet = DebugHooks.openSheet, sheet.hasPrefix("timeline") || ["usage", "context", "rename", "selecttext", "regentitle", "artifact", "details", "compaction", "summarize", "translate"].contains(sheet) else { return }
        if sheet == "translate" { // translates the first answer once it is in
            if run == nil, !branchDebugDone, let m = conversation?.leafMessage, m.role == .assistant {
                branchDebugDone = true
                controller.translation.translate(m, context: context)
            }
            return
        }
        if sheet == "compaction" {
            if run == nil, let r = conversation?.sortedCompactions.last { compactionNotes = r }
            return
        }
        if sheet == "summarize" { // "Summarize now" once the first answer is in
            if run == nil, !branchDebugDone, let c = conversation, c.leafMessage?.role == .assistant {
                branchDebugDone = true
                controller.compactNow(conversation: c, context: context)
            }
            return
        }
        if sheet == "rename" {
            if run == nil, let c = conversation, c.messages.contains(where: { $0.role == .assistant }) {
                renameText = "score가 NULL인 행은 어떻게 처리되는지 SQL 집계 함수 동작 정리"
                showRename = true
            }
            return
        }
        if sheet == "regentitle" { // "Regenerate title" once the first answer is named
            if run == nil, !branchDebugDone, let c = conversation, c.leafMessage?.role == .assistant {
                branchDebugDone = true
                try? await Task.sleep(for: .seconds(3)) // past the automatic title
                guard !controller.isTitling(c.id) else { return }
                controller.autoRename(conversation: c, context: context, force: true)
            }
            return
        }
        if sheet == "artifact" { // the chat's newest artifact, once the answer is in
            if run == nil, debugArtifact == nil, let c = conversation,
               let a = ArtifactStore.shared.artifacts(conversationID: c.id).max(by: { $0.updated < $1.updated }) {
                debugArtifact = ArtifactRef(conversationID: c.id, id: a.id, title: a.title, version: a.version)
            }
            return
        }
        if sheet == "selecttext" {
            if run == nil, debugSelection == nil, let m = conversation?.leafMessage, m.role == .assistant {
                debugSelection = MarkdownPlain.text(from: m.text)
            }
            return
        }
        if sheet == "details" {
            if run == nil, conversation != nil { showDetails = true }
            return
        }
        if sheet == "usage" || sheet == "context" {
            if run == nil, conversation?.messages.contains(where: { $0.role == .assistant }) == true { showContext = true }
            return
        }
        if sheet == "timelinelive" {
            guard let id = run?.messageID else { return }
            try? await Task.sleep(for: .seconds(2.5))
            timeline = conversation?.messages.first { $0.id == id }.map { TimelineRequest(message: $0, showsTools: true) }
        } else if run == nil {
            timeline = conversation?.messages.filter { $0.role == .assistant }.max { $0.sortIndex < $1.sortIndex }
                .map { TimelineRequest(message: $0, showsTools: sheet != "timelinereasoning") }
        }
    }
    #endif

    #if DEBUG
    /// `-StrataDebugBranch switch`: edits the first question and regenerates the answer, so the switchers show.
    /// `-StrataDebugBranch editbar`: puts the first question into the composer in edit mode.
    func debugBranching() async {
        guard let mode = DebugHooks.value("StrataDebugBranch"), let c = conversation,
              let first = c.activePath.first(where: { $0.role == .user }) else { return }
        func settle() async {
            for _ in 0..<200 {
                try? await Task.sleep(for: .milliseconds(200))
                if !isStreamingHere { break }
            }
        }
        if mode == "editbar" { beginEdit(first); return }
        controller.send(text: "An edited version of the first question", images: [], conversation: c, context: context, editing: first)
        await settle()
        controller.regenerate(conversation: c, context: context)
        await settle()
    }
    #endif

    func debugActions() async {
        #if DEBUG
        func openRequestedSheet() {
            switch DebugHooks.openSheet {
            case "usage" where conversation != nil: showContext = true
            case "model", "chatsettings": showChatSettings = true
            case "settings", "diagnostics", "licenses", "connection", "health", "icloud": onOpenSettings()
            case "attach": showAttach = true
            case "code": debugViewer = true
            default: break
            }
        }
        if DebugHooks.autoPickRecent {
            showAttach = true
            try? await Task.sleep(for: .seconds(4)) // the strip picks a photo and the sheet closes
            if let text = DebugHooks.autoSend { draft.text = text; send() }
            return
        }
        if let text = DebugHooks.autoSend, conversation == nil, !DebugHooks.autoSendFired {
            DebugHooks.autoSendFired = true // New Chat later must not send it again
            try? await Task.sleep(for: .seconds(1.5))
            // `-StrataAutoSendRepeat N` sends it N times, each after the last answer, for a long chat.
            let times = max(1, DebugHooks.value("StrataAutoSendRepeat").flatMap(Int.init) ?? 1)
            for _ in 0..<times {
                draft.text = text
                send()
                for _ in 0..<200 {
                    try? await Task.sleep(for: .milliseconds(200))
                    if !isStreamingHere { break }
                }
                try? await Task.sleep(for: .seconds(1))
            }
            // `-StrataDebugJump 1`: scroll to the top, then press the jump button.
            if DebugHooks.value("StrataDebugJump") != nil {
                position.scrollTo(edge: .top)
                try? await Task.sleep(for: .seconds(3))
                jumpToBottom()
                // How long the main thread stalls while the jump lays the rows out (printed for smoke runs).
                let clock = ContinuousClock()
                var last = clock.now, worst = Duration.zero
                let end = last + .seconds(4)
                while clock.now < end {
                    try? await Task.sleep(for: .milliseconds(16))
                    worst = max(worst, clock.now - last)
                    last = clock.now
                }
                print("StrataDebugJump worst main-thread gap:", worst, "atBottom:", atBottom)
            }
        } else if DebugHooks.autoSend != nil {
            return
        } else {
            try? await Task.sleep(for: .seconds(1))
        }
        openRequestedSheet()
        if let text = DebugHooks.value("StrataDraft") { draft.text = text }
        #if os(iOS)
        if let n = DebugHooks.value("StrataOpenMenu").flatMap(Int.init) {
            try? await Task.sleep(for: .seconds(1.5))
            DebugHooks.presentMenu(index: n)
        }
        #endif
        #endif
    }
}

#if DEBUG
/// `-StrataOpenSheet artifact` presents one by its ref.
extension ArtifactRef: Identifiable {}

/// The sheets `-StrataOpenSheet` opens for screenshots, kept apart from the chat's own modifier chain (a long chain
/// makes the type checker give up).
struct DebugSheets: ViewModifier {
    @Binding var viewer: Bool
    @Binding var selection: String?
    @Binding var artifact: ArtifactRef?

    func body(content: Content) -> some View {
        content
            .fullScreenCoverOrSheet(isPresented: $viewer) {
                CodeViewer(content: .init(language: "swift", code: (1...60).map { "let step\($0) = configure(glassEffect: .regular, id: \($0)) // long line to scroll" }.joined(separator: "\n"))).inAppLinks()
            }
            .sheet(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
                SelectableTextSheet(text: selection ?? "")
            }
            .fullScreenCoverOrSheet(item: $artifact) { ArtifactViewer(ref: $0) }
    }
}
#endif
