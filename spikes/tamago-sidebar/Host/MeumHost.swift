// meum host for Tamago's sidebar: the floating-layout spike (approach A, trimmed to mode A) with the
// sidebar card's placeholder replaced by Tamago's SwiftUI view, compiled unchanged from
// tamago/extension/Sources against the local CmuxExtensionKit shim.
//
// Data, all read-only towards Max's real setup:
//   workspaces  `cmux rpc extension.sidebar.snapshot '{}'` every 2 s (fixture file if refused)
//   Tama        Tamago's own DaemonClient GETs 127.0.0.1:47321/state (fixture if --daemon fixture)
//   actions     every non-GET request (Tamago's POST /action) is caught by BlockActions and logged,
//               never sent. Selecting a workspace is logged and shown locally, never sent to cmux.
//
// Keys:  n add card  w remove card  Tab next card  l layout  m material  q quit
// Args:  --material glass|vibrancy|liquid|solid  --cards N  --layout master|columns  --autoquit S
//        --blur PT  --tint 0..1  --feed cmux|fixture  --daemon live|fixture  --selftest
// Remote: distributed notification "meum.tamago.cmd" with object = add|remove|next|layout|material|dump|quit|material:<m>
// Output: one JSON line per event on stdout.

import AppKit
import CoreImage
import QuartzCore
import SwiftUI
import CmuxExtensionKit

func emit(_ d: [String: Any]) {
    var d = d
    d["t"] = (CACurrentMediaTime() * 1000).rounded() / 1000
    if let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]),
       let s = String(data: data, encoding: .utf8) { print(s) }
}

// MARK: - Arguments

struct Options {
    var material = "glass"
    var cards = 2
    var layout = "master"
    var autoquit: Double = 60
    var blur: CGFloat = 4
    var tint: CGFloat = 0.35
    var duration: Double = 0.22
    var feed = "cmux"
    var daemon = "live"
    var selftest = false

    init() {
        let a = CommandLine.arguments
        func v(_ f: String) -> String? { a.firstIndex(of: f).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        material = v("--material") ?? material
        cards = Int(v("--cards") ?? "") ?? cards
        layout = v("--layout") ?? layout
        autoquit = Double(v("--autoquit") ?? "") ?? autoquit
        blur = CGFloat(Double(v("--blur") ?? "") ?? Double(blur))
        tint = CGFloat(Double(v("--tint") ?? "") ?? Double(tint))
        duration = Double(v("--duration") ?? "") ?? duration
        feed = v("--feed") ?? feed
        daemon = v("--daemon") ?? daemon
        selftest = a.contains("--selftest")
    }
}
let opts = Options()

let mainScreenHeight = NSScreen.screens[0].frame.height
func toCG(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: mainScreenHeight - r.maxY, width: r.width, height: r.height) }
func rectDict(_ r: NSRect) -> [String: Double] {
    let c = toCG(r); return ["x": Double(c.minX), "y": Double(c.minY), "w": Double(c.width), "h": Double(c.height)]
}
let resourcesDir = Bundle.main.resourceURL!

// MARK: - Adapter 1: block every action Tamago sends to its daemon

