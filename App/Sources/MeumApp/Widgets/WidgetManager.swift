import AppKit
import MeumControl
import MeumCore
import MeumKit

/// Loads native widgets (MeumKit, layer 2) into stacked cards under the sidebar, one card per widget.
///
/// A widget is a folder `<name>.meumwidget/` in the widgets directory (`$MEUM_WIDGETS_DIR`, default
/// `~/.local/share/meum/widgets`) holding `manifest.json` (`{"id", "displayName", "library", "scope"?}`) and the
/// dynamic library named there. Every folder without a file `disabled` gets a card. Workspace widgets
/// (`"scope": "workspace"`) sit above global ones; `Settings.widgetOrder` orders the cards within each group.
/// `widget.reload` (CLI `meum widget reload`) drops every widget and loads the libraries again; each load
/// dlopens a fresh copy, so a rebuilt library shows without restarting meum (the old code stays mapped).
@MainActor
final class WidgetManager {
    /// global: a sidebar card, the same on every workspace; workspace: a sidebar card that follows the selected
    /// workspace; tile: no sidebar card, only widget tabs (e.g. a browser).
    enum Scope: String { case global, workspace, tile }

    struct Entry {
        var folder: URL
        var id: String
        var displayName: String
        var library: URL
        var disabled: Bool
        var scope: Scope
        /// The manifest's background program, if any (`WidgetHelpers`).
        var helper: WidgetHelpers.Spec?
    }

    /// One card under the sidebar and the widget in it (nil when it failed to load, or the "no widgets" card).
    final class Slot: MeumWidgetHost {
        let entry: Entry?
        let card = WidgetSlotCardView(frame: NSRect(x: 0, y: 0, width: 240, height: 150))
        fileprivate(set) var widget: MeumWidget?
        fileprivate(set) var error: String?
        /// What the widget asked for with `setPreferredHeight`; 0 hides the card.
        fileprivate(set) var requestedHeight: CGFloat?
        fileprivate var lastAppearance: MeumWidgetAppearance?
        fileprivate var lastVisibility: MeumWidgetVisibility?
        fileprivate var lastWorkspace: MeumWorkspaceInfo??
        fileprivate var lastSidebarCollapsed: Bool?
        fileprivate weak var manager: WidgetManager?

        init(entry: Entry?, manager: WidgetManager) {
            self.entry = entry
            self.manager = manager
            card.requestedHeight = { [weak self] in
                guard let self else { return nil }
                return self.hiddenInRail ? 0 : self.requestedHeight
            }
        }

        /// Hidden by the widget itself (`setPreferredHeight(0)`).
        var isCollapsed: Bool { requestedHeight == 0 }
        var isSidebarCollapsed: Bool { manager?.controller?.settings.sidebarCollapsed ?? false }
        var dataDirectory: URL { manager?.dataDirectory(for: entry?.id ?? "_") ?? FileManager.default.temporaryDirectory }
        /// The sidebar is collapsed and this widget has no look for the rail (or there is no widget).
        var hiddenInRail: Bool { isSidebarCollapsed && !(widget?.supportsCollapsedSidebar ?? false) }
        var key: String { entry?.folder.path ?? "" }

        var appearance: MeumWidgetAppearance { manager?.appearance ?? MeumWidgetAppearance() }
        var visibility: MeumWidgetVisibility {
            let v = manager?.screenVisibility ?? MeumWidgetVisibility(isShown: false, isOnScreen: false)
            return MeumWidgetVisibility(isShown: widget != nil && !isCollapsed && !hiddenInRail, isOnScreen: v.isOnScreen)
        }
        var socketPath: String { manager?.socketPath ?? "" }
        var selectedWorkspace: MeumWorkspaceInfo? { manager?.selectedWorkspace }
        var placement: MeumWidgetPlacement { .sidebar }
        var configuration: String? { nil }
        func setConfiguration(_ json: String?) {}
        func publish(_ json: String) { manager?.publish(widget: entry?.id ?? "", tab: nil, json) }

