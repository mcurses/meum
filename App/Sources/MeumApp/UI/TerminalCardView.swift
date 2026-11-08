import AppKit

/// A terminal card: a slim tab strip over the surfaces of its tabs (only the selected one is visible).
/// The strip shows only when the card has more than one tab; a single tab gets the whole card.
final class TerminalCardView: CardHostView {
    let cardID: UUID
    let strip = TabStripView()
    /// Shown instead of the strip on a one-tab card, so its tab can still be dragged elsewhere.
    let grabHandle = GrabHandleView()
    let surfaceArea = FlippedView()
    private(set) var surfaces: [UUID: SurfaceView] = [:]
    /// Widget tabs: the widget's view instead of a surface (`WidgetManager` owns the widget).
    private(set) var widgetViews: [UUID: NSView] = [:]
    private(set) var selectedTabID: UUID?

    init(cardID: UUID) {
        self.cardID = cardID
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        strip.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: TabStripView.height)
        strip.autoresizingMask = [.width]
        surfaceArea.frame = NSRect(x: 0, y: TabStripView.height, width: content.bounds.width,
                                   height: max(0, content.bounds.height - TabStripView.height))
        surfaceArea.autoresizingMask = [.width, .height]
        surfaceArea.wantsLayer = true
        content.addSubview(surfaceArea)
        content.addSubview(strip)
        grabHandle.frame = NSRect(x: (content.bounds.width - GrabHandleView.size.width) / 2, y: 0,
                                  width: GrabHandleView.size.width, height: GrabHandleView.size.height)
        grabHandle.autoresizingMask = [.minXMargin, .maxXMargin]
        grabHandle.tab = { [weak self] in self?.selectedTabID }
        content.addSubview(grabHandle)
        strip.onItemsChanged = { [weak self] in self?.updateStripVisibility() }
        updateStripVisibility()
    }

    /// Whether the tab strip is shown: only with more than one tab.
    var stripVisible: Bool { !strip.isHidden }

    private func updateStripVisibility() {
        let show = strip.items.count > 1
        grabHandle.isHidden = show
        guard strip.isHidden == show else { return }
        strip.isHidden = !show
        let top = show ? TabStripView.height : 0
        surfaceArea.frame = NSRect(x: 0, y: top, width: content.bounds.width,
                                   height: max(0, content.bounds.height - top))
        // a surface pushes its new size to the pty itself unless a layout animation is running; the
        // animation's end commits the final sizes
        for s in surfaces.values where s.frame != surfaceArea.bounds { s.frame = surfaceArea.bounds }
        for v in widgetViews.values { v.frame = surfaceArea.bounds }
    }

    required init?(coder: NSCoder) { fatalError() }

    func surface(for tab: UUID) -> SurfaceView? { surfaces[tab] }
    var selectedSurface: SurfaceView? { selectedTabID.flatMap { surfaces[$0] } }

    func add(_ surface: SurfaceView, for tab: UUID) {
        surfaces[tab] = surface
        surface.frame = surfaceArea.bounds
        surfaceArea.addSubview(surface)
    }

    /// Detaches and returns the surface of a tab (the caller frees it).
    func remove(tab: UUID) -> SurfaceView? {
        guard let s = surfaces.removeValue(forKey: tab) else { return nil }
        s.removeFromSuperview()
        return s
    }

    func select(_ tab: UUID) {
        selectedTabID = tab
        for (id, s) in surfaces { s.setVisible(id == tab) }
        for (id, v) in widgetViews { v.isHidden = id != tab }
    }

    func widgetView(for tab: UUID) -> NSView? { widgetViews[tab] }

    func addWidget(_ view: NSView, for tab: UUID) {
        widgetViews[tab] = view
        view.frame = surfaceArea.bounds
        view.autoresizingMask = [.width, .height]
        view.isHidden = tab != selectedTabID
        surfaceArea.addSubview(view)
    }

    /// Detaches a widget tab's view (it may be added to another card).
    @discardableResult
    func removeWidget(tab: UUID) -> NSView? {
        guard let v = widgetViews.removeValue(forKey: tab) else { return nil }
        if v.superview === surfaceArea { v.removeFromSuperview() }
        return v
    }

    /// Mid-animation, surfaces keep their size (no pty resize per frame); at the end they get the final one.
    func setLiveResize(_ live: Bool) {
        for s in surfaces.values { s.liveResize = live }
    }

    func commitSurfaceSizes() {
        for s in surfaces.values {
            s.liveResize = true
            if s.frame != surfaceArea.bounds { s.frame = surfaceArea.bounds } else { s.pushSize() }
        }
    }
}

