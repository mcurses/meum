// Floating layout spike for "meum".
//
// Mode A: one invisible container window (borderless, clear, covers the visibleFrame);
//         the sidebar and terminal "cards" are rounded, shadowed views inside it.
// Mode B: one borderless window per card, positioned by the app's own layout engine.
//
// Both modes share the layout engine and the animation driver (display-link tween),
// so the comparison is about the window structure, not the animation code.
//
// Keys:   n add card   w remove focused card   Tab next card   l toggle layout (master/columns)
//         m cycle material   p toggle passthrough poll (mode A)   q quit
// Args:   --mode A|B  --material glass|vibrancy|liquid|solid  --cards N  --layout master|columns
//         --group child|none (B)  --passthrough none|poll (A)  --autoquit SECONDS
//         --duration SECONDS (relayout animation, default 0.22)  --blur PT  --tint 0..1
//         --backdrop x,y,w,h   (CG top-left coords; run as a plain titled "other app" window)
// Remote: distributed notification "meum.spike.cmd" with object = add|remove|next|layout|material|dump|quit
// Output: one JSON line per event on stdout.

import AppKit
import CoreImage
import QuartzCore

setvbuf(stdout, nil, _IOLBF, 0)

func emit(_ d: [String: Any]) {
    var d = d
    d["t"] = (CACurrentMediaTime() * 1000).rounded() / 1000
    if let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]),
       let s = String(data: data, encoding: .utf8) { print(s) }
}

// MARK: - Arguments

struct Options {
    var mode = "A"
    var material = "glass"
    var cards = 3
    var layout = "master"
    var group = "child"
    var passthrough = "none"
    var autoquit: Double = 90
    var backdrop: CGRect?
    var blur: CGFloat = 4
    var tint: CGFloat = 0.35
    var duration: Double = 0.22

    init() {
        let a = CommandLine.arguments
        func v(_ f: String) -> String? { a.firstIndex(of: f).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        mode = v("--mode") ?? mode
        material = v("--material") ?? material
        cards = Int(v("--cards") ?? "") ?? cards
        layout = v("--layout") ?? layout
        group = v("--group") ?? group
        passthrough = v("--passthrough") ?? passthrough
        autoquit = Double(v("--autoquit") ?? "") ?? autoquit
        blur = CGFloat(Double(v("--blur") ?? "") ?? Double(blur))
        tint = CGFloat(Double(v("--tint") ?? "") ?? Double(tint))
        duration = Double(v("--duration") ?? "") ?? duration
        if let b = v("--backdrop") {
            let p = b.split(separator: ",").compactMap { Double($0) }
            if p.count == 4 { backdrop = CGRect(x: p[0], y: p[1], width: p[2], height: p[3]) }
        }
    }
}
let opts = Options()

let mainScreenHeight = NSScreen.screens[0].frame.height
/// AppKit global (bottom-left origin) -> CG global (top-left origin)
func toCG(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: mainScreenHeight - r.maxY, width: r.width, height: r.height) }
func fromCG(_ r: CGRect) -> NSRect { NSRect(x: r.minX, y: mainScreenHeight - r.maxY, width: r.width, height: r.height) }
func rectDict(_ r: NSRect) -> [String: Double] {
    let c = toCG(r); return ["x": Double(c.minX), "y": Double(c.minY), "w": Double(c.width), "h": Double(c.height)]
}

// MARK: - Wallpaper (ported from ~/code/wallpaper-glass, minimal)

final class Wallpaper {
    static let shared = Wallpaper()
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private(set) var image: CGImage?
    private(set) var screenFrame: NSRect = .zero

