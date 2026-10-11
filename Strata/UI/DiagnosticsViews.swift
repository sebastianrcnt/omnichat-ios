import SwiftUI
import SwiftData

enum DiagnosticsFormat {
    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false // "0 bytes", not "Zero KB"
        return f.string(fromByteCount: n)
    }
    static func bytes(_ n: Int) -> String { bytes(Int64(n)) }
    static func bytes(_ n: UInt64) -> String { bytes(Int64(clamping: n)) }
    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .standard) }
}

/// The system share sheet for a file or folder.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// "Save debug bundle": the strip-images option, the save button, and the share sheet for the saved folder.
struct DebugBundleSection: View {
    @Environment(\.theme) private var theme
    @AppStorage("debugBundleStripImages") private var stripImages = true
    let save: @MainActor (DebugRedaction.Options) async throws -> URL

    @State private var saved: URL?
    @State private var error: String?
    @State private var saving = false
    @State private var showShare = false

    var body: some View {
        GroupedSection(header: "Debug bundle", footer: footer) {
            SettingsToggleRow(title: "Strip images", subtitle: "Replaces inline image data with its size.", isOn: $stripImages)
            SettingsRow(systemImage: "square.and.arrow.down", title: saving ? "Saving…" : "Save debug bundle") {
                guard !saving else { return }
                saving = true
                error = nil
                Task {
                    defer { saving = false }
                    do {
                        saved = try await save(.init(stripImages: stripImages))
                        showShare = true
                    } catch { self.error = error.localizedDescription }
                }
            }
        }
        .sheet(isPresented: $showShare) {
            if let saved { ShareSheet(url: saved).presentationDetents([.medium, .large]) }
        }
    }

    private var footer: LocalizedStringKey {
        if let error { return "Could not save: \(error)" }
        if let saved { return "Saved to Documents/Debug/\(saved.lastPathComponent). API keys and Authorization values are always removed." }
        return "Saves report.json, request bodies and memory stats to Documents/Debug. API keys and Authorization values are always removed."
    }
}

// MARK: - Conversation details

struct ConversationDetailsSheet: View {
    @Environment(\.theme) private var theme
    let conversation: Conversation
    let contextLength: Int
    @Environment(ChatController.self) private var controller

    @State private var details: ConversationDiagnostics?
    @State private var app: AppDiagnostics?