/// Tab strip: one segment per tab (agent dot, title, close button) and a "+" at the end. Drawn, not built
/// from subviews, so a relayout is one `needsDisplay`.
final class TabStripView: NSView {
    /// Not a title bar: a drag here is meum's own (a tab, a card, a selection), never a window move (see CardHostView).
    override var mouseDownCanMoveWindow: Bool { false }
    static let height: CGFloat = 28

    struct Item: Equatable {
        var id: UUID
        var title: String
        /// The Claude Code session's name, drawn dimmer before the title (unless it has labels).
        var name: String? = nil
        /// Labels the session attached to itself, drawn as chips before the title.
        var labels: [String] = []
        var agent: TabAgentState?
        /// claude runs in the tab but no hook reached meum: a hollow dot instead of none
        var silent: Bool = false
    }

    var items: [Item] = [] {
        didSet {
            guard items != oldValue else { return }
            needsDisplay = true
            if items.count != oldValue.count { onItemsChanged?() }
        }
    }
    /// Called when the number of tabs changes (the card shows or hides the strip).
    var onItemsChanged: (() -> Void)?
    var selectedID: UUID? { didSet { if selectedID != oldValue { needsDisplay = true } } }
    var focused = false { didSet { if focused != oldValue { needsDisplay = true } } }
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onNew: (() -> Void)?
    var onActivate: (() -> Void)?
    private var hoverID: UUID?
    private var trackingArea: NSTrackingArea?
    private let tips = DrawnToolTips()

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private let plusWidth: CGFloat = 28
    private let pad: CGFloat = 6

    private func segmentFrames() -> [(Item, NSRect)] {
        guard !items.isEmpty else { return [] }
        let avail = bounds.width - plusWidth - pad * 2
        let w = max(60, min(200, avail / CGFloat(items.count)))
        return items.enumerated().map { i, item in
            (item, NSRect(x: pad + CGFloat(i) * w, y: 4, width: w - 4, height: bounds.height - 7))
        }
    }

    private var plusRect: NSRect {
        let last = segmentFrames().last?.1.maxX ?? pad
        return NSRect(x: min(last + 4, bounds.width - plusWidth), y: 4, width: 22, height: bounds.height - 7)
    }

