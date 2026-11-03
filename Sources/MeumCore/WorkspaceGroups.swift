// Sidebar groups of workspaces: create, move into and out of, rename, fold, ungroup. Pure value mutations on
// AppState. The invariant `normalizeGroups` restores after every change: a group's members are contiguous in
// `workspaces` (where its first member is), every `Workspace.group` names an existing group, and no group is empty.
import Foundation

extension AppState {
    public func group(_ id: UUID) -> WorkspaceGroup? { groups.first { $0.id == id } }

    /// Members of a group, in sidebar order.
    public func members(of group: UUID) -> [Workspace] { workspaces.filter { $0.group == group } }

    /// A new group holding `ids` (in their current order), placed where the first of them is. Members of other
    /// groups leave those. Returns the group's id, nil if none of `ids` exists.
    @discardableResult
    public mutating func createGroup(name: String, workspaces ids: [UUID], collapsed: Bool = false) -> UUID? {
        let wanted = Set(ids)
        guard let first = workspaces.firstIndex(where: { wanted.contains($0.id) }) else { return nil }
        let g = WorkspaceGroup(name: name, collapsed: collapsed)
        groups.append(g)
        moveWorkspaces(ids, before: workspaces[first].id, group: g.id)
        return g.id
    }

    /// Moves `ids` (keeping their relative order) before `anchor` (nil: to the end) and puts them in `group`
    /// (nil: no group). An anchor that is itself moved is replaced by the next workspace that is not.
    public mutating func moveWorkspaces(_ ids: [UUID], before anchor: UUID?, group: UUID?) {
        let wanted = Set(ids)
        guard !wanted.isEmpty, group == nil || self.group(group!) != nil else { return }
        var anchor = anchor
        if let a = anchor, wanted.contains(a), let i = index(of: a) {
            anchor = workspaces[i...].first { !wanted.contains($0.id) }?.id
        }
        var moving = workspaces.filter { wanted.contains($0.id) }
        guard !moving.isEmpty else { return }
        for i in moving.indices { moving[i].group = group }
        workspaces.removeAll { wanted.contains($0.id) }
        let at = anchor.flatMap { index(of: $0) } ?? workspaces.count
        workspaces.insert(contentsOf: moving, at: at)
        normalizeGroups()
    }

    /// Puts `ids` in `group` at its end, or (nil) takes them out of their groups and places them right after.
    public mutating func setGroup(_ ids: [UUID], to group: UUID?) {
        if let group {
            guard self.group(group) != nil else { return }
            let wanted = Set(ids)
            let last = workspaces.lastIndex { $0.group == group && !wanted.contains($0.id) }
            let anchor = last.flatMap { l in workspaces[(l + 1)...].first { !wanted.contains($0.id) }?.id }
            if last == nil {
                // an empty group cannot exist; joining nothing means the first of `ids` stays where it is
                moveWorkspaces(ids, before: workspaces.first { wanted.contains($0.id) }?.id, group: group)
            } else {
                moveWorkspaces(ids, before: anchor, group: group)
            }
        } else {
            // per group, its leaving members (in order) go right after the whole group
            let wanted = Set(ids)
            let gs = workspaces.filter { wanted.contains($0.id) }.compactMap(\.group)
            for g in gs.reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } } {
                let leaving = workspaces.filter { wanted.contains($0.id) && $0.group == g }.map(\.id)
                let last = workspaces.lastIndex { $0.group == g }!
                let anchor = last + 1 < workspaces.count ? workspaces[last + 1].id : nil
                moveWorkspaces(leaving, before: anchor, group: nil)
            }
        }
    }

    /// Moves a whole group before `anchor` (nil: to the end). An anchor inside another group means before that group.
    public mutating func moveGroup(_ id: UUID, before anchor: UUID?) {
        let ids = members(of: id).map(\.id)
        var anchor = anchor
        if let a = anchor, let ws = workspace(a), let other = ws.group, other != id {
            anchor = members(of: other).first?.id
        }
        moveWorkspaces(ids, before: anchor, group: id)
    }

    @discardableResult
    public mutating func renameGroup(_ id: UUID, to name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = groups.firstIndex(where: { $0.id == id }) else { return false }
        groups[i].name = n
        return true
    }

    @discardableResult
    public mutating func setGroupCollapsed(_ id: UUID, _ collapsed: Bool) -> Bool {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return false }
        groups[i].collapsed = collapsed
        return true
    }

    /// Dissolves a group; its workspaces stay where they are.
    @discardableResult
    public mutating func ungroup(_ id: UUID) -> Bool {
        guard group(id) != nil else { return false }
        for i in workspaces.indices where workspaces[i].group == id { workspaces[i].group = nil }
        normalizeGroups()
        return true
    }

    /// Restores the invariant: unknown group ids cleared, each group's members gathered where its first member is
    /// (a block dropped inside another group therefore ends up after it), empty groups dropped.
    public mutating func normalizeGroups() {
        let known = Set(groups.map(\.id))
        for i in workspaces.indices where workspaces[i].group.map({ !known.contains($0) }) ?? false { workspaces[i].group = nil }
        var out: [Workspace] = []
        var placed: Set<UUID> = []
        for ws in workspaces {
            guard let g = ws.group else { out.append(ws); continue }
            if placed.insert(g).inserted { out.append(contentsOf: workspaces.filter { $0.group == g }) }
        }
        workspaces = out
        let used = Set(workspaces.compactMap(\.group))
        groups.removeAll { !used.contains($0.id) }
    }
}
