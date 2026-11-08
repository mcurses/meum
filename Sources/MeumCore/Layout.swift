// BSP layout: tree queries, geometry and mutations. Pure functions over the value model.
//
// Geometry uses a top-left origin (y grows downwards): `first` is left/top, `second` right/bottom. The app
// draws into a flipped view, so frames map 1:1.

import CoreGraphics
import Foundation

public enum Direction: String, Codable, Sendable, CaseIterable {
    case left, right, up, down
}

/// Where a split puts the new card relative to the existing one.
public enum SplitPlacement: String, Codable, Sendable {
    case right, down

    var axis: SplitAxis { self == .right ? .horizontal : .vertical }
}

// MARK: - Tree queries

extension LayoutNode {
    /// All cards, in tree order (first before second).
    public var cards: [Card] {
        switch self {
        case .card(let c): return [c]
        case .split(let s): return s.first.cards + s.second.cards
        }
    }

    public var id: UUID {
        switch self {
        case .card(let c): return c.id
        case .split(let s): return s.id
        }
    }

    public func card(_ id: UUID) -> Card? { cards.first { $0.id == id } }

    public func card(containingTab tabID: UUID) -> Card? {
        cards.first { $0.tabs.contains { $0.id == tabID } }
    }

    /// Applies `transform` to the card with `id`. Returns nil when the card does not exist.
    func updatingCard(_ id: UUID, _ transform: (inout Card) -> Void) -> LayoutNode? {
        switch self {
        case .card(var c):
            guard c.id == id else { return nil }
            transform(&c)
            return .card(c)
        case .split(var s):
            if let f = s.first.updatingCard(id, transform) { s.first = f; return .split(s) }
            if let r = s.second.updatingCard(id, transform) { s.second = r; return .split(s) }
            return nil
        }
    }

    /// Replaces the card `id` with `node`. Returns nil when the card does not exist.
    func replacingCard(_ id: UUID, with node: LayoutNode) -> LayoutNode? {
        switch self {
        case .card(let c):
            return c.id == id ? node : nil
        case .split(var s):
            if let f = s.first.replacingCard(id, with: node) { s.first = f; return .split(s) }
            if let r = s.second.replacingCard(id, with: node) { s.second = r; return .split(s) }
            return nil
        }
    }

    /// Removes the card `id`; its parent split collapses into the sibling.
    /// `.some(nil)` means the tree is now empty, `nil` means the card was not found.
    func removingCard(_ id: UUID) -> LayoutNode?? {
        switch self {
        case .card(let c):
            return c.id == id ? .some(nil) : nil
        case .split(var s):
            if let r = s.first.removingCard(id) {
                guard let rest = r else { return .some(s.second) }
                s.first = rest
                return .some(.split(s))
            }
            if let r = s.second.removingCard(id) {
                guard let rest = r else { return .some(s.first) }
                s.second = rest
                return .some(.split(s))
            }
            return nil
        }
    }

    /// The splits from the root down to the card `id` (outermost first), with the side the card is on.
    func path(to cardID: UUID) -> [(split: Split, inFirst: Bool)]? {
        switch self {
        case .card(let c):
            return c.id == cardID ? [] : nil
        case .split(let s):
            if let p = s.first.path(to: cardID) { return [(s, true)] + p }
            if let p = s.second.path(to: cardID) { return [(s, false)] + p }
            return nil
        }
    }

    func updatingSplit(_ id: UUID, _ transform: (inout Split) -> Void) -> LayoutNode {
        switch self {
        case .card: return self
        case .split(var s):
            if s.id == id { transform(&s); return .split(s) }
            s.first = s.first.updatingSplit(id, transform)
            s.second = s.second.updatingSplit(id, transform)
            return .split(s)
        }
    }
}

// MARK: - Geometry

extension LayoutNode {
    /// Frame of every card inside `rect`, with `gap` points between siblings. Frames are whole points.
    public func frames(in rect: CGRect, gap: CGFloat) -> [UUID: CGRect] {
        var out: [UUID: CGRect] = [:]
        collectFrames(in: rect, gap: gap, into: &out)
        return out
    }

