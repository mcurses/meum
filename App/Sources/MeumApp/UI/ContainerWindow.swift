import AppKit

/// Approach A from the floating-layout spike (docs/research/spike-floating-layout.md): one clear window holding every card, screen-sized by default.
/// Clicks on fully transparent pixels (the gaps) fall through to whatever is behind, by the window server's
/// own alpha hit test.
///
/// It is a titled, resizable window with all its chrome hidden (no title bar, no buttons, no shadow), so macOS
/// and window managers treat it as a standard window: its edges and corners resize it, the Window menu and
/// tiling work, Rectangle moves it. By mouse, the sidebar's header and the strip over the top gap
/// (`WindowDragStrip`) move it, as a title bar would; a terminal card's top bar moves that card.
final class ContainerWindow: NSWindow {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.titled, .resizable, .miniaturizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        minSize = NSSize(width: 480, height: 320)
        isReleasedWhenClosed = false
        collectionBehavior = [.managed, .fullScreenNone]
        title = "meum"
        acceptsMouseMovedEvents = true
    }

    // borderless windows can't become key (no keyboard input) unless they say so
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The container's content view: flipped, so card frames from MeumCore (top-left origin) map 1:1.
final class RootView: NSView {
    /// With `catchClicks`, the gaps get a 1% fill so clicks there stay in meum instead of passing through.
    var catchClicks = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard catchClicks else { return }
        NSColor(white: 0, alpha: 0.01).setFill()
        dirtyRect.fill()
    }
}

/// The top gap above the cards: a title bar without a bar. Dragging it moves the window, a double click does what
/// the user's "double-click a window's title bar" setting says (zoom by default). Painted with a 1% fill so the
/// window server does not pass its clicks through to the app behind.
final class WindowDragStrip: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.01).setFill()
        dirtyRect.fill()
    }

    override func mouseDown(with event: NSEvent) { window?.titleBarMouseDown(event) }
}

extension NSWindow {
    /// What a mouse down on a title bar does: a drag moves the window, a double click does what the user's
    /// "double-click a window's title bar" setting says (zoom by default). For meum's stand-ins for a title bar:
    /// the top gap and the sidebar's header.
    func titleBarMouseDown(_ event: NSEvent) {
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": performMiniaturize(nil)
            case "None": break
            default: performZoom(nil)
            }
            return
        }
        performDrag(with: event)
    }
}
