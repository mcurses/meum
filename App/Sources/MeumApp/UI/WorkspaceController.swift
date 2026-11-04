import AppKit
import MeumControl
import MeumCore
import QuartzCore

/// Owns the container window and keeps it in step with the store: one card view per card of the selected
/// workspace, one libghostty surface per tab of that workspace (hidden workspaces have none), animated
/// relayout, keyboard focus, the sidebar and the user actions behind the menu keys.
@MainActor
final class WorkspaceController: NSObject, SidebarHost {
    let store: WorkspaceStore
    let sessions: ZmxSessions
    var agents: AgentStateSource
    /// Tabs running claude that meum hears nothing from (AppControl.refreshSilentAgents); a hollow dot marks them.
    var silentAgentTabs: Set<UUID> = [] { didSet { if silentAgentTabs != oldValue { refreshChrome() } } }
    let paths: StatePaths
    let window: ContainerWindow
    let root = RootView()
    let sidebarCard = SidebarCardView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
    /// The widget cards under the sidebar, top to bottom (`WidgetManager` owns them).
    private(set) var widgetCards: [WidgetSlotCardView] = []
    /// The built-in Tips widget: first in the widget stack while `showStartHint` is on.
    let tipsCard = WidgetSlotCardView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
    private(set) var cardViews: [UUID: TerminalCardView] = [:]
    private(set) var shownWorkspaceID: UUID?
    private let emptyHint = NSTextField(labelWithString: "")
    private let fixedFrame: CGRect?

    static let animationDuration: CFTimeInterval = 0.2
    /// The smallest a card gets when a split is resized with the mouse.
    static let minCardSize: CGFloat = 140

    /// The live settings (layout values are read from here; `applySettings` reacts to changes).
    var settings = Settings()
    var gap: CGFloat { CGFloat(settings.cardGap) }
    /// The sidebar's width as laid out: the narrow rail while collapsed.
    var sidebarWidth: CGFloat { settings.sidebarCollapsed ? Self.railWidth : CGFloat(settings.sidebarWidth) }
    /// The collapsed sidebar's width: workspace icons, and the widgets' collapsed looks.
    static let railWidth: CGFloat = 60
    /// Changes a setting through the live settings (saved, applied, published). Set by the control layer.
    var setSetting: ((String, JSON) -> Void)?

    /// Collapses or expands the sidebar (menu, shortcut, API). Goes through the settings, so it is saved.
    func setSidebarCollapsed(_ collapsed: Bool) {
        if collapsed { sidebarCard.sidebar.endEditing(commit: true) }
        setSetting?("sidebarCollapsed", .bool(collapsed))
    }
    /// A widget card's height; nil when the widget hid it (`setPreferredHeight(0)`).
    func widgetHeight(_ card: WidgetSlotCardView) -> CGFloat? {
        if card.requestedHeight() == 0 { return nil }
        if card === tipsCard { return card.requestedHeight() }
        return settings.widgetHeightAuto ? (card.preferredHeight ?? 150) : CGFloat(settings.widgetHeight)
    }

    /// Replaces the widget cards (after a widget reload or reorder).
    func setWidgetCards(_ installed: [WidgetSlotCardView]) {
        let cards = [tipsCard] + installed
        for v in widgetCards where !cards.contains(where: { $0 === v }) {
            v.removeFromSuperview()
            currentFrames[ObjectIdentifier(v)] = nil
        }
        for v in cards where v.superview == nil {
            v.glass.reloadWallpaper()
            root.addSubview(v, positioned: .above, relativeTo: sidebarCard)
        }
        widgetCards = cards
    }

    /// Split ratios while a divider is dragged: layout uses them, the store gets the final one on mouse-up.
    var liveRatios: [UUID: Double] = [:]
    var dividerViews: [UUID: DividerView] = [:]
    /// The tab being dragged out of a strip, with its drop feedback.
    var tabDrag: TabDrag?
    let dropOverlay = DropOverlayView()

    /// Tells the control layer a status entry was clicked (it publishes `status.clicked`).
    var onStatusClicked: ((UUID, String, StatusEntry) -> Void)?
    /// Opens a status entry's link. A debug instance records it instead (`openedURLs`), so tests open nothing.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private var widgetClickMonitor: Any?
    /// The widget host, told when the selected workspace changes.
    weak var widgets: WidgetManager?
    /// Called after every reconcile (the debug interface uses it to log).
    var afterReconcile: (() -> Void)?
    /// Per-workspace data outside the model (git branch, status entries), written by the control layer.
    var workspaceExtras: [UUID: WorkspaceExtras] = [:] { didSet { if workspaceExtras != oldValue { refreshChrome() } } }
    /// Prepended to PATH in every new tab (the bundle's bin/ with `meum` and `meum-hook`).
    var tabBinDir: String?