    private func collectFrames(in rect: CGRect, gap: CGFloat, into out: inout [UUID: CGRect]) {
        switch self {
        case .card(let c):
            out[c.id] = rect
        case .split(let s):
            let (a, b) = Self.divide(rect, axis: s.axis, ratio: s.ratio, gap: gap)
            s.first.collectFrames(in: a, gap: gap, into: &out)
            s.second.collectFrames(in: b, gap: gap, into: &out)
        }
    }

    static func divide(_ r: CGRect, axis: SplitAxis, ratio: Double, gap: CGFloat) -> (CGRect, CGRect) {
        switch axis {
        case .horizontal:
            let avail = max(0, r.width - gap)
            let w1 = (avail * CGFloat(ratio)).rounded()
            let a = CGRect(x: r.minX, y: r.minY, width: w1, height: r.height)
            let b = CGRect(x: r.minX + w1 + gap, y: r.minY, width: max(0, r.maxX - (r.minX + w1 + gap)),
                           height: r.height)
            return (a, b)
        case .vertical:
            let avail = max(0, r.height - gap)
            let h1 = (avail * CGFloat(ratio)).rounded()
            let a = CGRect(x: r.minX, y: r.minY, width: r.width, height: h1)
            let b = CGRect(x: r.minX, y: r.minY + h1 + gap, width: r.width,
                           height: max(0, r.maxY - (r.minY + h1 + gap)))
            return (a, b)
        }
    }
}

/// Picks the card next to `from` in `direction` among `frames` (top-left origin). Prefers cards that overlap
/// on the cross axis, then the nearest edge, then the largest overlap, then the top/left one. Nil when there is none.
public func neighbor(of from: UUID, in direction: Direction, frames: [UUID: CGRect]) -> UUID? {
    guard let f = frames[from] else { return nil }
    let eps: CGFloat = 0.5
    struct Candidate {
        let id: UUID; let distance: CGFloat; let overlap: CGFloat; let centerDistance: CGFloat; let cross: CGFloat
    }
    var cands: [Candidate] = []
    for (id, r) in frames where id != from {
        let distance: CGFloat
        let overlap: CGFloat
        switch direction {
        case .right:
            guard r.minX >= f.maxX - eps else { continue }
            distance = r.minX - f.maxX
            overlap = min(f.maxY, r.maxY) - max(f.minY, r.minY)
        case .left:
            guard r.maxX <= f.minX + eps else { continue }
            distance = f.minX - r.maxX
            overlap = min(f.maxY, r.maxY) - max(f.minY, r.minY)
        case .down:
            guard r.minY >= f.maxY - eps else { continue }
            distance = r.minY - f.maxY
            overlap = min(f.maxX, r.maxX) - max(f.minX, r.minX)
        case .up:
            guard r.maxY <= f.minY + eps else { continue }
            distance = f.minY - r.maxY
            overlap = min(f.maxX, r.maxX) - max(f.minX, r.minX)
        }
        let cd = hypot(r.midX - f.midX, r.midY - f.midY)
        let cross = (direction == .left || direction == .right) ? r.minY : r.minX
        cands.append(Candidate(id: id, distance: distance, overlap: overlap, centerDistance: cd, cross: cross))
    }
    let overlapping = cands.filter { $0.overlap > 0 }
    if !overlapping.isEmpty {
        return overlapping.min { a, b in
            if abs(a.distance - b.distance) > eps { return a.distance < b.distance }
            if abs(a.overlap - b.overlap) > eps { return a.overlap > b.overlap }
            return a.cross < b.cross // ties go to the top / left one

        }?.id
    }
    return cands.min { $0.centerDistance < $1.centerDistance }?.id
}

// MARK: - Workspace mutations

extension Workspace {
    /// A new workspace with one card holding one tab in `cwd`.
    public static func make(name: String, cwd: String? = nil, color: String? = nil) -> Workspace {
        let card = Card(tab: Tab(cwd: cwd))
        return Workspace(name: name, color: color, cwd: cwd, root: .card(card), focusedCardID: card.id)
    }

    public var cards: [Card] { root?.cards ?? [] }
    public var allTabs: [Tab] { cards.flatMap(\.tabs) }

    /// The focused card, falling back to the first card when the stored id is stale.
    public var focusedCard: Card? {
        guard let root else { return nil }
        if let id = focusedCardID, let c = root.card(id) { return c }
        return root.cards.first
    }