    var body: some View {
        SheetScaffold(title: "Conversation details", trailing: {
            GlassIconButton(systemName: "arrow.clockwise", label: "Refresh") { refresh() }
        }) {
            if let d = details {
                content(d)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, DS.Spacing.xl)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .task { await Task.yield(); refresh() }
    }

    private func refresh() {
        details = ConversationDiagnostics.make(for: conversation, window: contextLength)
    }

    @ViewBuilder
    private func content(_ d: ConversationDiagnostics) -> some View {
        GroupedSection(header: "Structure") {
            SettingsRow(title: "Messages", value: "\(d.structure.messages)")
            SettingsRow(title: "You / assistant", value: "\(d.structure.userMessages) / \(d.structure.assistantMessages)")
            if let branches = d.structure.branches { SettingsRow(title: "Branches", value: "\(branches)") }
            SettingsRow(title: "Active path", value: "\(d.structure.activePathLength) messages")
        }
        GroupedSection(header: "Storage", footer: "Values of 128 KB or more are kept in separate files by SwiftData; that count is an estimate.") {
            SettingsRow(title: "Text", value: DiagnosticsFormat.bytes(d.storage.textBytes))
            SettingsRow(title: "Reasoning", value: DiagnosticsFormat.bytes(d.storage.reasoningBytes))
            SettingsRow(title: "Steps", value: DiagnosticsFormat.bytes(d.storage.stepsBytes))
            SettingsRow(title: "Segments", value: DiagnosticsFormat.bytes(d.storage.segmentsBytes))
            SettingsRow(title: "Sources", value: DiagnosticsFormat.bytes(d.storage.sourcesBytes))
            SettingsRow(title: "Attachments", value: "\(d.storage.attachments)")
            SettingsRow(title: "Images, full size", value: DiagnosticsFormat.bytes(d.storage.attachmentFullBytes))
            SettingsRow(title: "Images, thumbnails", value: DiagnosticsFormat.bytes(d.storage.attachmentThumbnailBytes))
            SettingsRow(title: "Resume data, static", value: DiagnosticsFormat.bytes(d.storage.resumeStaticBytes))
            SettingsRow(title: "Resume data, dynamic", value: DiagnosticsFormat.bytes(d.storage.resumeDynamicBytes))
            SettingsRow(title: "External values (est.)", value: "\(d.storage.externalValues)")
            SettingsRow(title: "External bytes (est.)", value: DiagnosticsFormat.bytes(d.storage.externalBytes))
        }
        GroupedSection(header: "Context") {
            if let p = d.context.promptTokens, let c = d.context.completionTokens {
                SettingsRow(title: "Prompt tokens", value: p.formatted())
                SettingsRow(title: "Completion tokens", value: c.formatted())
                SettingsRow(title: "Cached", value: d.context.cachedTokens.map { "\($0.formatted())" + (d.context.cacheHitPercent.map { " (\($0)%)" } ?? "") } ?? "—")
            } else {
                SettingsRow(title: "Last usage", value: "—")
            }
            SettingsRow(title: "Estimate", value: "\(TokenFormat.short(d.context.estimatedTokens)) of \(TokenFormat.short(d.context.windowTokens)) tokens")
            if let compaction = d.context.compaction { SettingsRow(title: "Compaction", value: compaction) }
        }
        GroupedSection(header: "Recent requests", footer: d.requests.isEmpty ? "Requests sent from this device since the app started appear here." : "The last \(RequestRing.keepRecent) request bodies, kept compressed in memory.") {
            if d.requests.isEmpty {
                SettingsRow(title: "No requests yet")
            } else {
                ForEach(Array(d.requests.enumerated()), id: \.offset) { _, r in RequestRowView(request: r) }
            }
        }
        GroupedSection(header: "Checkpoint", footer: "This turn's resume checkpoint. Empty for connections without resumable replies.") {
            SettingsRow(title: "Static size", value: DiagnosticsFormat.bytes(d.checkpoint.staticBytes))
            SettingsRow(title: "Dynamic size", value: DiagnosticsFormat.bytes(d.checkpoint.dynamicBytes))
            SettingsRow(title: "Last flush", value: d.checkpoint.lastFlush.map(DiagnosticsFormat.time) ?? "—")
            SettingsRow(title: "Flushes", value: "\(d.checkpoint.flushCount)")
            SettingsRow(title: "Written this turn", value: DiagnosticsFormat.bytes(d.checkpoint.bytesWrittenThisTurn))
        }
        DebugBundleSection { options in try await saveBundle(d, options: options) }
    }

    private func saveBundle(_ d: ConversationDiagnostics, options: DebugRedaction.Options) async throws -> URL {
        let app = await AppDiagnostics.collect(activeTurn: controller.activeConversationID?.uuidString, backgroundLease: controller.backgroundStateDescription)
        return try DebugBundle.write(app: app, conversations: [d], requestConversations: [conversation.id], options: options)
    }
}

struct RequestRowView: View {
    @Environment(\.theme) private var theme
    let request: ConversationDiagnostics.Request

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
            HStack {
                Text(DiagnosticsFormat.time(request.time)).font(DS.Typography.ui).foregroundStyle(theme.textPrimary)
                Spacer()
                Text(request.finishReason ?? "—").font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
            }
            Text(request.url).font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary).lineLimit(1).truncationMode(.middle)
            Text("\(DiagnosticsFormat.bytes(request.bodyBytes)) · \(request.messageCount ?? 0) messages")
                .font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
            if let p = request.promptTokens, let c = request.completionTokens {
                Text("\(p.formatted()) in · \(c.formatted()) out" + (request.cachedTokens.map { " · \($0.formatted()) cached" } ?? ""))
                    .font(DS.Typography.uiSmall).foregroundStyle(theme.textSecondary)
            }
            if let note = request.note {
                Text(note + (request.toolsDiffer ? "; tools differ" : ""))
                    .font(DS.Typography.uiSmall)
                    .foregroundStyle(note.hasPrefix("same prefix") && !request.toolsDiffer ? theme.textTertiary : theme.destructive)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
    }
}