    init(store: WorkspaceStore, sessions: ZmxSessions, agents: AgentStateSource, paths: StatePaths,
         frame: CGRect?) {
        self.store = store
        self.sessions = sessions
        self.agents = agents
        self.paths = paths
        self.fixedFrame = frame
        let screen = NSScreen.main ?? NSScreen.screens[0]
        window = ContainerWindow(frame: frame ?? screen.visibleFrame)
        super.init()
        Wallpaper.shared.load(for: screen)
        // the sidebar and widget cards exist before the wallpaper is loaded
        sidebarCard.glass.reloadWallpaper()
        root.frame = NSRect(origin: .zero, size: window.frame.size)
        root.wantsLayer = true
        root.catchClicks = settings.gapsCatchClicks
        window.contentView = root
        root.addSubview(sidebarCard)
        sidebarCard.sidebar.host = self
        emptyHint.stringValue = "No tabs. ⌘T opens one."
        emptyHint.textColor = NSColor(white: 1, alpha: 0.6)
        emptyHint.font = .systemFont(ofSize: 14, weight: .medium)
        emptyHint.isHidden = true
        root.addSubview(emptyHint)
        let hint = StartHintView(frame: .zero)
        hint.onClose = { [weak self] in self?.setSetting?("showStartHint", .bool(false)) }
        tipsCard.host(hint)
        tipsCard.requestedHeight = { [weak self, weak hint] in
            guard let self, let hint, self.settings.showStartHint, !self.settings.sidebarCollapsed else { return 0 }
            return hint.height(forWidth: self.sidebarWidth)
        }
        tipsCard.glass.reloadWallpaper()
        root.addSubview(tipsCard, positioned: .above, relativeTo: sidebarCard)
        widgetCards = [tipsCard]
        dropOverlay.frame = root.bounds
        dropOverlay.autoresizingMask = [.width, .height]
        root.addSubview(dropOverlay)

        store.onChange = { [weak self] change in
            switch change {
            case .structure(let animate): self?.reconcile(animate: animate)
            case .cosmetic: self?.refreshChrome()
            }
        }
        agents.onChange = { [weak self] in self?.refreshChrome() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanged() }
        }
    }

    func start() {
        watchWidgetClicks()
        if store.state.workspaces.isEmpty {
            store.mutate(.structure(animate: false)) { $0.addWorkspace(.make(name: "Workspace 1", cwd: NSHomeDirectory())) }
        }
        window.makeKeyAndOrderFront(nil)
        reconcile(animate: false)
    }

    private var wallpaperWork: DispatchWorkItem?

    /// Applies settings live: geometry (gap, sidebar, widget), card look (radius, background), click-through.
    func applySettings(_ new: Settings, old: Settings?) {
        settings = new
        if old?.showStartHint != new.showStartHint, old != nil { reconcile(animate: true) }
        root.catchClicks = new.gapsCatchClicks
        var a = CardAppearance.current
        a.radius = CGFloat(new.cornerRadius)
        a.background = new.background
        a.wallpaper = new.wallpaper
        a.liquidStyle = new.liquidStyle
        a.frameSaturation = CGFloat(new.focusFrameSaturation)
        a.frameOpacity = CGFloat(new.focusFrameOpacity)
        a.tint = CGFloat(new.glassTint)
        a.solid = SidebarView.nsColor(hex: new.solidColor) ?? a.solid
        let looks = a != CardAppearance.current || old == nil
        CardAppearance.current = a
        if looks { for v in allCardHosts { v.applyAppearance() } }
        if let old, old.glassBlur != new.glassBlur {
            // re-blurring the wallpaper takes a moment: once the slider rests
            wallpaperWork?.cancel()
            let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.reloadWallpaper() } }
            wallpaperWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: w)
        } else if old == nil {
            Wallpaper.shared.blur = CGFloat(new.glassBlur)
        }
        sidebarCard.sidebar.collapsed = new.sidebarCollapsed
        sidebarCard.sidebar.display = SidebarDisplay(new)
        guard let old else { return }   // the first call comes before start(), which lays out
        if old.sidebarCollapsed != new.sidebarCollapsed {
            // widgets learn about the rail first, so a card's new preferred height is in the same animation
            widgets?.hostStateChanged()
            reconcile(animate: true)
            return
        }
        if old.cardGap == new.cardGap, old.sidebarWidth == new.sidebarWidth,
           old.widgetHeight == new.widgetHeight, old.widgetHeightAuto == new.widgetHeightAuto,
           old.widgetOrder == new.widgetOrder { return }
        reconcile(animate: false)
    }

    var allCardHosts: [CardHostView] { [sidebarCard] + widgetCards + Array(cardViews.values) }

    private func reloadWallpaper() {
        Wallpaper.shared.blur = CGFloat(settings.glassBlur)
        Wallpaper.shared.load(for: window.screen ?? NSScreen.main ?? NSScreen.screens[0])
        for v in allCardHosts { v.glass.reloadWallpaper() }
    }

    private func screenChanged() {
        guard fixedFrame == nil, let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(screen.visibleFrame, display: true)
        root.frame = NSRect(origin: .zero, size: window.frame.size)
        Wallpaper.shared.load(for: screen)
        for v in allCardHosts { v.glass.reloadWallpaper() }
        reconcile(animate: false)
    }

    // MARK: - Reconcile

    var selectedWorkspace: Workspace? { store.state.selectedWorkspace }

    /// Brings views and surfaces in line with the model.
    func reconcile(animate: Bool) {
        var animate = animate
        let ws = selectedWorkspace
        if ws?.id != shownWorkspaceID {
            parkCards()
            shownWorkspaceID = ws?.id
            animate = false
            // a workspace shown before comes back with its own card views: surfaces still attached, nothing replays
            if let id = ws?.id, let parked = parkedCards.removeValue(forKey: id) {
                cardViews = parked
                for v in parked.values { root.addSubview(v, positioned: .below, relativeTo: emptyHint) }
            }
        }
        prunePark()
        let targets = targetFrames(for: ws)
        var newCards: Set<UUID> = []
        var liveSessions: Set<String>?

        if let ws {
            let wanted = Set(ws.cards.map(\.id))
            // A tab that moved to another card keeps its surface: detach it into a pool and re-add it below.
            // The libghostty surface and its zmx client survive the move; nothing restarts.
            let wantedTabs = Set(ws.allTabs.map(\.id))
            var pool: [UUID: SurfaceView] = [:]
            for (id, v) in cardViews {
                let keep = Set(ws.card(id)?.tabs.map(\.id) ?? [])
                for tab in Array(v.surfaces.keys) where !keep.contains(tab) {
                    guard let s = v.remove(tab: tab) else { continue }
                    if wantedTabs.contains(tab) { pool[tab] = s } else { s.destroySurface() }
                }
            }
            // widget tabs: detach views from cards that no longer hold the tab; drop instances of closed tabs
            for v in cardViews.values {
                let keep = Set(ws.card(v.cardID)?.tabs.map(\.id) ?? [])
                for tab in Array(v.widgetViews.keys) where !keep.contains(tab) {
                    v.removeWidget(tab: tab)
                }
            }
            for (id, v) in cardViews where !wanted.contains(id) {
                v.removeFromSuperview()
                cardViews[id] = nil
                currentFrames[ObjectIdentifier(v)] = nil
            }
            for card in ws.cards {
                let v: TerminalCardView
                if let existing = cardViews[card.id] {
                    v = existing
                } else {
                    v = makeCardView(card.id)
                    cardViews[card.id] = v
                    root.addSubview(v, positioned: .below, relativeTo: emptyHint)
                    // new cards start at their final frame (so surfaces attach at their real size) and fade in
                    if let t = targets[.card(card.id)] { place(v, t) }
                    newCards.insert(card.id)
                }
                let tabIDs = Set(card.tabs.map(\.id))
                for tab in Array(v.surfaces.keys) where !tabIDs.contains(tab) { v.remove(tab: tab)?.destroySurface() }
                for tab in card.tabs where tab.isWidget && v.widgetView(for: tab.id) == nil {
                    guard let w = widgets else { continue }
                    v.addWidget(w.tileView(tab: tab.id, widget: tab.widget!), for: tab.id)
                }
                for tab in card.tabs where !tab.isWidget && v.surface(for: tab.id) == nil {
                    if let moved = pool.removeValue(forKey: tab.id) {
                        v.add(moved, for: tab.id)
                        continue
                    }
                    if liveSessions == nil { liveSessions = sessions.list() }
                    v.add(makeSurface(tab: tab, workspace: ws, live: liveSessions!), for: tab.id)
                }
                v.select(card.selectedTabID)
            }
            for s in pool.values { s.destroySurface() }
        }
        // widget instances of closed tabs (in any workspace) go
        widgets?.releaseTiles(notIn: Set(store.state.workspaces.flatMap { $0.allTabs.filter(\.isWidget).map(\.id) }))
        refreshChrome()
        emptyHint.isHidden = !(ws?.cards.isEmpty ?? true)
        if !emptyHint.isHidden, let area = targets[.area] {
            emptyHint.sizeToFit()
            emptyHint.frame.origin = NSPoint(x: area.midX - emptyHint.frame.width / 2, y: area.midY - 10)
        }
        applyLayout(targets, animate: animate, fadeIn: newCards)
        focusTerminal()
        afterReconcile?()
    }

    /// Card views of hidden workspaces, by workspace. Their terminals stay attached to their zmx sessions (only
    /// occluded, so Ghostty doesn't draw them): switching back reattaches nothing and replays nothing, and the
    /// terminal keeps its own screen, scrollback and selection.
    private var parkedCards: [UUID: [UUID: TerminalCardView]] = [:]

    /// Takes the shown workspace's card views out of the window and keeps them for its next showing.
    private func parkCards() {
        for v in cardViews.values {
            for s in v.surfaces.values { s.setVisible(false) }
            v.removeFromSuperview()
            currentFrames[ObjectIdentifier(v)] = nil
        }
        if let id = shownWorkspaceID, store.state.workspace(id) != nil, !cardViews.isEmpty {
            parkedCards[id] = cardViews
        } else {
            for v in cardViews.values { destroy(v) }
        }
        cardViews = [:]
    }

    /// Drops what the model no longer has from the parked views: closed workspaces, removed cards, tabs that
    /// closed or moved (a moved tab gets a fresh surface where it is now, so the old one must let go of its session).
    private func prunePark() {
        let state = store.state
        for (wsID, views) in parkedCards {
            guard let w = state.workspace(wsID) else {
                for v in views.values { destroy(v) }
                parkedCards[wsID] = nil
                continue
            }
            var kept = views
            for (cardID, v) in views {
                guard let card = w.card(cardID) else {
                    destroy(v)
                    kept[cardID] = nil
                    continue
                }
                let tabs = Set(card.tabs.map(\.id))
                for tab in Array(v.surfaces.keys) where !tabs.contains(tab) { v.remove(tab: tab)?.destroySurface() }
                for tab in Array(v.widgetViews.keys) where !tabs.contains(tab) { v.removeWidget(tab: tab) }
            }
            parkedCards[wsID] = kept.isEmpty ? nil : kept
        }
    }

    private func destroy(_ v: TerminalCardView) {
        for tab in Array(v.widgetViews.keys) { v.removeWidget(tab: tab) }
        for tab in Array(v.surfaces.keys) { v.remove(tab: tab)?.destroySurface() }
        v.removeFromSuperview()
        currentFrames[ObjectIdentifier(v)] = nil
    }

    /// Takes every widget tab's view out of its card and drops the widget instances (workspace hidden, or the
    /// widgets reload); the next reconcile makes new ones for the shown workspace.
    func dropWidgetTiles() {
        for v in cardViews.values + parkedCards.values.flatMap(\.values) {
            for tab in Array(v.widgetViews.keys) { v.removeWidget(tab: tab) }
        }
        widgets?.releaseAllTiles()
    }

    private func makeCardView(_ id: UUID) -> TerminalCardView {
        let v = TerminalCardView(cardID: id)
        v.applyAppearance()
        v.strip.onDragBegan = { [weak self] tab, p in self?.tabDragBegan(tab, from: id, at: p) }
        v.strip.onDragMoved = { [weak self] p in self?.tabDragMoved(p) }
        v.strip.onDragEnded = { [weak self] p in self?.tabDragEnded(p) }
        // a one-tab card has no strip: its grab handle drags that tab the same way
        v.grabHandle.onDragBegan = { [weak self] tab, p in self?.tabDragBegan(tab, from: id, at: p) }
        v.grabHandle.onDragMoved = { [weak self] p in self?.tabDragMoved(p) }
        v.grabHandle.onDragEnded = { [weak self] p in self?.tabDragEnded(p) }
        v.strip.onSelect = { [weak self] tab in
            self?.store.mutate(.structure(animate: false), save: true) { s in
                guard let ws = s.workspace(containingTab: tab) else { return }
                s.updateWorkspace(ws.id) { $0.selectTab(tab) }
            }
        }
        v.strip.onClose = { [weak self] tab in self?.closeTab(tab) }
        v.strip.onNew = { [weak self] in self?.newTab(inCard: id) }
        v.strip.onActivate = { [weak self] in self?.focusCard(id) }
        return v
    }

    private func makeSurface(tab: Tab, workspace ws: Workspace, live: Set<String>) -> SurfaceView {
        var cwd = tab.cwd ?? ws.cwd ?? NSHomeDirectory()
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) || !isDir.boolValue {
            cwd = NSHomeDirectory()
        }
        let (command, resumed) = sessions.command(for: tab, live: live)
        if resumed { Log.info("tab \(tab.id): session gone, resuming agent \(tab.agent?.sessionID ?? "?")") }
        var env = [
            "\(Product.envPrefix)SOCKET": paths.socket.path,
            "\(Product.envPrefix)WORKSPACE": ws.id.uuidString,
            "\(Product.envPrefix)TAB": tab.id.uuidString,
            "COLORTERM": "truecolor",
        ]
        if let bin = tabBinDir {
            let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = ([bin] + path.split(separator: ":").map(String.init).filter { $0 != bin }).joined(separator: ":")
            // the Claude Code plugin starts `$MEUM_CLI mcp`: this meum's own CLI, wherever the app lives
            env["\(Product.envPrefix)CLI"] = bin + "/meum"
        }
        let s = SurfaceView(tabID: tab.id, workingDirectory: cwd, command: command, env: env)
        s.onFocus = { [weak self] s in self?.surfaceFocused(s) }
        s.onExit = { [weak self] s in self?.surfaceExited(s) }
        s.onTitle = { [weak self] s, title in
            self?.store.mutate(.cosmetic, save: false) { $0.updateTab(s.tabID) { $0.title = title } }
        }
        s.onPwd = { [weak self] s, pwd in
            let path = URL(string: pwd)?.path ?? pwd
            self?.store.mutate(.cosmetic, save: false) { $0.updateTab(s.tabID) { $0.cwd = path } }
        }
        return s
    }

    private func surfaceFocused(_ s: SurfaceView) {
        guard let ws = selectedWorkspace, let card = ws.card(containingTab: s.tabID),
              ws.focusedCardID != card.id else { return }
        store.mutate(.structure(animate: false), save: false) { st in
            st.updateWorkspace(ws.id) { $0.focusCard(card.id) }
        }
    }

    private func surfaceExited(_ s: SurfaceView) {
        if s.exitedEarly() {
            // a failed start (zmx missing, bad command): leave ghostty's notice on screen. Its next close
            // callback (after a key press) comes back here and closes the tab.
            Log.error("tab \(s.tabID): process exited right after start; leaving it open")
            return
        }
        closeTab(s.tabID)
    }

    /// Redraws everything that is not geometry: strips, focus borders, sidebar.
    func refreshChrome() {
        let ws = selectedWorkspace
        if let ws {
            for card in ws.cards {
                guard let v = cardViews[card.id] else { continue }
                v.strip.items = card.tabs.map { t in
                    TabStripView.Item(id: t.id, title: Self.title(for: t), name: t.agent?.name,
                                      labels: t.agent?.labels ?? [], agent: agents.state(forTab: t.id),
                                      silent: silentAgentTabs.contains(t.id))
                }
                // a one-tab card has no strip: its grab handle names the session instead
                v.grabHandle.labels = card.selectedTab.agent?.labels ?? []
                v.grabHandle.setToolTip(name: card.selectedTab.agent?.name)
                v.strip.selectedID = card.selectedTabID
                let focused = card.id == ws.focusedCard?.id
                v.strip.focused = focused
                v.glass.focused = focused
                v.glass.accent = SidebarView.nsColor(hex: ws.color)   // its saturation and opacity: CardAppearance
            }
        }
        sidebarCard.sidebar.reload()
        widgets?.hostStateChanged()   // the selected workspace, its name, colour or directory may have changed
    }

    static func title(for t: Tab) -> String {
        if let title = t.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        if let cwd = t.cwd, !cwd.isEmpty {
            if cwd == NSHomeDirectory() { return "~" }
            return (cwd as NSString).lastPathComponent
        }
        return "shell"
    }

    // MARK: - Geometry and animation

    enum Slot: Hashable { case sidebar, widget(Int), area, card(UUID) }

    func targetFrames(for ws: Workspace?) -> [Slot: NSRect] {
        let b = root.bounds
        let g = gap
        let sw = sidebarWidth
        var out: [Slot: NSRect] = [:]
        // widget cards stack upward from the bottom edge; the sidebar takes what is left above them
        let heights = widgetCards.map { widgetHeight($0) }
        let stack = heights.compactMap { $0 }.reduce(0) { $0 + $1 + g }
        out[.sidebar] = NSRect(x: g, y: g, width: sw, height: max(100, b.height - 2 * g - stack))
        var y = out[.sidebar]!.maxY + g
        for (i, h) in heights.enumerated() {
            guard let h else { continue }
            out[.widget(i)] = NSRect(x: g, y: y, width: sw, height: h)
            y += h + g
        }
        let area = NSRect(x: g + sw + g, y: g, width: max(100, b.width - (g + sw + g) - g),
                          height: max(100, b.height - 2 * g))
        out[.area] = area
        for (id, r) in layoutWorkspace(ws)?.frames(in: area, gap: g) ?? [:] { out[.card(id)] = r }
        return out
    }

    /// The workspace as laid out right now: with the ratios of a divider drag in progress.
    func layoutWorkspace(_ ws: Workspace?) -> Workspace? {
        guard var ws, !liveRatios.isEmpty else { return ws }
        for (id, r) in liveRatios { ws.setRatio(split: id, ratio: r) }
        return ws
    }

    func screenRect(for r: NSRect) -> NSRect {
        let wf = window.frame
        return NSRect(x: wf.minX + r.minX, y: wf.maxY - r.maxY, width: r.width, height: r.height)
    }

    func placeCard(_ v: CardHostView, _ r: NSRect) { place(v, r) }
    var lastSurfaceResize: CFTimeInterval { get { _lastSurfaceResize } set { _lastSurfaceResize = newValue } }
    static let surfaceResizeInterval: CFTimeInterval = 0.1

    private func place(_ v: CardHostView, _ r: NSRect) {
        v.place(r, screenRect: screenRect(for: r))
        currentFrames[ObjectIdentifier(v)] = r
    }

    private var currentFrames: [ObjectIdentifier: NSRect] = [:]
    private var _lastSurfaceResize: CFTimeInterval = 0
    private struct Anim { let view: CardHostView; let from: NSRect; let to: NSRect; let fade: Bool }
    private var anims: [Anim] = []
    private var animStart: CFTimeInterval = 0
    private var link: CADisplayLink?

    private func applyLayout(_ targets: [Slot: NSRect], animate: Bool, fadeIn: Set<UUID>) {
        var pairs: [(CardHostView, NSRect, Bool)] = []
        if let r = targets[.sidebar] { pairs.append((sidebarCard, r, false)) }
        for (i, v) in widgetCards.enumerated() {
            let r = targets[.widget(i)]
            v.isHidden = r == nil
            if r == nil { currentFrames[ObjectIdentifier(v)] = nil }   // fades in again when shown
            if let r { pairs.append((v, r, currentFrames[ObjectIdentifier(v)] == nil)) }
        }
        for (id, v) in cardViews {
            if let r = targets[.card(id)] { pairs.append((v, r, fadeIn.contains(id))) }
        }
        finishAnimation()
        layoutDividers(targets)
        if !animate {
            for (v, r, _) in pairs { place(v, r); v.alphaValue = 1 }
            if !liveRatios.isEmpty { return }   // a divider drag sizes the surfaces itself (throttled)
            for v in cardViews.values { v.commitSurfaceSizes() }
            return
        }
        anims = pairs.map { v, r, fade in
            Anim(view: v, from: currentFrames[ObjectIdentifier(v)] ?? r, to: r, fade: fade)
        }
        for v in cardViews.values { v.setLiveResize(false) }
        for a in anims where a.fade { a.view.alphaValue = 0; place(a.view, a.to) }
        animStart = CACurrentMediaTime()
        if link == nil {
            link = window.displayLink(target: self, selector: #selector(tick(_:)))
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link?.add(to: .main, forMode: .common)
        }
        link?.isPaused = false
    }

    @objc private func tick(_ l: CADisplayLink) {
        guard !anims.isEmpty else { l.isPaused = true; return }
        var p = min(1, (CACurrentMediaTime() - animStart) / Self.animationDuration)
        p = 1 - pow(1 - p, 3) // ease-out cubic
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for a in anims {
            if a.fade {
                a.view.alphaValue = CGFloat(p)
                continue
            }
            let f = a.from, t = a.to
            let r = p >= 1 ? t : NSRect(x: (f.minX + (t.minX - f.minX) * p).rounded(),
                                        y: (f.minY + (t.minY - f.minY) * p).rounded(),
                                        width: (f.width + (t.width - f.width) * p).rounded(),
                                        height: (f.height + (t.height - f.height) * p).rounded())
            place(a.view, r)
        }
        CATransaction.commit()
        if p >= 1 { finishAnimation() }
    }

    /// Jumps a running animation to its end and gives every surface its final size, once.
    private func finishAnimation() {
        guard !anims.isEmpty else { return }
        let done = anims
        anims = []
        link?.isPaused = true
        for a in done { place(a.view, a.to); a.view.alphaValue = 1 }
        for v in cardViews.values { v.commitSurfaceSizes() }
    }

    var isAnimating: Bool { !anims.isEmpty }

    // MARK: - Focus

    func focusTerminal() {
        guard !sidebarCard.sidebar.isEditing, let ws = selectedWorkspace, let card = ws.focusedCard,
              let v = cardViews[card.id] else { return }
        if card.selectedTab.isWidget {
            // a widget keeps whatever it focused inside itself; otherwise its view takes the keyboard
            guard let w = v.widgetView(for: card.selectedTab.id) else { return }
            if let r = window.firstResponder as? NSView, r.isDescendant(of: w) { return }
            window.makeFirstResponder(w.subviews.first ?? w)
            return
        }
        guard let s = v.selectedSurface else { return }
        if window.firstResponder !== s { window.makeFirstResponder(s) }
    }

    /// A click into a widget tab focuses its card (terminals report focus themselves). Installed once.
    func watchWidgetClicks() {
        widgetClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard let self, e.window === self.window, let ws = self.selectedWorkspace else { return e }
            let p = self.root.convert(e.locationInWindow, from: nil)
            for card in ws.cards where card.selectedTab.isWidget && card.id != ws.focusedCardID {
                guard let v = self.cardViews[card.id], let w = v.widgetView(for: card.selectedTab.id),
                      w.convert(w.bounds, to: self.root).contains(p) else { continue }
                self.store.mutate(.structure(animate: false), save: false) { $0.updateWorkspace(ws.id) { $0.focusCard(card.id) } }
            }
            return e
        }
    }

    var focusedSurface: SurfaceView? {
        guard let ws = selectedWorkspace, let card = ws.focusedCard else { return nil }
        return cardViews[card.id]?.selectedSurface
    }

    func surface(forTab id: UUID) -> SurfaceView? {
        for v in cardViews.values + parkedCards.values.flatMap(\.values) { if let s = v.surface(for: id) { return s } }
        return nil
    }

    func focusCard(_ id: UUID) {
        guard let ws = selectedWorkspace else { return }
        store.mutate(.structure(animate: false), save: false) { $0.updateWorkspace(ws.id) { $0.focusCard(id) } }
        focusTerminal()
    }

    // MARK: - Actions

    var terminalArea: NSRect { targetFrames(for: nil)[.area] ?? root.bounds }

    private func focusedTabCwd() -> String? {
        guard let ws = selectedWorkspace else { return nil }
        return ws.focusedCard?.selectedTab.cwd ?? ws.cwd
    }

    @discardableResult
    func newWorkspace(name: String? = nil, cwd: String? = nil, color: String? = nil) -> UUID {
        let n = store.state.workspaces.count + 1
        var nameToUse = name ?? "Workspace \(n)"
        if name == nil {
            var i = n
            let names = Set(store.state.workspaces.map(\.name))
            while names.contains(nameToUse) { i += 1; nameToUse = "Workspace \(i)" }
        }
        let ws = Workspace.make(name: nameToUse, cwd: cwd ?? NSHomeDirectory(), color: color)
        store.mutate { $0.addWorkspace(ws) }
        return ws.id
    }

    /// Shows a tab: selects its workspace, focuses its card and selects it there.
    @discardableResult
    func selectTab(_ tabID: UUID) -> Bool {
        guard let ws = store.state.workspace(containingTab: tabID) else { return false }
        store.mutate(.structure(animate: false)) { s in
            s.selectWorkspace(ws.id)
            s.updateWorkspace(ws.id) { $0.selectTab(tabID) }
        }
        focusTerminal()
        return true
    }

    func selectWorkspace(at index: Int) { store.mutate { $0.selectWorkspace(at: index) } }
    func selectAdjacentWorkspace(_ d: Int) { store.mutate { $0.selectAdjacentWorkspace(d) } }

    func newTab(inCard card: UUID? = nil) {
        guard let ws = selectedWorkspace else { newWorkspace(); return }
        let tab = Tab(cwd: focusedTabCwd())
        store.mutate { $0.updateWorkspace(ws.id) { $0.addTab(tab, toCard: card) } }
    }

    /// Adds a widget tab as a new card to the right of the focused card (in the selected workspace).
    @discardableResult
    func addWidgetTab(_ widgetID: String) -> UUID? {
        guard let ws = selectedWorkspace, let e = widgets?.entry(widgetID) else { return nil }
        let tab = Tab(title: e.displayName, cwd: ws.cwd, widget: e.id)
        store.mutate { $0.updateWorkspace(ws.id) { $0.split(placement: .right, tab: tab) } }
        return tab.id
    }

    func split(_ placement: SplitPlacement) {
        guard let ws = selectedWorkspace else { return }
        let tab = Tab(cwd: focusedTabCwd())
        store.mutate { $0.updateWorkspace(ws.id) { $0.split(placement: placement, tab: tab) } }
    }

    /// Closes a tab and ends its zmx session. Closing a workspace's last tab closes the workspace.
    func closeTab(_ tabID: UUID) {
        guard let ws = store.state.workspace(containingTab: tabID) else { return }
        if ws.allTabs.count == 1 {
            closeWorkspace(ws.id)
            return
        }
        store.mutate { $0.updateWorkspace(ws.id) { $0.closeTab(tabID) } }
        sessions.kill(tabs: [tabID])
    }

    func closeFocusedTab() {
        guard let tab = selectedWorkspace?.focusedCard?.selectedTab else { return }
        closeTab(tab.id)
    }

    /// Closes a workspace and ends the zmx sessions of all its tabs. The last workspace is replaced by a
    /// fresh one, so the window is never empty.
    func closeWorkspace(_ id: UUID) {
        guard let ws = store.state.workspace(id) else { return }
        let tabs = ws.allTabs.map(\.id)
        store.mutate { s in
            s.closeWorkspace(id)
            if s.workspaces.isEmpty { s.addWorkspace(.make(name: "Workspace 1", cwd: NSHomeDirectory())) }
        }
        sessions.kill(tabs: tabs)
    }

    func moveFocus(_ d: Direction) {
        guard let ws = selectedWorkspace else { return }
        let area = terminalArea
        let g = gap
        store.mutate(.structure(animate: false), save: false) {
            $0.updateWorkspace(ws.id) { $0.moveFocus(d, in: area, gap: g) }
        }
    }

    /// Moves a tab into a card at a position (`index` is its position there afterwards; nil: the end).
    @discardableResult
    func moveTab(_ tab: UUID, toCard card: UUID, index: Int?) -> Bool {
        var ok = false
        store.mutate { ok = $0.moveTab(tab, toCard: card, index: index) }
        focusTerminal()
        return ok
    }

    /// Splits `card` and moves the tab into the new card on `side`. Returns the new card's id.
    @discardableResult
    func moveTab(_ tab: UUID, splitting card: UUID, side: Direction) -> UUID? {
        var new: UUID?
        store.mutate { new = $0.moveTab(tab, splitting: card, side: side) }
        focusTerminal()
        return new
    }

    @discardableResult
    func setRatio(split: UUID, ratio: Double) -> Bool {
        var ok = false
        store.mutate { ok = $0.setRatio(split: split, ratio: ratio) }
        return ok
    }

    func resize(_ d: Direction) {
        guard let ws = selectedWorkspace else { return }
        store.mutate { $0.updateWorkspace(ws.id) { $0.resizeFocused(d, delta: 0.05) } }
    }

    func selectAdjacentTab(_ d: Int) {
        guard let ws = selectedWorkspace else { return }
        store.mutate(.structure(animate: false)) { $0.updateWorkspace(ws.id) { $0.selectAdjacentTab(d) } }
    }

    func renameSelectedWorkspace() {
        guard let id = store.state.selectedWorkspaceID else { return }
        if settings.sidebarCollapsed {
            // no room for a name in the rail: expand, and open the field once the sidebar has its width
            setSidebarCollapsed(false)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.animationDuration + 0.05) { [weak self] in
                self?.sidebarCard.sidebar.beginRename(id)
            }
            return
        }
        sidebarCard.sidebar.beginRename(id)
    }

    func closeSelectedWorkspace() {
        guard let id = store.state.selectedWorkspaceID else { return }
        closeWorkspace(id)
    }

    // MARK: - SidebarHost

    var sidebarItems: [SidebarItem] {
        let sel = store.state.selectedWorkspaceID
        return store.state.workspaces.map { ws in
            let ex = workspaceExtras[ws.id]
            return SidebarItem(id: ws.id, name: ws.name, color: ws.color, icon: ws.icon, pinned: ws.pinned, selected: ws.id == sel,
                               agents: agents.summary(forWorkspace: ws), branch: ex?.branch,
                               status: ex?.status.map { SidebarStatus(key: $0.key, value: $0.entry.value, color: $0.entry.color,
                                                                     url: $0.entry.url) } ?? [],
                               directory: ws.focusedCard?.selectedTab.cwd ?? ws.cwd, metadata: ws.metadata ?? [:],
                               ports: ex?.ports ?? [], group: ws.group,
                               labels: ws.labels ?? [])
        }
    }

    func sidebarSelect(_ id: UUID) { store.mutate { $0.selectWorkspace(id) }; focusTerminal() }
    func sidebarNew() { newWorkspace() }
    func sidebarRename(_ id: UUID, to name: String) { store.mutate(.cosmetic) { $0.renameWorkspace(id, to: name) } }
    func sidebarClose(_ id: UUID) { closeWorkspace(id) }
    func sidebarMove(_ id: UUID, to index: Int) { store.mutate(.cosmetic) { $0.moveWorkspace(id, to: index) } }
    func sidebarSetIcon(_ id: UUID, _ icon: String?) {
        store.mutate(.cosmetic) { $0.setIcon(id, icon) }
    }

    func sidebarSetColor(_ id: UUID, _ hex: String?) {
        store.mutate(.cosmetic) { $0.setColor(id, hex) }
    }
    func sidebarSetPinned(_ id: UUID, _ pinned: Bool) { store.mutate(.cosmetic) { $0.setPinned(id, pinned) } }
    func sidebarDidEndInteraction() { focusTerminal() }
    var sidebarGroups: [SidebarGroup] {
        store.state.groups.map { SidebarGroup(id: $0.id, name: $0.name, collapsed: $0.collapsed) }
    }
    func sidebarNewGroup(_ ids: [UUID]) -> UUID? {
        var made: UUID?
        let names = Set(store.state.groups.map(\.name))
        let name = (1...).lazy.map { $0 == 1 ? "Group" : "Group \($0)" }.first { !names.contains($0) }!
        store.mutate(.cosmetic) { made = $0.createGroup(name: name, workspaces: ids) }
        return made
    }
    func sidebarSetGroup(_ ids: [UUID], _ group: UUID?) { store.mutate(.cosmetic) { $0.setGroup(ids, to: group) } }
    func sidebarMoveWorkspaces(_ ids: [UUID], before anchor: UUID?, group: UUID?) {
        store.mutate(.cosmetic) { $0.moveWorkspaces(ids, before: anchor, group: group) }
    }
    func sidebarMoveGroup(_ id: UUID, before anchor: UUID?) { store.mutate(.cosmetic) { $0.moveGroup(id, before: anchor) } }
    func sidebarRenameGroup(_ id: UUID, to name: String) { store.mutate(.cosmetic) { $0.renameGroup(id, to: name) } }
    func sidebarSetGroupCollapsed(_ id: UUID, _ collapsed: Bool) {
        store.mutate(.cosmetic) { $0.setGroupCollapsed(id, collapsed) }
    }
    func sidebarUngroup(_ id: UUID) { store.mutate(.cosmetic) { $0.ungroup(id) } }
    func sidebarOpenPort(_ port: Int) {
        if let url = URL(string: "http://localhost:\(port)") { openURL(url) }
    }
    func sidebarStatusClicked(_ id: UUID, key: String) {
        guard let entry = workspaceExtras[id]?.status.first(where: { $0.key == key })?.entry else { return }
        onStatusClicked?(id, key, entry)
        if let s = entry.url, let url = URL(string: s) { openURL(url) }
    }
}