/// Catches every request that isn't a GET (Tamago's only other request is POST /action) before it
/// leaves the process, logs it and answers 200 {"ok":true}, so Tamago behaves as if it worked.
/// With --daemon fixture it also answers GET /state from fixtures/state.json.
/// URLProtocol.registerClass applies to URLSession.shared, which DaemonClient uses.
final class BlockActions: URLProtocol {
    override class func canInit(with r: URLRequest) -> Bool {
        if r.httpMethod != "GET" { return true }
        return opts.daemon == "fixture" && r.url?.path == "/state"
    }
    override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
    override func startLoading() {
        let url = request.url!
        var body: Data
        if request.httpMethod == "GET" {
            body = (try? Data(contentsOf: resourcesDir.appendingPathComponent("state.json"))) ?? Data("{}".utf8)
            emit(["ev": "daemonFixture", "url": url.absoluteString])
        } else {
            var sent = request.httpBody ?? Data()
            if sent.isEmpty, let s = request.httpBodyStream {
                s.open(); var buf = [UInt8](repeating: 0, count: 16384)
                while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; sent.append(buf, count: n) }
                s.close()
            }
            emit(["ev": "actionBlocked", "method": request.httpMethod ?? "?", "url": url.absoluteString,
                  "body": String(data: sent, encoding: .utf8) ?? "<\(sent.count) bytes>"])
            body = Data(#"{"ok":true,"blockedBy":"meum-spike"}"#.utf8)
        }
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// MARK: - Adapter 2: workspaces from the running cmux, read-only

/// Polls `cmux rpc extension.sidebar.snapshot '{}'` and maps its snake_case JSON to the shim's
/// CmuxSidebarSnapshot. Falls back to fixtures/snapshot.json if cmux refuses or isn't there.
@MainActor
final class CmuxFeed {
    nonisolated static let cli = "/Applications/cmux.app/Contents/Resources/bin/cmux"
    var onSnapshot: ((CmuxSidebarSnapshot, String) -> Void)?
    private var timer: Timer?
    private var lastSource = ""
    private var titles: [UUID: String] = [:]

    func title(_ id: UUID) -> String { titles[id] ?? "?" }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
    }

    private func tick() {
        let useCmux = opts.feed == "cmux"
        DispatchQueue.global().async {
            var data: Data?
            var source = "fixture"
            var error = ""
            if useCmux {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: Self.cli)
                p.arguments = ["rpc", "extension.sidebar.snapshot", "{}"]
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err
                do {
                    try p.run()
                    let d = out.fileHandleForReading.readDataToEndOfFile()
                    let e = err.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    if p.terminationStatus == 0 { data = d; source = "cmux" } else { error = String(data: e, encoding: .utf8) ?? "exit \(p.terminationStatus)" }
                } catch let e { error = "\(e)" }
            }
            if data == nil { data = try? Data(contentsOf: resourcesDir.appendingPathComponent("snapshot.json")); source = "fixture" }
            let snap = data.flatMap(Self.map)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let snap else { emit(["ev": "feedError", "error": error]); return }
                    for w in snap.workspaces { self.titles[w.id] = w.title }
                    if source != self.lastSource {
                        self.lastSource = source
                        emit(["ev": "feed", "source": source, "workspaces": snap.workspaces.count,
                              "selected": snap.selectedWorkspaceID.map { self.title($0) } ?? "-", "cmuxError": error])
                    }
                    self.onSnapshot?(snap, source)
                }
            }
        }
    }

    nonisolated static func map(_ data: Data) -> CmuxSidebarSnapshot? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ws = j["workspaces"] as? [[String: Any]] else { return nil }
        let workspaces: [CmuxSidebarWorkspace] = ws.compactMap { w in
            guard let id = (w["id"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
            let branches = w["git_branches"] as? [Any] ?? []
            let branch = (branches.first as? String) ?? ((branches.first as? [String: Any])?["branch"] as? String)
                ?? (w["branch_summary"] as? String)
            return CmuxSidebarWorkspace(id: id, title: w["title"] as? String ?? "", isPinned: w["pinned"] as? Bool ?? false,
                                        gitBranch: branch, unreadCount: w["unread_count"] as? Int ?? 0)
        }
        let seq = (j["sequence"] as? NSNumber)?.uint64Value ?? 0
        let sel = (j["selected_workspace_id"] as? String).flatMap(UUID.init(uuidString:))
        return CmuxSidebarSnapshot(sequence: seq, selectedWorkspaceID: sel, workspaces: workspaces)
    }
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

// MARK: - Cards

let fakeLines = [
    "max@amo ~/code/meum (main) $ ls spikes",
    "claude-hooks  floating-layout  ghostty-zmx  tamago-sidebar",
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
    let title = NSTextField(labelWithString: "")
    /// The sidebar card's content: Tamago's SwiftUI view.
    var hosted: NSView? { didSet { oldValue?.removeFromSuperview(); if let hosted { addSubview(hosted) }; label.isHidden = hosted != nil; title.isHidden = hosted != nil; needsLayout = true } }
    var material: String { didSet { applyMaterial() } }
    var focused = false { didSet { updateBorder() } }
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
        title.stringValue = "term \(id)"
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = NSColor(white: 0.9, alpha: 1)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byClipping
        label.stringValue = fakeLines.joined(separator: "\n")
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
        // Tamago draws its own row insets; give it the whole card below a small top margin.
        hosted?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 8)
        positionWallpaper()
    }
    override func mouseDown(with e: NSEvent) { Engine.shared.focus(cardID: cardID, via: "click") }
}

// MARK: - Mode A container window

