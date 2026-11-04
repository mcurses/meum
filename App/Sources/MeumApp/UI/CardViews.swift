import AppKit
import MeumCore

/// How every card is drawn, from the settings. Shared by all cards; `GlassView.apply` reads it.
struct CardAppearance: Equatable {
    var radius: CGFloat = 12
    var background: Settings.Background = .glass
    /// The pinned wallpaper under the material (not under `solid`).
    var wallpaper = true
    var liquidStyle: Settings.LiquidStyle = .regular
    /// The focused card's frame (`Settings.focusFrameSaturation` / `focusFrameOpacity`).
    var frameSaturation: CGFloat = 1
    var frameOpacity: CGFloat = 0.8
    var tint: CGFloat = 0.35
    var solid: NSColor = NSColor(calibratedRed: 0.086, green: 0.094, blue: 0.114, alpha: 1)

    @MainActor static var current = CardAppearance()
}

/// The rounded body of a card. Not flipped (the wallpaper anchoring math assumes AppKit coordinates, as in the
/// floating-layout spike); content goes into the flipped `content` view.
///
/// Background, bottom to top: the pinned wallpaper layer (when on), the material (a vibrancy view, or a Liquid
/// Glass view on macOS 26), the tint view, then the content. A solid background is the layer's own colour. Over
/// the pinned wallpaper the materials blur and refract that still picture (vibrancy within the window); without it
/// they show what is behind meum.
final class GlassView: NSView {
    private let wallLayer = CALayer()
    private let effect = NSVisualEffectView()
    /// The macOS 26 Liquid Glass view, made on first use.
    private var liquid: NSView?
    private let tintView = NSView()
    let content = FlippedView()
    /// Where this card sits on screen (AppKit global coordinates). Anchors the wallpaper.
    var screenRect: NSRect = .zero { didSet { positionWallpaper() } }
    var focused = false { didSet { if focused != oldValue { updateBorder() } } }
    var accent: NSColor? { didSet { updateBorder() } }
    private(set) var radius: CGFloat = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let l = layer!
        l.cornerCurve = .continuous
        l.masksToBounds = true
        l.borderWidth = 1
        wallLayer.anchorPoint = .zero
        wallLayer.contentsGravity = .resize
        wallLayer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "hidden": NSNull()]
        l.addSublayer(wallLayer)
        effect.blendingMode = .behindWindow
        effect.material = .hudWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.frame = bounds
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor.black.cgColor
        tintView.frame = bounds
        tintView.autoresizingMask = [.width, .height]
        addSubview(tintView)
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        apply()
        updateBorder()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Applies `CardAppearance.current` and the wallpaper image.
    func apply() {
        let a = CardAppearance.current
        radius = a.radius
        layer?.cornerRadius = a.radius
        effect.maskImage = Self.mask(radius: a.radius)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let pinned = a.wallpaper && a.background != .solid
        wallLayer.isHidden = !pinned
        // under the pinned wallpaper an opaque base, so nothing behind meum shows through its edges
        layer?.backgroundColor = a.background == .solid ? a.solid.cgColor
            : pinned ? NSColor(calibratedWhite: 0.06, alpha: 1).cgColor : NSColor.clear.cgColor
        var material = a.background
        if material == .liquid, Self.liquidAvailable == false { material = .vibrancy }
        effect.isHidden = material != .vibrancy
        // over the pinned wallpaper, vibrancy blurs that picture (inside the window); without it, what is behind
        effect.blendingMode = pinned ? .withinWindow : .behindWindow
        if material == .liquid { showLiquid(a) } else { liquid?.isHidden = true }
        tintView.isHidden = material == .solid
        tintView.alphaValue = a.tint
        CATransaction.commit()
        reloadWallpaper()
        updateBorder()
    }

    static var liquidAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// Shows (making it on first use) the Liquid Glass view, just above the wallpaper and below the tint.
    private func showLiquid(_ a: CardAppearance) {
        guard #available(macOS 26.0, *) else { return }
        let g: NSGlassEffectView
        if let existing = liquid as? NSGlassEffectView {
            g = existing
        } else {
            g = NSGlassEffectView()
            g.frame = bounds
            g.autoresizingMask = [.width, .height]
            addSubview(g, positioned: .below, relativeTo: tintView)
            liquid = g
        }
        g.isHidden = false
        g.cornerRadius = a.radius
        g.style = a.liquidStyle == .clear ? .clear : .regular
    }

    func reloadWallpaper() {
        let a = CardAppearance.current
        wallLayer.contents = a.wallpaper && a.background != .solid ? Wallpaper.shared.image : nil
        wallLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        positionWallpaper()
    }

    func positionWallpaper() {
        let sf = Wallpaper.shared.screenFrame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wallLayer.frame = CGRect(x: sf.minX - screenRect.minX, y: sf.minY - screenRect.minY,
                                 width: sf.width, height: sf.height)
        CATransaction.commit()
    }

    /// A stretchable rounded-rect mask, so the vibrancy follows the card's corners.
    static func mask(radius: CGFloat) -> NSImage {
        let r = max(0, radius)
        let side = r * 2 + 1
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    private func updateBorder() {
        let a = CardAppearance.current
        let c = focused ? Self.frameColor(accent, saturation: a.frameSaturation, opacity: a.frameOpacity)
            : NSColor(white: 1, alpha: 0.08)
        layer?.borderColor = c.cgColor
        layer?.borderWidth = focused ? 1.5 : 1
    }

    /// The focus frame: the workspace colour with its saturation scaled (white without a colour), at `opacity`.
    static func frameColor(_ accent: NSColor?, saturation: CGFloat, opacity: CGFloat) -> NSColor {
        guard let c = accent?.usingColorSpace(.sRGB) else { return NSColor(white: 1, alpha: opacity) }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, al: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &al)
        return NSColor(hue: h, saturation: s * max(0, min(1, saturation)), brightness: b, alpha: opacity)
    }

    override func layout() {
        super.layout()
        positionWallpaper()
    }
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Carries the card's shadow (`NSShadow`: AppKit resets layer shadows set directly) around a `GlassView`.
class CardHostView: NSView {
    let glass = GlassView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let sh = NSShadow()
        sh.shadowColor = NSColor(white: 0, alpha: 0.5)
        sh.shadowBlurRadius = 16
        sh.shadowOffset = NSSize(width: 0, height: -5)
        shadow = sh
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError() }

    var content: NSView { glass.content }

    /// Places the card. `frame` is in the container's (flipped) coordinates, `screenRect` in screen coordinates.
    func place(_ frame: NSRect, screenRect: NSRect) {
        self.frame = frame
        updateShadowPath()
        glass.screenRect = screenRect
    }

    func updateShadowPath() {
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: glass.radius, cornerHeight: glass.radius, transform: nil)
    }

    /// Re-reads `CardAppearance.current`.
    func applyAppearance() {
        glass.apply()
        updateShadowPath()
    }
}

