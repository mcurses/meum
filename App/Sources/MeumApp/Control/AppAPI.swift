import AppKit
import MeumControl
import MeumCore

/// Every method in `MeumMethod.handlerOwned`, on the app's store. Runs on the main actor (`ControlBridge`).
/// Params follow docs/design/architecture.md and the `meum` CLI: workspace methods take `id` (or
/// `workspace`), tab methods take `tab` (or `id`). Ids are UUIDs, any case; workspaces also match by exact name.
@MainActor
final class AppAPI {
    unowned let control: AppControl
    var controller: WorkspaceController { control.controller }
    var store: WorkspaceStore { controller.store }
    var state: AppState { store.state }

    init(control: AppControl) { self.control = control }

    /// `widget.send` and `widget.screenshot`: they wait for the widget's reply.
    func handleAsync(method: String, params p: JSON) async throws -> JSON {
        guard let widgets = control.widgets else { throw ControlError.unavailable("no widget host") }
        var tab: UUID?
        if let t = nonEmpty(p["tab"]?.stringValue) {
            guard let id = UUID(uuidString: t) ?? state.workspaces.lazy.flatMap(\.allTabs).first(where: {
                $0.id.uuidString.lowercased().hasPrefix(t.lowercased())
            })?.id else { throw ControlError.notFound("no tab '\(t)'") }
            tab = id
        }
        let widgetID = nonEmpty(p["widget"]?.stringValue)
        guard tab != nil || widgetID != nil else { throw ControlError.invalidParams("needs 'tab' (a widget tab) or 'widget' (a sidebar widget id)") }
        let (w, view) = try widgets.target(tab: tab, widget: widgetID)
        if method == MeumMethod.widgetSend {
            guard let m = p["message"], !m.isNull else { throw ControlError.invalidParams("needs 'message'") }
            let text = m.stringValue.flatMap { (try? JSON.parse($0)) != nil ? $0 : nil } ?? m.compactString
            let reply = try await widgets.send(text, to: w)
            return (try? JSON.parse(reply)) ?? .string(reply)
        }
        // screenshot: the widget's own answer, else meum draws the view
        var png: Data?
        if let r = try? await widgets.send(#"{"action":"screenshot"}"#, to: w, timeout: 15),
           let b64 = (try? JSON.parse(r))?["png"]?.stringValue {
            png = Data(base64Encoded: b64)
        }
        if png == nil { png = WidgetManager.snapshot(view) }
        guard let png else { throw ControlError.unavailable("could not take a screenshot of that widget") }
        if let path = nonEmpty(p["path"]?.stringValue) {
            let url = URL(fileURLWithPath: expand(path))
            try png.write(to: url)
            return ["path": .string(url.path), "bytes": .int(png.count)]
        }
        return ["png": .string(png.base64EncodedString()), "bytes": .int(png.count)]
    }

    /// `widget.catalog`, `widget.install`, `widget.update`: they wait for the network.
    func handleUpdate(method: String, params p: JSON) async throws -> JSON {
        guard let u = control.updater else { throw ControlError.unavailable("no updater") }
        guard u.canUpdate else { return u.statusJSON(nil) }
        do {
            let r = try await u.check()
            if method == MeumMethod.updateInstall {
                guard let r else { return u.statusJSON(nil) }
                let relaunch = p["relaunch"]?.boolValue ?? true
                try await u.install(r, relaunch: false)
                if relaunch {
                    // answer first, then restart
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { u.relaunch(Bundle.main.bundleURL) }
                }
                return ["installed": .string(r.version), "relaunching": .bool(relaunch)]
            }
            return u.statusJSON(r)
        } catch let e as ControlError {
            throw e
        } catch {
            throw ControlError.unavailable("\(error)")
        }
    }

    func handleLibrary(method: String, params p: JSON) async throws -> JSON {
        let installer = control.installer
        do {
            switch method {
            case MeumMethod.widgetCatalog:
                return try await installer.catalogJSON()
            default:
                guard let id = nonEmpty(p["id"]?.stringValue) else { throw ControlError.invalidParams("needs 'id'") }
                return try await installer.install(id, updateOnly: method == MeumMethod.widgetUpdate)
            }
        } catch let e as ControlError {
            throw e
        } catch {
            throw ControlError.unavailable("\(error)")
        }
    }

    func handle(method: String, params p: JSON) throws -> JSON {
        switch method {
        case MeumMethod.tree:
            return ModelJSON.tree(state, extras: controller.workspaceExtras, agents: control.agents.statesJSON)

        case MeumMethod.workspaceList:
            return .array(state.workspaces.map { ws in
                .object(ModelJSON.workspaceSummary(ws, selected: ws.id == state.selectedWorkspaceID,
                                                   extras: controller.workspaceExtras[ws.id],
                                                   agents: control.agents.summary(tabs: ws.allTabs.map(\.id.uuidString))))
            })

        case MeumMethod.workspaceNew:
            let cwd = p["cwd"]?.stringValue.map(expand)
            if let cwd { try requireDirectory(cwd) }
            let color = try p["color"]?.stringValue.map(hexColor)
            let id = controller.newWorkspace(name: nonEmpty(p["name"]?.stringValue), cwd: cwd, color: color)
            return ["id": .string(id.uuidString)]

        case MeumMethod.workspaceSelect:
            let ws = try workspace(p)
            store.mutate { $0.selectWorkspace(ws.id) }
            controller.focusTerminal()
            return .null

        case MeumMethod.workspaceRename:
            let ws = try workspace(p)
            guard let name = nonEmpty(p["name"]?.stringValue) else { throw ControlError.invalidParams("needs 'name'") }
            store.mutate(.cosmetic) { $0.renameWorkspace(ws.id, to: name) }
            return .null

        case MeumMethod.workspaceClose:
            controller.closeWorkspace(try workspace(p).id)
            return .null

        case MeumMethod.workspaceReorder:
            let ws = try workspace(p)
            guard let i = p["index"]?.intValue else { throw ControlError.invalidParams("needs 'index'") }
            store.mutate(.cosmetic) { $0.moveWorkspace(ws.id, to: max(0, min(i, $0.workspaces.count - 1))) }
            return .null

        case MeumMethod.workspaceSetColor:
            let ws = try workspace(p)
            let c = p["color"]
            let hex: String? = (c == nil || c!.isNull || c?.stringValue == "none" || c?.stringValue == "")
                ? nil : try hexColor(c?.stringValue ?? "")
            store.mutate(.cosmetic) { $0.setColor(ws.id, hex) }
            return .null

        case MeumMethod.workspaceSetLabels:
            let ws = try workspace(p)
            // without 'labels': a read, changing nothing
            guard p["labels"] != nil else {
                return ["id": .string(ws.id.uuidString), "labels": .array((ws.labels ?? []).map { .string($0) })]
            }
            guard let arr = p["labels"]?.arrayValue else { throw ControlError.invalidParams("needs 'labels' (a list of strings)") }
            let labels: [String]
            do { labels = try AgentSnapshot.validLabels(arr.map { $0.stringValue ?? "" }) } catch {
                throw ControlError.invalidParams("\(error)")
            }
            store.mutate(.cosmetic) { $0.updateWorkspace(ws.id) { $0.labels = labels.isEmpty ? nil : labels } }
            return ["id": .string(ws.id.uuidString), "labels": .array(labels.map { .string($0) })]

        case MeumMethod.workspaceSetIcon:
            let ws = try workspace(p)
            let raw = p["icon"]
            var icon: String?
            if let raw, !raw.isNull, let s = raw.stringValue, !s.isEmpty, s != "none" {
                guard let parsed = WorkspaceIcon(s) else {
                    throw ControlError.invalidParams("icon: sf:<SF Symbol name> (preferred), or up to two characters")
                }
                if case .symbol(let name) = parsed, NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
                    throw ControlError.invalidParams("no SF Symbol named '\(name)'")
                }
                icon = parsed.raw
            }
            store.mutate(.cosmetic) { $0.setIcon(ws.id, icon) }
            return ["id": .string(ws.id.uuidString), "icon": icon.map { .string($0) } ?? .null]

        case MeumMethod.workspaceSetMeta:
            let ws = try workspace(p)
            var changes: [String: String?] = [:]
            if let o = p["metadata"]?.objectValue {
                for (k, v) in o { changes[k] = v.isNull ? .some(nil) : .some(v.stringValue ?? v.compactString) }
            } else {
                guard let k = nonEmpty(p["key"]?.stringValue) else { throw ControlError.invalidParams("needs 'key' (and 'value', null removes) or 'metadata'") }
                let v = p["value"]
                changes[k] = (v == nil || v!.isNull) ? .some(nil) : .some(v!.stringValue ?? v!.compactString)
            }
            for k in changes.keys where k.isEmpty || k.count > 128 { throw ControlError.invalidParams("bad key '\(k)'") }
            store.mutate(.cosmetic) { s in
                _ = s.updateWorkspace(ws.id) { w in
                    var m = w.metadata ?? [:]
                    for (k, v) in changes { m[k] = v }
                    w.metadata = m.isEmpty ? nil : m
                }
            }
            let now = state.workspace(ws.id)?.metadata ?? [:]
            return ["id": .string(ws.id.uuidString), "metadata": .object(now.mapValues { .string($0) })]

        case MeumMethod.groupList:
            return ["groups": ModelJSON.groups(state)]

        case MeumMethod.groupNew:
            let ids = try workspaceList(p["workspaces"])
            guard !ids.isEmpty else { throw ControlError.invalidParams("needs 'workspaces' (one or more)") }
            let name = p["name"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !name.isEmpty else { throw ControlError.invalidParams("needs 'name'") }
            var made: UUID?
            store.mutate(.cosmetic) { made = $0.createGroup(name: name, workspaces: ids) }
            guard let made, let g = state.group(made) else { throw ControlError.internalError("group not created") }
            return ModelJSON.group(g, in: state)

        case MeumMethod.groupRename:
            let g = try groupRef(p)
            guard let name = p["name"]?.stringValue, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ControlError.invalidParams("needs 'name'")
            }
            store.mutate(.cosmetic) { $0.renameGroup(g.id, to: name) }
            return ModelJSON.group(state.group(g.id)!, in: state)

        case MeumMethod.groupSetCollapsed:
            let g = try groupRef(p)
            let want = p["collapsed"].flatMap { $0.isNull ? nil : $0.boolValue } ?? !g.collapsed
            store.mutate(.cosmetic) { $0.setGroupCollapsed(g.id, want) }
            return ["collapsed": .bool(want)]

        case MeumMethod.groupUngroup:
            let g = try groupRef(p)
            store.mutate(.cosmetic) { $0.ungroup(g.id) }
            return .null

        case MeumMethod.workspaceSetGroup:
            var ids = try workspaceList(p["ids"])
            if ids.isEmpty { ids = [try workspace(p).id] }
            let target: UUID?
            if let v = p["group"], !v.isNull, v.stringValue != "none" { target = try groupRef(["group": v]).id } else { target = nil }
            store.mutate(.cosmetic) { $0.setGroup(ids, to: target) }
            return ["groups": ModelJSON.groups(state)]

        case MeumMethod.sidebarSetCollapsed:
            let current = controller.settings.sidebarCollapsed
            let want = p["collapsed"].flatMap { $0.isNull ? nil : $0.boolValue } ?? !current
            if want != current { controller.setSidebarCollapsed(want) }
            return ["collapsed": .bool(controller.settings.sidebarCollapsed)]

        case MeumMethod.workspacePin:
            let ws = try workspace(p)
            store.mutate(.cosmetic) { $0.setPinned(ws.id, p["pinned"]?.boolValue ?? true) }
            return .null

        case MeumMethod.workspaceMarkRead, MeumMethod.workspaceMarkUnread:
            let ws = try workspace(p)
            let tabs = ws.allTabs.map(\.id.uuidString)
            if method == MeumMethod.workspaceMarkRead { control.agents.markRead(tabs: tabs) } else { control.agents.markUnread(tabs: tabs) }
            return .null

        case MeumMethod.tabNew:
            return try newTab(p)

        case MeumMethod.tabSelect:
            let (_, tab) = try self.tab(p)
            controller.selectTab(tab.id)
            return .null

        case MeumMethod.tabClose:
            let (_, tab) = try self.tab(p)
            controller.closeTab(tab.id)
            return .null

        case MeumMethod.tabSendText:
            let (_, tab) = try self.tab(p)
            guard let text = p["text"]?.stringValue else { throw ControlError.invalidParams("needs 'text'") }
            try sendText(text, to: tab)
            return .null

        case MeumMethod.tabMove:
            return try moveTab(p)

        case MeumMethod.tabFocused:
            guard let ws = state.selectedWorkspace, let tab = ModelJSON.focusedTab(ws) else {
                throw ControlError.notFound("no focused tab")
            }
            return ["workspace": .string(ws.id.uuidString), "tab": .string(tab.id.uuidString),
                    "widget": tab.widget.map { .string($0) } ?? .null,
                    // the Claude Code session's own name (display only; address the tab by its id)
                    "name": tab.agent?.name.map { .string($0) } ?? .null,
                    // labels the session attached to itself (tab.setLabels)
                    "labels": .array((tab.agent?.labels ?? []).map { .string($0) })]

        case MeumMethod.tabSetLabels:
            let (_, tab) = try self.tab(p)
            // without 'labels': a read, changing nothing
            guard p["labels"] != nil else {
                return ["tab": .string(tab.id.uuidString), "labels": .array((tab.agent?.labels ?? []).map { .string($0) })]
            }
            guard let arr = p["labels"]?.arrayValue else { throw ControlError.invalidParams("needs 'labels' (a list of strings)") }
            let labels: [String]
            do { labels = try AgentSnapshot.validLabels(arr.map { $0.stringValue ?? "" }) } catch {
                throw ControlError.invalidParams("\(error)")
            }
            guard tab.agent != nil else {
                throw ControlError.unavailable("tab \(tab.id.uuidString) has no Claude Code session (labels belong to one; are meum's hooks installed?)")
            }
            store.mutate(.cosmetic) { $0.updateTab(tab.id) { $0.agent?.labels = labels.isEmpty ? nil : labels } }
            control.bus.publish("tab.labels", ["tab": .string(tab.id.uuidString), "labels": .array(labels.map { .string($0) })])
            return ["tab": .string(tab.id.uuidString), "labels": .array(labels.map { .string($0) })]

        case MeumMethod.tabPaste:
            let (_, tab) = try self.tab(p)
            guard let text = p["text"]?.stringValue else { throw ControlError.invalidParams("needs 'text'") }
            if tab.isWidget { throw ControlError.unavailable("tab \(tab.id.uuidString) is a widget tab, not a terminal") }
            guard let surface = controller.surface(forTab: tab.id) else {
                throw ControlError.unavailable("tab \(tab.id.uuidString) has no attached terminal yet (its workspace was not shown since meum started)")
            }
            // ghostty's paste path: bracketed exactly when the program asked for it; the surface may be hidden
            // (a parked workspace) and keeps its focus state either way
            let submit = p["submit"]?.boolValue ?? false
            surface.insertPasted(text: text, submit: submit)
            return ["tab": .string(tab.id.uuidString), "submitted": .bool(submit)]

        case MeumMethod.splitResize:
            guard let ref = p["split"]?.stringValue ?? p["id"]?.stringValue, let id = UUID(uuidString: ref),
                  state.workspaces.contains(where: { $0.split(id) != nil }) else {
                throw ControlError.notFound("no split '\(p["split"]?.stringValue ?? p["id"]?.stringValue ?? "")'")
            }
            guard let r = p["ratio"]?.doubleValue, r.isFinite else { throw ControlError.invalidParams("needs 'ratio' (0.1…0.9)") }
            controller.setRatio(split: id, ratio: r)
            let now = state.workspaces.lazy.compactMap { $0.split(id) }.first?.ratio ?? r
            return ["split": .string(id.uuidString), "ratio": .double(now)]

        case MeumMethod.widgetList:
            guard let w = control.widgets else { throw ControlError.unavailable("no widget host") }
            return w.listJSON()

        case MeumMethod.widgetReload:
            guard let w = control.widgets else { throw ControlError.unavailable("no widget host") }
            w.reload()
            return w.listJSON()

        case MeumMethod.widgetRemove:
            guard let id = nonEmpty(p["id"]?.stringValue) else { throw ControlError.invalidParams("needs 'id'") }
            return try control.installer.remove(id, data: p["data"]?.boolValue ?? false)

        case MeumMethod.widgetAllow:
            // trust is not the socket's to give: open Settings where the user can, and say why
            control.onOpenSettings?("widgets")
            throw ControlError(code: "forbidden", message: SettingsJSON.trustRefusal("a widget's trust")
                + "; Settings is open at Widgets")

        case MeumMethod.widgetEnable:
            guard let w = control.widgets else { throw ControlError.unavailable("no widget host") }
            guard let id = nonEmpty(p["id"]?.stringValue) else { throw ControlError.invalidParams("needs 'id'") }
            try w.setEnabled(id, p["enabled"]?.boolValue ?? true)
            return w.listJSON()

        case MeumMethod.settingsGet:
            guard let settings = control.settings else { throw ControlError.unavailable("no settings") }
            if let key = p["key"]?.stringValue {
                guard let v = SettingsJSON.value(settings.value, key) else {
                    throw ControlError.invalidParams("unknown setting '\(key)'; known: \(SettingsJSON.keys.joined(separator: ", "))")
                }
                return ["key": .string(key), "value": v]
            }
            return ["settings": SettingsJSON.object(settings.value), "path": .string(settings.store.url.path)]

        case MeumMethod.settingsSet:
            guard let settings = control.settings else { throw ControlError.unavailable("no settings") }
            guard let key = nonEmpty(p["key"]?.stringValue) else { throw ControlError.invalidParams("needs 'key'") }
            guard let value = p["value"] else { throw ControlError.invalidParams("needs 'value'") }
            if SettingsJSON.socketReadOnly.contains(key) {
                throw ControlError(code: "forbidden", message: SettingsJSON.socketRefusal(key))
            }
            return ["key": .string(key), "value": try settings.set(key, value)]

        case MeumMethod.statusSet:
            let ws = try workspace(p, keys: ["workspace", "id"])
            guard let key = nonEmpty(p["key"]?.stringValue) else { throw ControlError.invalidParams("needs 'key'") }
            let value = p["value"]?.stringValue ?? p["value"].map { $0.compactString } ?? ""
            let color = try p["color"]?.stringValue.map(hexColor)
            let url = nonEmpty(p["url"]?.stringValue)
            if let url, URL(string: url)?.scheme == nil {
                throw ControlError.invalidParams("'url' must be a URL with a scheme, e.g. myboard://… or https://…")
            }
            var e = controller.workspaceExtras[ws.id] ?? WorkspaceExtras()
            e.set(key, StatusEntry(value: value, color: color, url: url))
            controller.workspaceExtras[ws.id] = e
            control.bus.publish("status.changed", ["workspace": .string(ws.id.uuidString), "key": .string(key),
                                                   "value": .string(value), "color": color.map { .string($0) } ?? .null,
                                                   "url": url.map { .string($0) } ?? .null])
            return .null

        case MeumMethod.statusClear:
            let ws = try workspace(p, keys: ["workspace", "id"])
            guard let key = nonEmpty(p["key"]?.stringValue) else { throw ControlError.invalidParams("needs 'key'") }
            var e = controller.workspaceExtras[ws.id] ?? WorkspaceExtras()
            if e.clear(key) {
                controller.workspaceExtras[ws.id] = e
                control.bus.publish("status.changed", ["workspace": .string(ws.id.uuidString), "key": .string(key),
                                                       "value": .null, "color": .null])
            }
            return .null

        case MeumMethod.notify:
            guard let title = nonEmpty(p["title"]?.stringValue) else { throw ControlError.invalidParams("needs 'title'") }
            var tabID: UUID?
            if p["tab"] != nil, p["tab"]?.isNull == false { tabID = try tab(p, keys: ["tab"]).1.id }
            return control.notify(title: title, body: p["body"]?.stringValue, tab: tabID)

        case MeumMethod.agentHook:
            return try control.handleHook(p)

        default:
            throw ControlError.methodNotFound(method)
        }
    }