    func load(for screen: NSScreen, blurPoints: CGFloat) {
        screenFrame = screen.frame
        let ws = NSWorkspace.shared
        guard let url = ws.desktopImageURL(for: screen),
              let ns = NSImage(contentsOf: url),
              let img = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { image = nil; return }
        let o = ws.desktopImageOptions(for: screen) ?? [:]
        let clipping = (o[.allowClipping] as? NSNumber)?.boolValue ?? true
        let scale = screen.backingScaleFactor
        let pw = Int(screen.frame.width * scale), ph = Int(screen.frame.height * scale)
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.interpolationQuality = .high
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        let W = CGFloat(pw), H = CGFloat(ph), iw = CGFloat(img.width), ih = CGFloat(img.height)
        let s = clipping ? max(W / iw, H / ih) : min(W / iw, H / ih)
        ctx.draw(img, in: CGRect(x: (W - iw * s) / 2, y: (H - ih * s) / 2, width: iw * s, height: ih * s))
        guard var out = ctx.makeImage() else { return }
        if blurPoints > 0 {
            let input = CIImage(cgImage: out)
            let b = input.clampedToExtent().applyingGaussianBlur(sigma: Double(blurPoints * scale)).cropped(to: input.extent)
            if let c = ci.createCGImage(b, from: input.extent) { out = c }
        }
        image = out
    }
}

// MARK: - Card content (shared by both modes)

let fakeLines = [
    "max@amo ~/code/meum (main) $ git log --oneline -3",
    "3f2a1c9 Tile terminal cards with even gaps",
    "8b71e04 Shared layout engine for both window models",
    "1d0c5aa Initial spike",
    "max@amo ~/code/meum (main) $ ls",
    "RESULT.md  Sources  build.sh  probe.swift  shots",
    "max@amo ~/code/meum (main) $ claude",
    "  ✻ Thinking…",
    "max@amo ~/code/meum (main) $ █",
]

final class CardContent: NSView {
    let cardID: Int
    let isSidebar: Bool
    let radius: CGFloat = 14
    private let wallLayer = CALayer()
    private let tintLayer = CALayer()
    private var effect: NSView?
    private let label = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    var material: String { didSet { applyMaterial() } }
    var focused = false { didSet { updateBorder() } }
    /// Where this card sits on screen (AppKit global). Used to anchor the wallpaper.
    var screenRect: NSRect = .zero { didSet { positionWallpaper() } }

    init(id: Int, sidebar: Bool, material: String) {
        cardID = id; isSidebar = sidebar; self.material = material
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        wantsLayer = true
        layer!.cornerRadius = radius
        layer!.cornerCurve = .continuous
        layer!.masksToBounds = true
        layer!.borderWidth = 1
        wallLayer.anchorPoint = .zero
        wallLayer.contentsGravity = .resize
        tintLayer.backgroundColor = NSColor.black.cgColor
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = NSColor(white: 1, alpha: 0.85)
        title.stringValue = sidebar ? "WORKSPACES" : "term \(id)"
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = NSColor(white: 0.9, alpha: 1)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byClipping
        label.stringValue = sidebar
            ? "●  meum          2\n○  api-server\n●  wallpaper-glass\n○  tamago\n○  agent-docs\n\nfixed width 240 pt"
            : fakeLines.joined(separator: "\n")
        addSubview(title); addSubview(label)
        applyMaterial()
        updateBorder()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func applyMaterial() {
        effect?.removeFromSuperview(); effect = nil
        wallLayer.removeFromSuperlayer(); tintLayer.removeFromSuperlayer()
        layer!.backgroundColor = nil
        switch material {
        case "glass":
            wallLayer.contents = Wallpaper.shared.image
            wallLayer.contentsScale = window?.backingScaleFactor ?? 2
            tintLayer.opacity = Float(opts.tint)
            layer!.insertSublayer(wallLayer, at: 0)
            layer!.insertSublayer(tintLayer, above: wallLayer)
            positionWallpaper()
        case "vibrancy":
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .behindWindow
            v.state = .active
            v.maskImage = Self.roundedMask(radius: radius)
            effect = v
        case "liquid":
            if #available(macOS 26.0, *) {
                let g = NSGlassEffectView()
                g.cornerRadius = radius
                g.tintColor = NSColor(white: 0, alpha: 0.25)
                effect = g
            } else { layer!.backgroundColor = NSColor(white: 0.08, alpha: 0.92).cgColor }
        default:
            layer!.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 0.94).cgColor
        }
        if let effect { effect.frame = bounds; effect.autoresizingMask = [.width, .height]; addSubview(effect, positioned: .below, relativeTo: nil) }
        needsLayout = true
    }

    static func roundedMask(radius r: CGFloat) -> NSImage {
        let size = NSSize(width: r * 2 + 1, height: r * 2 + 1)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill(); NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill(); return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    func positionWallpaper() {
        guard material == "glass" else { return }
        let sf = Wallpaper.shared.screenFrame
        CATransaction.begin(); CATransaction.setDisableActions(true)
        wallLayer.frame = CGRect(x: sf.minX - screenRect.minX, y: sf.minY - screenRect.minY, width: sf.width, height: sf.height)
        tintLayer.frame = bounds
        CATransaction.commit()
    }

    private func updateBorder() {
        layer!.borderColor = NSColor(white: 1, alpha: focused ? 0.55 : 0.12).cgColor
    }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 14, y: bounds.height - 28, width: bounds.width - 28, height: 16)
        label.frame = NSRect(x: 14, y: 10, width: bounds.width - 28, height: bounds.height - 44)
        positionWallpaper()
    }
    override func mouseDown(with e: NSEvent) { Engine.shared.focus(cardID: cardID, via: "click") }
}

