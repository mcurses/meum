import AppKit
import MeumCore

/// Workspace ▸ Go to Workspace… (⌘P): a search field over the meum window that finds a workspace or a tab as you type
/// (`WorkspaceSearch`). ↑↓ (or ⌃P ⌃N) move, Return goes there, Escape or a click elsewhere closes it.
@MainActor
final class SwitcherController: NSObject, NSTextFieldDelegate {
    private weak var controller: WorkspaceController?
    private var panel: SwitcherPanel?
    private let field = NSTextField()
    private let list = SwitcherListView()
    private let scroll = NSScrollView()
    private(set) var hits: [WorkspaceSearch.Hit] = []
    private(set) var selected = 0
    /// Workspaces most recently left first (kept in memory only).
    private(set) var recent: [UUID] = []
    private var lastSelected: UUID?

    static let width: CGFloat = 560
    static let rowHeight: CGFloat = 44
    static let maxVisibleRows = 9
    static let fieldHeight: CGFloat = 52

    init(controller: WorkspaceController) {
        self.controller = controller
        super.init()
        lastSelected = controller.store.state.selectedWorkspaceID
    }

    var isOpen: Bool { panel?.isVisible == true }
    var query: String { field.stringValue }

    /// Called on every model change: keeps the recency order, and the open list current.
    func modelChanged() {
        guard let c = controller else { return }
        let sel = c.store.state.selectedWorkspaceID
        if sel != lastSelected {
            if let prev = lastSelected {
                recent.removeAll { $0 == prev }
                recent.insert(prev, at: 0)
            }
            if let sel { recent.removeAll { $0 == sel } }
            lastSelected = sel
        }
        let ids = Set(c.store.state.workspaces.map(\.id))
        recent.removeAll { !ids.contains($0) }
        if isOpen { refresh(keepSelection: true) }
    }

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard let c = controller else { return }
        if panel == nil { build() }
        guard let panel else { return }
        field.stringValue = ""
        refresh(keepSelection: false)
        position(over: c.window)
        if panel.parent == nil { c.window.addChildWindow(panel, ordered: .above) }
        if c.background {
            panel.orderFront(nil)   // a test instance never takes the user's focus
        } else {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(field)
        }
    }

    func close(refocus: Bool = true) {
        guard let panel, panel.isVisible else { return }
        controller?.window.removeChildWindow(panel)
        panel.orderOut(nil)
        if refocus {
            controller?.window.makeKey()
            controller?.focusTerminal()
        }
    }

    /// Sets the query as if typed (the debug interface uses it too).
    func setQuery(_ q: String) {
        field.stringValue = q
        refresh(keepSelection: false)
    }

    func move(_ d: Int) {
        guard !hits.isEmpty else { return }
        selected = (selected + d + hits.count) % hits.count
        list.selected = selected
        list.scrollToVisible(list.rowRect(selected))
    }

    /// Goes to the selected row's workspace or tab, and closes.
    func choose(_ index: Int? = nil) {
        let i = index ?? selected
        guard let c = controller, hits.indices.contains(i) else { return }
        let target = hits[i].target
        close(refocus: false)
        switch target {
        case .workspace(let id): c.sidebarSelect(id)
        case .tab(_, let tab): c.selectTab(tab)
        }
        c.window.makeKey()
    }

    // MARK: testing

    var debugState: [String: Any] {
        [
            "open": isOpen, "query": query, "selected": selected,
            "recent": recent.map(\.uuidString),
            "frame": panel.map { [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height] } ?? [],
            "rows": hits.map { h -> [String: Any] in
                var r: [String: Any] = ["title": h.title, "subtitle": h.subtitle, "matches": h.titleMatches,
                                        "workspace": h.target.workspaceID.uuidString]
                if case .tab(_, let t) = h.target { r["tab"] = t.uuidString }
                return r
            },
        ]
    }

    /// The list as a PNG on a dark ground (the blur and the text field draw nothing off screen).
    func snapshot() throws -> Data {
        let size = scroll.frame.size
        let img = NSImage(size: size)
        img.lockFocusFlipped(true)
        NSColor(white: 0.13, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        list.draw(NSRect(origin: .zero, size: size))
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return png
    }

    // MARK: building

    private func build() {
        let p = SwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.appearance = NSAppearance(named: .darkAqua)
        p.onResign = { [weak self] in self?.close(refocus: false) }

        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 14
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 0.5
        fx.layer?.borderColor = NSColor(white: 1, alpha: 0.15).cgColor
        p.contentView = fx

        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        glass.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        glass.contentTintColor = NSColor(white: 1, alpha: 0.5)
        glass.frame = NSRect(x: 18, y: 0, width: 22, height: Self.fieldHeight)
        glass.autoresizingMask = [.minYMargin]
        fx.addSubview(glass)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.textColor = NSColor(white: 1, alpha: 0.95)
        field.placeholderAttributedString = NSAttributedString(string: "Go to workspace or tab", attributes: [
            .font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor(white: 1, alpha: 0.35),
        ])
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        fx.addSubview(field)

        let sep = NSBox()
        sep.boxType = .custom
        sep.borderWidth = 0
        sep.fillColor = NSColor(white: 1, alpha: 0.1)
        sep.identifier = NSUserInterfaceItemIdentifier("sep")
        fx.addSubview(sep)

        list.onClick = { [weak self] i in self?.choose(i) }
        list.onHover = { [weak self] i in
            guard let self else { return }
            self.selected = i
            self.list.selected = i
        }
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        fx.addSubview(scroll)
        panel = p
    }

    private func layoutPanel() {
        guard let panel, let fx = panel.contentView else { return }
        let rows = max(1, min(hits.count, Self.maxVisibleRows))
        let listH = CGFloat(rows) * Self.rowHeight + 12
        let h = Self.fieldHeight + 1 + listH
        var f = panel.frame
        f.origin.y += f.height - h
        f.size = NSSize(width: Self.width, height: h)
        panel.setFrame(f, display: true)
        fx.frame = NSRect(origin: .zero, size: f.size)
        field.frame = NSRect(x: 48, y: h - Self.fieldHeight + 13, width: Self.width - 64, height: 26)
        fx.subviews.first { $0.identifier?.rawValue == "sep" }?.frame = NSRect(x: 0, y: listH, width: Self.width, height: 1)
        for v in fx.subviews where v is NSImageView { v.frame = NSRect(x: 18, y: h - Self.fieldHeight, width: 22, height: Self.fieldHeight) }
        scroll.frame = NSRect(x: 0, y: 0, width: Self.width, height: listH)
        list.frame = NSRect(x: 0, y: 0, width: Self.width, height: max(listH, CGFloat(max(hits.count, 1)) * Self.rowHeight + 12))
    }

    private func position(over window: NSWindow) {
        guard let panel else { return }
        let w = window.frame
        let h = panel.frame.height
        panel.setFrameOrigin(NSPoint(x: w.midX - Self.width / 2, y: w.maxY - w.height * 0.18 - h))
    }

    private func refresh(keepSelection: Bool) {
        guard let c = controller else { return }
        let old = keepSelection && hits.indices.contains(selected) ? hits[selected].target : nil
        hits = WorkspaceSearch.results(c.store.state, query: field.stringValue, recent: recent)
        selected = old.flatMap { t in hits.firstIndex { $0.target == t } } ?? 0
        list.rows = hits.map { row(for: $0, in: c) }
        list.selected = selected
        list.emptyText = hits.isEmpty ? "No workspace or tab matches “\(field.stringValue)”" : nil
        layoutPanel()
        list.scrollToVisible(list.rowRect(selected))
    }

    private func row(for hit: WorkspaceSearch.Hit, in c: WorkspaceController) -> SwitcherListView.Row {
        let state = c.store.state
        switch hit.target {
        case .workspace(let id):
            let ws = state.workspace(id)
            let index = state.index(of: id)
            return .init(hit: hit, icon: ws?.icon.flatMap(WorkspaceIcon.init) ?? WorkspaceIcon.fallback(forName: hit.title),
                         color: SidebarView.nsColor(hex: ws?.color),
                         dots: ws.map { SidebarView.agentDots(c.agents.summary(forWorkspace: $0)) } ?? [],
                         shortcut: index.flatMap { $0 < 9 ? c.shortcutDisplay("workspace\($0 + 1)") : nil },
                         current: id == state.selectedWorkspaceID)
        case .tab(let wsID, let tab):
            let ws = state.workspace(wsID)
            let a = c.agents.state(forTab: tab)
            let dot: NSColor? = a.map { $0.phase == .needsInput ? .systemOrange : $0.unread ? .systemBlue
                : $0.phase == .running ? .systemGreen : NSColor(white: 1, alpha: 0.45) }
            let isWidget = ws?.tab(tab)?.isWidget == true
            return .init(hit: hit, icon: .symbol(isWidget ? "square.grid.2x2" : a != nil ? "sparkle" : "terminal"),
                         color: SidebarView.nsColor(hex: ws?.color), dots: dot.map { [$0] } ?? [], shortcut: nil,
                         current: false, isTab: true)
        }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { refresh(keepSelection: false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.insertNewline(_:)): choose()
        case #selector(NSResponder.cancelOperation(_:)): close()
        case #selector(NSResponder.insertTab(_:)): move(1)
        case #selector(NSResponder.insertBacktab(_:)): move(-1)
        default: return false
        }
        return true
    }
}