// MARK: - App-wide diagnostics

struct AppDiagnosticsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Environment(ChatController.self) private var controller

    @State private var app: AppDiagnostics?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                if let a = app { content(a) } else { ProgressView().frame(maxWidth: .infinity).padding(.top, DS.Spacing.xl) }
            }
            .padding(DS.Spacing.lg)
        }
        .background(theme.background.ignoresSafeArea())
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Measured only while this screen is open.
            while !Task.isCancelled {
                app = await AppDiagnostics.collect(activeTurn: controller.activeConversationID?.uuidString,
                                                   backgroundLease: controller.backgroundStateDescription)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    @ViewBuilder
    private func content(_ a: AppDiagnostics) -> some View {
        GroupedSection(header: "Memory") {
            SettingsRow(title: "Footprint", value: DiagnosticsFormat.bytes(a.memory.footprintBytes))
            SettingsRow(title: "Peak", value: DiagnosticsFormat.bytes(a.memory.peakBytes))
            SettingsRow(title: "Available", value: a.memory.availableBytes == 0 ? "—" : DiagnosticsFormat.bytes(a.memory.availableBytes))
            SettingsRow(title: "Memory warnings", value: "\(a.memory.memoryWarnings)")
        }
        GroupedSection(header: "Storage") {
            SettingsRow(title: "Chat database", value: DiagnosticsFormat.bytes(a.storage.storeBytes))
            SettingsRow(title: "External storage", value: DiagnosticsFormat.bytes(a.storage.externalBytes))
            SettingsRow(title: "External files", value: "\(a.storage.externalFiles)")
            SettingsRow(title: "Favicon cache", value: DiagnosticsFormat.bytes(a.storage.faviconDiskBytes))
            SettingsRow(title: "Favicon files", value: "\(a.storage.faviconDiskFiles)")
        }
        GroupedSection(header: "Caches", footer: "Image and favicon counts are upper bounds: the system cache evicts without saying so.") {
            SettingsRow(title: "Pages", value: "\(a.caches.pageCacheEntries)")
            SettingsRow(title: "Page characters", value: a.caches.pageCacheCharacters.formatted())
            SettingsRow(title: "Image data URLs", value: "≤ \(DiagnosticsFormat.bytes(a.caches.dataURLBytesAdded))")
            SettingsRow(title: "Image cache limit", value: DiagnosticsFormat.bytes(a.caches.dataURLLimit))
            SettingsRow(title: "Favicon images", value: "≤ \(a.caches.faviconImages)")
            SettingsRow(title: "Request ring", value: DiagnosticsFormat.bytes(a.caches.requestRingBytes))
        }
        GroupedSection(header: "Live") {
            SettingsRow(title: "Hidden web views", value: "\(a.live.hiddenWebViews)")
            SettingsRow(title: "Active turn", value: a.live.activeTurn.map { String($0.prefix(8)).lowercased() } ?? "none")
            SettingsRow(title: "Recovery loops", value: "\(a.live.recoveryLoops)")
            SettingsRow(title: "Background lease", value: a.live.backgroundLease)
            SettingsRow(title: "Background identifiers", value: "\(a.live.registeredBackgroundIdentifiers) registered")
        }
        GroupedSection(header: "Counters") {
            SettingsRow(title: "Checkpoint bytes written", value: DiagnosticsFormat.bytes(a.counters.checkpointBytesWritten))
            SettingsRow(title: "Checkpoint saves", value: "\(a.counters.checkpointSaves)")
            SettingsRow(title: "Recovery attempts", value: "\(a.counters.recoveryAttempts)")
        }
        DebugBundleSection { options in try await saveBundle(options: options) }
    }

    private func saveBundle(options: DebugRedaction.Options) async throws -> URL {
        let app = await AppDiagnostics.collect(activeTurn: controller.activeConversationID?.uuidString,
                                               backgroundLease: controller.backgroundStateDescription)
        let ids = RequestRing.shared.conversationIDs
        let conversations = (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        let details = conversations.map { ConversationDiagnostics.make(for: $0, window: settings.defaultContextLength) }
        return try DebugBundle.write(app: app, conversations: details, options: options)
    }
}