// MARK: - Window structures

protocol Structure: AnyObject {
    func add(_ c: CardContent, sidebar: Bool)
    func remove(_ c: CardContent)
    func apply(_ rects: [(CardContent, NSRect)], final: Bool)
    func focus(_ c: CardContent)
    func dump() -> [String: Any]
}

/// Borderless windows can't become key unless they say so.
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Mode A: one invisible full-visibleFrame container window.
final class ContainerStructure: NSObject, Structure {
    let window: KeyableWindow
    let root = NSView()
    var hosts: [ObjectIdentifier: NSView] = [:]
    var pollTimer: Timer?
    var toggles = 0

    override init() {
        let vf = NSScreen.main!.visibleFrame
        window = KeyableWindow(contentRect: vf, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .fullScreenNone]
        root.wantsLayer = true
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        if opts.passthrough == "poll" { startPoll() }
    }

    func startPoll() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            guard let self else { return }
            let p = NSEvent.mouseLocation
            let inside = self.hosts.values.contains { h in
                let r = self.window.convertToScreen(h.convert(h.bounds, to: nil)); return r.contains(p)
            }
            if self.window.ignoresMouseEvents == inside { self.window.ignoresMouseEvents = !inside; self.toggles += 1 }
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    func add(_ c: CardContent, sidebar: Bool) {
        let host = NSView()   // carries the shadow; the card inside clips to its rounded corners
        host.wantsLayer = true
        // AppKit owns a layer-backed view's layer shadow and resets it from `NSView.shadow`,
        // so setting layer.shadow* directly does nothing visible. Use NSShadow.
        let sh = NSShadow()
        sh.shadowColor = NSColor(white: 0, alpha: 0.55)
        sh.shadowBlurRadius = 18
        sh.shadowOffset = NSSize(width: 0, height: -6)
        host.shadow = sh
        c.autoresizingMask = [.width, .height]
        host.addSubview(c)
        root.addSubview(host)
        hosts[ObjectIdentifier(c)] = host
    }
    func remove(_ c: CardContent) { hosts.removeValue(forKey: ObjectIdentifier(c))?.removeFromSuperview() }

    func apply(_ rects: [(CardContent, NSRect)], final: Bool) {
        let wo = window.frame.origin
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (c, r) in rects {
            guard let h = hosts[ObjectIdentifier(c)] else { continue }
            h.frame = r.offsetBy(dx: -wo.x, dy: -wo.y)
            c.frame = h.bounds
            h.layer!.shadowPath = CGPath(roundedRect: h.bounds, cornerWidth: c.radius, cornerHeight: c.radius, transform: nil)
            c.screenRect = r
        }
        CATransaction.commit()
    }
    func focus(_ c: CardContent) { window.makeKeyAndOrderFront(nil); window.makeFirstResponder(c) }
    func dump() -> [String: Any] {
        ["windows": [["num": window.windowNumber, "frame": rectDict(window.frame), "key": window.isKeyWindow]],
         "ignoresMouse": window.ignoresMouseEvents, "pollToggles": toggles]
    }
}

/// Mode B: one borderless window per card.
final class WindowsStructure: NSObject, Structure, NSWindowDelegate {
    var wins: [ObjectIdentifier: KeyableWindow] = [:]
    var parent: KeyableWindow?