/// The widget slot under the sidebar. Hosts the native widget `WidgetManager` loads, or shows a placeholder.
final class WidgetSlotCardView: CardHostView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private(set) var hosted: NSView?
    /// The height the widget asked for through `MeumWidgetHost.setPreferredHeight`.
    var requestedHeight: () -> CGFloat? = { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor(white: 1, alpha: 0.28)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -16),
        ])
        showPlaceholder(nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Hosts a widget view, replacing the placeholder.
    func host(_ view: NSView) {
        unhost()
        label.isHidden = true
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
        hosted = view
    }

    func unhost() {
        hosted?.removeFromSuperview()
        hosted = nil
        label.isHidden = false
    }

    /// The placeholder text: an invitation without a widget (a click opens Settings ▸ Widgets), or why loading failed.
    func showPlaceholder(_ text: String?) {
        unhost()
        label.stringValue = text ?? "No widgets · Get Widgets…"
        invites = text == nil
    }
    private var invites = false
    /// Opens Settings at Widgets (set by the app delegate).
    static var onGetWidgets: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if hosted == nil, invites { Self.onGetWidgets?() } else { super.mouseDown(with: event) }
    }

    /// The height for the "auto" widget height: what the widget asked for, else its fitting size; nil without.
    var preferredHeight: CGFloat? {
        guard hosted != nil else { return nil }
        if let h = requestedHeight() { return h }
        guard let h = hosted?.fittingSize.height, h > 0 else { return nil }
        return h
    }
}

