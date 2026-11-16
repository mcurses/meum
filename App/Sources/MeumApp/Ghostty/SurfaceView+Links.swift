// Links in a terminal surface: the grid geometry that maps a point to a cell, the hover line, the ⇧⌘-click and
// right-click on a link, and the keyboard hints (Terminal ▸ Open Link…). ⌘-click itself is ghostty's: it
// underlines the link and sends OPEN_URL, which lands in `openLinkFromGhostty`.

import AppKit
import GhosttyKit
import MeumControl

/// What a surface asks about links; the workspace controller answers (it knows the tab's folders and the apps).
@MainActor protocol SurfaceLinkHost: AnyObject {
    func linkTarget(_ raw: String, tab: UUID) -> TerminalLinks.Target?
    func perform(_ t: TerminalLinks.Target, tab: UUID, alternate: Bool)
    func linkActionTitle(_ t: TerminalLinks.Target, alternate: Bool) -> String
    func linkMenu(_ t: TerminalLinks.Target, tab: UUID) -> NSMenu
}

extension SurfaceView {
    // MARK: - Grid

    struct Grid {
        let columns: Int, rows: Int
        let cellWidth: CGFloat, cellHeight: CGFloat
        /// The first cell's top-left corner, in the view's (flipped) points.
        let origin: NSPoint

        func cell(at p: NSPoint) -> (row: Int, column: Int)? {
            let c = Int(floor((p.x - origin.x) / cellWidth)), r = Int(floor((p.y - origin.y) / cellHeight))
            guard c >= 0, c < columns, r >= 0, r < rows else { return nil }
            return (r, c)
        }

        func rect(row: Int, column: Int, cells: Int = 1) -> NSRect {
            NSRect(x: origin.x + CGFloat(column) * cellWidth, y: origin.y + CGFloat(row) * cellHeight,
                   width: CGFloat(cells) * cellWidth, height: cellHeight)
        }

        /// One rect per row a link covers.
        func rects(_ p: TerminalLinks.Placed) -> [NSRect] {
            (p.row...p.endRow).map { r in
                let from = r == p.row ? p.column : 0
                let to = r == p.endRow ? p.endColumn : columns - 1
                return rect(row: r, column: from, cells: to - from + 1)
            }
        }
    }

    /// Where the cells are. ghostty centres the grid (window-padding-balance) and caps the top padding at the
    /// horizontal padding plus half a cell; the explicit padding is 8 points (GhosttyApp's config).
    var grid: Grid? {
        guard let surface, let window else { return nil }
        let s = ghostty_surface_size(surface)
        guard s.columns > 0, s.rows > 0, s.cell_width_px > 0, s.cell_height_px > 0 else { return nil }
        let scale = window.backingScaleFactor
        let cw = CGFloat(s.cell_width_px), ch = CGFloat(s.cell_height_px)
        let left = (CGFloat(s.width_px) - CGFloat(s.columns) * cw) / 2
        let top = min((CGFloat(s.height_px) - CGFloat(s.rows) * ch) / 2, 8 * scale + cw / 2)
        return Grid(columns: Int(s.columns), rows: Int(s.rows), cellWidth: cw / scale, cellHeight: ch / scale,
                    origin: NSPoint(x: left / scale, y: top / scale))
    }