    func add(_ c: CardContent, sidebar: Bool) {
        let w = KeyableWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true            // window server derives the shadow from the rounded alpha shape
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.managed, .fullScreenNone]
        w.delegate = self
        w.contentView = c
        wins[ObjectIdentifier(c)] = w
        if sidebar { parent = w; w.makeKeyAndOrderFront(nil) }
        else if opts.group == "child", let parent { parent.addChildWindow(w, ordered: .above) }
        else { w.orderFront(nil) }
    }
    func remove(_ c: CardContent) {
        guard let w = wins.removeValue(forKey: ObjectIdentifier(c)) else { return }
        w.parent?.removeChildWindow(w)
        w.orderOut(nil)
    }
    func apply(_ rects: [(CardContent, NSRect)], final: Bool) {
        for (c, r) in rects {
            guard let w = wins[ObjectIdentifier(c)] else { continue }
            w.setFrame(r, display: true)
            c.screenRect = r
            if final { w.invalidateShadow() }
        }
    }
    func focus(_ c: CardContent) { wins[ObjectIdentifier(c)]?.makeKeyAndOrderFront(nil) }
    func windowDidBecomeKey(_ n: Notification) {
        guard let w = n.object as? NSWindow, let c = w.contentView as? CardContent else { return }
        Engine.shared.focusChanged(to: c, via: "windowDidBecomeKey")
    }
    func dump() -> [String: Any] {
        ["windows": wins.values.map { w in
            ["num": w.windowNumber, "frame": rectDict(w.frame), "key": w.isKeyWindow,
             "card": (w.contentView as? CardContent)?.cardID ?? -1,
             "children": w.childWindows?.count ?? 0] as [String: Any] }]
    }
}

// MARK: - Layout engine + animation driver (shared)

final class Engine: NSObject {
    static let shared = Engine()
    var structure: Structure!
    var sidebar: CardContent!
    var cards: [CardContent] = []
    var focused: CardContent?
    var layout = opts.layout
    var material = opts.material
    var nextID = 1
    let gap: CGFloat = 12, sidebarWidth: CGFloat = 240

    // animation state
    var from: [ObjectIdentifier: NSRect] = [:], to: [ObjectIdentifier: NSRect] = [:], current: [ObjectIdentifier: NSRect] = [:]
    var animStart: CFTimeInterval = 0, animating = false
    let duration: CFTimeInterval = opts.duration
    var link: CADisplayLink?
    var tickTimes: [CFTimeInterval] = [], applyCost: [CFTimeInterval] = []

    func start() {
        Wallpaper.shared.load(for: NSScreen.main!, blurPoints: opts.blur)
        structure = opts.mode == "B" ? WindowsStructure() : ContainerStructure()
        sidebar = CardContent(id: 0, sidebar: true, material: material)
        structure.add(sidebar, sidebar: true)
        for _ in 0..<opts.cards { addCard(animated: false) }
        relayout(animated: false)
        focus(cardID: cards.first?.cardID ?? 0, via: "start")
    }

    func targetRects() -> [(CardContent, NSRect)] {
        let a = NSScreen.main!.visibleFrame
        let g = gap
        let sb = NSRect(x: a.minX + g, y: a.minY + g, width: sidebarWidth, height: a.height - 2 * g)
        var out: [(CardContent, NSRect)] = [(sidebar, sb)]
        let rest = NSRect(x: sb.maxX + g, y: a.minY + g, width: a.maxX - g - (sb.maxX + g), height: a.height - 2 * g)
        let n = cards.count
        guard n > 0 else { return out }
        if layout == "columns" || n == 1 {
            let w = (rest.width - CGFloat(n - 1) * g) / CGFloat(n)
            for (i, c) in cards.enumerated() {
                out.append((c, NSRect(x: rest.minX + CGFloat(i) * (w + g), y: rest.minY, width: w, height: rest.height).integral))
            }
        } else {
            let mw = (rest.width - g) / 2
            out.append((cards[0], NSRect(x: rest.minX, y: rest.minY, width: mw, height: rest.height)))
            let m = n - 1
            let h = (rest.height - CGFloat(m - 1) * g) / CGFloat(m)
            for i in 0..<m {   // top to bottom
                let y = rest.maxY - CGFloat(i + 1) * h - CGFloat(i) * g
                out.append((cards[i + 1], NSRect(x: rest.minX + mw + g, y: y, width: mw, height: h).integral))
            }
        }
        return out
    }