        func setPreferredHeight(_ height: CGFloat) {
            let h = height <= 0 ? 0 : min(max(height.rounded(), 40), 800)
            guard h != requestedHeight else { return }
            let collapseChanged = (h == 0) != isCollapsed
            requestedHeight = h
            if collapseChanged || manager?.controller?.settings.widgetHeightAuto == true { manager?.relayout() }
            if collapseChanged { manager?.pushState() }
        }

        func selectWorkspace(_ id: UUID) { manager?.selectWorkspace(id) }
        func notify(title: String, body: String, workspace: UUID?) { manager?.notify(title: title, body: body, workspace: workspace) }
    }

    /// A widget shown as a tab in the tiling area. One instance per tab, alive as long as the tab exists (also
    /// while its workspace is hidden: the view is then out of the window, and `visibility` says so).
    final class Tile: MeumWidgetHost {
        let tab: UUID
        let widgetID: String
        let container = FlippedView()
        fileprivate(set) var widget: MeumWidget?
        fileprivate var lastAppearance: MeumWidgetAppearance?
        fileprivate var lastVisibility: MeumWidgetVisibility?
        fileprivate var lastWorkspace: MeumWorkspaceInfo??
        fileprivate weak var manager: WidgetManager?
        private let label = NSTextField(wrappingLabelWithString: "")