    // MARK: tabs

    private func newTab(_ p: JSON) throws -> JSON {
        let ws: Workspace
        if p["workspace"]?.stringValue != nil { ws = try workspace(p, keys: ["workspace"]) } else {
            guard let sel = state.selectedWorkspace else { throw ControlError.notFound("no workspace") }
            ws = sel
        }
        var cardID: UUID?
        if let c = p["card"]?.stringValue {
            guard let id = UUID(uuidString: c), ws.card(id) != nil else { throw ControlError.notFound("no card '\(c)' in that workspace") }
            cardID = id
        }
        var cwd = p["cwd"]?.stringValue.map(expand)
        if let cwd { try requireDirectory(cwd) } else { cwd = ModelJSON.focusedTab(ws)?.cwd ?? ws.cwd }
        var tab = Tab(cwd: cwd, command: nonEmpty(p["command"]?.stringValue))
        if let w = nonEmpty(p["widget"]?.stringValue) {
            guard let widgets = control.widgets, let e = widgets.entry(w) else {
                throw ControlError.notFound("no widget '\(w)'; see `meum widget list`")
            }
            var config: String?
            if let c = p["config"], !c.isNull {
                if let text = c.stringValue {
                    guard (try? JSON.parse(text)) != nil else { throw ControlError.invalidParams("'config' is not JSON") }
                    config = text
                } else {
                    config = c.compactString
                }
            }
            tab = Tab(title: e.displayName, cwd: cwd, widget: e.id, widgetConfig: config)
        }
        var placed: UUID?
        defer {
            // a widget tab opened from outside (a Claude session, a script) never takes the keyboard: the
            // workspace keeps its focused card
            if tab.isWidget, let prior = ws.focusedCardID, prior != placed {
                store.mutate(.structure(animate: false), save: true) { $0.updateWorkspace(ws.id) { $0.focusCard(prior) } }
            }
        }
        switch p["split"]?.stringValue {
        case nil:
            store.mutate { $0.updateWorkspace(ws.id) { placed = $0.addTab(tab, toCard: cardID) } }
        case "right", "down":
            let placement: SplitPlacement = p["split"]?.stringValue == "down" ? .down : .right
            store.mutate { $0.updateWorkspace(ws.id) { placed = $0.split(cardID, placement: placement, tab: tab) } }
        default:
            throw ControlError.invalidParams("'split' must be \"right\" or \"down\"")
        }
        return ["id": .string(tab.id.uuidString), "workspace": .string(ws.id.uuidString),
                "card": placed.map { .string($0.uuidString) } ?? .null]
    }