    private func closeRect(in seg: NSRect) -> NSRect {
        NSRect(x: seg.maxX - 20, y: seg.midY - 8, width: 16, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        // a hairline under the strip
        NSColor(white: 1, alpha: 0.06).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        var tipRects: [(NSRect, String)] = []
        defer { tips.apply(tipRects, to: self) }
        for (item, r) in segmentFrames() {
            let selected = item.id == selectedID
            if selected {
                NSColor(white: 1, alpha: focused ? 0.16 : 0.09).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            } else if item.id == hoverID {
                NSColor(white: 1, alpha: 0.05).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            }
            var x = r.minX + 8
            if let agent = item.agent {
                let dot = NSRect(x: x, y: r.midY - 3.5, width: 7, height: 7)
                Self.color(for: agent).setFill()
                NSBezierPath(ovalIn: dot).fill()
                tipRects.append((dot.insetBy(dx: -3, dy: -4), AgentLegend.tab(agent)))
                x += 12
            } else if item.silent {
                let dot = NSRect(x: x + 0.5, y: r.midY - 3, width: 6, height: 6)
                let ring = NSBezierPath(ovalIn: dot)
                ring.lineWidth = 1.2
                NSColor(white: 1, alpha: 0.45).setStroke()
                ring.stroke()
                tipRects.append((dot.insetBy(dx: -3, dy: -4), AgentLegend.silent))
                x += 12
            }
            let showClose = selected || item.id == hoverID
            for l in item.labels where x < r.maxX - 60 {
                let w = LabelChip.draw(l, x: x, midY: r.midY, strong: selected)
                tipRects.append((NSRect(x: x, y: r.midY - 7, width: w, height: 14), AgentLegend.tabLabel))
                x += w + 4
            }
            let titleWidth = r.maxX - x - (showClose ? 24 : 8)
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: selected ? .semibold : .regular),
                .foregroundColor: NSColor(white: 1, alpha: selected ? 0.92 : 0.6),
                .paragraphStyle: para,
            ]
            let text = NSMutableAttributedString()
            if item.labels.isEmpty, let name = item.name, !name.isEmpty {
                var dim = attrs
                dim[.font] = NSFont.systemFont(ofSize: 11.5, weight: .medium)
                dim[.foregroundColor] = NSColor(white: 1, alpha: selected ? 0.55 : 0.38)
                text.append(NSAttributedString(string: name + "  ", attributes: dim))
            }
            text.append(NSAttributedString(string: item.title, attributes: attrs))
            text.draw(in: NSRect(x: x, y: r.midY - 7.5, width: max(0, titleWidth), height: 16))
            if showClose {
                let c = closeRect(in: r)
                let p = NSBezierPath()
                let inset = c.insetBy(dx: 4.5, dy: 4.5)
                p.move(to: NSPoint(x: inset.minX, y: inset.minY)); p.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
                p.move(to: NSPoint(x: inset.maxX, y: inset.minY)); p.line(to: NSPoint(x: inset.minX, y: inset.maxY))
                p.lineWidth = 1.3
                NSColor(white: 1, alpha: 0.55).setStroke()
                p.stroke()
            }
        }
        let pr = plusRect
        let p = NSBezierPath()
        p.move(to: NSPoint(x: pr.midX - 4.5, y: pr.midY)); p.line(to: NSPoint(x: pr.midX + 4.5, y: pr.midY))
        p.move(to: NSPoint(x: pr.midX, y: pr.midY - 4.5)); p.line(to: NSPoint(x: pr.midX, y: pr.midY + 4.5))
        p.lineWidth = 1.4
        NSColor(white: 1, alpha: 0.5).setStroke()
        p.stroke()
    }

    static func color(for s: TabAgentState) -> NSColor {
        switch s.phase {
        case .needsInput: return NSColor.systemOrange
        case .running: return NSColor.systemGreen
        case .idle: return s.unread ? NSColor.systemBlue : NSColor(white: 1, alpha: 0.35)
        }
    }

    /// Where a dragged tab would go if dropped at `x`: the gap index 0…items.count among the current segments.
    func insertionIndex(atX x: CGFloat) -> Int {
        let segs = segmentFrames()
        for (i, (_, r)) in segs.enumerated() where x < r.midX { return i }
        return segs.count
    }

    /// The x of the insertion caret for a gap index, in this view's coordinates.
    func caretX(forIndex i: Int) -> CGFloat {
        let segs = segmentFrames()
        guard !segs.isEmpty else { return pad }
        if i < segs.count { return segs[i].1.minX - 2 }
        return segs[segs.count - 1].1.maxX + 2
    }

    func segmentRect(for id: UUID) -> NSRect? { segmentFrames().first { $0.0.id == id }?.1 }

    // Dragging a tab: mouse-down on a segment, then a move past a small threshold starts the drag; the
    // controller tracks the drop target (this view keeps receiving the dragged events wherever the mouse goes).
    var onDragBegan: ((UUID, NSPoint) -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?
    private var pressedTab: UUID?
    private var pressPoint: NSPoint = .zero
    private(set) var dragging = false

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        pressedTab = nil
        dragging = false
        onActivate?()
        if plusRect.contains(pt) { onNew?(); return }
        for (item, r) in segmentFrames() where r.contains(pt) {
            if (item.id == selectedID || item.id == hoverID), closeRect(in: r).contains(pt) {
                onClose?(item.id)
            } else {
                onSelect?(item.id)
                pressedTab = item.id
                pressPoint = event.locationInWindow
            }
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let tab = pressedTab else { return }
        let p = event.locationInWindow
        if !dragging {
            guard hypot(p.x - pressPoint.x, p.y - pressPoint.y) >= 4 else { return }
            dragging = true
            onDragBegan?(tab, p)
        }
        onDragMoved?(p)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressedTab = nil; dragging = false }
        guard dragging else { return }
        onDragEnded?(event.locationInWindow)
    }

    override func otherMouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        for (item, r) in segmentFrames() where r.contains(pt) { onClose?(item.id); return }
    }

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
        let h = segmentFrames().first { $0.1.contains(pt) }?.0.id
        if h != hoverID { hoverID = h; needsDisplay = true }
        NSCursor.arrow.set()
    }

    override func mouseExited(with event: NSEvent) {
        if hoverID != nil { hoverID = nil; needsDisplay = true }
    }
}

