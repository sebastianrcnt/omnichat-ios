import Foundation
import SwiftData

/// Keeps one of each record that should exist once: a conversation per id, a saved skill per name, a synced file per
/// path. CloudKit has no unique constraints, so two devices that both upload the same thing (a store restored onto a
/// second device before sync existed, a skill both saved) end up with two records.
///
/// Every device runs this on its own, so the copy that stays must be the same everywhere, or each device would delete a
/// different copy and both would go. It is chosen by a value that never changes once a record exists (the device it
/// came from), never by ones that may be stale here (`updatedAt`, a child count still arriving). Copies from the same
/// device are left as they are. What only the other copy has is moved over first, so nothing is lost.
enum SyncDedupe {
    struct Report: Equatable {
        var conversations = 0
        var skills = 0
        var files = 0
    }

    @discardableResult
    static func run(_ context: ModelContext) throws -> Report {
        Report(conversations: try conversations(context), skills: try skills(context), files: try files(context))
    }

    /// Among copies of one record, the one that stays: the smallest origin. Nil when that can't be told the same way on
    /// every device (no origin, or two copies from the same device).
    static func keeper<T>(_ copies: [T], origin: (T) -> String?) -> T? {
        let ranked = copies.sorted { (origin($0) ?? "\u{10FFFF}") < (origin($1) ?? "\u{10FFFF}") }
        guard let first = ranked.first, let o = origin(first), ranked.dropFirst().allSatisfy({ origin($0) != o }) else { return nil }
        return first
    }

    // MARK: Conversations

    /// Merges and deletes extra copies of conversations, except those with an id in `skipping` (on screen or replying:
    /// the next run takes them). Returns how many copies were removed.
    static func conversations(_ context: ModelContext, skipping: Set<UUID> = []) throws -> Int {
        var descriptor = FetchDescriptor<Conversation>()
        descriptor.propertiesToFetch = [\.id, \.syncOrigin]
        let all = try context.fetch(descriptor)
        var removed = 0
        for copies in Dictionary(grouping: all, by: \.id).values where copies.count > 1 && !skipping.contains(copies[0].id) {
            guard let keep = keeper(copies, origin: \.syncOrigin) else { continue }
            for extra in copies where extra !== keep {
                merge(extra, into: keep)
                context.delete(extra)
                removed += 1
            }
        }
        if context.hasChanges { try context.save() }
        return removed
    }

    /// Moves what only `extra` has into `keep`: messages and compactions it alone holds, the newer title, pin, branch and
    /// model, and any frozen snapshot `keep` lacks (a frozen value is never replaced, so the cached prefix holds).
    static func merge(_ extra: Conversation, into keep: Conversation) {
        let messageIDs = Set(keep.messages.map(\.id))
        for message in extra.messages where !messageIDs.contains(message.id) { message.conversation = keep }
        let compactionIDs = Set(keep.compactions.map(\.id))
        for record in extra.compactions where !compactionIDs.contains(record.id) { record.conversation = keep }
        if extra.updatedAt > keep.updatedAt {
            keep.updatedAt = extra.updatedAt
            keep.title = extra.title
            keep.titleIsUserSet = extra.titleIsUserSet
            keep.autoRenameDone = keep.autoRenameDone || extra.autoRenameDone
            keep.isPinned = extra.isPinned
            keep.leafID = extra.leafID
            keep.connectionID = extra.connectionID
            keep.modelID = extra.modelID
            keep.effortRaw = extra.effortRaw
            keep.lastPromptTokens = extra.lastPromptTokens
            keep.lastCompletionTokens = extra.lastCompletionTokens
            keep.lastCachedTokens = extra.lastCachedTokens
            keep.lastReasoningTokens = extra.lastReasoningTokens
            keep.lastCacheWriteTokens = extra.lastCacheWriteTokens
            keep.lastUsageMessageID = extra.lastUsageMessageID
            keep.toolSwitchesRaw = extra.toolSwitchesRaw
            keep.announcedToolsRaw = extra.announcedToolsRaw
            if extra.sourcesData != nil { keep.sourcesData = extra.sourcesData }
        }
        if keep.createdDay.isEmpty { keep.createdDay = extra.createdDay }
        if keep.preferencesSnapshot == nil { keep.preferencesSnapshot = extra.preferencesSnapshot }
        if keep.skillIndexSnapshot == nil { keep.skillIndexSnapshot = extra.skillIndexSnapshot }
        if keep.pluginSectionSnapshot == nil { keep.pluginSectionSnapshot = extra.pluginSectionSnapshot }
        if keep.offeredToolsRaw == nil {
            keep.offeredToolsRaw = extra.offeredToolsRaw
            keep.announcedToolsRaw = extra.announcedToolsRaw
        }
        keep.treeLinked = keep.treeLinked && extra.treeLinked
    }

    // MARK: Skills

    static func skills(_ context: ModelContext) throws -> Int {
        let all = try context.fetch(FetchDescriptor<SyncedSkill>())
        var removed = 0
        for copies in Dictionary(grouping: all, by: \.name).values where copies.count > 1 {
            guard let keep = keeper(copies, origin: \.origin) else { continue }
            for extra in copies where extra !== keep {
                if extra.updatedAt > keep.updatedAt {
                    keep.update(from: extra.skill)
                    keep.updatedAt = extra.updatedAt
                }
                context.delete(extra)
                removed += 1
            }
        }
        if context.hasChanges { try context.save() }
        return removed
    }

    // MARK: Files

    static func files(_ context: ModelContext) throws -> Int {
        var descriptor = FetchDescriptor<SyncedFile>()
        descriptor.propertiesToFetch = [\.path, \.origin, \.updatedAt]
        let all = try context.fetch(descriptor)
        var removed = 0
        for copies in Dictionary(grouping: all, by: \.path).values where copies.count > 1 {
            guard let keep = keeper(copies, origin: \.origin) else { continue }
            for extra in copies where extra !== keep {
                if extra.updatedAt > keep.updatedAt {
                    keep.data = extra.data
                    keep.updatedAt = extra.updatedAt
                }
                context.delete(extra)
                removed += 1
            }
        }
        if context.hasChanges { try context.save() }
        return removed
    }
}
