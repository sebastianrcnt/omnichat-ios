import Foundation
import SwiftData

/// Rough size of a conversation's prompt, the way atto estimates it: characters / 4.
enum ContextEstimate {
    static let tokensPerImage = 765

    static func tokens(characters: Int, images: Int = 0) -> Int { characters / 4 + images * tokensPerImage }

    /// What the next request would carry: the answers, the user's text, tool calls and results, and the images.
    @MainActor
    static func tokens(of conversation: Conversation) -> Int {
        var characters = 0
        var images = 0
        for message in conversation.messages {
            characters += message.text.utf8.count
            images += message.attachments.count
            for step in message.steps {
                characters += step.assistantContent.utf8.count
                for call in step.calls { characters += call.arguments.utf8.count + call.result.utf8.count }
            }
        }
        return tokens(characters: characters, images: images)
    }
}

enum Diagnostics {
    /// Drops what the diagnostics keep in memory for a deleted conversation.
    @MainActor
    static func forget(_ conversation: UUID) {
        RequestRing.shared.removeConversation(conversation)
        DiagnosticCounters.shared.forget(conversation: conversation)
    }
}

struct ConversationDiagnostics: Codable, Equatable, Sendable {
    struct Structure: Codable, Equatable, Sendable {
        var messages = 0
        var userMessages = 0
        var assistantMessages = 0
        /// Leaves of the message tree: 1 for a conversation that never branched.
        var branches: Int?
        var activePathLength = 0
    }

    struct Storage: Codable, Equatable, Sendable {
        var textBytes = 0
        var reasoningBytes = 0
        var stepsBytes = 0
        var segmentsBytes = 0
        var sourcesBytes = 0
        var attachments = 0
        var attachmentFullBytes = 0
        var attachmentThumbnailBytes = 0
        var resumeStaticBytes = 0
        var resumeDynamicBytes = 0
        /// Values big enough that SwiftData keeps them in a separate file (an estimate: the store does not say which).
        var externalValues = 0
        var externalBytes = 0
    }

    struct Context: Codable, Equatable, Sendable {
        var promptTokens: Int?
        var completionTokens: Int?
        var cachedTokens: Int?
        var cacheHitPercent: Int?
        var estimatedTokens = 0
        var windowTokens = 0
        /// Describes compaction once it exists.
        var compaction: String?
    }

    struct Request: Codable, Equatable, Sendable {
        var file: String
        var time: Date
        var url: String
        var bodyBytes: Int
        var storedBytes: Int
        var messageCount: Int?
        var finishReason: String?
        var promptTokens: Int?
        var completionTokens: Int?
        var cachedTokens: Int?
        /// Relation to the previous request in the list; nil for the first.
        var note: String?
        var toolsDiffer = false
    }

    struct Checkpoint: Codable, Equatable, Sendable {
        var staticBytes = 0
        var dynamicBytes = 0
        var lastFlush: Date?
        var flushCount = 0
        var bytesWrittenThisTurn = 0
    }

    var id: UUID
    var title: String
    var structure = Structure()
    var storage = Storage()
    var context = Context()
    var requests: [Request] = []
    var checkpoint = Checkpoint()

    /// SwiftData keeps values above about this size in separate files.
    static let externalThreshold = 128 * 1024

    @MainActor
    static func make(for conversation: Conversation, window: Int, ring: RequestRing = .shared,
                     counters: DiagnosticCounters = .shared) -> ConversationDiagnostics {
        var d = ConversationDiagnostics(id: conversation.id, title: conversation.displayTitle)
        let messages = conversation.sortedMessages
        d.structure = Structure(messages: messages.count,
                                userMessages: messages.filter { $0.role == .user }.count,
                                assistantMessages: messages.filter { $0.role == .assistant }.count,
                                branches: conversation.treeIndex.leafCount, activePathLength: conversation.activePath.count)

        var s = Storage()
        func external(_ bytes: Int) {
            if bytes >= externalThreshold { s.externalValues += 1; s.externalBytes += bytes }
        }
        for m in messages {
            s.textBytes += m.text.utf8.count
            s.reasoningBytes += m.reasoning.utf8.count
            let steps = m.stepsData?.count ?? 0, segments = m.segmentsData?.count ?? 0
            let rs = m.resumeData?.count ?? 0, rd = m.resumeDynamicData?.count ?? 0
            s.stepsBytes += steps; s.segmentsBytes += segments
            s.resumeStaticBytes += rs; s.resumeDynamicBytes += rd
            external(steps); external(segments); external(rs)
            for a in m.attachments {
                s.attachments += 1
                s.attachmentFullBytes += a.jpegData.count
                s.attachmentThumbnailBytes += a.thumbnailData?.count ?? 0
                external(a.jpegData.count)
            }
        }
        s.sourcesBytes = conversation.sourcesData?.count ?? 0
        external(s.sourcesBytes)
        d.storage = s

        var c = Context(estimatedTokens: ContextEstimate.tokens(of: conversation), windowTokens: window)
        if let u = conversation.lastUsage {
            c.promptTokens = u.promptTokens
            c.completionTokens = u.completionTokens
            c.cachedTokens = u.cachedTokens
            if let cached = u.cachedTokens, u.promptTokens > 0 {
                c.cacheHitPercent = Int((Double(cached) / Double(u.promptTokens) * 100).rounded())
            }
        }
        d.context = c

        d.requests = requestSummaries(ring.recent(for: conversation.id), conversation: conversation.id)

        if let stats = counters.checkpointStats(for: conversation.id) {
            d.checkpoint = Checkpoint(staticBytes: stats.staticBytes, dynamicBytes: stats.dynamicBytes, lastFlush: stats.lastFlush,
                                      flushCount: stats.flushCount, bytesWrittenThisTurn: stats.bytesWritten)
        }
        return d
    }