/// A small grip at the top centre of a card without a tab strip: dragging it drags the card's tab, as dragging the
/// tab in a strip would (into another card, or onto a card's edge to split it; Escape cancels). It sits in the
/// terminal's top padding, faint until the pointer is over it.
final class GrabHandleView: NSView {
    /// Not a title bar: a drag here is meum's own (a tab, a card, a selection), never a window move (see CardHostView).
    override var mouseDownCanMoveWindow: Bool { false }
    static let size = NSSize(width: 56, height: 10)
    /// The session's labels, drawn as chips right of the handle (a one-tab card has no strip to show them).
    var labels: [String] = [] {
        didSet {
            guard labels != oldValue, let sv = superview else { return }
            // stays centred on the handle: as wide again on the left as the chips take on the right
            let extra = labels.isEmpty ? 0 : labels.reduce(4) { $0 + LabelChip.width($1) + 4 }
            let w = Self.size.width + 2 * extra
            frame = NSRect(x: (sv.bounds.width - w) / 2, y: 0, width: w, height: labels.isEmpty ? Self.size.height : 16)
            needsDisplay = true
        }
    }
    /// The tab a drag moves (the card's selected tab).
    var tab: () -> UUID? = { nil }
    var onDragBegan: ((UUID, NSPoint) -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?
    private var hover = false { didSet { if hover != oldValue { needsDisplay = true } } }
    private var pressPoint: NSPoint?
    private var dragging: UUID?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSRect(x: (bounds.width - 36) / 2, y: 3, width: 36, height: 4)
        NSColor(white: 1, alpha: hover || dragging != nil ? 0.55 : 0.18).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 2, yRadius: 2).fill()
        var x = pill.maxX + 14
        for l in labels { x += LabelChip.draw(l, x: x, midY: 8, strong: false) + 4 }
    }

    /// The handle's tooltip: the session's name, and what the chips are.
    func setToolTip(name: String?) {
        let parts = [name, labels.isEmpty ? nil : AgentLegend.tabLabel + ": " + labels.joined(separator: ", ")]
        let t = parts.compactMap { $0 }.joined(separator: "\n")
        toolTip = t.isEmpty ? nil : t
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        trackingArea = a
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }

    override func mouseDown(with event: NSEvent) {
        pressPoint = event.locationInWindow
        dragging = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressPoint else { return }
        let p = event.locationInWindow
        if dragging == nil {
            guard hypot(p.x - start.x, p.y - start.y) >= 4, let t = tab() else { return }
            dragging = t
            onDragBegan?(t, p)
        }
        onDragMoved?(p)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressPoint = nil; dragging = nil; needsDisplay = true }
        guard dragging != nil else { return }
        onDragEnded?(event.locationInWindow)
    }
}

/// A small rounded label ("maintainer") as tabs, the grab handle and the sidebar draw it.
enum LabelChip {
    static let font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)

    static func width(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 10
    }

    /// Draws the chip with its left edge at `x`, centred on `midY`; returns its width.
    @discardableResult
    static func draw(_ text: String, x: CGFloat, midY: CGFloat, strong: Bool) -> CGFloat {
        let w = width(text)
        let r = NSRect(x: x, y: midY - 7, width: w, height: 14)
        NSColor(white: 1, alpha: strong ? 0.16 : 0.10).setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 1, alpha: strong ? 0.85 : 0.65)]
        (text as NSString).draw(at: NSPoint(x: x + 5, y: midY - 6.5), withAttributes: attrs)
        return w
    }
}

/// Tooltips for things a view draws itself (dots, chips, names): collected while drawing as (rect, text) and
/// registered again only when they change.
final class DrawnToolTips {
    private var tips: [(NSRect, String)] = []
    /// The owners AppKit shows (an owner without `view(_:stringForToolTip:…)` shows its description); kept alive here.
    private var owners: [NSString] = []

    func apply(_ new: [(NSRect, String)], to view: NSView) {
        guard new.count != tips.count || zip(new, tips).contains(where: { $0.0 != $1.0 || $0.1 != $1.1 }) else { return }
        tips = new
        view.removeAllToolTips()
        owners = new.map { $0.1 as NSString }
        for (i, t) in new.enumerated() { view.addToolTip(t.0, owner: owners[i], userData: nil) }
    }
}

/// What the agent dots and label chips mean, in words, for their tooltips.
enum AgentLegend {
    static func tab(_ s: TabAgentState) -> String {
        switch s.phase {
        case .needsInput: return "Claude is waiting for you"
        case .running: return "Claude is working"
        case .idle: return s.unread ? "Claude finished; not read yet" : "Claude is idle"
        }
    }

    /// The sidebar's dots: one per live session; orange waits for you, blue finished unread, green working, grey idle.
    static func workspace(_ a: WorkspaceAgentSummary) -> String {
        guard a.liveSessions > 0 else { return "" }
        let working = min(a.running, max(0, a.liveSessions - a.needsInput - a.unread))
        let rest = max(0, a.liveSessions - a.needsInput - a.unread - working)
        var parts: [String] = []
        if a.needsInput > 0 { parts.append("\(a.needsInput) waiting for you (orange)") }
        if a.unread > 0 { parts.append("\(a.unread) finished, not read yet (blue)") }
        if working > 0 { parts.append("\(working) working (green)") }
        if rest > 0 { parts.append("\(rest) idle (grey)") }
        return "Claude sessions: " + parts.joined(separator: ", ")
    }

    static let tabLabel = "A label the Claude session in this tab set on itself"
    static let silent = "Claude runs here, but meum hears nothing from it, so there's no dot: its Claude hooks aren't "
        + "installed for this profile, or it started before they were. Settings ▸ Claude hooks; then restart this Claude."
    static let workspaceLabel = "A label of this workspace, set by a Claude session in it"
}
