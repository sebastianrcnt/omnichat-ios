import Foundation

/// A conversation is a tree of messages, as in atto's session tree. Each message has a parent; appending makes the new
/// message a child of the active leaf and moves the leaf to it. Editing a user message or regenerating an answer adds a
/// sibling beside the old message, and the old branch stays. What is shown, and what is sent to the model, is the path
/// from the root to the leaf, so continuing any branch replays exactly the messages that were on it, byte for byte, and
/// the provider's prompt cache still matches.
///
/// Context compaction does not rewrite history. A `CompactionRecord` is anchored to a message on the path: the history
/// sent from there on is the record's replacement followed by the messages after the anchor, and the messages before it
/// stay in the tree (and on screen). A branch that does not pass through the anchor is not affected by it.

/// What the tree logic needs of a message.
struct TreeNode: Equatable, Sendable {
    var id: UUID
    var parent: UUID?
    var created: Date
    /// Tie-break for equal creation times (the message's sort index).
    var order: Int
    var lastActiveChild: UUID?
}

/// "2 / 3": which of a message's siblings is showing.
struct BranchPosition: Equatable, Sendable {
    /// 1-based, in creation order.
    var index: Int
    var count: Int
}

/// An index over a conversation's nodes: paths, siblings and descent.
struct MessageTreeIndex: Sendable {
    private let byID: [UUID: TreeNode]
    private let childrenByParent: [UUID?: [UUID]] // creation order
    let leaf: UUID?

    init(_ nodes: [TreeNode], leaf: UUID?) {
        var map: [UUID: TreeNode] = [:]
        for n in nodes { map[n.id] = n }
        byID = map
        var children: [UUID?: [TreeNode]] = [:]
        for n in nodes {
            // A parent that is not in the conversation makes the message a root.
            let parent = n.parent.flatMap { map[$0] != nil ? $0 : nil }
            children[parent, default: []].append(n)
        }
        childrenByParent = children.mapValues { $0.sorted { ($0.created, $0.order) < ($1.created, $1.order) }.map(\.id) }
        self.leaf = leaf
    }

    /// The messages from the root to `id`, in order. Empty for an unknown id.
    func path(to id: UUID?) -> [UUID] {
        var reversed: [UUID] = []
        var seen = Set<UUID>()
        var current = id
        while let c = current, let node = byID[c], seen.insert(c).inserted {
            reversed.append(c)
            current = node.parent
        }
        return reversed.reversed()
    }

    /// The active path: root to leaf.
    var activePath: [UUID] { path(to: leaf) }

    func parent(of id: UUID) -> UUID? { byID[id]?.parent.flatMap { byID[$0] != nil ? $0 : nil } }

    func children(of id: UUID?) -> [UUID] { childrenByParent[id] ?? [] }

    /// The message and its siblings, in creation order.
    func siblings(of id: UUID) -> [UUID] {
        guard byID[id] != nil else { return [] }
        return children(of: parent(of: id))
    }

    /// Nil when the message is an only child.
    func branch(of id: UUID) -> BranchPosition? {
        let all = siblings(of: id)
        guard all.count > 1, let i = all.firstIndex(of: id) else { return nil }
        return BranchPosition(index: i + 1, count: all.count)
    }

    /// The sibling `offset` places away, or nil past either end.
    func sibling(of id: UUID, offset: Int) -> UUID? {
        let all = siblings(of: id)
        guard let i = all.firstIndex(of: id), all.indices.contains(i + offset) else { return nil }
        return all[i + offset]
    }

    /// The leaf reached from `id` by following each message's last active child, or the most recently created child
    /// when it has none (or it is gone).
    func deepest(from id: UUID) -> UUID {
        var current = id
        var seen = Set<UUID>([id])
        while true {
            let kids = children(of: current)
            guard !kids.isEmpty else { return current }
            let next = byID[current]?.lastActiveChild.flatMap { kids.contains($0) ? $0 : nil } ?? kids[kids.count - 1]
            guard seen.insert(next).inserted else { return current }
            current = next
        }
    }

    /// Messages with no children.
    var leafCount: Int { byID.keys.filter { children(of: $0).isEmpty }.count }

