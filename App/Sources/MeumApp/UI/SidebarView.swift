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
    func sidebarSetPinned(_ id: UUID, _ pinned: Bool)
    /// A status entry with a URL was clicked.
    func sidebarStatusClicked(_ id: UUID, key: String)
    /// The sidebar finished an interaction (rename, menu); the host returns keyboard focus to the terminal.
    func sidebarDidEndInteraction()
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

    var hasSubtitle: Bool { branch != nil || !status.isEmpty }
}

struct SidebarStatus: Equatable {
    var key: String
    var value: String
    var color: String?
    var url: String?
}

/// The built-in sidebar: workspace rows with colour stripe, name, agent dots and selection; click to select,
/// drag to reorder, double-click or right-click to rename, colour, pin or close; "+" to add.
/// Collapsed (the narrow rail), each workspace is an icon tile with its agent dot; the name is the tooltip.
final class SidebarView: FlippedView, NSTextFieldDelegate, NSViewToolTipOwner {
    weak var host: SidebarHost?
    private(set) var items: [SidebarItem] = []
    static let headerHeight: CGFloat = 44
    static let expandedRowHeight: CGFloat = 42
    static let collapsedRowHeight: CGFloat = 48
    private let inset: CGFloat = 8

    /// The narrow rail: icons instead of names.
    var collapsed = false {
        didSet {
            guard collapsed != oldValue else { return }
            if collapsed { endEditing(commit: true) }
            hoverIndex = nil
            needsDisplay = true
            updateToolTips()
        }
    }
    private var rowHeight: CGFloat { collapsed ? Self.collapsedRowHeight : Self.expandedRowHeight }

    private var hoverIndex: Int?
    private var pressIndex: Int?
    private var pressPoint: NSPoint = .zero
    private var dragIndex: Int?
    private var dropIndex: Int?
    private var editor: NSTextField?
    private var editingID: UUID?
    private var trackingArea: NSTrackingArea?

    static let palette: [(String, String?)] = [
        ("None", nil), ("Red", "#ff5f57"), ("Orange", "#ff9f0a"), ("Yellow", "#ffd60a"), ("Green", "#32d74b"),
        ("Teal", "#40c8e0"), ("Blue", "#0a84ff"), ("Purple", "#bf5af2"), ("Pink", "#ff375f"),
    ]