    public func card(_ id: UUID) -> Card? { root?.card(id) }
    public func card(containingTab tabID: UUID) -> Card? { root?.card(containingTab: tabID) }
    public func tab(_ id: UUID) -> Tab? { allTabs.first { $0.id == id } }

    public func frames(in rect: CGRect, gap: CGFloat) -> [UUID: CGRect] {
        root?.frames(in: rect, gap: gap) ?? [:]
    }

    /// Adds `tab` to `cardID` (default: the focused card) and selects it. With no cards, creates one.
    @discardableResult
    public mutating func addTab(_ tab: Tab, toCard cardID: UUID? = nil) -> UUID {
        guard let root else {
            let card = Card(tab: tab)
            self.root = .card(card)
            focusedCardID = card.id
            return card.id
        }
        let target = cardID ?? focusedCard?.id ?? root.cards[0].id
        if let updated = root.updatingCard(target, { c in
            c.tabs.insert(tab, at: c.selectedIndex + 1)
            c.selectedTabID = tab.id
        }) {
            self.root = updated
            focusedCardID = target
            return target
        }
        return addTab(tab, toCard: root.cards[0].id)
    }

    /// Splits `cardID` (default: the focused card); the new card holding `tab` goes right of or below it and
    /// takes focus. Returns the new card's id, nil when the card does not exist.
    @discardableResult
    public mutating func split(_ cardID: UUID? = nil, placement: SplitPlacement, tab: Tab,
                               ratio: Double = 0.5) -> UUID? {
        let newCard = Card(tab: tab)
        guard let root else {
            self.root = .card(newCard)
            focusedCardID = newCard.id
            return newCard.id
        }
        guard let targetID = cardID ?? focusedCard?.id, let old = root.card(targetID) else { return nil }
        let node = LayoutNode.split(Split(axis: placement.axis, ratio: ratio, first: .card(old),
                                          second: .card(newCard)))
        guard let updated = root.replacingCard(targetID, with: node) else { return nil }
        self.root = updated
        focusedCardID = newCard.id
        return newCard.id
    }

    /// Closes a tab. The neighbouring tab of its card becomes selected; a card left without tabs is removed
    /// and its parent split collapses. Focus moves to the card that took the removed card's place.
    /// Returns false when the tab does not exist.
    @discardableResult
    public mutating func closeTab(_ tabID: UUID) -> Bool {
        guard let root, let card = root.card(containingTab: tabID) else { return false }
        if card.tabs.count > 1 {
            self.root = root.updatingCard(card.id) { c in
                let i = c.tabs.firstIndex { $0.id == tabID }!
                c.tabs.remove(at: i)
                if c.selectedTabID == tabID { c.selectedTabID = c.tabs[min(i, c.tabs.count - 1)].id }
            }
            return true
        }
        return removeCard(card.id)
    }

    /// Removes a whole card (all its tabs). Returns false when it does not exist.
    @discardableResult
    public mutating func removeCard(_ cardID: UUID) -> Bool {
        guard let root, let path = root.path(to: cardID), let result = root.removingCard(cardID) else { return false }
        self.root = result
        if focusedCardID == cardID || focusedCardID.flatMap({ result?.card($0) }) == nil {
            // the sibling subtree takes the removed card's place; focus its card nearest to the removed one
            if let parent = path.last {
                let sibling = parent.inFirst ? parent.split.second : parent.split.first
                focusedCardID = parent.inFirst ? sibling.cards.first?.id : sibling.cards.last?.id
            } else {
                focusedCardID = nil
            }
        }
        return true
    }

    /// Selects a tab and focuses its card.
    @discardableResult
    public mutating func selectTab(_ tabID: UUID) -> Bool {
        guard let root, let card = root.card(containingTab: tabID) else { return false }
        self.root = root.updatingCard(card.id) { $0.selectedTabID = tabID }
        focusedCardID = card.id
        return true
    }

    /// Moves the selection in the focused card by `offset` tabs, wrapping around.
    public mutating func selectAdjacentTab(_ offset: Int) {
        guard let root, let card = focusedCard, card.tabs.count > 1 else { return }
        let n = card.tabs.count
        let i = ((card.selectedIndex + offset) % n + n) % n
        self.root = root.updatingCard(card.id) { $0.selectedTabID = card.tabs[i].id }
    }