    /// `tab.move {tab, card?, index?, split?: left|right|up|down}` (`targetCard` is an alias of `card`).
    /// Without `split`: into `card` (default: the tab's own card) at `index` (its position there afterwards;
    /// default the end). With `split`: `card` (default: the tab's own card) is split and the tab goes into the
    /// new card on that side.
    private func moveTab(_ p: JSON) throws -> JSON {
        let (_, tab) = try self.tab(p)
        var card = state.workspace(containingTab: tab.id)?.card(containingTab: tab.id)?.id
        if let c = p["card"]?.stringValue ?? p["targetCard"]?.stringValue {
            guard let id = UUID(uuidString: c), state.workspace(containingCard: id) != nil else {
                throw ControlError.notFound("no card '\(c)'")
            }
            card = id
        }
        guard let card else { throw ControlError.notFound("tab has no card") }
        let index = p["index"]?.intValue
        if p["index"] != nil, p["index"]?.isNull == false, index == nil { throw ControlError.invalidParams("'index' must be an integer") }
        if let s = p["split"]?.stringValue {
            guard let side = Direction(rawValue: s) else {
                throw ControlError.invalidParams("'split' must be left, right, up or down")
            }
            guard let new = controller.moveTab(tab.id, splitting: card, side: side) else {
                throw ControlError.conflict("cannot split a card by its only tab")
            }
            return ["tab": .string(tab.id.uuidString), "card": .string(new.uuidString),
                    "workspace": .string(state.workspace(containingCard: new)?.id.uuidString ?? "")]
        }
        guard controller.moveTab(tab.id, toCard: card, index: index) else { throw ControlError.internalError("move failed") }
        let ws = state.workspace(containingTab: tab.id)
        let final = ws?.card(containingTab: tab.id)
        return ["tab": .string(tab.id.uuidString), "card": .string(final?.id.uuidString ?? card.uuidString),
                "index": .int(final?.tabs.firstIndex { $0.id == tab.id } ?? 0),
                "workspace": .string(ws?.id.uuidString ?? "")]
    }

