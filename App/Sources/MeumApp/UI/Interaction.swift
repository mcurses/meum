import AppKit
import MeumCore
import QuartzCore

// Mouse interaction on the card layout: resizing splits by dragging the gap between cards, and dragging tabs
// between strips and onto card edges. Both end in the same store mutations the API uses (`split.resize`,
// `tab.move`), so they produce the same events.

// MARK: - Dividers

/// The draggable strip in the gap between the two children of a split. The window passes clicks on fully
/// transparent pixels through to the app behind, so this view paints a 1% fill: only these strips catch the
/// mouse, the rest of the gaps stay click-through (unless `gapsCatchClicks`).
final class DividerView: NSView {
    /// A drag on a divider resizes cards, also where it crosses the title bar strip.
    override var mouseDownCanMoveWindow: Bool { false }
    let splitID: UUID
    var axis: SplitAxis { didSet { if axis != oldValue { window?.invalidateCursorRects(for: self) } } }
    var onDrag: ((DividerView, NSPoint) -> Void)?
    var onEnd: ((DividerView) -> Void)?
    var onReset: ((DividerView) -> Void)?
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private(set) var dragging = false { didSet { if dragging != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    init(splitID: UUID, axis: SplitAxis) {
        self.splitID = splitID
        self.axis = axis
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var cursor: NSCursor { axis == .horizontal ? .resizeLeftRight : .resizeUpDown }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.01).setFill()
        bounds.fill()
        guard hovering || dragging else { return }
        // a short grip line in the middle of the gap
        let len: CGFloat = 36, w: CGFloat = 3
        let r = axis == .horizontal
            ? NSRect(x: bounds.midX - w / 2, y: bounds.midY - len / 2, width: w, height: len)
            : NSRect(x: bounds.midX - len / 2, y: bounds.midY - w / 2, width: len, height: w)
        NSColor(white: 1, alpha: dragging ? 0.75 : 0.45).setFill()
        NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
        super.updateTrackingAreas()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }
    override func mouseEntered(with event: NSEvent) { hovering = true; cursor.set() }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        if !dragging { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset?(self); return }
        dragging = true
        cursor.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        cursor.set()
        onDrag?(self, event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onEnd?(self)
        if !NSPointInRect(convert(event.locationInWindow, from: nil), bounds) { NSCursor.arrow.set(); hovering = false }
    }
}

// MARK: - Drop feedback

/// Draws the drop target of a tab drag over the cards: a tinted half of a card for an edge split, an outline
/// for "into this card", a caret in a tab strip. Never takes the mouse.
final class DropOverlayView: NSView {
    private let zone = CALayer()
    private let caret = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let accent = NSColor.controlAccentColor
        zone.backgroundColor = accent.withAlphaComponent(0.22).cgColor
        zone.borderColor = accent.withAlphaComponent(0.9).cgColor
        zone.borderWidth = 2
        zone.cornerRadius = 10
        zone.cornerCurve = .continuous
        zone.isHidden = true
        caret.backgroundColor = accent.cgColor
        caret.cornerRadius = 1.5
        caret.isHidden = true
        layer?.addSublayer(zone)
        layer?.addSublayer(caret)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(zone r: NSRect?, caret c: NSRect?) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        // appear in place; move and resize animated
        if let r {
            if zone.isHidden { CATransaction.setDisableActions(true) }
            zone.frame = r
            zone.isHidden = false
        } else {
            zone.isHidden = true
        }
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let c { caret.frame = c; caret.isHidden = false } else { caret.isHidden = true }
        CATransaction.commit()
    }

    func hide() { show(zone: nil, caret: nil) }
}

/// The pill that follows the mouse while a tab is dragged.
final class TabGhostView: NSView {
    let title: String
    init(title: String) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor(white: 0.18, alpha: 0.92).cgColor
        layer?.borderColor = NSColor(white: 1, alpha: 0.25).cgColor
        layer?.borderWidth = 1
        let w = min(220, (title as NSString).size(withAttributes: [.font: Self.font]).width + 24)
        frame.size.width = max(70, w)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    static let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)

    override func draw(_ dirtyRect: NSRect) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: bounds.insetBy(dx: 12, dy: 4.5),
                                 withAttributes: [.font: Self.font, .foregroundColor: NSColor(white: 1, alpha: 0.92),
                                                  .paragraphStyle: para])
    }
}

/// Where a dragged tab would land.
enum DropTarget: Equatable {
    /// Into `card`'s strip at gap index `gap` (0…tabs.count, counted with the dragged tab still in place).
    case strip(card: UUID, gap: Int)
    /// Into `card`, at the end (dropped on its body, away from the edges).
    case into(card: UUID)
    /// Split `card`, the tab's new card on `side`.
    case split(card: UUID, side: Direction)
}