    /// Linear parents for conversations saved before the tree existed (atto's `link()`): each message is the child of
    /// the one before it, in creation order. Returns (id, parent) pairs.
    static func linearParents(_ nodes: [TreeNode]) -> [(id: UUID, parent: UUID?)] {
        let ordered = nodes.sorted { ($0.order, $0.created) < ($1.order, $1.created) }
        var out: [(UUID, UUID?)] = []
        var previous: UUID?
        for n in ordered { out.append((n.id, previous)); previous = n.id }
        return out
    }
}

extension Conversation {
    var treeNodes: [TreeNode] {
        messages.map { TreeNode(id: $0.id, parent: $0.parentID, created: $0.createdAt, order: $0.sortIndex, lastActiveChild: $0.lastActiveChildID) }
    }

    /// Conversations from before branching are linked in creation order, with the leaf at the last message.
    /// Idempotent. Call before anything that changes the tree.
    func ensureTree() {
        guard !treeLinked else { return }
        let ordered = sortedMessages
        var previous: Message?
        for m in ordered {
            m.parentID = previous?.id
            m.lastActiveChildID = nil
            previous?.lastActiveChildID = m.id
            previous = m
        }
        leafID = ordered.last?.id
        treeLinked = true
    }

    /// True when the stored links cannot be used: a conversation from before branching, or one whose leaf is missing
    /// and whose messages weren't all linked (added without going through `attach`, so several are roots). Its
    /// messages are then taken in creation order. A linked tree that only lost its leaf (the leaf message was deleted)
    /// keeps its branches apart and follows `effectiveLeaf` instead: merging them would send both branches to the model.
    private var isLinear: Bool {
        guard treeLinked else { return true }
        if let leafID, messages.contains(where: { $0.id == leafID }) { return false }
        guard !messages.isEmpty else { return false }
        return messages.filter { $0.parentID == nil }.count > 1
    }

    /// The stored leaf, or when it is gone the newest message.
    private var effectiveLeaf: UUID? {
        if let leafID, messages.contains(where: { $0.id == leafID }) { return leafID }
        return sortedMessages.last?.id
    }

    /// The tree of this conversation (linear when the stored links cannot be used).
    var treeIndex: MessageTreeIndex {
        if !isLinear { return MessageTreeIndex(treeNodes, leaf: effectiveLeaf) }
        let nodes = MessageTreeIndex.linearParents(treeNodes)
        let parents = Dictionary(nodes.map { ($0.id, $0.parent) }, uniquingKeysWith: { first, _ in first })
        let linear = treeNodes.map { n -> TreeNode in var m = n; m.parent = parents[n.id] ?? nil; return m }
        return MessageTreeIndex(linear, leaf: sortedMessages.last?.id)
    }

    func message(id: UUID?) -> Message? {
        guard let id else { return nil }
        return messages.first { $0.id == id }
    }

    /// The messages from the root to `id`.
    func path(to id: UUID?) -> [Message] {
        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return treeIndex.path(to: id).compactMap { byID[$0] }
    }

    /// What is shown and what is sent: the path from the root to the leaf.
    var activePath: [Message] {
        if isLinear { return sortedMessages }
        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return MessageTreeIndex(treeNodes, leaf: effectiveLeaf).activePath.compactMap { byID[$0] }
    }

    var leafMessage: Message? { activePath.last }

    /// Adds `message` as a child of `parent` (nil: a new root) and makes it the leaf.
    func attach(_ message: Message, parent: Message?) {
        ensureTree()
        message.conversation = self
        message.parentID = parent?.id
        parent?.lastActiveChildID = message.id
        leafID = message.id
    }

    /// Moves the leaf, remembering the chosen child on every message along the new path.
    func setLeaf(_ id: UUID) {
        ensureTree()
        let path = path(to: id)
        guard path.last?.id == id else { return }
        for (parent, child) in zip(path, path.dropFirst()) where parent.lastActiveChildID != child.id {
            parent.lastActiveChildID = child.id
        }
        leafID = id
    }

    /// Shows the sibling `offset` places from `message`, continuing down that branch to its last active leaf.
    /// Returns false at either end.
    @discardableResult
    func switchBranch(of message: Message, by offset: Int) -> Bool {
        ensureTree()
        let index = treeIndex
        guard let sibling = index.sibling(of: message.id, offset: offset) else { return false }
        setLeaf(index.deepest(from: sibling))
        return true
    }
}