    /// Raw input into the tab's pty through zmx (works for tabs of hidden workspaces too, as long as their
    /// session runs).
    private func sendText(_ text: String, to tab: Tab) throws {
        let name = controller.sessions.name(for: tab.id)
        guard controller.sessions.list().contains(name) else {
            throw ControlError.unavailable("tab \(tab.id.uuidString) has no running session yet (its workspace was never shown)")
        }
        guard ZmxSessions.run(binary: controller.sessions.binary, ["send", name, text]) != nil else {
            throw ControlError.internalError("zmx send failed")
        }
    }

    // MARK: references

    /// A list of workspace references (ids or unique names).
    private func workspaceList(_ v: JSON?) throws -> [UUID] {
        guard let v, !v.isNull else { return [] }
        guard let arr = v.arrayValue else { throw ControlError.invalidParams("expected a list of workspaces") }
        return try arr.map { try workspace(["id": $0]).id }
    }

    /// `group`: an id or a unique group name.
    private func groupRef(_ p: JSON) throws -> WorkspaceGroup {
        guard let ref = p["group"]?.stringValue ?? p["id"]?.stringValue, !ref.isEmpty else {
            throw ControlError.invalidParams("needs 'group' (an id or a name)")
        }
        if let id = UUID(uuidString: ref), let g = state.group(id) { return g }
        let byName = state.groups.filter { $0.name == ref }
        if byName.count == 1 { return byName[0] }
        throw ControlError.notFound(byName.isEmpty ? "no group '\(ref)'" : "several groups are called '\(ref)'")
    }