/// The built-in Tips widget (setting `showStartHint`, switched in Settings ▸ Widgets or closed with its ×): the
/// gestures no menu shows, that terminals survive quitting, and where Settings and Help are. Not in the rail.
final class StartHintView: NSView {
    /// One tip per page: what it is, and a friendlier line in grey under it.
    static let tips: [(String, String)] = [
        ("Your terminals keep running when meum quits.",
         "Go ahead, restart meum. Your sessions will be waiting for you."),
        ("Drag a tab onto a card's edge to split it.",
         "Or onto another card to move it there. Double-click the gap between two cards to even them out."),
        ("⌘-click or ⇧-click selects several workspaces.",
         "Then right-click to put them in a group. A group folds away with a click on its name."),
        ("The dots tell you what Claude is up to.",
         "Orange waits for you, blue is done and unread, grey is idle. Hover a dot if you forget."),
        ("Make it yours with ⌘,",
         "Fonts, colour themes, glass, the sidebar, widgets and every shortcut."),
        ("There's more in the Help menu.",
         "Including how to let Claude Code drive meum itself."),
    ]
    private(set) var page = 0
    private let header = NSTextField(labelWithString: "Tips")
    private let counter = NSTextField(labelWithString: "")
    private let tip = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let prev = NSButton(), next = NSButton(), close = NSButton()
    var onClose: (() -> Void)?
    override var isFlipped: Bool { true }

    private static let tipFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let noteFont = NSFont.systemFont(ofSize: 11)

    override init(frame: NSRect) {
        super.init(frame: frame)
        header.font = .systemFont(ofSize: 10, weight: .bold)
        header.textColor = NSColor(white: 1, alpha: 0.45)
        counter.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        counter.textColor = NSColor(white: 1, alpha: 0.35)
        counter.alignment = .right
        tip.font = Self.tipFont
        tip.textColor = NSColor(white: 1, alpha: 0.88)
        note.font = Self.noteFont
        note.textColor = NSColor(white: 1, alpha: 0.48)
        for (b, symbol, label, action) in [(prev, "chevron.left", "Previous tip", #selector(prevClicked)),
                                           (next, "chevron.right", "Next tip", #selector(nextClicked)),
                                           (close, "xmark", "Don't show tips", #selector(closeClicked))] {
            b.bezelStyle = .inline
            b.isBordered = false
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 8.5, weight: .bold))
            b.contentTintColor = NSColor(white: 1, alpha: 0.5)
            b.toolTip = label
            b.target = self
            b.action = action
        }
        close.toolTip = "Don't show tips (Settings ▸ Widgets brings them back)"
        for v in [header, counter, tip, note, prev, next, close] { addSubview(v) }
        show(0)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeClicked() { onClose?() }
    @objc private func prevClicked() { show(page - 1) }
    @objc private func nextClicked() { show(page + 1) }

    /// Shows a page (wrapping around at both ends).
    func show(_ p: Int) {
        let n = Self.tips.count
        page = ((p % n) + n) % n
        tip.stringValue = Self.tips[page].0
        note.stringValue = Self.tips[page].1
        counter.stringValue = "\(page + 1) / \(n)"
        needsLayout = true
    }

    /// Measured the way the label draws (its cell wraps a little narrower than the plain text would).
    private static let measure = NSTextField(wrappingLabelWithString: "")
    private static func textHeight(_ s: String, _ font: NSFont, width: CGFloat) -> CGFloat {
        measure.font = font
        measure.stringValue = s
        return ceil(measure.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height)
    }

    /// The height the card needs at a width: the tallest page, so paging doesn't make the card jump.
    func height(forWidth w: CGFloat) -> CGFloat {
        let tw = w - 24
        let body = Self.tips.map { Self.textHeight($0.0, Self.tipFont, width: tw) + 4 + Self.textHeight($0.1, Self.noteFont, width: tw) }
            .max() ?? 0
        return 30 + body + 14
    }

    override func layout() {
        super.layout()
        let w = bounds.width, tw = w - 24
        header.frame = NSRect(x: 12, y: 10, width: 60, height: 14)
        close.frame = NSRect(x: w - 26, y: 7, width: 18, height: 18)
        next.frame = NSRect(x: w - 48, y: 7, width: 18, height: 18)
        prev.frame = NSRect(x: w - 68, y: 7, width: 18, height: 18)
        counter.frame = NSRect(x: w - 118, y: 10, width: 48, height: 14)
        let th = Self.textHeight(tip.stringValue, Self.tipFont, width: tw)
        tip.preferredMaxLayoutWidth = tw
        tip.frame = NSRect(x: 12, y: 30, width: tw, height: th)
        note.preferredMaxLayoutWidth = tw
        note.frame = NSRect(x: 12, y: 30 + th + 4, width: tw, height: Self.textHeight(note.stringValue, Self.noteFont, width: tw))
    }
}
