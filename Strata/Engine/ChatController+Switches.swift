import Foundation
import SwiftUI
import SwiftData
import Observation

/// Each chat's tool and package switches, and what the model is told about them.
extension ChatController {
    // MARK: Tool switches

    /// The chat's tool switches: its own, or the defaults in Settings until it has any.
    func toolSwitches(_ conversation: Conversation?) -> Set<ToolGroup> {
        conversation?.toolSwitches ?? settings.defaultToolGroups
    }

    /// The composer's "+" menu: applies from the next message. A call to a group turned off is refused at once.
    /// Packages that need the group turn off with it; those that can't share a chat with it turn off when it turns on.
    func setTool(_ group: ToolGroup, on: Bool, conversation: Conversation) {
        var switches = toolSwitches(conversation)
        if on { switches.insert(group) } else { switches.remove(group) }
        let kept = conversation.packageSwitches.map { ids in
            ids.filter { id in
                guard let p = packages.package(id: id) else { return true }
                return on ? !p.exclusiveGroups.contains(group) : !p.requiredGroups.contains(group)
            }
        }
        conversation.setSwitches(groups: switches, packages: kept)
    }

    // MARK: Package switches

    /// The chat's package switches: its own, or the defaults until it has any.
    func packageSwitches(_ conversation: Conversation?) -> Set<String> {
        conversation?.packageSwitches ?? defaultPackages(groups: toolSwitches(conversation))
    }

    /// The packages a new chat starts with: those on in new chats (Settings › Packages), except one that needs a tool
    /// group the chat has off or can't share it with one it has on. Read at the chat's first send.
    func defaultPackages(groups: Set<ToolGroup>) -> Set<String> {
        Set(packages.all.filter { p in
            p.record.onInNewChats && p.addsToChats && p.requiredGroups.isSubset(of: groups) && p.exclusiveGroups.isDisjoint(with: groups)
        }.map(\.id))
    }

    /// The "+" menu's package switch: applies from the next message. Turning a package on turns on the groups it needs
    /// and off those it can't share a chat with (and the packages that need those).
    func setPackage(_ id: String, on: Bool, conversation: Conversation) {
        var groups = toolSwitches(conversation)
        var ids = packageSwitches(conversation)
        applyPackage(id, on: on, groups: &groups, packages: &ids)
        conversation.setSwitches(groups: groups, packages: ids)
    }

    /// `setPackage` on plain switches (a new chat's, before it exists).
    func applyPackage(_ id: String, on: Bool, groups: inout Set<ToolGroup>, packages ids: inout Set<String>) {
        guard on, let package = packages.package(id: id) else { ids.remove(id); return }
        ids.insert(id)
        groups.formUnion(package.requiredGroups)
        groups.subtract(package.exclusiveGroups)
        let now = groups
        ids = ids.filter { other in
            guard other != id, let p = packages.package(id: other) else { return true }
            return p.requiredGroups.isSubset(of: now) && p.exclusiveGroups.isDisjoint(with: now)
        }
    }

    /// The snapshot of `ids` as installed now, in id order, leaving out a package whose tools would pass the chat's
    /// budget (`PackageLimits.toolsPerChat`) after those before it.
    func packageSnapshot(for ids: Set<String>, adding base: PackageSnapshot = PackageSnapshot(entries: [])) -> PackageSnapshot {
        var snapshot = base
        var count = base.entries.reduce(0) { $0 + $1.tools.count }
        for package in packages.all.filter({ ids.contains($0.id) && !base.ids.contains($0.id) && $0.addsToChats }).sorted(by: { PackageJSON.byteOrder($0.id, $1.id) }) {
            guard count + package.tools.count <= PackageLimits.toolsPerChat else { continue }
            count += package.tools.count
            snapshot = snapshot.adding(PackageSnapshot.entry(package))
        }
        return snapshot
    }

    /// The packages the chat's requests offer: its frozen snapshot after the first request, its switches before.
    func chatPackages(_ conversation: Conversation) -> PackageSnapshot? {
        if conversation.offeredTools != nil { return conversation.packageSnapshot }
        let current = packageSnapshot(for: packageSwitches(conversation))
        return current.entries.isEmpty ? nil : current
    }

    /// A chat that hasn't set its switches takes the defaults (groups and packages) at its first send.
    private func takeDefaultSwitches(_ conversation: Conversation) {
        guard conversation.toolSwitches == nil || conversation.packageSwitches == nil else { return }
        conversation.setSwitches(groups: toolSwitches(conversation), packages: packageSwitches(conversation))
    }

    /// The tool groups the chat's requests offer: frozen at its first request (`freeze`), its switches before that.
    /// Its packages freeze with them (`Conversation.frozenPackages`).
    func offeredTools(_ conversation: Conversation, freeze: Bool) -> Set<ToolGroup> {
        if let offered = conversation.offeredTools { return offered }
        let current = toolSwitches(conversation)
        guard freeze else { return current }
        takeDefaultSwitches(conversation)
        _ = conversation.frozenPackages { packageSnapshot(for: packageSwitches(conversation)) }
        return conversation.frozenTools(current: current)
    }

    /// Before a turn's first request. Switches flipped since the model last heard of them are told in a note at the end
    /// of the turn's user message (`Message.apiNote`: in requests only, kept so later requests repeat it). The tool
    /// list and the system message stay as they were, so the cached prefix holds.
    func applyToolSwitches(_ conversation: Conversation, path: [Message]) {
        let current = toolSwitches(conversation)
        takeDefaultSwitches(conversation)
        let currentPackages = packageSwitches(conversation)
        guard let offered = conversation.offeredTools else { return } // the first request freezes them as they are
        let announced = conversation.announcedTools ?? offered
        let changed = Set(ToolGroup.allCases.filter { offered.contains($0) && current.contains($0) != announced.contains($0) })
        let snapshot = conversation.packageSnapshot ?? PackageSnapshot(entries: [])
        let announcedPackages = conversation.announcedPackages ?? snapshot.ids
        let changedPackages = snapshot.ids.filter { currentPackages.contains($0) != announcedPackages.contains($0) }
        if !changed.isEmpty || !changedPackages.isEmpty, let user = path.last, user.role == .user {
            // Sent again (Regenerate): the groups and packages it named before keep their place, with their state now.
            let named = changedPackages.union(ToolSwitch.packageIDs(inNote: user.apiNote, snapshot: snapshot))
            user.apiNote = ToolSwitch.note(groups: changed.union(ToolGroup.groups(inNote: user.apiNote)), enabled: current,
                                           packages: snapshot.entries.filter { named.contains($0.id) }.map { ($0.id, $0.name) },
                                           enabledPackages: currentPackages)
        }
        // A group turned on that the chat wasn't offered at its start joins the offered set: its tools and its system
        // prompt section are added, which changes the request's prefix, so the provider's prompt cache is lost once.
        // (Off at the start costs nothing: not offered, nothing cached yet.) A package turned on joins the snapshot
        // the same way.
        conversation.offeredTools = offered.union(current)
        let grown = packageSnapshot(for: currentPackages, adding: snapshot)
        if grown != snapshot { conversation.packageSnapshot = grown }
        conversation.setAnnounced(groups: current, packages: currentPackages.intersection(grown.ids))
    }
}