    public mutating func focusCard(_ cardID: UUID) {
        if root?.card(cardID) != nil { focusedCardID = cardID }
    }

    /// Moves focus to the neighbouring card in `direction`, using the geometry for `rect`.
    @discardableResult
    public mutating func moveFocus(_ direction: Direction, in rect: CGRect, gap: CGFloat) -> Bool {
        guard let from = focusedCard?.id,
              let to = neighbor(of: from, in: direction, frames: frames(in: rect, gap: gap)) else { return false }
        focusedCardID = to
        return true
    }

    /// Moves the divider of the focused card's nearest enclosing split of the matching axis in `direction`
    /// by `delta` (share of that split). Returns false when there is no such split.
    @discardableResult
    public mutating func resizeFocused(_ direction: Direction, delta: Double = 0.05) -> Bool {
        guard let root, let cardID = focusedCard?.id, let path = root.path(to: cardID) else { return false }
        let axis: SplitAxis = (direction == .left || direction == .right) ? .horizontal : .vertical
        guard let target = path.last(where: { $0.split.axis == axis })?.split else { return false }
        let sign: Double = (direction == .right || direction == .down) ? 1 : -1
        self.root = root.updatingSplit(target.id) { $0.ratio += sign * delta }
        return true
    }

    public mutating func setRatio(split splitID: UUID, ratio: Double) {
        root = root?.updatingSplit(splitID) { $0.ratio = ratio }
    }

    /// Applies `transform` to the tab `id`. Returns false when it does not exist.
    @discardableResult
    public mutating func updateTab(_ id: UUID, _ transform: (inout Tab) -> Void) -> Bool {
        guard let root, let card = root.card(containingTab: id) else { return false }
        self.root = root.updatingCard(card.id) { c in
            if let i = c.tabs.firstIndex(where: { $0.id == id }) { transform(&c.tabs[i]) }
        }
        return true
    }
}

// MARK: - AppState mutations

extension AppState {
    public var selectedWorkspace: Workspace? {
        guard let id = selectedWorkspaceID else { return nil }
        return workspaces.first { $0.id == id }
    }

    public func workspace(_ id: UUID) -> Workspace? { workspaces.first { $0.id == id } }
    public func index(of id: UUID) -> Int? { workspaces.firstIndex { $0.id == id } }

    /// The workspace that owns a tab.
    public func workspace(containingTab tabID: UUID) -> Workspace? {
        workspaces.first { $0.tab(tabID) != nil }
    }

    public enum SessionLookup: Equatable { case found(UUID), none, ambiguous(Int) }

    /// The tab whose Claude Code session has this id, by the whole id or a unique prefix of at least 8 characters
    /// (case doesn't matter).
    public func tab(claudeSession ref: String) -> SessionLookup {
        let r = ref.lowercased()
        let tabs = workspaces.flatMap(\.allTabs).filter { $0.agent != nil }
        if let t = tabs.first(where: { $0.agent?.sessionID.lowercased() == r }) { return .found(t.id) }
        guard r.count >= 8 else { return .none }
        let m = tabs.filter { $0.agent?.sessionID.lowercased().hasPrefix(r) == true }
        return m.count == 1 ? .found(m[0].id) : m.isEmpty ? .none : .ambiguous(m.count)
    }

    /// Appends a workspace (or inserts it at `index`) and optionally selects it.
    public mutating func addWorkspace(_ ws: Workspace, at index: Int? = nil, select: Bool = true) {
        let i = min(max(0, index ?? workspaces.count), workspaces.count)
        workspaces.insert(ws, at: i)
        if select || selectedWorkspaceID == nil { selectedWorkspaceID = ws.id }
    }

    @discardableResult
    public mutating func selectWorkspace(_ id: UUID) -> Bool {
        guard workspace(id) != nil else { return false }
        selectedWorkspaceID = id
        return true
    }

    @discardableResult
    public mutating func selectWorkspace(at index: Int) -> Bool {
        guard workspaces.indices.contains(index) else { return false }
        selectedWorkspaceID = workspaces[index].id
        return true
    }

    /// Moves the selection by `offset`, wrapping around.
    public mutating func selectAdjacentWorkspace(_ offset: Int) {
        guard !workspaces.isEmpty else { return }
        let n = workspaces.count
        let cur = selectedWorkspaceID.flatMap { index(of: $0) } ?? 0
        selectedWorkspaceID = workspaces[((cur + offset) % n + n) % n].id
    }