struct TabDrag {
    let tab: UUID
    let sourceCard: UUID
    let ghost: TabGhostView
    var target: DropTarget?
    /// Watches for Escape, which cancels the drag.
    var keyMonitor: Any?
}

extension WorkspaceController {
    // MARK: dividers

    /// One divider view per split of the shown workspace, over the gap strips. Hit area: at least 8 pt.
    func layoutDividers(_ targets: [Slot: NSRect]) {
        let ws = layoutWorkspace(selectedWorkspace)
        let area = targets[.area] ?? root.bounds
        let dividers = ws?.dividers(in: area, gap: gap) ?? []
        let wanted = Set(dividers.map(\.splitID))
        for (id, v) in dividerViews where !wanted.contains(id) {
            v.removeFromSuperview()
            dividerViews[id] = nil
        }
        for d in dividers {
            let v: DividerView
            if let existing = dividerViews[d.splitID] {
                v = existing
                v.axis = d.axis
            } else {
                v = DividerView(splitID: d.splitID, axis: d.axis)
                v.onDrag = { [weak self] v, p in self?.dividerDragged(v, to: p) }
                v.onEnd = { [weak self] v in self?.dividerDragEnded(v) }
                v.onReset = { [weak self] v in self?.setRatio(split: v.splitID, ratio: 0.5) }
                dividerViews[d.splitID] = v
                root.addSubview(v, positioned: .below, relativeTo: dropOverlay)
            }
            let minHit: CGFloat = 8
            var r = d.rect
            if d.axis == .horizontal, r.width < minHit { r = r.insetBy(dx: (r.width - minHit) / 2, dy: 0) }
            if d.axis == .vertical, r.height < minHit { r = r.insetBy(dx: 0, dy: (r.height - minHit) / 2) }
            if v.frame != r { v.frame = r; v.needsDisplay = true }
        }
    }

    /// Mouse-move during a divider drag: re-lay out the cards at once (no animation). Surfaces get their new
    /// size at most every `surfaceResizeInterval`, and once more at the end, so the pty and the program in it
    /// do not reflow on every frame.
    func dividerDragged(_ v: DividerView, to windowPoint: NSPoint) {
        guard let ws = layoutWorkspace(selectedWorkspace) else { return }
        let p = root.convert(windowPoint, from: nil)
        let pos = v.axis == .horizontal ? p.x : p.y
        guard let r = ws.ratio(forSplit: v.splitID, dividerAt: pos, in: terminalArea, gap: gap,
                               minCard: Self.minCardSize) else { return }
        if liveRatios[v.splitID] == r { return }
        liveRatios[v.splitID] = r
        let t0 = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyLiveLayout()
        CATransaction.commit()
        let now = CACurrentMediaTime()
        if now - lastSurfaceResize >= Self.surfaceResizeInterval {
            lastSurfaceResize = now
            for c in cardViews.values { c.commitSurfaceSizes() }
            Log.debug("divider: layout+surfaces \(String(format: "%.2f", (CACurrentMediaTime() - t0) * 1000)) ms")
        }
    }

    func dividerDragEnded(_ v: DividerView) {
        guard let r = liveRatios[v.splitID] else { return }
        liveRatios = [:]
        lastSurfaceResize = 0
        // one store mutation for the whole drag: one save, one split.resized event
        store.mutate(.structure(animate: false)) { $0.setRatio(split: v.splitID, ratio: r) }
        for c in cardViews.values { c.commitSurfaceSizes() }
        focusTerminal()
    }

    /// Places cards and dividers for the current (live) model without animation and without touching surfaces.
    private func applyLiveLayout() {
        let targets = targetFrames(for: selectedWorkspace)
        for (id, v) in cardViews {
            if let r = targets[.card(id)] { placeCard(v, r) }
        }
        layoutDividers(targets)
    }

    // MARK: tab drag