    /// Short file stem for a conversation in the debug bundle.
    static func fileStem(for id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    static func requestSummaries(_ records: [RequestRecord], conversation: UUID) -> [Request] {
        var out: [Request] = []
        var previousBody: Data?
        for (i, r) in records.enumerated() {
            let body = RequestRing.body(of: r)
            var req = Request(file: "requests/\(fileStem(for: conversation))-\(i + 1).json", time: r.time, url: r.url,
                              bodyBytes: r.bodyBytes, storedBytes: r.storedBytes,
                              messageCount: r.messageCount ?? body.map { RequestInspection.messages(in: $0).count },
                              finishReason: r.finishReason, promptTokens: r.usage?.promptTokens,
                              completionTokens: r.usage?.completionTokens, cachedTokens: r.usage?.cachedTokens)
            if let body, let result = PrefixNote.describe(previous: previousBody, current: body) {
                req.note = result.note
                req.toolsDiffer = result.toolsDiffer
            }
            previousBody = body
            out.append(req)
        }
        return out
    }
}

struct AppDiagnostics: Codable, Equatable, Sendable {
    struct Memory: Codable, Equatable, Sendable {
        var footprintBytes: UInt64 = 0
        var peakBytes: UInt64 = 0
        var availableBytes: UInt64 = 0
        var memoryWarnings = 0
    }

    struct Storage: Codable, Equatable, Sendable {
        var storeBytes: Int64 = 0
        var externalBytes: Int64 = 0
        var externalFiles = 0
        var faviconDiskBytes: Int64 = 0
        var faviconDiskFiles = 0
    }

    struct Caches: Codable, Equatable, Sendable {
        var pageCacheEntries = 0
        var pageCacheCharacters = 0
        /// Bytes added to the image data-URL cache since it was last emptied (an upper bound: it evicts silently).
        var dataURLBytesAdded = 0
        var dataURLLimit = 0
        var dataURLBuilds = 0
        var faviconImages = 0
        var requestRingBytes = 0
        var requestRingConversations = 0
    }

    struct Live: Codable, Equatable, Sendable {
        var hiddenWebViews = 0
        var activeTurn: String?
        var recoveryLoops = 0
        var backgroundLease = ""
        var registeredBackgroundIdentifiers = 0
    }

    struct Counters: Codable, Equatable, Sendable {
        var checkpointBytesWritten = 0
        var checkpointSaves = 0
        var recoveryAttempts = 0
    }

    var generated = Date()
    var memory = Memory()
    var storage = Storage()
    var caches = Caches()
    var live = Live()
    var counters = Counters()

    /// Reads everything. Disk sizes are measured off the main actor.
    @MainActor
    static func collect(activeTurn: String?, backgroundLease: String, storeRoot: URL = .applicationSupportDirectory,
                        faviconDirectory: URL? = nil, ring: RequestRing = .shared,
                        counters: DiagnosticCounters = .shared) async -> AppDiagnostics {
        var d = AppDiagnostics()
        let mem = ProcessMemory.snapshot()
        d.memory = Memory(footprintBytes: mem.footprintBytes, peakBytes: mem.peakBytes, availableBytes: mem.availableBytes,
                          memoryWarnings: MemoryPurge.purgeCount)
        let pages = PageCache.shared.stats
        let urls = ImageDataURLCache.shared
        d.caches = Caches(pageCacheEntries: pages.entries, pageCacheCharacters: pages.characters,
                          dataURLBytesAdded: urls.bytesAdded, dataURLLimit: urls.costLimit, dataURLBuilds: urls.buildCount,
                          faviconImages: FaviconImages.count, requestRingBytes: ring.totalBytes,
                          requestRingConversations: ring.conversationIDs.count)
        d.live = Live(hiddenWebViews: counters.hiddenWebViews, activeTurn: activeTurn, recoveryLoops: counters.recoveryLoopsActive,
                      backgroundLease: backgroundLease, registeredBackgroundIdentifiers: counters.registeredBackgroundIdentifiers)
        d.counters = Counters(checkpointBytesWritten: counters.checkpointBytesWritten, checkpointSaves: counters.checkpointSaves,
                              recoveryAttempts: counters.recoveryAttempts)
        let favicons = faviconDirectory ?? FaviconStore.shared.cacheDirectory
        let sizes = await Task.detached(priority: .utility) {
            (DiskUsage.swiftDataStore(in: storeRoot), DiskUsage.size(of: favicons))
        }.value
        d.storage = Storage(storeBytes: sizes.0.store.bytes, externalBytes: sizes.0.external.bytes,
                            externalFiles: sizes.0.external.files, faviconDiskBytes: sizes.1.bytes, faviconDiskFiles: sizes.1.files)
        return d
    }

    /// atto's memstats line, adapted: there is no garbage collector here, so it reports the footprint the system counts.
    var memorySummary: String {
        func mb(_ b: UInt64) -> String { String(format: "%.1f MB", Double(b) / 1_048_576) }
        return "footprint \(mb(memory.footprintBytes)) · peak \(mb(memory.peakBytes)) · available \(mb(memory.availableBytes))"
            + " · \(memory.memoryWarnings) memory warnings · \(live.hiddenWebViews) web views"
    }
}