    /// Applies `transform` to workspace `id`. Returns false when it does not exist.
    @discardableResult
    public mutating func updateWorkspace(_ id: UUID, _ transform: (inout Workspace) -> Void) -> Bool {
        guard let i = index(of: id) else { return false }
        transform(&workspaces[i])
        return true
    }

    @discardableResult
    public mutating func renameWorkspace(_ id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return updateWorkspace(id) { $0.name = trimmed }
    }

    @discardableResult
    public mutating func setColor(_ id: UUID, _ color: String?) -> Bool { updateWorkspace(id) { $0.color = color } }

    @discardableResult
    public mutating func setIcon(_ id: UUID, _ icon: String?) -> Bool { updateWorkspace(id) { $0.icon = icon } }

    @discardableResult
    public mutating func setPinned(_ id: UUID, _ pinned: Bool) -> Bool { updateWorkspace(id) { $0.pinned = pinned } }

    /// Removes a workspace. If it was selected, the next one (or the previous, at the end) becomes selected.
    @discardableResult
    public mutating func closeWorkspace(_ id: UUID) -> Workspace? {
        guard let i = index(of: id) else { return nil }
        let removed = workspaces.remove(at: i)
        if selectedWorkspaceID == id {
            selectedWorkspaceID = workspaces.isEmpty ? nil : workspaces[min(i, workspaces.count - 1)].id
        }
        normalizeGroups()
        return removed
    }

    /// Moves workspace `id` so it ends up at `index` (clamped).
    @discardableResult
    /// Moving it into the middle of a group makes it a member; moving it away from its group takes it out.
    public mutating func moveWorkspace(_ id: UUID, to index: Int) -> Bool {
        guard let from = self.index(of: id) else { return false }
        let ws = workspaces.remove(at: from)
        let i = min(max(0, index), workspaces.count)
        let before = i > 0 ? workspaces[i - 1].group : nil, after = i < workspaces.count ? workspaces[i].group : nil
        var moved = ws
        if before != nil, before == after { moved.group = before }
        else if let g = ws.group, before != g, after != g { moved.group = nil }
        workspaces.insert(moved, at: i)
        normalizeGroups()
        return true
    }

    /// Applies `transform` to the tab `id` in whichever workspace holds it.
    @discardableResult
    public mutating func updateTab(_ id: UUID, _ transform: (inout Tab) -> Void) -> Bool {
        guard let ws = workspace(containingTab: id) else { return false }
        return updateWorkspace(ws.id) { $0.updateTab(id, transform) }
    }

    /// Every tab id in the state, for reconciling live sessions.
    public var allTabIDs: Set<UUID> { Set(workspaces.flatMap { $0.allTabs.map(\.id) }) }

    /// Makes the state self-consistent after loading: a selection that exists, focused cards that exist.
    public mutating func normalize() {
        if let s = selectedWorkspaceID, workspace(s) == nil { selectedWorkspaceID = nil }
        if selectedWorkspaceID == nil { selectedWorkspaceID = workspaces.first?.id }
        for i in workspaces.indices {
            if let f = workspaces[i].focusedCardID, workspaces[i].card(f) == nil { workspaces[i].focusedCardID = nil }
            if workspaces[i].focusedCardID == nil { workspaces[i].focusedCardID = workspaces[i].cards.first?.id }
        }
    }
}

// MARK: - Moving tabs

extension LayoutNode {
    public func split(_ id: UUID) -> Split? {
        switch self {
        case .card: return nil
        case .split(let s):
            if s.id == id { return s }
            return s.first.split(id) ?? s.second.split(id)
        }
    }

    /// Every split, outermost first.
    public var splits: [Split] {
        switch self {
        case .card: return []
        case .split(let s): return [s] + s.first.splits + s.second.splits
        }
    }
}

extension Workspace {
    public func split(_ id: UUID) -> Split? { root?.split(id) }

    /// Takes a tab out of its card and returns it. A card left without tabs is removed and its parent split
    /// collapses (the tree can become empty). The neighbouring tab becomes the card's selection.
    public mutating func detachTab(_ tabID: UUID) -> Tab? {
        guard let root, let card = root.card(containingTab: tabID),
              let tab = card.tabs.first(where: { $0.id == tabID }) else { return nil }
        if card.tabs.count > 1 {
            closeTab(tabID)
        } else {
            removeCard(card.id)
        }
        return tab
    }

