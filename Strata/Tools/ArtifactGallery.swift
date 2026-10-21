import Foundation

// The Artifacts gallery's logic: which artifacts show for a search, in what order, grouped how. No views here, so it is
// tested on its own.

/// How the gallery lays out its artifacts. Remembered per device.
enum ArtifactGalleryMode: String, CaseIterable, Identifiable, Sendable {
    case grid, list, byChat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: String(localized: "Grid")
        case .list: String(localized: "List")
        case .byChat: String(localized: "By Chat")
        }
    }

    var systemImage: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        case .byChat: "rectangle.grid.1x2"
        }
    }
}

/// The gallery's order. Remembered per device.
enum ArtifactGallerySort: String, CaseIterable, Identifiable, Sendable {
    case updated, title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .updated: String(localized: "Last Updated")
        case .title: String(localized: "Title")
        }
    }
}

/// One artifact in the gallery: the stored entry and what it shows of the chat that made it.
struct ArtifactGalleryItem: Hashable, Sendable, Identifiable {
    var entry: ArtifactStore.Entry
    /// The chat's title; nil when the chat is unknown.
    var chatTitle: String?
    /// The chat's last activity, for ordering the By Chat sections.
    var chatUpdated: Date?

    var id: String { entry.id }
    var artifact: Artifact { entry.artifact }
    var conversationID: UUID { entry.conversationID }
}

/// A By Chat section: one chat and its artifacts in the gallery's order.
struct ArtifactGalleryGroup: Hashable, Sendable, Identifiable {
    var conversationID: UUID
    var chatTitle: String?
    var items: [ArtifactGalleryItem]

    var id: UUID { conversationID }
}

enum ArtifactGallery {
    /// The items whose artifact title or chat title contains every word of `query` (ignoring case and accents). A blank
    /// query keeps them all.
    static func filter(_ items: [ArtifactGalleryItem], query: String) -> [ArtifactGalleryItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let haystack = item.artifact.title + "\n" + (item.chatTitle ?? "")
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// Last updated first, or by title (A to Z, as Finder sorts names); ties fall back to the other key, then the id, so
    /// the order never changes between loads.
    static func sorted(_ items: [ArtifactGalleryItem], by sort: ArtifactGallerySort) -> [ArtifactGalleryItem] {
        items.sorted { a, b in
            switch sort {
            case .updated:
                if a.artifact.updated != b.artifact.updated { return a.artifact.updated > b.artifact.updated }
                let order = a.artifact.title.localizedStandardCompare(b.artifact.title)
                if order != .orderedSame { return order == .orderedAscending }
            case .title:
                let order = a.artifact.title.localizedStandardCompare(b.artifact.title)
                if order != .orderedSame { return order == .orderedAscending }
                if a.artifact.updated != b.artifact.updated { return a.artifact.updated > b.artifact.updated }
            }
            return a.id < b.id
        }
    }

    /// One section per chat, newest chat first (its last activity, or its newest artifact when the chat's is unknown);
    /// each keeps the order of `items`.
    static func grouped(_ items: [ArtifactGalleryItem]) -> [ArtifactGalleryGroup] {
        var groups: [UUID: ArtifactGalleryGroup] = [:]
        var newest: [UUID: Date] = [:]
        for item in items {
            groups[item.conversationID, default: ArtifactGalleryGroup(conversationID: item.conversationID, chatTitle: item.chatTitle,
                                                                      items: [])].items.append(item)
            let date = item.chatUpdated ?? item.artifact.updated
            newest[item.conversationID] = max(newest[item.conversationID] ?? date, date)
        }
        return groups.values.sorted { a, b in
            let da = newest[a.conversationID] ?? .distantPast, db = newest[b.conversationID] ?? .distantPast
            return da != db ? da > db : a.conversationID.uuidString < b.conversationID.uuidString
        }
    }

    /// What the gallery shows, in the order it shows it: filtered, sorted, and for By Chat the sections one after another.
    /// The viewer pages through this order.
    static func ordered(_ items: [ArtifactGalleryItem], query: String, sort: ArtifactGallerySort,
                        mode: ArtifactGalleryMode) -> [ArtifactGalleryItem] {
        let shown = sorted(filter(items, query: query), by: sort)
        return mode == .byChat ? grouped(shown).flatMap(\.items) : shown
    }

    /// The gallery items for stored entries, with their chats' titles. Entries of unknown chats are left out.
    static func items(_ entries: [ArtifactStore.Entry], chats: [UUID: (title: String, updated: Date)]) -> [ArtifactGalleryItem] {
        entries.compactMap { entry in
            guard let chat = chats[entry.conversationID] else { return nil }
            return ArtifactGalleryItem(entry: entry, chatTitle: chat.title, chatUpdated: chat.updated)
        }
    }
}
