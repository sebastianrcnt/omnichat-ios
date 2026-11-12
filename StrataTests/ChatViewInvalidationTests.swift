import Testing
import Foundation
import SwiftUI
import SwiftData
import UIKit
@testable import Strata

/// Hosts the real chat view over a long conversation and counts how often the transcript's rows are evaluated: the
/// composer growing and taking focus must not re-evaluate them, and only the rows on screen are ever built.
@MainActor
@Suite(.serialized)
struct ChatViewInvalidationTests {
    @MainActor @Observable final class Knobs { var focusToken = 0 }

    struct Harness: View {
        let knobs: Knobs
        let conversation: Conversation
        let draft: ComposerDraft

        var body: some View {
            ChatView(conversation: .constant(conversation), onOpenSidebar: {}, onOpenSettings: {},
                     focusToken: knobs.focusToken, draft: draft)
        }
    }

    private func settle(_ host: UIViewController, seconds: Double = 0.6) async {
        try? await Task.sleep(for: .seconds(seconds))
        host.view.layoutIfNeeded()
    }

    /// Waits until the rows stop being evaluated (the first layout, the scroll to the end), at most `limit` seconds.
    private func settleUntilStill(_ host: UIViewController, limit: Double = 8) async {
        let clock = ContinuousClock()
        let end = clock.now + .seconds(limit)
        var last = (-1, -1)
        while clock.now < end {
            await settle(host, seconds: 0.5)
            let now = (MessageRows.evaluations, MessageRow.evaluations)
            if now == last { return }
            last = now
        }
    }

    @Test func composerHeightAndFocusLeaveTheRowsAlone() async throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, Attachment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let conversation = Conversation(modelID: "m")
        conversation.autoRenameDone = true
        context.insert(conversation)
        var last: Message?
        for i in 0..<300 {
            let m = Message(role: i.isMultiple(of: 2) ? .user : .assistant,
                            text: i.isMultiple(of: 2) ? "Question \(i)?" : "Answer \(i), with a few words so the row has some height.",
                            sortIndex: i)
            m.createdAt = Date(timeIntervalSince1970: Double(i))
            context.insert(m)
            conversation.attach(m, parent: last)
            last = m
        }
        try context.save()

        let knobs = Knobs()
        let draft = ComposerDraft()
        let root = Harness(knobs: knobs, conversation: conversation, draft: draft)
            .environment(\.modelContext, context)
            .environment(\.theme, DSTheme())
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            Issue.record("no window scene available; skipped")
            return
        }
        let host = UIHostingController(rootView: root)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = host
        window.windowLevel = .alert + 1
        window.isHidden = false
        defer { window.isHidden = true }
        MessageRows.evaluations = 0
        MessageRow.evaluations = 0
        host.view.layoutIfNeeded()
        await settleUntilStill(host)

        let rowsBuilt = MessageRows.evaluations
        let rowBodies = MessageRow.evaluations
        #expect(rowsBuilt >= 1)
        // Lazy: a screenful of rows (and a few around it), not 300.
        #expect(rowBodies > 0 && rowBodies < 60, "row bodies: \(rowBodies)")

        // The composer grows to several lines.
        draft.text = "one\ntwo\nthree\nfour\nfive"
        await settle(host)
        #expect(MessageRows.evaluations == rowsBuilt)

        // The composer takes focus (New Chat's focus request), then loses it.
        knobs.focusToken = 1
        await settle(host)
        #expect(MessageRows.evaluations == rowsBuilt)
        draft.text = ""
        await settle(host)
        #expect(MessageRows.evaluations == rowsBuilt)
        print("ChatViewInvalidation: rows built for 300 messages:", rowBodies, "row lists evaluated:", MessageRows.evaluations,
              "rows re-evaluated by composer and focus:", MessageRow.evaluations - rowBodies)
    }
}
