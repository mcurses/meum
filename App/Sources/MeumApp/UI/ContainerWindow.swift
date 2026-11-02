import AppKit

/// Approach A from spikes/floating-layout: one borderless, clear, screen-sized window holding every card.
/// Clicks on fully transparent pixels (the gaps) fall through to whatever is behind, by the window server's
/// own alpha hit test.
final class ContainerWindow: NSWindow {
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
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