/// A borderless panel that can take the keyboard, and closes when it loses it.
final class SwitcherPanel: NSPanel {
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
    override func cancelOperation(_ sender: Any?) { onResign?() }
}

/// The switcher's rows, drawn like the sidebar's: icon tile, title with the matched letters bright, a dim line below,
/// agent dots and the workspace's shortcut on the right.
final class SwitcherListView: NSView {
    struct Row {
        var hit: WorkspaceSearch.Hit
        var icon: WorkspaceIcon
        var color: NSColor?
        var dots: [NSColor]
        var shortcut: String?
        var current: Bool
        var isTab = false
    }

    var rows: [Row] = [] { didSet { needsDisplay = true } }
    var selected = 0 { didSet { if selected != oldValue { needsDisplay = true } } }
    var emptyText: String? { didSet { needsDisplay = true } }
    var onClick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?
    override var isFlipped: Bool { true }

    func rowRect(_ i: Int) -> NSRect {
        NSRect(x: 6, y: 6 + CGFloat(i) * SwitcherController.rowHeight, width: bounds.width - 12, height: SwitcherController.rowHeight)
    }

    private func index(at p: NSPoint) -> Int? {
        let i = Int((p.y - 6) / SwitcherController.rowHeight)
        return p.y >= 6 && rows.indices.contains(i) ? i : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)), i != selected { onHover?(i) }
    }

    override func mouseDown(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) { onClick?(i) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let t = emptyText {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 1, alpha: 0.45)]
            (t as NSString).draw(at: NSPoint(x: 20, y: 18), withAttributes: attrs)
            return
        }
        for (i, row) in rows.enumerated() {
            let r = rowRect(i)
            guard r.intersects(dirtyRect) else { continue }
            if i == selected {
                NSColor(srgbRed: 0x3D / 255, green: 0x7B / 255, blue: 1, alpha: 0.45).setFill()
                NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            }
            // icon tile
            let side: CGFloat = 28
            let tile = NSRect(x: r.minX + 10, y: r.midY - side / 2, width: side, height: side)
            (row.color?.withAlphaComponent(row.isTab ? 0.2 : 0.35) ?? NSColor(white: 1, alpha: row.isTab ? 0.06 : 0.1)).setFill()
            NSBezierPath(roundedRect: tile, xRadius: 7, yRadius: 7).fill()
            SidebarView.drawIcon(row.icon, in: tile, selected: i == selected)

            // right side: shortcut, then dots
            var right = r.maxX - 12
            if let s = row.shortcut {
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12),
                                                           .foregroundColor: NSColor(white: 1, alpha: 0.4)]
                let size = (s as NSString).size(withAttributes: attrs)
                (s as NSString).draw(at: NSPoint(x: right - size.width, y: r.midY - size.height / 2), withAttributes: attrs)
                right -= size.width + 12
            }
            for c in row.dots.reversed() {
                c.setFill()
                NSBezierPath(ovalIn: NSRect(x: right - 7, y: r.midY - 3.5, width: 7, height: 7)).fill()
                right -= 11
            }

            // title (matched letters bright and bold), subtitle below
            let x = tile.maxX + 12
            let width = max(0, right - 8 - x)
            let title = NSMutableAttributedString(string: row.hit.title, attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor(white: 1, alpha: row.hit.titleMatches.isEmpty ? 0.92 : 0.7),
            ])
            let chars = Array(row.hit.title)
            var utf16 = 0
            var offsets: [Int] = []
            for ch in chars { offsets.append(utf16); utf16 += String(ch).utf16.count }
            for m in row.hit.titleMatches where m < chars.count {
                title.addAttributes([.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 14, weight: .bold)],
                                    range: NSRange(location: offsets[m], length: String(chars[m]).utf16.count))
            }
            if row.current {
                title.append(NSAttributedString(string: "  current", attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 1, alpha: 0.35)]))
            }
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            title.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: title.length))
            let sub = row.hit.subtitle
            if sub.isEmpty {
                title.draw(in: NSRect(x: x, y: r.midY - 9, width: width, height: 18))
            } else {
                title.draw(in: NSRect(x: x, y: r.minY + 5, width: width, height: 18))
                (sub as NSString).draw(in: NSRect(x: x, y: r.minY + 24, width: width, height: 15), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 1, alpha: 0.45), .paragraphStyle: para])
            }
        }
    }
}
