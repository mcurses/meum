import AppKit
import MeumCore

/// How every card is drawn, from the settings. Shared by all cards; `GlassView.apply` reads it.
struct CardAppearance: Equatable {
    var radius: CGFloat = 12
    var background: Settings.Background = .glass
    var tint: CGFloat = 0.35
    var solid: NSColor = NSColor(calibratedRed: 0.086, green: 0.094, blue: 0.114, alpha: 1)

    @MainActor static var current = CardAppearance()
}

/// The rounded body of a card. Not flipped (the wallpaper anchoring math assumes AppKit coordinates, as in the
/// floating-layout spike); content goes into the flipped `content` view.
///
/// Background, bottom to top: the wallpaper layer (glass), a behind-window vibrancy view (vibrancy), the tint
/// view, then the content. A solid background is the layer's own colour.
final class GlassView: NSView {
    private let wallLayer = CALayer()
    private let effect = NSVisualEffectView()
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
        switch a.background {
        case .glass:
            wallLayer.isHidden = false
            effect.isHidden = true
            tintView.isHidden = false
            layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1).cgColor
        case .vibrancy:
            wallLayer.isHidden = true
            effect.isHidden = false
            tintView.isHidden = false
            layer?.backgroundColor = NSColor.clear.cgColor
        case .solid:
            wallLayer.isHidden = true
            effect.isHidden = true
            tintView.isHidden = true
            layer?.backgroundColor = a.solid.cgColor
        }
        tintView.alphaValue = a.tint
        CATransaction.commit()
        reloadWallpaper()
    }

    func reloadWallpaper() {
        wallLayer.contents = CardAppearance.current.background == .glass ? Wallpaper.shared.image : nil
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
        let c = focused ? (accent ?? NSColor(white: 1, alpha: 0.8)) : NSColor(white: 1, alpha: 0.08)
        layer?.borderColor = c.cgColor
        layer?.borderWidth = focused ? 1.5 : 1
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

    /// The placeholder text: "widgets" without a widget, or why loading failed.
    func showPlaceholder(_ text: String?) {
        unhost()
        label.stringValue = text ?? "widgets"
    }

    /// The height for the "auto" widget height: what the widget asked for, else its fitting size; nil without.
    var preferredHeight: CGFloat? {
        guard hosted != nil else { return nil }
        if let h = requestedHeight() { return h }
        guard let h = hosted?.fittingSize.height, h > 0 else { return nil }
        return h
    }
}
