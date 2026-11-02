import AppKit

/// A terminal card: a slim tab strip over the surfaces of its tabs (only the selected one is visible).
/// The strip shows only when the card has more than one tab; a single tab gets the whole card.
final class TerminalCardView: CardHostView {
    let cardID: UUID
    let strip = TabStripView()
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
        strip.onItemsChanged = { [weak self] in self?.updateStripVisibility() }
        updateStripVisibility()
    }

    /// Whether the tab strip is shown: only with more than one tab.
    var stripVisible: Bool { !strip.isHidden }

    private func updateStripVisibility() {
        let show = strip.items.count > 1
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
    static let height: CGFloat = 28

    struct Item: Equatable {
        var id: UUID
        var title: String
        var agent: TabAgentState?
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
                x += 12
            }
            let showClose = selected || item.id == hoverID
            let titleWidth = r.maxX - x - (showClose ? 24 : 8)
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: selected ? .semibold : .regular),
                .foregroundColor: NSColor(white: 1, alpha: selected ? 0.92 : 0.6),
                .paragraphStyle: para,
            ]
            (item.title as NSString).draw(in: NSRect(x: x, y: r.midY - 7.5, width: max(0, titleWidth), height: 16),
                                          withAttributes: attrs)
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