    /// Inserts `tab` into `cardID` at `index` (clamped; default: the end), selects it and focuses the card.
    @discardableResult
    public mutating func insertTab(_ tab: Tab, intoCard cardID: UUID, at index: Int? = nil) -> Bool {
        guard let root, root.card(cardID) != nil else { return false }
        self.root = root.updatingCard(cardID) { c in
            let i = min(max(0, index ?? c.tabs.count), c.tabs.count)
            c.tabs.insert(tab, at: i)
            c.selectedTabID = tab.id
        }
        focusedCardID = cardID
        return true
    }

    /// Splits `cardID` and puts a new card holding `tab` on `side` of it; the new card takes focus.
    /// `ratio` is the new card's share. Returns the new card's id, nil when the card does not exist.
    @discardableResult
    public mutating func insertTab(_ tab: Tab, splitting cardID: UUID, side: Direction, ratio: Double = 0.5) -> UUID? {
        guard let root, let old = root.card(cardID) else { return nil }
        let newCard = Card(tab: tab)
        let axis: SplitAxis = (side == .left || side == .right) ? .horizontal : .vertical
        let newFirst = side == .left || side == .up
        let node = LayoutNode.split(Split(axis: axis, ratio: newFirst ? ratio : 1 - ratio,
                                          first: newFirst ? .card(newCard) : .card(old),
                                          second: newFirst ? .card(old) : .card(newCard)))
        guard let updated = root.replacingCard(cardID, with: node) else { return nil }
        self.root = updated
        focusedCardID = newCard.id
        return newCard.id
    }

    /// Moves a tab into the card `cardID` at `index` (its position there after the move; default: the end).
    /// Within one card this reorders. A source card left empty is removed and its split collapses.
    /// The tab ends up selected in a focused card. Returns false when the tab or the card does not exist.
    @discardableResult
    public mutating func moveTab(_ tabID: UUID, toCard cardID: UUID, index: Int? = nil) -> Bool {
        guard let root, let src = root.card(containingTab: tabID), root.card(cardID) != nil else { return false }
        // a card's only tab moved within that card: nothing changes (detaching would remove the target)
        if src.id == cardID, src.tabs.count == 1 { return selectTab(tabID) }
        guard let tab = detachTab(tabID) else { return false }
        return insertTab(tab, intoCard: cardID, at: index)
    }

    /// Moves a tab out of its card into a new card on `side` of `cardID` (splitting it). Splitting a card by
    /// its own only tab is a no-op (returns nil). Returns the new card's id.
    @discardableResult
    public mutating func moveTab(_ tabID: UUID, splitting cardID: UUID, side: Direction,
                                 ratio: Double = 0.5) -> UUID? {
        guard let root, let src = root.card(containingTab: tabID), root.card(cardID) != nil else { return nil }
        if src.id == cardID, src.tabs.count == 1 { return nil }
        guard let tab = detachTab(tabID) else { return nil }
        return insertTab(tab, splitting: cardID, side: side, ratio: ratio)
    }
}

extension AppState {
    public func workspace(containingCard cardID: UUID) -> Workspace? {
        workspaces.first { $0.card(cardID) != nil }
    }

    /// `Workspace.moveTab(_:toCard:index:)` across workspaces: the target card may live in another workspace.
    /// A source workspace left without tabs keeps existing with an empty tree.
    @discardableResult
    public mutating func moveTab(_ tabID: UUID, toCard cardID: UUID, index: Int? = nil) -> Bool {
        guard let src = workspace(containingTab: tabID), let dst = workspace(containingCard: cardID) else { return false }
        var ok = false
        if src.id == dst.id {
            updateWorkspace(src.id) { ok = $0.moveTab(tabID, toCard: cardID, index: index) }
            return ok
        }
        var tab: Tab?
        updateWorkspace(src.id) { tab = $0.detachTab(tabID) }
        guard let tab else { return false }
        updateWorkspace(dst.id) { ok = $0.insertTab(tab, intoCard: cardID, at: index) }
        return ok
    }

