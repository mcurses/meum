import AppKit
import MeumCore

/// What the built-in sidebar reads and does. Kept small and model-shaped so the sidebar can later become a
/// real extension on the public API (docs/design/sidebar-widgets-extensibility.md).
@MainActor
protocol SidebarHost: AnyObject {
    var sidebarItems: [SidebarItem] { get }
    func sidebarSelect(_ id: UUID)
    func sidebarNew()
    func sidebarRename(_ id: UUID, to name: String)
    func sidebarClose(_ id: UUID)
    func sidebarMove(_ id: UUID, to index: Int)
    func sidebarSetColor(_ id: UUID, _ hex: String?)
    /// `Workspace.icon` as stored (`sf:<symbol>` or up to two characters); nil: the name's first letter.
    func sidebarSetIcon(_ id: UUID, _ icon: String?)
    func sidebarSetPinned(_ id: UUID, _ pinned: Bool)
    /// A status entry with a URL was clicked.
    func sidebarStatusClicked(_ id: UUID, key: String)
    /// A listening port was clicked: open http://localhost:<port>.
    func sidebarOpenPort(_ port: Int)
    /// The sidebar finished an interaction (rename, menu); the host returns keyboard focus to the terminal.
    func sidebarDidEndInteraction()

    // groups
    var sidebarGroups: [SidebarGroup] { get }
    /// A new group from these workspaces; returns its id.
    func sidebarNewGroup(_ ids: [UUID]) -> UUID?
    /// Puts the workspaces at the end of a group, or (nil) takes them out of theirs.
    func sidebarSetGroup(_ ids: [UUID], _ group: UUID?)
    /// Moves workspaces before `anchor` (nil: the end) into `group` (nil: none).
    func sidebarMoveWorkspaces(_ ids: [UUID], before anchor: UUID?, group: UUID?)
    func sidebarMoveGroup(_ id: UUID, before anchor: UUID?)
    func sidebarRenameGroup(_ id: UUID, to name: String)
    func sidebarSetGroupCollapsed(_ id: UUID, _ collapsed: Bool)
    func sidebarUngroup(_ id: UUID)
}

struct SidebarGroup: Equatable {
    var id: UUID
    var name: String
    var collapsed: Bool
}

struct SidebarItem: Equatable {
    var id: UUID
    var name: String
    var color: String?
    /// `Workspace.icon` (emoji, up to two characters, or `sf:<symbol>`); nil: the name's first letter.
    var icon: String? = nil
    var pinned: Bool
    var selected: Bool
    var agents: WorkspaceAgentSummary
    /// Git branch of the workspace's focused tab cwd.
    var branch: String? = nil
    /// `status.set` entries, in insertion order.
    var status: [SidebarStatus] = []
    /// The focused tab's folder.
    var directory: String? = nil
    /// `workspace.setMeta` labels, by key.
    var metadata: [String: String] = [:]
    /// TCP ports the workspace's tab processes listen on.
    var ports: [Int] = []
    /// Its sidebar group.
    var group: UUID? = nil
    /// The workspace's own labels (`workspace.setLabels`), not its sessions'.
    var labels: [String] = []
}

/// What a row shows besides the name: the `sidebarShow…` settings.
struct SidebarDisplay: Equatable {
    var branch = true
    var directory = false
    var status = true
    var metadata = false
    var ports = true
    var agentDots = true
    var shortcuts = true
    var pin = true
    var icons = false

    init() {}
    init(_ s: Settings) {
        branch = s.sidebarShowBranch
        directory = s.sidebarShowDirectory
        status = s.sidebarShowStatus
        metadata = s.sidebarShowMetadata
        ports = s.sidebarShowPorts
        agentDots = s.sidebarShowAgentDots
        shortcuts = s.sidebarShowShortcuts
        pin = s.sidebarShowPin
        icons = s.sidebarShowIcons
    }

    /// Where a row's name and second line start: after the colour stripe, and after the icon when it is shown.
    var textInset: CGFloat { icons ? 42 : 16 }

    func hasSubtitle(_ i: SidebarItem) -> Bool {
        (branch && i.branch != nil) || (directory && i.directory != nil) || (status && !i.status.isEmpty)
            || (metadata && !i.metadata.isEmpty) || (ports && !i.ports.isEmpty)
    }
}

struct SidebarStatus: Equatable {
    var key: String
    var value: String
    var color: String?
    var url: String?
}

/// The built-in sidebar: workspace rows with colour stripe, name, agent dots and selection; click to select,
/// drag to reorder, double-click or right-click to rename, colour, pin or close; "+" to add.
/// Collapsed (the narrow rail), each workspace is an icon tile with its agent dot; the name is the tooltip. A group
/// is a divider there (click to fold), and a folded group one stacked tile with its member count.
final class SidebarView: FlippedView, NSTextFieldDelegate {
    weak var host: SidebarHost?
    private(set) var items: [SidebarItem] = []
    private(set) var groups: [SidebarGroup] = []
    /// Workspaces selected besides the primary one (the selected workspace): cmd-click toggles, shift-click
    /// selects a range. Group actions and drags apply to all of them.
    private(set) var marked: Set<UUID> = []
    static let groupHeaderHeight: CGFloat = 26
    private let memberIndent: CGFloat = 10

    /// What the sidebar shows, top to bottom: group headers and workspace rows (indices into groups / items).
    enum Row: Equatable { case header(Int), workspace(Int) }
    private(set) var rows: [Row] = []
    private(set) var frames: [NSRect] = []
    static let headerHeight: CGFloat = 44
    static let expandedRowHeight: CGFloat = 42
    static let collapsedRowHeight: CGFloat = 48
    /// The rail's group rows: an open group's divider, a folded group's stacked tile.
    static let railDividerHeight: CGFloat = 14
    static let railFoldedHeight: CGFloat = 50
    /// Dividers in the rail that belong to no row (after a group, before ungrouped workspaces), as y positions.
    private(set) var railDividers: [CGFloat] = []
    private let inset: CGFloat = 8