    func tabDragBegan(_ tab: UUID, from card: UUID, at windowPoint: NSPoint) {
        guard let ws = selectedWorkspace, let t = ws.tab(tab) else { return }
        let ghost = TabGhostView(title: Self.title(for: t))
        ghost.alphaValue = 0.95
        root.addSubview(ghost, positioned: .above, relativeTo: dropOverlay)
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53, let self, self.tabDrag != nil else { return e }   // 53: Escape
            self.cancelTabDrag()
            return nil
        }
        tabDrag = TabDrag(tab: tab, sourceCard: card, ghost: ghost, target: nil, keyMonitor: monitor)
        tabDragMoved(windowPoint)
    }

    /// Drops the drag without moving anything (Escape). The strip's later mouse events find no drag and do nothing.
    func cancelTabDrag() {
        guard let drag = tabDrag else { return }
        endTabDrag(drag)
    }

    private func endTabDrag(_ drag: TabDrag) {
        tabDrag = nil
        if let m = drag.keyMonitor { NSEvent.removeMonitor(m) }
        drag.ghost.removeFromSuperview()
        dropOverlay.hide()
        NSCursor.arrow.set()
    }

    func tabDragMoved(_ windowPoint: NSPoint) {
        guard var drag = tabDrag else { return }
        let p = root.convert(windowPoint, from: nil)
        drag.ghost.frame.origin = NSPoint(x: p.x + 12, y: p.y + 14)   // below-right, the caret stays visible
        let (target, zone, caret) = dropTarget(at: p, dragging: drag.tab, from: drag.sourceCard)
        drag.target = target
        tabDrag = drag
        dropOverlay.show(zone: zone, caret: caret)
        (target == nil ? NSCursor.arrow : NSCursor.closedHand).set()
    }

    func tabDragEnded(_ windowPoint: NSPoint) {
        tabDragMoved(windowPoint)
        guard let drag = tabDrag else { return }
        endTabDrag(drag)
        guard let target = drag.target else { return }
        perform(drop: target, tab: drag.tab, from: drag.sourceCard)
    }

    func perform(drop target: DropTarget, tab: UUID, from source: UUID) {
        switch target {
        case .strip(let card, let gap):
            var index = gap
            // the gap index counts the dragged tab where it is; its final position in its own card is one less
            if card == source, let i = selectedWorkspace?.card(card)?.tabs.firstIndex(where: { $0.id == tab }), gap > i {
                index -= 1
            }
            moveTab(tab, toCard: card, index: index)
        case .into(let card):
            moveTab(tab, toCard: card, index: nil)
        case .split(let card, let side):
            moveTab(tab, splitting: card, side: side)
        }
    }

    /// The drop target under `p` (root coordinates) and its feedback: a zone rect and/or a caret rect.
    func dropTarget(at p: NSPoint, dragging tab: UUID, from source: UUID) -> (DropTarget?, NSRect?, NSRect?) {
        guard let ws = selectedWorkspace else { return (nil, nil, nil) }
        for card in ws.cards {
            guard let v = cardViews[card.id], v.frame.contains(p) else { continue }
            let f = v.frame
            let onlyTabOfSource = card.id == source && card.tabs.count == 1
            // the strip: insert at a position (a one-tab card shows no strip: its whole card is body)
            let stripH = v.stripVisible ? TabStripView.height : 0
            if p.y < f.minY + stripH {
                if onlyTabOfSource { return (nil, nil, nil) }
                let local = v.strip.convert(p, from: root)
                let gap = v.strip.insertionIndex(atX: local.x)
                let x = v.strip.convert(NSPoint(x: v.strip.caretX(forIndex: gap), y: 0), to: root).x
                let caret = NSRect(x: x - 1.5, y: f.minY + 5, width: 3, height: TabStripView.height - 10)
                return (.strip(card: card.id, gap: gap), nil, caret)
            }
            // the body: an edge zone splits, the middle joins the card
            let body = NSRect(x: f.minX, y: f.minY + stripH, width: f.width, height: f.height - stripH)
            let dx = (p.x - body.minX) / max(1, body.width), dy = (p.y - body.minY) / max(1, body.height)
            let edges: [(Direction, CGFloat)] = [(.left, dx), (.right, 1 - dx), (.up, dy), (.down, 1 - dy)]
            let nearest = edges.min { $0.1 < $1.1 }!
            let inset: CGFloat = 4
            if nearest.1 < 0.28, !onlyTabOfSource {
                let half: NSRect
                switch nearest.0 {
                case .left: half = NSRect(x: f.minX, y: f.minY, width: f.width / 2, height: f.height)
                case .right: half = NSRect(x: f.midX, y: f.minY, width: f.width / 2, height: f.height)
                case .up: half = NSRect(x: f.minX, y: f.minY, width: f.width, height: f.height / 2)
                case .down: half = NSRect(x: f.minX, y: f.midY, width: f.width, height: f.height / 2)
                }
                return (.split(card: card.id, side: nearest.0), half.insetBy(dx: inset, dy: inset), nil)
            }
            if card.id == source { return (nil, nil, nil) }   // already there
            return (.into(card: card.id), f.insetBy(dx: inset, dy: inset), nil)
        }
        return (nil, nil, nil)
    }
}