        init(tab: UUID, widgetID: String, manager: WidgetManager) {
            self.tab = tab
            self.widgetID = widgetID
            self.manager = manager
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = NSColor(white: 1, alpha: 0.4)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -24),
            ])
        }

        fileprivate func host(_ w: MeumWidget) {
            widget = w
            label.isHidden = true
            w.view.frame = container.bounds
            w.view.autoresizingMask = [.width, .height]
            container.addSubview(w.view)
        }

        fileprivate func fail(_ text: String) {
            label.stringValue = text
            label.isHidden = false
        }

        var appearance: MeumWidgetAppearance {
            var a = manager?.appearance ?? MeumWidgetAppearance()
            a.width = container.bounds.width
            return a
        }
        var visibility: MeumWidgetVisibility {
            let v = manager?.screenVisibility ?? MeumWidgetVisibility(isShown: false, isOnScreen: false)
            let inWindow = container.window != nil && !container.isHiddenOrHasHiddenAncestor
            return MeumWidgetVisibility(isShown: widget != nil && inWindow, isOnScreen: v.isOnScreen)
        }
        var socketPath: String { manager?.socketPath ?? "" }
        /// The tile's own workspace (it may be hidden while the tile is messaged).
        var selectedWorkspace: MeumWorkspaceInfo? { manager?.workspaceInfo(containingTab: tab) }
        var placement: MeumWidgetPlacement { .tile(tab: tab) }
        var dataDirectory: URL { manager?.dataDirectory(for: widgetID) ?? FileManager.default.temporaryDirectory }
        var configuration: String? { manager?.controller?.store.state.workspace(containingTab: tab)?.tab(tab)?.widgetConfig }
        func setConfiguration(_ json: String?) {
            manager?.controller?.store.mutate(.cosmetic) { _ = $0.updateTab(self.tab) { $0.widgetConfig = json } }
        }
        func publish(_ json: String) { manager?.publish(widget: widgetID, tab: tab, json) }
        func setPreferredHeight(_ height: CGFloat) {}
        func selectWorkspace(_ id: UUID) { manager?.selectWorkspace(id) }
        func notify(title: String, body: String, workspace: UUID?) { manager?.notify(title: title, body: body, workspace: workspace) }
    }

    let directory: URL
    fileprivate weak var controller: WorkspaceController?
    private weak var control: AppControl?
    /// The cards, top to bottom.
    private(set) var slots: [Slot] = []
    /// Widget tabs of the shown workspace, by tab id.
    private(set) var tiles: [UUID: Tile] = [:]
    /// Registrations loaded since the last reload, by widget folder: tiles of one widget share its library.
    private var registrations: [URL: MeumWidgetRegistration] = [:]
    /// The widget library: decides whether a library may load (pinned hash, trusted team, developer mode).
    weak var installer: WidgetInstaller?
    /// The trust decision of the last load attempt per widget id (for `widget.list` and Settings).
    private(set) var trustByID: [String: WidgetTrust] = [:]
    private var loadCount = 0
    private var observers: [NSObjectProtocol] = []
    private var screensAsleep = false

    init(controller: WorkspaceController, control: AppControl, directory: URL?) {
        self.controller = controller
        self.control = control
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/\(Product.name)/widgets", isDirectory: true)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: controller.window,
                                        queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.pushState() } })
        let wc = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            observers.append(wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screensAsleep = asleep
                    self?.pushState()
                }
            })
        }
    }

    // MARK: discovery

    func scan() -> [Entry] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.pathExtension == "meumwidget" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { folder in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let lib = obj["library"] as? String else {
                    Log.error("widget \(folder.lastPathComponent): manifest.json missing or without \"library\"")
                    return nil
                }
                let id = obj["id"] as? String ?? folder.deletingPathExtension().lastPathComponent
                return Entry(folder: folder, id: id, displayName: obj["displayName"] as? String ?? id,
                             library: folder.appendingPathComponent(lib),
                             disabled: fm.fileExists(atPath: folder.appendingPathComponent("disabled").path),
                             scope: Scope(rawValue: (obj["scope"] as? String ?? "").lowercased()) ?? .global,
                             helper: WidgetHelpers.spec(widgetID: id, folder: folder, manifest: obj))
            }
    }

    /// Enabled entries in card order: workspace widgets first, then global; `widgetOrder` within each, then name.
    static func ordered(_ entries: [Entry], order: [String]) -> [Entry] {
        func rank(_ e: Entry) -> Int { order.firstIndex(of: e.id) ?? Int.max }
        return entries.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if x.scope != y.scope { return x.scope == .workspace }
            if rank(x) != rank(y) { return rank(x) < rank(y) }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: loading

    /// Drops every widget and loads the enabled ones, one card each.
    @discardableResult
    func reload() -> String? {
        // background programs first: they run whether or not the widget shows anywhere
        helpers?.sync(scan().filter { !$0.disabled && (installer?.helperTrusted($0) ?? true) }.compactMap(\.helper))
        unloadAll()
        registrations = [:]
        trustByID = [:]
        // widget tabs are rebuilt with the new libraries by the reconcile below
        controller?.dropWidgetTiles()
        releaseAllTiles()
        let entries = Self.ordered(scan().filter { !$0.disabled && $0.scope != .tile }, order: controller?.settings.widgetOrder ?? [])
        slots = entries.map { Slot(entry: $0, manager: self) }
        if slots.isEmpty {
            let s = Slot(entry: nil, manager: self)
            s.card.showPlaceholder(nil)
            slots = [s]
        }
        for s in slots { s.card.applyAppearance() }
        controller?.setWidgetCards(slots.map(\.card))
        for s in slots {
            guard let entry = s.entry else { continue }
            do {
                try load(entry, into: s)
            } catch {
                s.error = "\(error)"
                Log.error("widget \(entry.id): \(error)")
                s.card.showPlaceholder("\(entry.displayName): \(error)")
            }
        }
        relayout()
        return slots.compactMap(\.error).first
    }

    /// Re-sorts the cards after `widgetOrder` changed, without reloading.
    func reorder() {
        let order = controller?.settings.widgetOrder ?? []
        let entries = Self.ordered(slots.compactMap(\.entry), order: order)
        let sorted = entries.compactMap { e in slots.first { $0.entry?.folder == e.folder } }
        guard sorted.count == slots.count, sorted.map(\.key) != slots.map(\.key) else { return }
        slots = sorted
        controller?.setWidgetCards(slots.map(\.card))
        relayout()
    }

    struct LoadError: Error, CustomStringConvertible {
        let description: String
    }

    private func load(_ entry: Entry, into slot: Slot) throws {
        let reg = try registration(entry)
        slot.lastAppearance = appearance
        slot.lastWorkspace = .some(selectedWorkspace)
        let w = reg.make(slot)
        slot.widget = w
        slot.lastVisibility = slot.visibility
        slot.card.host(w.view)
        Log.info("widget loaded: \(reg.manifest.id) \(reg.manifest.version) from \(entry.folder.lastPathComponent)")
        control?.bus.publish("widget.loaded", ["id": .string(reg.manifest.id), "version": .string(reg.manifest.version)])
    }

    /// The widget's registration, loading its library the first time since the last reload.
    private func registration(_ entry: Entry) throws -> MeumWidgetRegistration {
        if let r = registrations[entry.folder] { return r }
        guard FileManager.default.fileExists(atPath: entry.library.path) else {
            throw LoadError(description: "library \(entry.library.lastPathComponent) not found")
        }
        // a fresh path per load, so dlopen maps the current file instead of returning the cached image
        loadCount += 1
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("meum-widgets", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp.path)
        let copy = tmp.appendingPathComponent("\(getpid())-\(loadCount)-\(entry.library.lastPathComponent)")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: entry.library, to: copy)
        // the trust check runs on the copy, right before dlopen: the installed file may change, the copy doesn't
        if let installer {
            let trust = installer.trust(of: copy, id: entry.id)
            trustByID[entry.id] = trust
            if case .unverified(let why) = trust {
                try? FileManager.default.removeItem(at: copy)
                throw LoadError(description: "not verified (\(why)); allow it in Settings ▸ Widgets")
            }
        }
        if FileManager.default.fileExists(atPath: entry.folder.appendingPathComponent("libMeumKit.dylib").path) {
            throw LoadError(description: "it bundles its own libMeumKit.dylib; widgets must use meum's")
        }
        guard let handle = dlopen(copy.path, RTLD_NOW | RTLD_LOCAL) else {
            throw LoadError(description: "dlopen: " + String(cString: dlerror()))
        }
        guard let sym = dlsym(handle, MeumKit.entrySymbol) else {
            throw LoadError(description: "no \(MeumKit.entrySymbol) in \(entry.library.lastPathComponent)")
        }
        typealias Main = @convention(c) () -> UnsafeMutableRawPointer
        let reg = MeumWidgetRegistration.adopt(unsafeBitCast(sym, to: Main.self)())
        guard reg.manifest.apiVersion == MeumKit.apiVersion else {
            throw LoadError(description: "speaks \(reg.manifest.apiVersion), meum speaks \(MeumKit.apiVersion)")
        }
        registrations[entry.folder] = reg
        return reg
    }

    // MARK: background programs and data

    /// Runs the widgets' helpers; nil until `startHelpers` (the app calls it once at launch).
    private(set) var helpers: WidgetHelpers?

    func startHelpers() {
        guard helpers == nil, let c = controller else { return }
        helpers = WidgetHelpers(socketPath: c.paths.socket.path, stateDirectory: c.paths.directory,
                                dataDirectory: { [weak self] id in self?.dataDirectory(for: id) ?? FileManager.default.temporaryDirectory })
        helpers?.sync(scan().filter { !$0.disabled && (installer?.helperTrusted($0) ?? true) }.compactMap(\.helper))
    }

    /// Stops a widget's helper (before removing or replacing the widget). The next `reload` starts it again if
    /// the widget is still installed and enabled.
    func stopHelper(id: String) { helpers?.stop(id) }

    /// pinned | team | developer | unverified, for a widget: from its last load, else checked now on the file.
    func trustKind(_ e: Entry) -> String {
        if let t = trustByID[e.id] { return t.kind }
        guard let installer else { return "developer" }
        return installer.trust(of: e.library, id: e.id).kind
    }

    /// Starts a widget's helper now, if it has one and is enabled and not running.
    func startHelper(id: String) {
        guard let spec = entry(id).flatMap({ $0.disabled ? nil : $0.helper }), helpers?.running[spec.widgetID] == nil else { return }
        helpers?.start(spec)
    }

    func stopAllHelpers() { helpers?.stopAll() }

    /// A widget's own data folder: `<state dir>/widgets/<id>/` (`~/.local/state/meum/widgets/<id>/` by default),
    /// created on first use. MeumKit `host.dataDirectory`; helpers get it as MEUM_WIDGET_DATA.
    func dataDirectory(for id: String) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        let base = controller?.paths.directory ?? FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("widgets", isDirectory: true).appendingPathComponent(safe, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: widget tabs

    /// Finds an installed widget by id or folder name (disabled ones too: disabling hides the sidebar card).
    func entry(_ id: String) -> Entry? {
        scan().first { $0.id == id || $0.folder.deletingPathExtension().lastPathComponent == id }
    }

    /// The view of a widget tab, making its widget instance the first time.
    func tileView(tab: UUID, widget id: String) -> NSView {
        if let t = tiles[tab] { return t.container }
        let t = Tile(tab: tab, widgetID: id, manager: self)
        tiles[tab] = t
        guard let e = entry(id) else {
            t.fail("widget \(id) is not installed")
            return t.container
        }
        do {
            let reg = try registration(e)
            if t.container.frame.isEmpty { t.container.frame = NSRect(x: 0, y: 0, width: 900, height: 700) }
            t.lastAppearance = t.appearance
            t.lastWorkspace = .some(t.selectedWorkspace)
            let w = reg.make(t)
            t.host(w)
            t.lastVisibility = t.visibility
        } catch {
            Log.error("widget tab \(id): \(error)")
            t.fail("\(e.displayName): \(error)")
        }
        return t.container
    }

    /// Drops a widget tab's instance (its tab closed, or its workspace was hidden).
    func releaseTile(_ tab: UUID) {
        guard let t = tiles.removeValue(forKey: tab) else { return }
        t.widget?.willUnload()
        t.container.removeFromSuperview()
    }

    func releaseAllTiles() { for id in Array(tiles.keys) { releaseTile(id) } }

    /// Drops instances whose tab no longer exists in any workspace.
    func releaseTiles(notIn tabs: Set<UUID>) {
        for id in Array(tiles.keys) where !tabs.contains(id) { releaseTile(id) }
    }

    private func unloadAll() {
        for s in slots {
            s.widget?.willUnload()
            s.card.unhost()
            s.widget = nil
        }
        slots = []
    }

    private var relayoutPending = false

    /// Lays out again on the next turn of the run loop. A widget may ask for a height while meum is in the middle
    /// of a layout pass (e.g. from `workspaceDidChange`); laying out right there would be overwritten by that pass.
    fileprivate func relayout() {
        guard !relayoutPending else { return }
        relayoutPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.relayoutPending = false
                self.controller?.reconcile(animate: true)
            }
        }
    }

    // MARK: pushing host state

    /// Called by the controller after settings, layout or workspace changes.
    func hostStateChanged() { pushState() }

    fileprivate func pushState() {
        let a = appearance
        let ws = selectedWorkspace
        for s in slots {
            guard let w = s.widget else { continue }
            let collapsed = s.isSidebarCollapsed
            if s.lastSidebarCollapsed != collapsed {
                // a change, or a widget that starts while the sidebar is collapsed
                if (s.lastSidebarCollapsed != nil || collapsed), w.supportsCollapsedSidebar { w.sidebarCollapsedDidChange(collapsed) }
                s.lastSidebarCollapsed = collapsed
            }
            if a != s.lastAppearance { s.lastAppearance = a; w.appearanceDidChange(a) }
            let v = s.visibility
            if v != s.lastVisibility { s.lastVisibility = v; w.visibilityDidChange(v) }
            if s.lastWorkspace != .some(ws) { s.lastWorkspace = .some(ws); w.workspaceDidChange(ws) }
        }
        for t in tiles.values {
            guard let w = t.widget else { continue }
            let ta = t.appearance
            if ta != t.lastAppearance { t.lastAppearance = ta; w.appearanceDidChange(ta) }
            let v = t.visibility
            if v != t.lastVisibility { t.lastVisibility = v; w.visibilityDidChange(v) }
            let tws = t.selectedWorkspace
            if t.lastWorkspace != .some(tws) { t.lastWorkspace = .some(tws); w.workspaceDidChange(tws) }
        }
    }

    // MARK: host state shared by every slot

    var appearance: MeumWidgetAppearance {
        let s = controller?.settings ?? Settings()
        let card = CardAppearance.current
        let material: MeumWidgetAppearance.Material
        var lum = 0.12
        switch s.background {
        case .glass: material = .glass
        case .vibrancy: material = .vibrancy; lum = 0.2
        // MeumKit's Material has no Liquid Glass case (adding one would trip widgets built before it): the nearest
        // existing look is the glass over the pinned wallpaper, else the frosted vibrancy
        case .liquid: material = s.wallpaper ? .glass : .vibrancy; lum = s.liquidStyle == .clear ? 0.25 : 0.18
        case .solid:
            material = .solid
            if let c = card.solid.usingColorSpace(.sRGB) {
                lum = 0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent)
            }
        }
        return MeumWidgetAppearance(scheme: lum > 0.55 ? .light : .dark, material: material, backgroundLuminance: lum,
                                    accentColor: .controlAccentColor, cornerRadius: card.radius, bottomInset: 0,
                                    width: controller?.sidebarWidth ?? 240)
    }

    fileprivate var screenVisibility: MeumWidgetVisibility {
        let win = controller?.window
        let onScreen = (win?.isVisible ?? false) && (win?.occlusionState.contains(.visible) ?? false) && !screensAsleep
        return MeumWidgetVisibility(isShown: true, isOnScreen: onScreen)
    }

    var socketPath: String { controller?.paths.socket.path ?? "" }

    var selectedWorkspace: MeumWorkspaceInfo? {
        controller?.selectedWorkspace.map(info)
    }

    func info(_ ws: Workspace) -> MeumWorkspaceInfo {
        MeumWorkspaceInfo(id: ws.id, name: ws.name, cwd: ws.cwd, color: ws.color,
                          remotes: controller?.workspaceExtras[ws.id]?.remotes ?? [], metadata: ws.metadata ?? [:])
    }

    fileprivate func workspaceInfo(containingTab tab: UUID) -> MeumWorkspaceInfo? {
        controller?.store.state.workspace(containingTab: tab).map(info)
    }

    fileprivate func publish(widget: String, tab: UUID?, _ json: String) {
        let data = (try? JSON.parse(json)) ?? .string(json)
        control?.bus.publish("widget.event", ["widget": .string(widget),
                                              "tab": tab.map { .string($0.uuidString) } ?? .null, "data": data])
    }

    // MARK: messages

    struct SendError: Error, CustomStringConvertible { let description: String }

    /// The instance a message goes to: a widget tab (made if its workspace was never shown) or a sidebar card.
    func target(tab: UUID?, widget id: String?) throws -> (MeumWidget, NSView) {
        if let tab {
            guard let t = controller?.store.state.workspace(containingTab: tab)?.tab(tab), let wid = t.widget else {
                throw ControlError.notFound("no widget tab '\(tab.uuidString)'")
            }
            _ = tileView(tab: tab, widget: wid)
            guard let tile = tiles[tab], let w = tile.widget else {
                throw ControlError.unavailable("widget '\(wid)' did not load")
            }
            return (w, tile.container)
        }
        guard let id, let s = slots.first(where: { $0.entry?.id == id }), let w = s.widget else {
            throw ControlError.notFound("no loaded sidebar widget '\(id ?? "")'")
        }
        return (w, s.card.content)
    }

    /// Sends JSON text to a widget and waits (up to `timeout`) for its reply.
    func send(_ message: String, to w: MeumWidget, timeout: TimeInterval = 30) async throws -> String {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            var done = false
            let finish: (Result<String, Error>) -> Void = { r in
                guard !done else { return }
                done = true
                c.resume(with: r)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                MainActor.assumeIsolated { finish(.failure(ControlError.unavailable("the widget did not answer within \(Int(timeout)) s"))) }
            }
            w.receive(message) { reply in finish(.success(reply)) }
        }
    }

    /// A PNG of a widget's view drawn by meum (for widgets that don't answer a screenshot message). Web views
    /// and other layer-backed content may come out blank this way.
    static func snapshot(_ v: NSView) -> Data? {
        guard v.bounds.width > 0, v.bounds.height > 0, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    fileprivate func selectWorkspace(_ id: UUID) {
        guard let c = controller, c.store.state.workspaces.contains(where: { $0.id == id }) else { return }
        c.sidebarSelect(id)
    }

    fileprivate func notify(title: String, body: String, workspace: UUID?) {
        let ws = workspace.flatMap { id in controller?.store.state.workspaces.first { $0.id == id } }
        let tab = ws.flatMap { ModelJSON.focusedTab($0)?.id }
        _ = control?.notify(title: title, body: body, tab: tab)
    }

    // MARK: API

    /// Enables or disables a widget by id (the `disabled` file in its folder), then reloads.
    func setEnabled(_ id: String, _ enabled: Bool) throws {
        guard let e = entry(id) else {
            throw ControlError.notFound("no widget '\(id)' in \(directory.path)")
        }
        let flag = e.folder.appendingPathComponent("disabled")
        if enabled { try? FileManager.default.removeItem(at: flag) } else {
            FileManager.default.createFile(atPath: flag.path, contents: Data())
        }
        reload()
    }

    func listJSON() -> JSON {
        let order = slots.map(\.key)
        let entries = scan().map { e -> JSON in
            let slot = slots.first { $0.entry?.folder == e.folder }
            let card = slot?.card
            return [
                "id": .string(e.id), "displayName": .string(e.displayName), "folder": .string(e.folder.path),
                "library": .string(e.library.lastPathComponent), "disabled": .bool(e.disabled),
                "scope": .string(e.scope.rawValue),
                "helper": e.helper == nil ? .null : (helpers?.json(e.id) ?? ["running": false]),
                "dataDirectory": .string(dataDirectory(for: e.id).path),
                "loaded": .bool(slot?.widget != nil),
                "supportsCollapsedSidebar": slot?.widget.map { .bool($0.supportsCollapsedSidebar) } ?? .null,
                "position": order.firstIndex(of: e.folder.path).map { .int($0) } ?? .null,
                "shown": .bool(card.map { !$0.isHidden } ?? false),
                "error": slot?.error.map { .string($0) } ?? .null,
                "trust": .string(trustKind(e)),
                "preferredHeight": slot?.requestedHeight.map { .double(Double($0)) } ?? .null,
                "height": card.flatMap { $0.isHidden ? nil : JSON.double(Double($0.frame.height)) } ?? .null,
            ]
        }
        return [
            "directory": .string(directory.path), "apiVersion": .string(MeumKit.apiVersion),
            "widgets": .array(entries), "error": slots.compactMap(\.error).first.map { .string($0) } ?? .null,
        ]
    }
}