    /// The viewport's rows as text, one string per row.
    func viewportRows(_ g: Grid) -> [String] {
        guard let surface else { return [] }
        return (0..<g.rows).map { r in
            var sel = ghostty_selection_s()
            sel.top_left = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(r))
            sel.bottom_right = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                               x: UInt32(g.columns - 1), y: UInt32(r))
            sel.rectangle = false
            var t = ghostty_text_s()
            guard ghostty_surface_read_text(surface, sel, &t) else { return "" }
            defer { ghostty_surface_free_text(surface, &t) }
            guard let ptr = t.text, t.text_len > 0 else { return "" }
            return String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(t.text_len)), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: "")
        }
    }

    /// The link under `p` that resolves to something, with where it sits.
    func link(at p: NSPoint) -> (TerminalLinks.Placed, TerminalLinks.Target)? {
        guard let g = grid, let cell = g.cell(at: p), let host = linkHost else { return nil }
        let rows = viewportRows(g)
        guard let placed = TerminalLinks.link(at: cell.row, column: cell.column, rows: rows, columns: g.columns),
              let t = host.linkTarget(placed.text, tab: tabID) else { return nil }
        return (placed, t)
    }

    /// A program that takes the mouse (vim, htop with mouse mode) gets clicks as they are.
    var mouseCaptured: Bool { surface.map { ghostty_surface_mouse_captured($0) } ?? false }

    static func linkMods(_ flags: NSEvent.ModifierFlags) -> (cmd: Bool, alternate: Bool)? {
        let f = flags.intersection([.command, .shift, .option, .control])
        if f == .command { return (true, false) }
        if f == [.command, .shift] { return (true, true) }
        return nil
    }

    // MARK: - ⌘-click (ghostty) and ⇧⌘-click (here)

    /// The target of ghostty's link text. ghostty's path pattern can run on into the next word ("./scripts/ and"):
    /// when its text does not resolve, the link meum finds under the mouse counts.
    func ghosttyLinkTarget(_ raw: String) -> (text: String, target: TerminalLinks.Target)? {
        guard let host = linkHost else { return nil }
        // the whole text, then without its last words
        var words = raw.split(separator: " ", omittingEmptySubsequences: false)
        while !words.isEmpty {
            let text = words.joined(separator: " ")
            if let t = host.linkTarget(text, tab: tabID) { return (text, t) }
            words.removeLast()
        }
        guard let p = lastReportedMousePoint, p.x >= 0, let (placed, t) = link(at: p), raw.contains(placed.text) else { return nil }
        return (placed.text, t)
    }

    func openLinkFromGhostty(_ raw: String) {
        guard let host = linkHost, let (_, t) = ghosttyLinkTarget(raw) else {
            Log.info("link not opened (no such file or an unsupported scheme): \(raw.prefix(200))")
            NSSound.beep()
            return
        }
        hideLinkHover()
        host.perform(t, tab: tabID, alternate: false)
    }

    /// Whether meum, not ghostty, finds the link under the mouse for these modifiers: always with ⇧⌘ (ghostty
    /// knows only ⌘), and with ⌘ too while a program has the mouse (Claude Code, vim): ghostty then leaves links
    /// to the program, which gets the click and opens the link its own way or not at all.
    func meumFindsLinks(_ mods: (cmd: Bool, alternate: Bool)) -> Bool { mods.alternate || mouseCaptured }

    /// A ⌘ or ⇧⌘ mouse-down on a link that meum handles (see `meumFindsLinks`): opens it and swallows the
    /// click. False: not such a click (it goes to the terminal; a plain ⌘-click to ghostty).
    func handleLinkClick(_ event: NSEvent) -> Bool {
        guard let mods = Self.linkMods(event.modifierFlags), meumFindsLinks(mods),
              let (_, t) = link(at: convert(event.locationInWindow, from: nil)) else { return false }
        hideLinkHover()
        linkHost?.perform(t, tab: tabID, alternate: mods.alternate)
        return true
    }

    /// A right-click on a link shows its menu. False: not on a link (the click goes to the terminal).
    func showLinkMenu(_ event: NSEvent) -> Bool {
        guard let host = linkHost,
              let (_, t) = link(at: convert(event.locationInWindow, from: nil)) else { return false }
        hideLinkHover()
        NSMenu.popUpContextMenu(host.linkMenu(t, tab: tabID), with: event, for: self)
        return true
    }

    // MARK: - Hover line

    /// ghostty's MOUSE_OVER_LINK: the link under the mouse while ⌘ is held ("" when it left it).
    func hoverLinkFromGhostty(_ raw: String) {
        guard !raw.isEmpty else { hoverRaw = nil; refreshLinkHover(); return }
        hoverRaw = raw
        refreshLinkHover()
    }

    /// Redraws the hover line for the mouse and modifiers now: ghostty's link with ⌘, our own with ⇧⌘.
    func refreshLinkHover(flags: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        guard let host = linkHost, pointerInside, let mods = Self.linkMods(flags) else { hideLinkHover(); return }
        let point = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? .zero
        var target: TerminalLinks.Target?
        var raw = hoverRaw
        var underline: [NSRect] = []
        if meumFindsLinks(mods) {
            if let g = grid, let (p, t) = link(at: point) { target = t; raw = p.text; underline = g.rects(p) } else { raw = nil }
        } else if let r = hoverRaw, let found = ghosttyLinkTarget(r) {
            target = found.target
            raw = found.text
        }
        showLinkUnderline(underline)
        guard let raw else { hideLinkHover(); return }
        let text: String
        if let target {
            let what = host.linkActionTitle(target, alternate: mods.alternate)
            let other = host.linkActionTitle(target, alternate: !mods.alternate)
            text = "\(what): \(target.display())   ·   \(mods.alternate ? "⌘" : "⇧⌘")-click: \(other)"
        } else {
            text = "Not found: \(raw.prefix(120))"
        }
        showLinkHover(text, near: point)
    }

    func showLinkHover(_ text: String, near point: NSPoint) {
        guard let host = superview else { return }
        let v = linkHover ?? LinkHoverView()
        if v.superview !== host { host.addSubview(v, positioned: .above, relativeTo: self) }
        linkHover = v
        v.label.stringValue = text
        let size = v.fittingSize
        let w = min(size.width, frame.width - 16)
        // bottom left of the terminal, or bottom right when the mouse is there
        let local = NSRect(x: 8, y: bounds.height - size.height - 8, width: w, height: size.height)
        var r = convert(local, to: host)
        let mouseIn = convert(NSRect(x: 0, y: local.minY - 20, width: local.maxX + 20, height: local.height + 40), to: host)
        if mouseIn.contains(convert(point, to: host)) {
            r.origin.x = convert(NSPoint(x: bounds.width - w - 8, y: 0), to: host).x
        }
        v.frame = r
        v.isHidden = false
    }

    func hideLinkHover() {
        linkHover?.isHidden = true
        linkUnderline?.isHidden = true
    }

    /// meum's own underline under a link it found (ghostty draws its own for the links it finds).
    func showLinkUnderline(_ rects: [NSRect]) {
        guard !rects.isEmpty, let host = superview else { linkUnderline?.isHidden = true; return }
        let v = linkUnderline ?? LinkUnderlineView()
        if v.superview !== host { host.addSubview(v, positioned: .above, relativeTo: self) }
        linkUnderline = v
        v.frame = frame
        v.rects = rects
        v.isHidden = false
    }

    // MARK: - Keyboard hints

    /// Labels every link on screen with a letter; typing it opens the link (Shift+letter the other way), Esc or a
    /// click ends it. False when there is no link to show.
    @discardableResult
    func showLinkHints() -> Bool {
        guard let host = linkHost, let g = grid, let parent = superview else { return false }
        let found = TerminalLinks.find(rows: viewportRows(g), columns: g.columns).compactMap { p in
            host.linkTarget(p.text, tab: tabID).map { (p, $0) }
        }
        guard !found.isEmpty else { return false }
        let labels = LinkHintsView.labels(count: found.count)
        let hints = zip(found, labels).map { pair, label in
            LinkHintsView.Hint(label: label, rects: g.rects(pair.0), target: pair.1)
        }
        let v = LinkHintsView(hints: hints) { [weak self] target, alternate in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
            if let target { self.linkHost?.perform(target, tab: self.tabID, alternate: alternate) }
        }
        v.frame = frame
        parent.addSubview(v, positioned: .above, relativeTo: self)
        window?.makeFirstResponder(v)
        return true
    }
}