    private func workspace(_ p: JSON, keys: [String] = ["id", "workspace"]) throws -> Workspace {
        guard let ref = keys.lazy.compactMap({ p[$0]?.stringValue }).first, !ref.isEmpty else {
            throw ControlError.invalidParams("needs '\(keys[0])' (a workspace id)")
        }
        if let id = UUID(uuidString: ref), let ws = state.workspace(id) { return ws }
        let byName = state.workspaces.filter { $0.name == ref }
        if byName.count == 1 { return byName[0] }
        throw ControlError.notFound("no workspace '\(ref)'")
    }

    private func tab(_ p: JSON, keys: [String] = ["tab", "id"]) throws -> (Workspace, Tab) {
        guard let ref = keys.lazy.compactMap({ p[$0]?.stringValue }).first, !ref.isEmpty else {
            throw ControlError.invalidParams("needs '\(keys[0])' (a tab id)")
        }
        guard let id = UUID(uuidString: ref), let ws = state.workspace(containingTab: id), let t = ws.tab(id) else {
            throw ControlError.notFound("no tab '\(ref)'")
        }
        return (ws, t)
    }

    // MARK: helpers

    private func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    private func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    private func requireDirectory(_ path: String) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw ControlError.invalidParams("not a directory: \(path)")
        }
    }

    private func hexColor(_ s: String) throws -> String {
        var h = s.trimmingCharacters(in: .whitespaces).lowercased()
        if !h.hasPrefix("#") { h = "#" + h }
        guard h.count == 7, UInt32(h.dropFirst(), radix: 16) != nil else {
            throw ControlError.invalidParams("colour must be #rrggbb, got '\(s)'")
        }
        return h
    }
}