    var isEditing: Bool { editor != nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func reload() {
        guard let host else { return }
        let new = host.sidebarItems
        if new != items {
            items = new
            needsDisplay = true
            updateToolTips()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        updateToolTips()
    }

    /// In the rail every tile shows its workspace's name as a tooltip.
    private func updateToolTips() {
        removeAllToolTips()
        guard collapsed else { return }
        for i in items.indices { addToolTip(rowRect(i), owner: self, userData: nil) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        rowIndex(at: point).map { items[$0].name } ?? ""
    }

    // MARK: Geometry

    private func rowRect(_ i: Int) -> NSRect {
        NSRect(x: inset, y: Self.headerHeight + CGFloat(i) * rowHeight, width: bounds.width - inset * 2,
               height: rowHeight - 2)
    }

    private var plusRect: NSRect {
        collapsed ? NSRect(x: (bounds.width - 22) / 2, y: 12, width: 22, height: 22)
            : NSRect(x: bounds.width - 34, y: 12, width: 22, height: 22)
    }

    private func rowIndex(at pt: NSPoint) -> Int? {
        let i = Int(floor((pt.y - Self.headerHeight) / rowHeight))
        return (pt.y >= Self.headerHeight && items.indices.contains(i)) ? i : nil
    }

    private func insertionIndex(at pt: NSPoint) -> Int {
        let i = Int(((pt.y - Self.headerHeight) / rowHeight).rounded())
        return min(max(0, i), items.count)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        statusHits = []   // every row is drawn below; drawSubtitle collects the link spans again
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

        // while dragging, draw the order the drop would produce, the dragged row outlined in its new slot
        var order = Array(items.indices)
        var draggedSlot: Int?
        if let d = dragIndex, let drop = dropIndex {
            let target = drop > d ? drop - 1 : drop
            order.remove(at: d)
            order.insert(d, at: min(target, order.count))
            draggedSlot = order.firstIndex(of: d)
        }
        for (slot, i) in order.enumerated() {
            let r = rowRect(slot)
            if slot == draggedSlot {
                NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
                let outline = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
                outline.lineWidth = 1.5
                outline.stroke()
            }
            if collapsed {
                drawTile(items[i], in: r, hover: dragIndex == nil && hoverIndex == i)
            } else {
                drawRow(items[i], in: r, index: slot, hover: dragIndex == nil && hoverIndex == i)
            }
        }
    }

    private func drawRow(_ item: SidebarItem, in r: NSRect, index: Int, hover: Bool, dragging: Bool = false) {
        if item.selected && !dragging {
            NSColor(srgbRed: 0x3D / 255, green: 0x7B / 255, blue: 1, alpha: 0.30).setFill()
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
        let midY = item.hasSubtitle ? r.minY + 14 : r.midY
        if item.hasSubtitle, item.id != editingID { drawSubtitle(item, in: r) }
        // right side: agent dots, then the ⌘N hint
        var right = r.maxX - 8
        if index < 9 {
            let hint: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor(white: 1, alpha: item.selected ? 0.45 : 0.25),
            ]
            let s = "⌘\(index + 1)" as NSString
            let w = s.size(withAttributes: hint).width
            s.draw(at: NSPoint(x: right - w, y: midY - 7), withAttributes: hint)
            right -= w + 8
        }
        let a = item.agents
        if a.anyNeedsInput {
            right = drawDot(NSColor.systemOrange, right: right, midY: midY)
        } else if a.anyUnread {
            right = drawDot(NSColor.systemBlue, right: right, midY: midY)
        }
        if a.liveSessions > 0 {
            for _ in 0..<min(a.liveSessions, 5) {
                right = drawDot(NSColor(white: 1, alpha: 0.45), right: right, midY: midY, size: 5)
            }
        }
        if item.pinned {
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
        let x = r.minX + 16
        (item.name as NSString).draw(in: NSRect(x: x, y: midY - 8.5, width: max(0, right - x - 4), height: 18),
                                     withAttributes: attrs)
    }

    /// The rail's tile: the workspace icon on its colour, the selection behind it, the agent state as a dot.
    private func drawTile(_ item: SidebarItem, in r: NSRect, hover: Bool) {
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
        let a = item.agents
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

    static func drawIcon(_ icon: WorkspaceIcon, in tile: NSRect, selected: Bool) {
        let alpha: CGFloat = selected ? 0.95 : 0.8
        switch icon {
        case .symbol(let name):
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
                .applying(.init(paletteColors: [NSColor(white: 1, alpha: alpha)]))
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = img.size
                img.draw(in: NSRect(x: tile.midX - s.width / 2, y: tile.midY - s.height / 2, width: s.width, height: s.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {
                drawIcon(.text("?"), in: tile, selected: selected)
            }
        case .text(let t):
            let emoji = t.unicodeScalars.contains { $0.properties.isEmojiPresentation }
            let size: CGFloat = emoji ? 17 : (t.count > 1 ? 12.5 : 15)
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
        if let b = item.branch { add("\u{2387} " + (b.count > 22 ? b.prefix(10) + "…" + b.suffix(10) : b), dim) }
        let x = r.minX + 16
        let maxX = r.maxX - 8
        for st in item.status {
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
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        line.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: line.length))
        line.draw(in: NSRect(x: x, y: r.minY + 22, width: max(0, maxX - x), height: 15))
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
        (statusHit(at: pt) != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    /// Clickable status entries as drawn last: (rect, workspace, key).
    private(set) var statusHits: [(NSRect, UUID, String)] = []

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
        guard let i = rowIndex(at: pt) else { return }
        if event.clickCount == 2, !collapsed {
            beginRename(items[i].id)
            return
        }
        pressIndex = i
        pressPoint = pt
    }

    override func mouseDragged(with event: NSEvent) {
        guard let p = pressIndex else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if dragIndex == nil, hypot(pt.x - pressPoint.x, pt.y - pressPoint.y) > 4 { dragIndex = p }
        guard dragIndex != nil else { return }
        dropIndex = insertionIndex(at: pt)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressIndex = nil; dragIndex = nil; dropIndex = nil; needsDisplay = true }
        if let d = dragIndex, let drop = dropIndex {
            let target = drop > d ? drop - 1 : drop
            if target != d { host?.sidebarMove(items[d].id, to: target) }
            return
        }
        let pt = convert(event.locationInWindow, from: nil)
        if pressIndex != nil, !collapsed, let (id, key) = statusHit(at: pt) {
            host?.sidebarStatusClicked(id, key: key)
            return
        }
        if let p = pressIndex { host?.sidebarSelect(items[p].id) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let pt = convert(event.locationInWindow, from: nil)
        guard let i = rowIndex(at: pt) else { return nil }
        let item = items[i]
        let m = NSMenu()
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
        m.addItem(withTitle: item.pinned ? "Unpin" : "Pin", action: #selector(menuPin(_:)), keyEquivalent: "")
            .representedObject = item.id
        m.addItem(.separator())
        m.addItem(withTitle: "Close Workspace", action: #selector(menuClose(_:)), keyEquivalent: "")
            .representedObject = item.id
        for mi in m.items where mi.action != nil { mi.target = self }
        return m
    }

    static func swatch(_ c: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            c.setFill(); NSBezierPath(ovalIn: r).fill(); return true
        }
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
        endEditing(commit: false)
        let r = rowRect(i)
        let f = NSTextField(frame: NSRect(x: r.minX + 12, y: r.midY - 11, width: r.width - 50, height: 22))
        f.stringValue = items[i].name
        f.font = .systemFont(ofSize: 13)
        f.focusRingType = .none
        f.bezelStyle = .roundedBezel
        f.delegate = self
        f.target = self
        f.action = #selector(editorCommitted(_:))
        addSubview(f)
        editor = f
        editingID = id
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
        if commit { host?.sidebarRename(id, to: name) }
        needsDisplay = true
        host?.sidebarDidEndInteraction()
    }

    /// Debug: the text field used for an inline rename, if one is open.
    var renameField: NSTextField? { editor }
}

/// The sidebar card: a `SidebarView` filling the card.
final class SidebarCardView: CardHostView {
    let sidebar = SidebarView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        sidebar.frame = content.bounds
        sidebar.autoresizingMask = [.width, .height]
        content.addSubview(sidebar)
    }

    required init?(coder: NSCoder) { fatalError() }
}