/// The small line at the bottom of a terminal that says what a ⌘-click on the link under the mouse does.
/// Lines under the cells of a link, over the terminal (in the surface's coordinates; clicks pass through).
final class LinkUnderlineView: NSView {
    var rects: [NSRect] = [] { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func hitTest(_: NSPoint) -> NSView? { nil }
    override func draw(_: NSRect) {
        NSColor.linkColor.setFill()
        for r in rects { NSRect(x: r.minX, y: r.maxY - 2, width: r.width, height: 1).fill() }
    }
}

final class LinkHoverView: NSView {
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        layer?.borderWidth = 0.5
        label.font = .systemFont(ofSize: 11)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// The overlay of Terminal ▸ Open Link…: a letter on each link; it holds the keyboard until a choice or Esc.
final class LinkHintsView: NSView {
    struct Hint {
        let label: String
        let rects: [NSRect]
        let target: TerminalLinks.Target
    }

    private let hints: [Hint]
    private var typed = ""
    private let done: (TerminalLinks.Target?, Bool) -> Void
    private var finished = false

    init(hints: [Hint], done: @escaping (TerminalLinks.Target?, Bool) -> Void) {
        self.hints = hints
        self.done = done
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    static let alphabet = Array("asdfjklghqweruiotyzxcvbnmp")

    /// Labels of equal length, so none is the start of another: one letter for up to 26 links, two beyond.
    static func labels(count: Int) -> [String] {
        if count <= alphabet.count { return alphabet.prefix(count).map { String($0) } }
        return Array(alphabet.flatMap { a in alphabet.map { String(a) + String($0) } }.prefix(count))
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        for h in hints where h.label.hasPrefix(typed) {
            NSColor.systemYellow.withAlphaComponent(0.22).setFill()
            for r in h.rects { NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill() }
            guard let first = h.rects.first else { continue }
            let text = NSAttributedString(string: h.label.uppercased(), attributes: [.font: font, .foregroundColor: NSColor.black])
            let size = text.size()
            let box = NSRect(x: max(0, first.minX - size.width - 8), y: first.minY + (first.height - size.height - 2) / 2,
                             width: size.width + 6, height: size.height + 2)
            NSColor.systemYellow.setFill()
            NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            text.draw(at: NSPoint(x: box.minX + 3, y: box.minY + 1))
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { finish(nil, false); return }   // Esc
        if event.keyCode == 51 { typed = String(typed.dropLast()); needsDisplay = true; return }   // Delete
        guard let ch = event.charactersIgnoringModifiers?.lowercased().first, Self.alphabet.contains(ch) else {
            NSSound.beep()
            return
        }
        let alternate = event.modifierFlags.contains(.shift)
        typed.append(ch)
        let matching = hints.filter { $0.label.hasPrefix(typed) }
        if matching.isEmpty { typed.removeLast(); NSSound.beep(); return }
        if matching.count == 1, matching[0].label == typed { finish(matching[0].target, alternate); return }
        needsDisplay = true
    }

    override func mouseDown(with _: NSEvent) { finish(nil, false) }

    override func resignFirstResponder() -> Bool {
        // the keyboard went elsewhere (another card, another app's window): the hints end
        DispatchQueue.main.async { [weak self] in self?.finish(nil, false, refocus: false) }
        return true
    }

    private func finish(_ t: TerminalLinks.Target?, _ alternate: Bool, refocus: Bool = true) {
        guard !finished else { return }
        finished = true
        removeFromSuperview()
        if refocus || t != nil { done(t, alternate) }
    }
}