    /// `Workspace.moveTab(_:splitting:side:)` across workspaces. Returns the new card's id.
    @discardableResult
    public mutating func moveTab(_ tabID: UUID, splitting cardID: UUID, side: Direction, ratio: Double = 0.5) -> UUID? {
        guard let src = workspace(containingTab: tabID), let dst = workspace(containingCard: cardID) else { return nil }
        var newCard: UUID?
        if src.id == dst.id {
            updateWorkspace(src.id) { newCard = $0.moveTab(tabID, splitting: cardID, side: side, ratio: ratio) }
            return newCard
        }
        var tab: Tab?
        updateWorkspace(src.id) { tab = $0.detachTab(tabID) }
        guard let tab else { return nil }
        updateWorkspace(dst.id) { newCard = $0.insertTab(tab, splitting: cardID, side: side, ratio: ratio) }
        return newCard
    }

    /// Sets a split's ratio (clamped to 0.1…0.9) in whichever workspace holds it. False when there is none.
    @discardableResult
    public mutating func setRatio(split splitID: UUID, ratio: Double) -> Bool {
        guard let ws = workspaces.first(where: { $0.split(splitID) != nil }) else { return false }
        return updateWorkspace(ws.id) { $0.setRatio(split: splitID, ratio: ratio) }
    }
}

// MARK: - Dividers (mouse resizing)

/// The gap between the two children of a split: what the mouse grabs to resize it.
public struct Divider: Equatable, Sendable {
    public var splitID: UUID
    public var axis: SplitAxis
    /// The gap strip between the children (top-left origin).
    public var rect: CGRect
    /// The whole split's rect, which the ratio divides.
    public var span: CGRect
}

extension LayoutNode {
    /// The divider of every split inside `rect`, outermost first.
    public func dividers(in rect: CGRect, gap: CGFloat) -> [Divider] {
        guard case .split(let s) = self else { return [] }
        let (a, b) = Self.divide(rect, axis: s.axis, ratio: s.ratio, gap: gap)
        let strip: CGRect = s.axis == .horizontal
            ? CGRect(x: a.maxX, y: rect.minY, width: b.minX - a.maxX, height: rect.height)
            : CGRect(x: rect.minX, y: a.maxY, width: rect.width, height: b.minY - a.maxY)
        return [Divider(splitID: s.id, axis: s.axis, rect: strip, span: rect)]
            + s.first.dividers(in: a, gap: gap) + s.second.dividers(in: b, gap: gap)
    }

    /// The smallest extent along `axis` this subtree can take when every card is at least `minCard` long.
    public func minExtent(_ axis: SplitAxis, minCard: CGFloat, gap: CGFloat) -> CGFloat {
        switch self {
        case .card: return minCard
        case .split(let s):
            let a = s.first.minExtent(axis, minCard: minCard, gap: gap)
            let b = s.second.minExtent(axis, minCard: minCard, gap: gap)
            return s.axis == axis ? a + gap + b : max(a, b)
        }
    }
}

extension Workspace {
    public func dividers(in rect: CGRect, gap: CGFloat) -> [Divider] { root?.dividers(in: rect, gap: gap) ?? [] }

    /// The ratio that puts the divider of `splitID` at `position` (the coordinate of the gap's centre along the
    /// split's axis, top-left origin), keeping every card at least `minCard` points long where the space
    /// allows. Nil when the split is not in this workspace.
    public func ratio(forSplit splitID: UUID, dividerAt position: CGFloat, in rect: CGRect, gap: CGFloat,
                      minCard: CGFloat) -> Double? {
        guard let root, let s = root.split(splitID),
              let d = root.dividers(in: rect, gap: gap).first(where: { $0.splitID == splitID }) else { return nil }
        let start = s.axis == .horizontal ? d.span.minX : d.span.minY
        let extent = s.axis == .horizontal ? d.span.width : d.span.height
        let avail = extent - gap
        guard avail > 0 else { return nil }
        var first = position - gap / 2 - start
        let lo = s.first.minExtent(s.axis, minCard: minCard, gap: gap)
        let hi = avail - s.second.minExtent(s.axis, minCard: minCard, gap: gap)
        if lo <= hi { first = min(max(first, lo), hi) } else { first = avail / 2 }
        return Split.clamp(Double(first / avail))
    }
}