    func relayout(animated: Bool) {
        let t = targetRects()
        if !animated {
            for (c, r) in t { current[ObjectIdentifier(c)] = r }
            structure.apply(t, final: true)
            emitLayout(); return
        }
        from = [:]; to = [:]
        for (c, r) in t {
            let k = ObjectIdentifier(c)
            from[k] = current[k] ?? NSRect(x: r.midX - 20, y: r.midY - 20, width: 40, height: 40)
            to[k] = r
        }
        animStart = CACurrentMediaTime(); animating = true
        tickTimes = []; applyCost = []
        if link == nil {
            link = NSScreen.main!.displayLink(target: self, selector: #selector(tick))
            link!.add(to: .main, forMode: .common)
        }
        link!.isPaused = false
    }

    @objc func tick(_ l: CADisplayLink) {
        guard animating else { link?.isPaused = true; return }
        let now = CACurrentMediaTime()
        tickTimes.append(now)
        var p = min(1, (now - animStart) / duration)
        p = 1 - pow(1 - p, 3)   // ease-out cubic
        let final = p >= 1
        var rects: [(CardContent, NSRect)] = []
        for c in [sidebar!] + cards {
            let k = ObjectIdentifier(c)
            guard let f = from[k], let t = to[k] else { continue }
            let r = NSRect(x: f.minX + (t.minX - f.minX) * p, y: f.minY + (t.minY - f.minY) * p,
                           width: f.width + (t.width - f.width) * p, height: f.height + (t.height - f.height) * p)
            let rr = final ? t : NSRect(x: r.minX.rounded(), y: r.minY.rounded(), width: r.width.rounded(), height: r.height.rounded())
            current[k] = rr
            rects.append((c, rr))
        }
        let s = CACurrentMediaTime()
        structure.apply(rects, final: final)
        applyCost.append(CACurrentMediaTime() - s)
        if final {
            animating = false
            link?.isPaused = true
            let dts = zip(tickTimes.dropFirst(), tickTimes).map { ($0 - $1) * 1000 }
            emit(["ev": "anim", "frames": tickTimes.count, "maxFrameGapMs": dts.max() ?? 0,
                  "meanApplyMs": applyCost.reduce(0, +) / Double(max(1, applyCost.count)) * 1000,
                  "maxApplyMs": (applyCost.max() ?? 0) * 1000])
            emitLayout()
        }
    }

    func addCard(animated: Bool) {
        let c = CardContent(id: nextID, sidebar: false, material: material)
        nextID += 1
        cards.append(c)
        structure.add(c, sidebar: false)
        if animated { relayout(animated: true); focus(cardID: c.cardID, via: "add") }
    }
    func removeFocused() {
        guard let f = focused, let i = cards.firstIndex(where: { $0 === f }) else { return }
        cards.remove(at: i)
        structure.remove(f)
        current.removeValue(forKey: ObjectIdentifier(f))
        relayout(animated: true)
        if !cards.isEmpty { focus(cardID: cards[max(0, i - 1)].cardID, via: "remove") }
    }
    func focusNext() {
        let all = cards
        guard !all.isEmpty else { return }
        let i = focused.flatMap { f in all.firstIndex { $0 === f } } ?? -1
        focus(cardID: all[(i + 1) % all.count].cardID, via: "tab")
    }
    func focus(cardID: Int, via: String) {
        guard let c = ([sidebar!] + cards).first(where: { $0.cardID == cardID }) else { return }
        structure.focus(c)
        focusChanged(to: c, via: via)
    }
    func focusChanged(to c: CardContent, via: String) {
        if focused === c { return }
        focused?.focused = false
        focused = c
        c.focused = true
        emit(["ev": "focus", "card": c.cardID, "via": via, "keyWindow": NSApp.keyWindow?.windowNumber ?? -1])
    }
    func cycleMaterial() {
        let all = ["glass", "vibrancy", "liquid", "solid"]
        material = all[((all.firstIndex(of: material) ?? 0) + 1) % all.count]
        for c in [sidebar!] + cards { c.material = material }
        emit(["ev": "material", "material": material])
    }
    func emitLayout() {
        var d = structure.dump()
        d["ev"] = "layout"
        d["mode"] = opts.mode
        d["cards"] = targetRects().map { ["id": $0.0.cardID, "rect": rectDict($0.1)] }
        d["focused"] = focused?.cardID ?? -1
        d["keyWindow"] = NSApp.keyWindow?.windowNumber ?? -1
        d["pid"] = ProcessInfo.processInfo.processIdentifier
        emit(d)
    }

    func command(_ s: String) {
        switch s {
        case "add": addCard(animated: true)
        case "remove": removeFocused()
        case "next": focusNext()
        case "layout": layout = layout == "master" ? "columns" : "master"; relayout(animated: true)
        case "material": cycleMaterial()
        case "dump": emitLayout()
        case "quit": NSApp.terminate(nil)
        default: if s.hasPrefix("material:") { material = String(s.dropFirst(9)); for c in [sidebar!] + cards { c.material = material } }
        }
    }
}

// MARK: - Backdrop: a plain titled window that plays "another app behind the gaps"

final class BackdropView: NSView {
    override func draw(_ r: NSRect) {
        NSColor(calibratedRed: 0.85, green: 0.25, blue: 0.2, alpha: 1).setFill(); bounds.fill()
        let s = NSAttributedString(string: "BACKDROP (other process)", attributes: [.font: NSFont.boldSystemFont(ofSize: 28), .foregroundColor: NSColor.white])
        s.draw(at: NSPoint(x: 30, y: bounds.midY))
    }
    override func mouseDown(with e: NSEvent) {
        emit(["ev": "backdropMouseDown", "at": ["x": Double(NSEvent.mouseLocation.x), "y": Double(mainScreenHeight - NSEvent.mouseLocation.y)]])
    }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var backdropWindow: NSWindow?
    func applicationDidFinishLaunching(_ n: Notification) {
        Timer.scheduledTimer(withTimeInterval: opts.autoquit, repeats: false) { _ in NSApp.terminate(nil) }
        if let b = opts.backdrop {
            let w = NSWindow(contentRect: fromCG(b), styleMask: [.titled], backing: .buffered, defer: false)
            w.title = "Backdrop"
            w.contentView = BackdropView()
            w.setFrame(fromCG(b), display: true)
            w.makeKeyAndOrderFront(nil)
            backdropWindow = w
            NSApp.activate(ignoringOtherApps: true)
            emit(["ev": "backdrop", "num": w.windowNumber, "pid": ProcessInfo.processInfo.processIdentifier])
            return
        }
        Engine.shared.start()
        NSApp.activate(ignoringOtherApps: true)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard !e.modifierFlags.contains(.command) else { return e }
            switch e.charactersIgnoringModifiers {
            case "n": Engine.shared.command("add")
            case "w": Engine.shared.command("remove")
            case "\t": Engine.shared.command("next")
            case "l": Engine.shared.command("layout")
            case "m": Engine.shared.command("material")
            case "q": Engine.shared.command("quit")
            default: emit(["ev": "key", "chars": e.characters ?? "", "keyWindow": NSApp.keyWindow?.windowNumber ?? -1,
                           "focusedCard": Engine.shared.focused?.cardID ?? -1]); return e
            }
            return nil
        }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { e in
            let hit = e.window?.contentView?.hitTest(e.locationInWindow)
            var v: NSView? = hit
            while let x = v, !(x is CardContent) { v = x.superview }
            emit(["ev": "mouseDown", "window": e.window?.windowNumber ?? -1, "card": (v as? CardContent)?.cardID ?? -1,
                  "hitClass": hit.map { String(describing: type(of: $0)) } ?? "nil"])
            return e
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("meum.spike.cmd"), object: nil, queue: .main) { n in
            if let s = n.object as? String { Engine.shared.command(s) }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            emit(["ev": "didBecomeKey", "window": (n.object as? NSWindow)?.windowNumber ?? -1])
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in emit(["ev": "appActive"]) }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in emit(["ev": "appInactive"]) }
        emit(["ev": "ready", "mode": opts.mode, "material": opts.material, "pid": ProcessInfo.processInfo.processIdentifier])
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