final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class Container {
    let window: KeyableWindow
    let root = NSView()
    var hosts: [ObjectIdentifier: NSView] = [:]

    init() {
        let vf = NSScreen.main!.visibleFrame
        window = KeyableWindow(contentRect: vf, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.managed, .fullScreenNone]
        root.wantsLayer = true
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
    }

    func add(_ c: CardContent) {
        let host = NSView()
        host.wantsLayer = true
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

    func apply(_ rects: [(CardContent, NSRect)]) {
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
    func focus(_ c: CardContent) { window.makeKeyAndOrderFront(nil) }
}

// MARK: - Layout engine + animation driver

final class Engine: NSObject {
    static let shared = Engine()
    var container: Container!
    var sidebar: CardContent!
    var cards: [CardContent] = []
    var focused: CardContent?
    var layout = opts.layout
    var material = opts.material
    var nextID = 1
    let gap: CGFloat = 12, sidebarWidth: CGFloat = 240

    var from: [ObjectIdentifier: NSRect] = [:], to: [ObjectIdentifier: NSRect] = [:], current: [ObjectIdentifier: NSRect] = [:]
    var animStart: CFTimeInterval = 0, animating = false
    var link: CADisplayLink?

    func start(sidebarContent: NSView) {
        Wallpaper.shared.load(for: NSScreen.main!, blurPoints: opts.blur)
        container = Container()
        sidebar = CardContent(id: 0, sidebar: true, material: material)
        sidebar.hosted = sidebarContent
        container.add(sidebar)
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
            for i in 0..<m {
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
            container.apply(t)
            emitLayout(); return
        }
        from = [:]; to = [:]
        for (c, r) in t {
            let k = ObjectIdentifier(c)
            from[k] = current[k] ?? NSRect(x: r.midX - 20, y: r.midY - 20, width: 40, height: 40)
            to[k] = r
        }
        animStart = CACurrentMediaTime(); animating = true
        if link == nil {
            link = NSScreen.main!.displayLink(target: self, selector: #selector(tick))
            link!.add(to: .main, forMode: .common)
        }
        link!.isPaused = false
    }

    @objc func tick(_ l: CADisplayLink) {
        guard animating else { link?.isPaused = true; return }
        var p = min(1, (CACurrentMediaTime() - animStart) / opts.duration)
        p = 1 - pow(1 - p, 3)
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
        container.apply(rects)
        if final { animating = false; link?.isPaused = true; emitLayout() }
    }

    func addCard(animated: Bool) {
        let c = CardContent(id: nextID, sidebar: false, material: material)
        nextID += 1
        cards.append(c)
        container.add(c)
        if animated { relayout(animated: true); focus(cardID: c.cardID, via: "add") }
    }
    func removeFocused() {
        guard let f = focused, let i = cards.firstIndex(where: { $0 === f }) else { return }
        cards.remove(at: i)
        container.remove(f)
        current.removeValue(forKey: ObjectIdentifier(f))
        relayout(animated: true)
        if !cards.isEmpty { focus(cardID: cards[max(0, i - 1)].cardID, via: "remove") }
    }
    func focusNext() {
        guard !cards.isEmpty else { return }
        let i = focused.flatMap { f in cards.firstIndex { $0 === f } } ?? -1
        focus(cardID: cards[(i + 1) % cards.count].cardID, via: "tab")
    }
    func focus(cardID: Int, via: String) {
        guard let c = ([sidebar!] + cards).first(where: { $0.cardID == cardID }) else { return }
        container.focus(c)
        if focused === c { return }
        focused?.focused = false
        focused = c
        c.focused = true
    }
    func setMaterial(_ m: String) {
        material = m
        for c in [sidebar!] + cards { c.material = m }
        emit(["ev": "material", "material": m])
    }
    func emitLayout() {
        emit(["ev": "layout", "window": container.window.windowNumber, "windowFrame": rectDict(container.window.frame),
              "cards": targetRects().map { ["id": $0.0.cardID, "rect": rectDict($0.1)] },
              "pid": ProcessInfo.processInfo.processIdentifier])
    }

    func command(_ s: String) {
        switch s {
        case "add": addCard(animated: true)
        case "remove": removeFocused()
        case "next": focusNext()
        case "layout": layout = layout == "master" ? "columns" : "master"; relayout(animated: true)
        case "material":
            let all = ["glass", "vibrancy", "liquid", "solid"]
            setMaterial(all[((all.firstIndex(of: material) ?? 0) + 1) % all.count])
        case "dump": emitLayout()
        case "quit": NSApp.terminate(nil)
        default: if s.hasPrefix("material:") { setMaterial(String(s.dropFirst(9))) }
        }
    }
}

// MARK: - The host the shim's `main()` finds by name

@objc(MeumSidebarHostApp)
final class MeumSidebarHostApp: NSObject, CmuxShimHostApp, NSApplicationDelegate {
    nonisolated(unsafe) static var keep: [AnyObject] = []

    static func run(sidebar ext: any CmuxSidebarExtension, body: AnyView) {
        setvbuf(stdout, nil, _IOLBF, 0)
        URLProtocol.registerClass(BlockActions.self)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.appearance = NSAppearance(named: .darkAqua)
        let delegate = MeumSidebarHostApp()
        let feed = CmuxFeed()
        keep = [delegate, feed, ext]
        app.delegate = delegate

        // Selection stays local: cmux is never told. The latest click wins over cmux's own selection.
        var localSelection: UUID?
        var last: CmuxSidebarSnapshot?
        let host = CmuxSidebarHost { id in
            emit(["ev": "selectWorkspace", "id": id.uuidString, "title": feed.title(id), "forwardedToCmux": false])
            localSelection = id
            Engine.shared.cards.first?.title.stringValue = "term 1 · \(feed.title(id))"
            if var s = last { s.selectedWorkspaceID = id; ext.update(context: CmuxSidebarContext(snapshot: s, host: hostRef!)) }
        }
        hostRef = host
        feed.onSnapshot = { snap, _ in
            var s = snap
            if let localSelection, s.workspaces.contains(where: { $0.id == localSelection }) { s.selectedWorkspaceID = localSelection }
            last = s
            ext.update(context: CmuxSidebarContext(snapshot: s, host: host))
        }

        let manifest = type(of: ext).manifest
        emit(["ev": "extension", "id": manifest.id, "name": manifest.displayName,
              "readScopes": manifest.readScopes.map(\.rawValue), "actionScopes": manifest.actionScopes.map(\.rawValue)])

        let hosting = NSHostingView(rootView: body.environment(\.colorScheme, .dark))
        delegate.onLaunch = {
            Engine.shared.start(sidebarContent: hosting)
            feed.start()
            if opts.selftest { selfTest() }
        }
        app.run()
    }
    nonisolated(unsafe) static var hostRef: CmuxSidebarHost?

    var onLaunch: (() -> Void)?

    func applicationDidFinishLaunching(_ n: Notification) {
        Timer.scheduledTimer(withTimeInterval: opts.autoquit, repeats: false) { _ in NSApp.terminate(nil) }
        onLaunch?()
        NSApp.activate(ignoringOtherApps: true)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            // Typing into a text field (Tamago's rename) must not trigger layout keys.
            if e.modifierFlags.contains(.command) || NSApp.keyWindow?.firstResponder is NSText { return e }
            switch e.charactersIgnoringModifiers {
            case "n": Engine.shared.command("add")
            case "w": Engine.shared.command("remove")
            case "\t": Engine.shared.command("next")
            case "l": Engine.shared.command("layout")
            case "m": Engine.shared.command("material")
            case "q": Engine.shared.command("quit")
            default: return e
            }
            return nil
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("meum.tamago.cmd"), object: nil, queue: .main) { n in
            if let s = n.object as? String { MainActor.assumeIsolated { Engine.shared.command(s) } }
        }
        emit(["ev": "ready", "pid": ProcessInfo.processInfo.processIdentifier, "feed": opts.feed, "daemon": opts.daemon])
    }

    /// Proves the action block without touching the real daemon: a POST shaped exactly like
    /// DaemonClient's, sent through URLSession.shared to a port nothing listens on. Blocked = 200
    /// from BlockActions; not blocked = connection refused.
    static func selfTest() {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:47399/action")!)
        r.httpMethod = "POST"
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["type": "touch", "kind": "feed"])
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 3
        Task {
            do {
                let (d, resp) = try await URLSession.shared.data(for: r)
                emit(["ev": "selftest", "blocked": (resp as? HTTPURLResponse)?.statusCode == 200, "reply": String(data: d, encoding: .utf8) ?? ""])
            } catch {
                emit(["ev": "selftest", "blocked": false, "error": "\(error)"])
            }
        }
    }
}