    /// The narrow rail: icons instead of names.
    var collapsed = false {
        didSet {
            guard collapsed != oldValue else { return }
            if collapsed { endEditing(commit: true) }
            hoverIndex = nil
            layoutRows()
            needsDisplay = true
            scrollSelectionToVisible()
        }
    }
    /// What each row shows besides the name.
    var display = SidebarDisplay() {
        didSet { if display != oldValue { needsDisplay = true } }
    }
    private var rowHeight: CGFloat { collapsed ? Self.collapsedRowHeight : Self.expandedRowHeight }

    /// Row indices (`rows`); -1 is the "+" button.
    private var hoverIndex: Int?
    private var pressIndex: Int?
    private var pressPoint: NSPoint = .zero
    private var pressFlags: NSEvent.ModifierFlags = []

    enum Dragged: Equatable { case workspaces([UUID]), group(UUID) }
    enum DropTarget: Equatable { case gap(Int), into(UUID) }
    private(set) var dragged: Dragged?
    private(set) var dropTarget: DropTarget?
    private var editor: NSTextField?
    private var editingID: UUID?
    private var editingGroup = false
    private var trackingArea: NSTrackingArea?

    static let palette: [(String, String?)] = [
        ("None", nil), ("Red", "#ff5f57"), ("Orange", "#ff9f0a"), ("Yellow", "#ffd60a"), ("Green", "#32d74b"),
        ("Teal", "#40c8e0"), ("Blue", "#0a84ff"), ("Purple", "#bf5af2"), ("Pink", "#ff375f"),
    ]

    var isEditing: Bool { editor != nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func reload() {
        guard let host else { return }
        let new = host.sidebarItems, newGroups = host.sidebarGroups
        if new != items || newGroups != groups {
            let oldPrimary = primaryID
            items = new
            groups = newGroups
            let ids = Set(items.map(\.id))
            marked = marked.filter { ids.contains($0) && $0 != primaryID }
            layoutRows()
            needsDisplay = true
            if primaryID != oldPrimary { scrollSelectionToVisible() }
        }
    }

    /// The scrolled height: every row, and some room below the last.
    private(set) var contentHeight: CGFloat = 0

    /// In its scroll view the sidebar is as tall as its rows, and at least as tall as what is visible.
    func fitToContent() {
        guard let clip = superview as? NSClipView else { return }
        let size = NSSize(width: clip.bounds.width, height: max(clip.bounds.height, contentHeight))
        guard frame.size != size else { return }
        let clipChanged = clip.bounds.height != lastClipHeight
        lastClipHeight = clip.bounds.height
        setFrameSize(size)
        if clipChanged { scrollSelectionToVisible() }   // a resized window keeps the selected row in view
    }
    private var lastClipHeight: CGFloat = 0

    /// Scrolls the selected workspace's row (or its folded group's) into view.
    func scrollSelectionToVisible() {
        guard let primaryID, let i = items.firstIndex(where: { $0.id == primaryID }) else { return }
        let r = rows.firstIndex(of: .workspace(i))
            ?? items[i].group.flatMap { g in groups.firstIndex { $0.id == g } }.flatMap { rows.firstIndex(of: .header($0)) }
        if let r { scrollToVisible(frames[r].insetBy(dx: 0, dy: -6)) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutRows()
        needsDisplay = true
    }

    var primaryID: UUID? { items.first { $0.selected }?.id }
    func isSelected(_ id: UUID) -> Bool { id == primaryID || marked.contains(id) }
    /// Every selected workspace, in sidebar order.
    var selectedIDs: [UUID] { items.map(\.id).filter(isSelected) }

    private func group(_ id: UUID?) -> SidebarGroup? { id.flatMap { g in groups.first { $0.id == g } } }

    /// Rows and their frames. In the rail a group's header is a divider (open) or a stacked tile (folded), and a
    /// divider also closes a group that ungrouped workspaces follow.
    private func layoutRows() {
        rows = []; frames = []; railDividers = []
        var y = Self.headerHeight
        var current: UUID?
        let w = bounds.width - inset * 2
        for (i, it) in items.enumerated() {
            if let g = it.group, g != current, let gi = groups.firstIndex(where: { $0.id == g }) {
                let h = !collapsed ? Self.groupHeaderHeight
                    : groups[gi].collapsed ? Self.railFoldedHeight : Self.railDividerHeight
                rows.append(.header(gi))
                frames.append(NSRect(x: inset, y: y, width: w, height: h - 2))
                y += h
            } else if collapsed, it.group == nil, group(current) != nil {
                railDividers.append(y + Self.railDividerHeight / 2 - 1)
                y += Self.railDividerHeight
            }
            current = it.group
            if group(it.group)?.collapsed == true { continue }
            let indent = !collapsed && group(it.group) != nil ? memberIndent : 0
            rows.append(.workspace(i))
            frames.append(NSRect(x: inset + indent, y: y, width: w - indent, height: rowHeight - 2))
            y += rowHeight
        }
        contentHeight = y + inset
        fitToContent()
    }

    /// Member rows of a group, as item indices.
    private func memberIndices(_ g: UUID) -> [Int] { items.indices.filter { items[$0].group == g } }

    /// Tooltips, collected while drawing: in the rail every tile's name (and its sessions' state) and every group's;
    /// in the full sidebar the agent dots, the label chips and names cut short.
    private let tips = DrawnToolTips()
    private(set) var tipRects: [(NSRect, String)] = []

    private func groupTip(_ g: SidebarGroup) -> String {
        "\(g.name) (\(memberIndices(g.id).count)) — click to \(g.collapsed ? "expand" : "collapse")"
    }

    // MARK: Geometry

    private var plusRect: NSRect {
        collapsed ? NSRect(x: (bounds.width - 22) / 2, y: 12, width: 22, height: 22)
            : NSRect(x: bounds.width - 34, y: 12, width: 22, height: 22)
    }

    /// The row under a point (its frame plus the 2 pt gap below, full width).
    private func rowIndex(at pt: NSPoint) -> Int? {
        frames.firstIndex { pt.y >= $0.minY && pt.y < $0.maxY + 2 }
    }

    /// Where a drag would drop: onto a group header (join it), else the gap between rows nearest the pointer.
    private func dropTarget(at pt: NSPoint) -> DropTarget {
        if case .workspaces = dragged, let r = rowIndex(at: pt), case .header(let gi) = rows[r],
           collapsed || (pt.y > frames[r].minY + 5 && pt.y < frames[r].maxY - 5) {
            return .into(groups[gi].id)
        }
        return .gap(frames.firstIndex { pt.y < $0.midY } ?? rows.count)
    }

    /// A gap as a model move: before which workspace, and into which group. Inside an open group (after its
    /// header or between two of its members) means into it; anywhere else means no group.
    private func resolve(gap g: Int, moving: Set<UUID>) -> (anchor: UUID?, group: UUID?) {
        var anchor: UUID?
        if g < rows.count {
            let start: Int
            switch rows[g] {
            case .header(let gi): start = memberIndices(groups[gi].id).first ?? items.count
            case .workspace(let i): start = i
            }
            anchor = items[start...].first { !moving.contains($0.id) }?.id
        }
        var into: UUID?
        if g > 0, case .header(let gi) = rows[g - 1], !groups[gi].collapsed {
            into = groups[gi].id
        } else if g > 0, g < rows.count, case .workspace(let a) = rows[g - 1], case .workspace(let b) = rows[g],
                  let ga = items[a].group, items[b].group == ga {
            into = ga
        }
        return (anchor, into)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        statusHits = []; portHits = []   // every row is drawn below; drawSubtitle collects the link spans again
        tipRects = []
        defer { tips.apply(tipRects, to: self) }
        let title: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor(white: 1, alpha: 0.45),
            .kern: 1.2,
        ]
        if !collapsed { ("WORKSPACES" as NSString).draw(at: NSPoint(x: 16, y: 17), withAttributes: title) }
        let pr = plusRect
        if hoverIndex == -1 {
            NSColor(white: 1, alpha: 0.1).setFill()
            NSBezierPath(roundedRect: pr, xRadius: 6, yRadius: 6).fill()
        }
        let p = NSBezierPath()
        p.move(to: NSPoint(x: pr.midX - 5, y: pr.midY)); p.line(to: NSPoint(x: pr.midX + 5, y: pr.midY))
        p.move(to: NSPoint(x: pr.midX, y: pr.midY - 5)); p.line(to: NSPoint(x: pr.midX, y: pr.midY + 5))
        p.lineWidth = 1.5
        NSColor(white: 1, alpha: 0.6).setStroke()
        p.stroke()

        let draggedIDs: Set<UUID> = {
            switch dragged {
            case .workspaces(let ids): return Set(ids)
            case .group(let g): return Set(items.filter { $0.group == g }.map(\.id))
            case nil: return []
            }
        }()
        for y in railDividers { drawRailLine(y: y) }
        for (r, row) in rows.enumerated() {
            let f = frames[r]
            let hover = dragged == nil && hoverIndex == r
            switch row {
            case .header(let gi):
                let target = dropTarget == .into(groups[gi].id) || dragged == .group(groups[gi].id)
                if collapsed {
                    drawRailGroup(groups[gi], in: f, hover: hover, target: target)
                    tipRects.append((f, groupTip(groups[gi])))
                } else {
                    drawGroupHeader(groups[gi], in: f, hover: hover, target: target)
                }
            case .workspace(let i):
                if collapsed {
                    drawTile(items[i], in: f, hover: hover)
                    let state = display.agentDots ? AgentLegend.workspace(items[i].agents) : ""
                    tipRects.append((f, items[i].name + (state.isEmpty ? "" : "\n" + state)))
                } else {
                    drawRow(items[i], in: f, index: i, hover: hover)
                }
                if draggedIDs.contains(items[i].id) {
                    NSColor(white: 0, alpha: 0.35).setFill()
                    NSBezierPath(roundedRect: f, xRadius: 7, yRadius: 7).fill()
                }
            }
        }
        // the drop position: a line in the gap (indented when it lands in a group)
        if dragged != nil, case .gap(let g) = dropTarget {
            let y = g < frames.count ? frames[g].minY - 1 : (frames.last.map { $0.maxY + 1 } ?? Self.headerHeight)
            let moving = draggedIDs
            let indent: CGFloat = !collapsed && resolve(gap: g, moving: moving).group != nil && dragged.map({
                if case .group = $0 { return false } else { return true } }) == true ? memberIndent : 0
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: inset + indent, y: y - 1, width: bounds.width - inset * 2 - indent, height: 2.5),
                         xRadius: 1.25, yRadius: 1.25).fill()
        }
    }

    /// A group's header: chevron, name, member count; folded, also its members' agent dots and the selection.
    private func drawGroupHeader(_ g: SidebarGroup, in r: NSRect, hover: Bool, target: Bool) {
        let members = items.filter { $0.group == g.id }
        let holdsSelection = g.collapsed && members.contains { isSelected($0.id) }
        if target {
            NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        } else if holdsSelection {
            NSColor(srgbRed: 0x3D / 255, green: 0x7B / 255, blue: 1, alpha: 0.18).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        } else if hover {
            NSColor(white: 1, alpha: 0.06).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        }
        // chevron: right when folded, down when open
        let c = NSPoint(x: r.minX + 12, y: r.midY)
        let chevron = NSBezierPath()
        if g.collapsed {
            chevron.move(to: NSPoint(x: c.x - 2, y: c.y - 4)); chevron.line(to: NSPoint(x: c.x + 2, y: c.y))
            chevron.line(to: NSPoint(x: c.x - 2, y: c.y + 4))
        } else {
            chevron.move(to: NSPoint(x: c.x - 4, y: c.y - 2)); chevron.line(to: NSPoint(x: c.x, y: c.y + 2))
            chevron.line(to: NSPoint(x: c.x + 4, y: c.y - 2))
        }
        chevron.lineWidth = 1.5
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        NSColor(white: 1, alpha: 0.5).setStroke()
        chevron.stroke()

        var right = r.maxX - 8
        let countAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium),
                                                          .foregroundColor: NSColor(white: 1, alpha: 0.3)]
        let count = "\(members.count)" as NSString
        let cw = count.size(withAttributes: countAttrs).width
        count.draw(at: NSPoint(x: right - cw, y: r.midY - 7), withAttributes: countAttrs)
        right -= cw + 8
        if g.collapsed, display.agentDots {
            var sum = WorkspaceAgentSummary()
            for m in members {
                sum.liveSessions += m.agents.liveSessions; sum.needsInput += m.agents.needsInput; sum.unread += m.agents.unread
                sum.running += m.agents.running
            }
            for c in Self.agentDots(sum) { right = drawDot(c, right: right, midY: r.midY, size: 6) }
        }
        guard !(editingGroup && editingID == g.id) else { return }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                    .foregroundColor: NSColor(white: 1, alpha: 0.7), .paragraphStyle: para]
        let x = r.minX + 22
        (g.name as NSString).draw(in: NSRect(x: x, y: r.midY - 8, width: max(0, right - x - 4), height: 17), withAttributes: attrs)
    }

    private func drawRailLine(y: CGFloat, from x0: CGFloat? = nil, to x1: CGFloat? = nil) {
        NSColor(white: 1, alpha: 0.16).setFill()
        let a = x0 ?? inset + 8, b = x1 ?? bounds.width - inset - 8
        NSRect(x: a, y: y, width: max(0, b - a), height: 1).fill()
    }

    /// A group in the rail. Open: a divider with a small chevron in its middle. Folded: a stacked tile with the
    /// member count, the members' most urgent agent state as a dot, and the selection when it holds the selected one.
    private func drawRailGroup(_ g: SidebarGroup, in r: NSRect, hover: Bool, target: Bool) {
        let members = items.filter { $0.group == g.id }
        if target || hover || (g.collapsed && members.contains { isSelected($0.id) }) {
            (target ? NSColor.controlAccentColor.withAlphaComponent(0.35)
                : hover ? NSColor(white: 1, alpha: 0.06)
                : NSColor(srgbRed: 0x3D / 255, green: 0x7B / 255, blue: 1, alpha: 0.30)).setFill()
            let bg = g.collapsed ? NSRect(x: r.minX, y: r.minY + 10, width: r.width, height: r.height - 10) : r
            NSBezierPath(roundedRect: bg, xRadius: g.collapsed ? 9 : 4, yRadius: g.collapsed ? 9 : 4).fill()
        }
        guard g.collapsed else {
            let y = r.midY - 0.5
            drawRailLine(y: y, to: r.midX - 7)
            drawRailLine(y: y, from: r.midX + 7)
            let c = NSPoint(x: r.midX, y: r.midY)
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: c.x - 3, y: c.y - 1.5)); chevron.line(to: NSPoint(x: c.x, y: c.y + 1.5))
            chevron.line(to: NSPoint(x: c.x + 3, y: c.y - 1.5))
            chevron.lineWidth = 1.3
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            NSColor(white: 1, alpha: hover ? 0.6 : 0.35).setStroke()
            chevron.stroke()
            return
        }
        // the divider, then two cards behind each other, the front one with the count
        drawRailLine(y: r.minY + 5)
        let w: CGFloat = 32, h: CGFloat = 24
        let front = NSRect(x: r.midX - w / 2, y: r.maxY - h - 6, width: w, height: h)
        let back = front.insetBy(dx: 4, dy: 0).offsetBy(dx: 0, dy: -5)
        NSColor(white: 1, alpha: 0.16).setFill()
        NSBezierPath(roundedRect: back, xRadius: 6, yRadius: 6).fill()
        NSColor(white: 0.16, alpha: 1).setFill()
        NSBezierPath(roundedRect: front, xRadius: 7, yRadius: 7).fill()
        NSColor(white: 1, alpha: 0.12).setFill()
        NSBezierPath(roundedRect: front, xRadius: 7, yRadius: 7).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                                                    .foregroundColor: NSColor(white: 1, alpha: 0.75)]
        let s = "\(members.count)" as NSString
        let sz = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: front.midX - sz.width / 2, y: front.midY - sz.height / 2), withAttributes: attrs)
        guard display.agentDots else { return }
        let needs = members.contains { $0.agents.anyNeedsInput }, unread = members.contains { $0.agents.anyUnread }
        let live = members.contains { $0.agents.liveSessions > 0 }
        guard let dot: NSColor = needs ? .systemOrange : unread ? .systemBlue : live ? NSColor(white: 1, alpha: 0.55) : nil
        else { return }
        let d: CGFloat = 8
        let dr = NSRect(x: front.maxX - d + 2.5, y: front.minY - 2.5, width: d, height: d)
        NSColor(white: 0.08, alpha: 1).setFill()
        NSBezierPath(ovalIn: dr.insetBy(dx: -1.5, dy: -1.5)).fill()
        dot.setFill()
        NSBezierPath(ovalIn: dr).fill()
    }

    private func drawRow(_ item: SidebarItem, in r: NSRect, index: Int, hover: Bool) {
        if item.selected {
            NSColor(srgbRed: 0x3D / 255, green: 0x7B / 255, blue: 1, alpha: 0.30).setFill()
            NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
        } else if marked.contains(item.id) {
            NSColor(srgbRed: 0x3D / 255, green: 0x7B / 255, blue: 1, alpha: 0.15).setFill()
            NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
        } else if hover {
            NSColor(white: 1, alpha: 0.06).setFill()
            NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
        }
        // colour stripe
        let stripe = NSRect(x: r.minX + 6, y: r.minY + 7, width: 3, height: r.height - 14)
        (Self.nsColor(hex: item.color) ?? NSColor(white: 1, alpha: 0.18)).setFill()
        NSBezierPath(roundedRect: stripe, xRadius: 1.5, yRadius: 1.5).fill()

        // first line: name, agent dots, ⌘N hint; second line (if any): branch and status entries
        let sub = display.hasSubtitle(item)
        let midY = sub ? r.minY + 14 : r.midY
        if display.icons {
            // the rail's tile, smaller: the icon on the workspace's colour, centred on the row
            let side: CGFloat = 22
            let tile = NSRect(x: r.minX + 14, y: r.midY - side / 2, width: side, height: side)
            (Self.nsColor(hex: item.color)?.withAlphaComponent(0.35) ?? NSColor(white: 1, alpha: 0.1)).setFill()
            NSBezierPath(roundedRect: tile, xRadius: 6, yRadius: 6).fill()
            Self.drawIcon(item.icon.flatMap(WorkspaceIcon.init) ?? WorkspaceIcon.fallback(forName: item.name),
                          in: tile, selected: item.selected, scale: 0.8)
        }
        if sub, item.id != editingID { drawSubtitle(item, in: r) }
        // right side: agent dots, then the ⌘N hint
        var right = r.maxX - 8
        if display.shortcuts, index < 9 {
            let hint: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor(white: 1, alpha: item.selected ? 0.45 : 0.25),
            ]
            let s = "⌘\(index + 1)" as NSString
            let w = s.size(withAttributes: hint).width
            s.draw(at: NSPoint(x: right - w, y: midY - 7), withAttributes: hint)
            right -= w + 8
        }
        // one dot per live Claude session (at most 5): orange waits on you, blue finished unread, grey otherwise
        let dotsRight = right
        for c in display.agentDots ? Self.agentDots(item.agents) : [] { right = drawDot(c, right: right, midY: midY, size: 6) }
        if right < dotsRight {
            tipRects.append((NSRect(x: right, y: midY - 7, width: dotsRight - right + 2, height: 14), AgentLegend.workspace(item.agents)))
        }
        // the workspace's labels, right to left, as long as the name keeps some room
        for l in item.labels.reversed() {
            let w = LabelChip.width(l)
            guard right - w - 4 > r.minX + 70 else { break }
            right -= w + 4
            LabelChip.draw(l, x: right, midY: midY, strong: item.selected)
            tipRects.append((NSRect(x: right, y: midY - 7, width: w, height: 14), AgentLegend.workspaceLabel))
        }
        if display.pin, item.pinned {
            let pin: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9),
                                                      .foregroundColor: NSColor(white: 1, alpha: 0.4)]
            ("📌" as NSString).draw(at: NSPoint(x: right - 12, y: midY - 6), withAttributes: pin)
            right -= 16
        }

        guard item.id != editingID else { return }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: item.selected ? .semibold : .regular),
            .foregroundColor: NSColor(white: 1, alpha: item.selected ? 0.95 : 0.75),
            .paragraphStyle: para,
        ]
        let x = r.minX + display.textInset
        let nameRect = NSRect(x: x, y: midY - 8.5, width: max(0, right - x - 4), height: 18)
        (item.name as NSString).draw(in: nameRect, withAttributes: attrs)
        if (item.name as NSString).size(withAttributes: attrs).width > nameRect.width {
            tipRects.append((nameRect, item.name))   // cut short: the whole name on hover
        }
    }

    /// The rail's tile: the workspace icon on its colour, the selection behind it, the agent state as a dot.
    private func drawTile(_ item: SidebarItem, in r: NSRect, hover: Bool) {
        if marked.contains(item.id) {
            NSColor(srgbRed: 0x3D / 255, green: 0x7B / 255, blue: 1, alpha: 0.15).setFill()
            NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
        }
        if item.selected {
            NSColor(srgbRed: 0x3D / 255, green: 0x7B / 255, blue: 1, alpha: 0.30).setFill()
            NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
        } else if hover {
            NSColor(white: 1, alpha: 0.06).setFill()
            NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9).fill()
        }
        let side: CGFloat = 32
        let tile = NSRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)
        let colour = Self.nsColor(hex: item.color)
        (colour?.withAlphaComponent(0.35) ?? NSColor(white: 1, alpha: 0.1)).setFill()
        NSBezierPath(roundedRect: tile, xRadius: 8, yRadius: 8).fill()
        Self.drawIcon(item.icon.flatMap(WorkspaceIcon.init) ?? WorkspaceIcon.fallback(forName: item.name),
                      in: tile, selected: item.selected)

        // agent state, top right of the tile: needs input, unread, or a running session
        let a = display.agentDots ? item.agents : WorkspaceAgentSummary()
        let dot: NSColor? = a.anyNeedsInput ? .systemOrange : a.anyUnread ? .systemBlue
            : a.liveSessions > 0 ? NSColor(white: 1, alpha: 0.55) : nil
        if let dot {
            let d: CGFloat = 9
            let dr = NSRect(x: tile.maxX - d + 2.5, y: tile.minY - 2.5, width: d, height: d)
            NSColor(white: 0.08, alpha: 1).setFill()
            NSBezierPath(ovalIn: dr.insetBy(dx: -1.5, dy: -1.5)).fill()
            dot.setFill()
            NSBezierPath(ovalIn: dr).fill()
        }
    }

    static func drawIcon(_ icon: WorkspaceIcon, in tile: NSRect, selected: Bool, scale: CGFloat = 1) {
        let alpha: CGFloat = selected ? 0.95 : 0.8
        switch icon {
        case .symbol(let name):
            let config = NSImage.SymbolConfiguration(pointSize: 15 * scale, weight: .medium)
                .applying(.init(paletteColors: [NSColor(white: 1, alpha: alpha)]))
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = img.size
                img.draw(in: NSRect(x: tile.midX - s.width / 2, y: tile.midY - s.height / 2, width: s.width, height: s.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                drawIcon(.text("?"), in: tile, selected: selected, scale: scale)
            }
        case .text(let t):
            let emoji = t.unicodeScalars.contains { $0.properties.isEmojiPresentation }
            let size: CGFloat = (emoji ? 17 : (t.count > 1 ? 12.5 : 15)) * scale
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold),
                .foregroundColor: NSColor(white: 1, alpha: alpha),
            ]
            let str = t as NSString
            let s = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: tile.midX - s.width / 2, y: tile.midY - s.height / 2), withAttributes: attrs)
        }
    }

    private func drawSubtitle(_ item: SidebarItem, in r: NSRect) {
        let font = NSFont.systemFont(ofSize: 10.5)
        let dim = NSColor(white: 1, alpha: item.selected ? 0.6 : 0.45)
        let line = NSMutableAttributedString()
        func add(_ s: String, _ c: NSColor) { line.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c])) }
        // a long branch must not push the status entries out of the row
        if display.branch, let b = item.branch { add("\u{2387} " + (b.count > 22 ? b.prefix(10) + "…" + b.suffix(10) : b), dim) }
        if display.directory, let d = item.directory {
            if line.length > 0 { add("  ", dim) }
            add(Self.shortPath(d), dim)
        }
        let x = r.minX + display.textInset
        let maxX = r.maxX - 8
        for port in display.ports ? item.ports : [] {
            if line.length > 0 { add("  ", dim) }
            let start = x + line.size().width
            add(":\(port)", NSColor(white: 1, alpha: item.selected ? 0.85 : 0.7))
            let n = ":\(port)".utf16.count
            line.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: NSColor(white: 1, alpha: 0.3)],
                               range: NSRange(location: line.length - n, length: n))
            let end = min(maxX, x + line.size().width)
            if end > start { portHits.append((NSRect(x: start, y: r.minY + 20, width: end - start, height: 18), port)) }
        }
        for st in display.status ? item.status : [] {
            if line.length > 0 { add("  ·  ", NSColor(white: 1, alpha: 0.25)) }
            let start = x + line.size().width
            add(st.key + " ", dim)
            add(st.value, Self.nsColor(hex: st.color) ?? NSColor(white: 1, alpha: item.selected ? 0.85 : 0.7))
            if st.url != nil {
                // a link: underlined, and its span is a click target (as far as it is visible)
                let n = (st.key + " " + st.value).utf16.count
                line.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                                    .underlineColor: NSColor(white: 1, alpha: 0.3)],
                                   range: NSRange(location: line.length - n, length: n))
                let end = min(maxX, x + line.size().width)
                if end > start {
                    statusHits.append((NSRect(x: start, y: r.minY + 20, width: end - start, height: 18), item.id, st.key))
                }
            }
        }
        if display.metadata {
            for (k, v) in item.metadata.sorted(by: { $0.key < $1.key }) {
                if line.length > 0 { add("  ·  ", NSColor(white: 1, alpha: 0.25)) }
                add(k + " ", dim)
                add(v, NSColor(white: 1, alpha: item.selected ? 0.85 : 0.7))
            }
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        line.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: line.length))
        line.draw(in: NSRect(x: x, y: r.minY + 22, width: max(0, maxX - x), height: 15))
    }

    /// A folder for the row: the home folder as `~`, and only the last two parts of a deep path.
    static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        var p = path
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { p = "~" + p.dropFirst(home.count) }
        let parts = p.split(separator: "/", omittingEmptySubsequences: true)
        return parts.count > 3 ? "…/" + parts.suffix(2).joined(separator: "/") : p
    }

    /// The row's agent dots, right to left: one per live session, coloured as on its tab (orange waiting, blue finished
    /// unread, green working, grey idle), the most urgent first, at most 5.
    static func agentDots(_ a: WorkspaceAgentSummary) -> [NSColor] {
        let waiting = min(a.needsInput, a.liveSessions)
        let unread = min(a.unread, a.liveSessions - waiting)
        let working = min(a.running, a.liveSessions - waiting - unread)
        let rest = a.liveSessions - waiting - unread - working
        let all = Array(repeating: NSColor.systemOrange, count: waiting) + Array(repeating: NSColor.systemBlue, count: unread)
            + Array(repeating: NSColor.systemGreen, count: working) + Array(repeating: NSColor(white: 1, alpha: 0.45), count: rest)
        return Array(all.prefix(5))
    }

    private func drawDot(_ c: NSColor, right: CGFloat, midY: CGFloat, size: CGFloat = 7) -> CGFloat {
        c.setFill()
        NSBezierPath(ovalIn: NSRect(x: right - size, y: midY - size / 2, width: size, height: size)).fill()
        return right - size - 4
    }

    static func nsColor(hex: String?) -> NSColor? {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways,
                                                       .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        trackingArea = a
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let h = plusRect.contains(pt) ? -1 : rowIndex(at: pt)
        if h != hoverIndex { hoverIndex = h; needsDisplay = true }
        (statusHit(at: pt) != nil || portHit(at: pt) != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    /// Clickable status entries as drawn last: (rect, workspace, key).
    private(set) var statusHits: [(NSRect, UUID, String)] = []

    /// Clickable ports as drawn last: (rect, port).
    private(set) var portHits: [(NSRect, Int)] = []

    func portHit(at pt: NSPoint) -> Int? { portHits.first { $0.0.contains(pt) }?.1 }

    func statusHit(at pt: NSPoint) -> (UUID, String)? {
        statusHits.first { $0.0.contains(pt) }.map { ($0.1, $0.2) }
    }

    override func mouseExited(with event: NSEvent) {
        if hoverIndex != nil { hoverIndex = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if editor != nil { endEditing(commit: true) }
        if plusRect.contains(pt) { host?.sidebarNew(); return }
        // the header ("WORKSPACES" and the space around it) is meum's title bar: it moves the whole window
        if pt.y < Self.headerHeight, rowIndex(at: pt) == nil { window?.titleBarMouseDown(event); return }
        guard let r = rowIndex(at: pt) else { return }
        if event.clickCount == 2, !collapsed {
            switch rows[r] {
            case .header(let gi): beginGroupRename(groups[gi].id)
            case .workspace(let i): beginRename(items[i].id)
            }
            return
        }
        pressIndex = r
        pressPoint = pt
        pressFlags = event.modifierFlags.intersection([.shift, .command])
    }

    override func mouseDragged(with event: NSEvent) {
        guard let p = pressIndex else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if dragged == nil, hypot(pt.x - pressPoint.x, pt.y - pressPoint.y) > 4 {
            switch rows[p] {
            case .header(let gi): dragged = .group(groups[gi].id)
            case .workspace(let i):
                let id = items[i].id
                dragged = .workspaces(isSelected(id) ? selectedIDs : [id])
            }
        }
        guard dragged != nil else { return }
        autoscroll(with: event)   // near the top or bottom edge, a drag scrolls the list
        dropTarget = dropTarget(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressIndex = nil; dragged = nil; dropTarget = nil; needsDisplay = true }
        if let d = dragged, let t = dropTarget {
            finishDrag(d, t)
            return
        }
        guard let p = pressIndex else { return }
        let pt = convert(event.locationInWindow, from: nil)
        switch rows[p] {
        case .header(let gi):
            host?.sidebarSetGroupCollapsed(groups[gi].id, !groups[gi].collapsed)
        case .workspace(let i):
            if pressFlags.isEmpty, !collapsed, let port = portHit(at: pt) {
                host?.sidebarOpenPort(port)
                return
            }
            if pressFlags.isEmpty, !collapsed, let (id, key) = statusHit(at: pt) {
                host?.sidebarStatusClicked(id, key: key)
                return
            }
            click(items[i].id, flags: pressFlags)
        }
    }

    /// Selection: a plain click selects one workspace; cmd-click adds or removes one, shift-click selects the range
    /// from the selected workspace. The clicked one becomes the selected (primary) workspace.
    func click(_ id: UUID, flags: NSEvent.ModifierFlags) {
        let primary = primaryID
        if flags.contains(.command) {
            if id == primary {
                // unselect the primary: the nearest other selected one takes over
                guard !marked.isEmpty, let i = items.firstIndex(where: { $0.id == id }) else { return }
                let next = items.indices.filter { marked.contains(items[$0].id) }.min { abs($0 - i) < abs($1 - i) }!
                marked.remove(items[next].id)
                host?.sidebarSelect(items[next].id)
            } else if marked.contains(id) {
                marked.remove(id)
                needsDisplay = true
            } else {
                if let primary { marked.insert(primary) }
                host?.sidebarSelect(id)
            }
            return
        }
        if flags.contains(.shift), let primary {
            let visible: [UUID] = rows.compactMap { if case .workspace(let i) = $0 { return items[i].id } else { return nil } }
            if let a = visible.firstIndex(of: primary), let b = visible.firstIndex(of: id) {
                marked = Set(visible[min(a, b)...max(a, b)]).subtracting([id])
                host?.sidebarSelect(id)
                needsDisplay = true
                return
            }
        }
        marked = []
        needsDisplay = true
        host?.sidebarSelect(id)
    }

    private func finishDrag(_ d: Dragged, _ t: DropTarget) {
        switch (d, t) {
        case (.workspaces(let ids), .into(let g)):
            host?.sidebarSetGroup(ids, g)
        case (.workspaces(let ids), .gap(let gap)):
            let (anchor, into) = resolve(gap: gap, moving: Set(ids))
            host?.sidebarMoveWorkspaces(ids, before: anchor, group: into)
        case (.group(let g), .gap(let gap)):
            let (anchor, _) = resolve(gap: gap, moving: Set(items.filter { $0.group == g }.map(\.id)))
            host?.sidebarMoveGroup(g, before: anchor)
        case (.group, .into):
            break
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let pt = convert(event.locationInWindow, from: nil)
        guard let r = rowIndex(at: pt) else { return nil }
        let m = NSMenu()
        if case .header(let gi) = rows[r] {
            let g = groups[gi]
            if collapsed {
                let title = NSMenuItem(title: g.name, action: nil, keyEquivalent: "")
                title.isEnabled = false
                m.addItem(title)
            } else {
                m.addItem(withTitle: "Rename Group…", action: #selector(menuRenameGroup(_:)), keyEquivalent: "")
                    .representedObject = g.id
            }
            m.addItem(withTitle: g.collapsed ? "Expand" : "Collapse", action: #selector(menuToggleGroup(_:)), keyEquivalent: "")
                .representedObject = g.id
            m.addItem(.separator())
            m.addItem(withTitle: "Ungroup", action: #selector(menuUngroup(_:)), keyEquivalent: "").representedObject = g.id
            for mi in m.items where mi.action != nil { mi.target = self }
            return m
        }
        guard case .workspace(let i) = rows[r] else { return nil }
        let item = items[i]
        if collapsed {
            let title = NSMenuItem(title: item.name, action: nil, keyEquivalent: "")
            title.isEnabled = false
            m.addItem(title)
        } else {
            m.addItem(withTitle: "Rename…", action: #selector(menuRename(_:)), keyEquivalent: "").representedObject = item.id
        }
        let colours = NSMenu()
        for (name, hex) in Self.palette {
            let mi = NSMenuItem(title: name, action: #selector(menuColor(_:)), keyEquivalent: "")
            mi.representedObject = [item.id, hex as Any]
            mi.state = item.color == hex ? .on : .off
            if let c = Self.nsColor(hex: hex) { mi.image = Self.swatch(c) }
            mi.target = self
            colours.addItem(mi)
        }
        let cm = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
        cm.submenu = colours
        m.addItem(cm)
        m.addItem(withTitle: "Icon…", action: #selector(menuIcon(_:)), keyEquivalent: "").representedObject = item.id
        m.addItem(withTitle: item.pinned ? "Unpin" : "Pin", action: #selector(menuPin(_:)), keyEquivalent: "")
            .representedObject = item.id

        // groups: for the whole selection when the clicked row is part of it
        let targets = isSelected(item.id) ? selectedIDs : [item.id]
        m.addItem(.separator())
        m.addItem(withTitle: targets.count > 1 ? "New Group from \(targets.count) Workspaces" : "New Group",
                  action: #selector(menuNewGroup(_:)), keyEquivalent: "").representedObject = targets
        let theirGroups = Set(targets.map { id in items.first { $0.id == id }?.group })
        let others = groups.filter { !(theirGroups.count == 1 && theirGroups.first == $0.id) }
        if !others.isEmpty {
            let sub = NSMenu()
            for g in others {
                let mi = NSMenuItem(title: g.name, action: #selector(menuMoveToGroup(_:)), keyEquivalent: "")
                mi.representedObject = [targets, g.id] as [Any]
                mi.target = self
                sub.addItem(mi)
            }
            let mg = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
            mg.submenu = sub
            m.addItem(mg)
        }
        if theirGroups.contains(where: { $0 != nil }) {
            m.addItem(withTitle: "Remove from Group", action: #selector(menuRemoveFromGroup(_:)), keyEquivalent: "")
                .representedObject = targets
        }
        m.addItem(.separator())
        m.addItem(withTitle: "Close Workspace", action: #selector(menuClose(_:)), keyEquivalent: "")
            .representedObject = item.id
        for mi in m.items where mi.action != nil { mi.target = self }
        return m
    }

    @objc private func menuNewGroup(_ s: NSMenuItem) {
        guard let ids = s.representedObject as? [UUID], let g = host?.sidebarNewGroup(ids) else { return }
        marked = []
        reload()
        if collapsed { host?.sidebarDidEndInteraction() } else { beginGroupRename(g) }
    }
    @objc private func menuMoveToGroup(_ s: NSMenuItem) {
        guard let pair = s.representedObject as? [Any], let ids = pair[0] as? [UUID], let g = pair[1] as? UUID else { return }
        host?.sidebarSetGroup(ids, g)
        host?.sidebarDidEndInteraction()
    }
    @objc private func menuRemoveFromGroup(_ s: NSMenuItem) {
        if let ids = s.representedObject as? [UUID] { host?.sidebarSetGroup(ids, nil) }
        host?.sidebarDidEndInteraction()
    }
    @objc private func menuRenameGroup(_ s: NSMenuItem) { if let id = s.representedObject as? UUID { beginGroupRename(id) } }
    @objc private func menuToggleGroup(_ s: NSMenuItem) {
        guard let id = s.representedObject as? UUID, let g = groups.first(where: { $0.id == id }) else { return }
        host?.sidebarSetGroupCollapsed(id, !g.collapsed)
        host?.sidebarDidEndInteraction()
    }
    @objc private func menuUngroup(_ s: NSMenuItem) {
        if let id = s.representedObject as? UUID { host?.sidebarUngroup(id) }
        host?.sidebarDidEndInteraction()
    }

    static func swatch(_ c: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            c.setFill(); NSBezierPath(ovalIn: r).fill(); return true
        }
    }

    private var iconPopover: NSPopover?
    @objc private func menuIcon(_ s: NSMenuItem) {
        guard let id = s.representedObject as? UUID else { return }
        showIconPicker(id)
    }

    /// The icon picker in a popover next to the workspace's row (or its folded group's).
    func showIconPicker(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let r = rows.firstIndex(of: .workspace(i))
            ?? items[i].group.flatMap { g in groups.firstIndex { $0.id == g } }.flatMap { rows.firstIndex(of: .header($0)) }
        guard let r else { return }
        iconPopover?.close()
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = IconPickerView.controller(current: items[i].icon) { [weak self, weak p] icon in
            self?.host?.sidebarSetIcon(id, icon)
            p?.close()
            self?.host?.sidebarDidEndInteraction()
        }
        p.show(relativeTo: frames[r], of: self, preferredEdge: .maxX)
        iconPopover = p
    }

    @objc private func menuRename(_ s: NSMenuItem) { if let id = s.representedObject as? UUID { beginRename(id) } }
    @objc private func menuPin(_ s: NSMenuItem) {
        guard let id = s.representedObject as? UUID, let it = items.first(where: { $0.id == id }) else { return }
        host?.sidebarSetPinned(id, !it.pinned)
        host?.sidebarDidEndInteraction()
    }
    @objc private func menuClose(_ s: NSMenuItem) {
        if let id = s.representedObject as? UUID { host?.sidebarClose(id) }
        host?.sidebarDidEndInteraction()
    }
    @objc private func menuColor(_ s: NSMenuItem) {
        guard let pair = s.representedObject as? [Any], let id = pair.first as? UUID else { return }
        host?.sidebarSetColor(id, pair.count > 1 ? pair[1] as? String : nil)
        host?.sidebarDidEndInteraction()
    }

    // MARK: Rename

    func beginRename(_ id: UUID) {
        guard !collapsed, let i = items.firstIndex(where: { $0.id == id }) else { return }
        // a member of a folded group: unfold it first
        if let g = group(items[i].group), g.collapsed { host?.sidebarSetGroupCollapsed(g.id, false); reload() }
        guard let r = rows.firstIndex(of: .workspace(i)).map({ frames[$0] }) else { return }
        openEditor(in: r, text: items[i].name, id: id, group: false)
    }

    func beginGroupRename(_ id: UUID) {
        guard !collapsed, let gi = groups.firstIndex(where: { $0.id == id }),
              let r = rows.firstIndex(of: .header(gi)).map({ frames[$0] }) else { return }
        openEditor(in: r, text: groups[gi].name, id: id, group: true)
    }

    private func openEditor(in r: NSRect, text: String, id: UUID, group: Bool) {
        endEditing(commit: false)
        let f = NSTextField(frame: NSRect(x: r.minX + (group ? 18 : display.textInset - 4), y: r.midY - 11,
                                          width: r.width - 50 - (group ? 0 : display.textInset - 16), height: 22))
        f.stringValue = text
        f.font = .systemFont(ofSize: 13)
        f.focusRingType = .none
        f.bezelStyle = .roundedBezel
        f.delegate = self
        f.target = self
        f.action = #selector(editorCommitted(_:))
        addSubview(f)
        editor = f
        editingID = id
        editingGroup = group
        needsDisplay = true
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
    }

    @objc private func editorCommitted(_ sender: NSTextField) { endEditing(commit: true) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            endEditing(commit: false)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) { endEditing(commit: true) }

    func endEditing(commit: Bool) {
        guard let f = editor, let id = editingID else { return }
        editor = nil
        editingID = nil
        let name = f.stringValue
        f.removeFromSuperview()
        if commit { if editingGroup { host?.sidebarRenameGroup(id, to: name) } else { host?.sidebarRename(id, to: name) } }
        editingGroup = false
        needsDisplay = true
        host?.sidebarDidEndInteraction()
    }

    /// Debug: the text field used for an inline rename, if one is open.
    var renameField: NSTextField? { editor }
}

/// A scroll view whose scroller is always the thin one that fades out. AppKit resets `scrollerStyle` to the system's
/// preference (the always-visible kind when a mouse is attached and scroll bars are on Automatic), so it is pinned.
final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}

/// The sidebar card: a `SidebarView` in a scroll view filling the card, so a long list scrolls.
final class SidebarCardView: CardHostView {
    let sidebar = SidebarView()
    let scroll = OverlayScrollView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.frame = content.bounds
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        // the window has a (hidden) title bar: without this, AppKit insets the list by its height
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        sidebar.frame = content.bounds
        scroll.documentView = sidebar
        content.addSubview(scroll)
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sidebar.fitToContent() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}
