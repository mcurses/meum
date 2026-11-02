// The model as the control API shows it: a flat node encoding (no Swift enum wrappers), plus the diff of two
// model states into bus events. Host-free so the app, tests and widgets share one shape.
//
//   tree            {"version":"meum.v1","selectedWorkspaceID":…,"workspaces":[Workspace…],"agents":{tab: AgentState}}
//   Workspace       {"id","name","color","icon","pinned","cwd","selected","focusedCardID","focusedTabID","branch",
//                    "cwds":[…],"remotes":[…],"metadata":{key: value},"status":{key:{"value","color","url"}},
//                    "root":Node|null}
//   Node (card)     {"type":"card","id","selectedTabID","tabs":[Tab…]}
//   Node (split)    {"type":"split","id","axis":"horizontal"|"vertical","ratio","first":Node,"second":Node}
//   Tab             {"id","title","cwd","command","agent":AgentSnapshot|null}
import Foundation
import MeumCore

/// One `status.set` entry shown in a workspace's sidebar row.
public struct StatusEntry: Equatable, Sendable {
    public var value: String
    public var color: String?
    /// Opened when the entry is clicked in the sidebar (any scheme, e.g. `myboard://…` or `https://…`).
    public var url: String?
    public init(value: String, color: String? = nil, url: String? = nil) {
        self.value = value
        self.color = color
        self.url = url
    }
    public var json: JSON {
        ["value": .string(value), "color": color.map { .string($0) } ?? .null, "url": url.map { .string($0) } ?? .null]
    }
}

/// Per-workspace data that lives outside the persisted model (status entries, git branch).
public struct WorkspaceExtras: Equatable, Sendable {
    public var branch: String?
    /// Origin URLs (credentials stripped) of the repositories of the workspace's directory and its tabs'
    /// directories, the workspace's own first, distinct.
    public var remotes: [String] = []
    /// Insertion-ordered keys.
    public var status: [(key: String, entry: StatusEntry)] = []
    public init(branch: String? = nil) { self.branch = branch }

    public static func == (a: WorkspaceExtras, b: WorkspaceExtras) -> Bool {
        a.branch == b.branch && a.remotes == b.remotes && a.status.map(\.key) == b.status.map(\.key) && a.status.map(\.entry) == b.status.map(\.entry)
    }

    public mutating func set(_ key: String, _ entry: StatusEntry) {
        if let i = status.firstIndex(where: { $0.key == key }) { status[i].entry = entry } else { status.append((key, entry)) }
    }

    @discardableResult
    public mutating func clear(_ key: String) -> Bool {
        guard let i = status.firstIndex(where: { $0.key == key }) else { return false }
        status.remove(at: i)
        return true
    }

    public var statusJSON: JSON { .object(Dictionary(status.map { ($0.key, $0.entry.json) }, uniquingKeysWith: { _, b in b })) }
}

public enum ModelJSON {
    static func str(_ s: String?) -> JSON { s.map { .string($0) } ?? .null }
    static func uuid(_ u: UUID?) -> JSON { u.map { .string($0.uuidString) } ?? .null }

    public static func snapshot(_ a: AgentSnapshot?) -> JSON {
        guard let a else { return .null }
        return ["sessionID": .string(a.sessionID), "configDir": str(a.configDir),
                "transcriptPath": str(a.transcriptPath), "cwd": str(a.cwd)]
    }

    public static func tab(_ t: Tab) -> JSON {
        ["id": .string(t.id.uuidString), "title": str(t.title), "cwd": str(t.cwd), "command": str(t.command),
         "agent": snapshot(t.agent), "widget": str(t.widget),
         "widgetConfig": t.widgetConfig.flatMap { try? JSON.parse($0) } ?? .null]
    }

    public static func node(_ n: LayoutNode?) -> JSON {
        guard let n else { return .null }
        switch n {
        case .card(let c):
            return ["type": "card", "id": .string(c.id.uuidString), "selectedTabID": .string(c.selectedTabID.uuidString),
                    "tabs": .array(c.tabs.map(tab))]
        case .split(let s):
            return ["type": "split", "id": .string(s.id.uuidString), "axis": .string(s.axis.rawValue),
                    "ratio": .double(s.ratio), "first": node(s.first), "second": node(s.second)]
        }
    }

    /// The tab that has keyboard focus inside a workspace (focused card's selected tab).
    public static func focusedTab(_ ws: Workspace) -> Tab? { ws.focusedCard?.selectedTab }

    /// Distinct tab cwds in layout order.
    public static func cwds(_ ws: Workspace) -> [String] {
        var seen: Set<String> = []
        return ws.allTabs.compactMap(\.cwd).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The fields every workspace rendering shares (no layout tree).
    public static func workspaceSummary(_ ws: Workspace, selected: Bool, extras: WorkspaceExtras?,
                                        agents: WorkspaceSummary? = nil) -> [String: JSON] {
        var o: [String: JSON] = [
            "id": .string(ws.id.uuidString), "name": .string(ws.name), "color": str(ws.color),
            "icon": str(ws.icon),
            "pinned": .bool(ws.pinned), "cwd": str(ws.cwd), "selected": .bool(selected),
            "focusedCardID": uuid(ws.focusedCardID), "focusedTabID": uuid(focusedTab(ws)?.id),
            "branch": str(extras?.branch), "cwds": .array(cwds(ws).map { .string($0) }),
            "remotes": .array((extras?.remotes ?? []).map { .string($0) }),
            "metadata": .object((ws.metadata ?? [:]).mapValues { .string($0) }),
            "status": extras?.statusJSON ?? .object([:]), "tabCount": .int(ws.allTabs.count),
        ]
        if let agents { o["agents"] = agents.json }
        return o
    }

    public static func workspace(_ ws: Workspace, selected: Bool, extras: WorkspaceExtras?) -> JSON {
        var o = workspaceSummary(ws, selected: selected, extras: extras)
        o["root"] = node(ws.root)
        return .object(o)
    }

    public static func tree(_ s: AppState, extras: [UUID: WorkspaceExtras], agents: JSON) -> JSON {
        ["version": .string(ControlInfo.apiVersion), "selectedWorkspaceID": uuid(s.selectedWorkspaceID),
         "workspaces": .array(s.workspaces.map { workspace($0, selected: $0.id == s.selectedWorkspaceID, extras: extras[$0.id]) }),
         "agents": agents]
    }

    // MARK: events

    /// The tab with keyboard focus in the whole app: the selected workspace's focused card's selected tab.
    public static func focusedTab(_ s: AppState) -> (workspace: UUID, tab: UUID)? {
        guard let ws = s.selectedWorkspace, let t = focusedTab(ws) else { return nil }
        return (ws.id, t.id)
    }

    /// Bus events for the step `old` -> `new`, in a stable order: removals, additions, changes, selections.
    ///
    /// - `workspace.added {workspace: Workspace, index}`, `workspace.removed {id}`,
    ///   `workspace.changed {id, fields: [..], workspace: Workspace}` (fields: name, color, icon, pinned, cwd, index,
    ///   layout, focus), `workspace.selected {id, previous}`
    /// - `tab.added {tab: Tab, workspace, card}`, `tab.removed {id, workspace}`,
    ///   `tab.changed {id, workspace, fields: [..], tab: Tab}` (fields: title, cwd, command, agent, card),
    ///   `tab.selected {id, workspace, previous}` when the app-wide focused tab changes
    public static func diff(old: AppState, new: AppState) -> [(type: String, data: JSON)] {
        var removals: [(String, JSON)] = [], additions: [(String, JSON)] = [], changes: [(String, JSON)] = [],
            selections: [(String, JSON)] = []
        let oldWS = Dictionary(old.workspaces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newWS = Dictionary(new.workspaces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let oldIndex = Dictionary(old.workspaces.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })

        // tabs: id -> (workspace, card, tab)
        func tabIndex(_ s: AppState) -> [UUID: (UUID, UUID, Tab)] {
            var out: [UUID: (UUID, UUID, Tab)] = [:]
            for ws in s.workspaces { for c in ws.cards { for t in c.tabs { out[t.id] = (ws.id, c.id, t) } } }
            return out
        }
        let oldTabs = tabIndex(old), newTabs = tabIndex(new)

        for ws in old.workspaces where newWS[ws.id] == nil {
            for t in ws.allTabs where newTabs[t.id] == nil {
                removals.append(("tab.removed", ["id": .string(t.id.uuidString), "workspace": .string(ws.id.uuidString)]))
            }
            removals.append(("workspace.removed", ["id": .string(ws.id.uuidString)]))
        }
        for (i, ws) in new.workspaces.enumerated() {
            guard let o = oldWS[ws.id] else {
                additions.append(("workspace.added", ["workspace": workspace(ws, selected: ws.id == new.selectedWorkspaceID, extras: nil),
                                                      "index": .int(i)]))
                continue
            }
            var fields: [String] = []
            if o.name != ws.name { fields.append("name") }
            if o.color != ws.color { fields.append("color") }
            if o.icon != ws.icon { fields.append("icon") }
            if o.metadata != ws.metadata { fields.append("metadata") }
            if o.pinned != ws.pinned { fields.append("pinned") }
            if o.cwd != ws.cwd { fields.append("cwd") }
            if oldIndex[ws.id] != i { fields.append("index") }
            if layoutShape(o.root) != layoutShape(ws.root) { fields.append("layout") }
            if o.focusedCardID != ws.focusedCardID { fields.append("focus") }
            if !fields.isEmpty {
                changes.append(("workspace.changed", ["id": .string(ws.id.uuidString), "index": .int(i),
                                                      "fields": .array(fields.map { .string($0) }),
                                                      "workspace": workspace(ws, selected: ws.id == new.selectedWorkspaceID, extras: nil)]))
            }
        }
        // tabs of surviving workspaces (and tabs that moved between workspaces)
        for (id, (wsID, _, _)) in oldTabs where newTabs[id] == nil && newWS[wsID] != nil {
            removals.append(("tab.removed", ["id": .string(id.uuidString), "workspace": .string(wsID.uuidString)]))
        }
        for ws in new.workspaces {
            for c in ws.cards {
                for t in c.tabs {
                    guard let (_, oldCard, ot) = oldTabs[t.id] else {
                        additions.append(("tab.added", ["tab": tab(t), "workspace": .string(ws.id.uuidString),
                                                        "card": .string(c.id.uuidString)]))
                        continue
                    }
                    var fields: [String] = []
                    if ot.title != t.title { fields.append("title") }
                    if ot.cwd != t.cwd { fields.append("cwd") }
                    if ot.command != t.command { fields.append("command") }
                    if ot.agent != t.agent { fields.append("agent") }
                    if oldCard != c.id { fields.append("card") }
                    if !fields.isEmpty {
                        changes.append(("tab.changed", ["id": .string(t.id.uuidString), "workspace": .string(ws.id.uuidString),
                                                        "card": .string(c.id.uuidString),
                                                        "fields": .array(fields.map { .string($0) }), "tab": tab(t)]))
                    }
                    // a move: another card, or a new position among the same tabs of the same card
                    let newIndex = c.tabs.firstIndex { $0.id == t.id }!
                    var moved = oldCard != c.id
                    if !moved, let oc = old.workspace(oldTabs[t.id]!.0)?.card(oldCard),
                       Set(oc.tabs.map(\.id)) == Set(c.tabs.map(\.id)), oc.tabs.firstIndex(where: { $0.id == t.id }) != newIndex {
                        moved = true
                    }
                    if moved {
                        let (oldWS, _, _) = oldTabs[t.id]!
                        changes.append(("tab.moved", ["id": .string(t.id.uuidString), "workspace": .string(ws.id.uuidString),
                                                      "card": .string(c.id.uuidString), "index": .int(newIndex),
                                                      "fromWorkspace": .string(oldWS.uuidString),
                                                      "fromCard": .string(oldCard.uuidString)]))
                    }
                }
            }
        }
        // split ratios (mouse or keyboard resizing, split.resize)
        for ws in new.workspaces {
            guard let o = oldWS[ws.id]?.root else { continue }
            for s in ws.root?.splits ?? [] {
                if let os = o.split(s.id), os.ratio != s.ratio {
                    changes.append(("split.resized", ["id": .string(s.id.uuidString), "workspace": .string(ws.id.uuidString),
                                                      "axis": .string(s.axis.rawValue), "ratio": .double(s.ratio),
                                                      "previous": .double(os.ratio)]))
                }
            }
        }
        if old.selectedWorkspaceID != new.selectedWorkspaceID, let sel = new.selectedWorkspaceID {
            selections.append(("workspace.selected", ["id": .string(sel.uuidString), "previous": uuid(old.selectedWorkspaceID)]))
        }
        let of = focusedTab(old), nf = focusedTab(new)
        if of?.tab != nf?.tab, let nf {
            selections.append(("tab.selected", ["id": .string(nf.tab.uuidString), "workspace": .string(nf.workspace.uuidString),
                                                "previous": uuid(of?.tab)]))
        }
        return removals + additions + changes + selections
    }

    /// The tree without tab contents: split axes/ratios, card ids, tab ids and selected tabs.
    static func layoutShape(_ n: LayoutNode?) -> String {
        guard let n else { return "-" }
        switch n {
        case .card(let c): return "c(\(c.id):\(c.selectedTabID):\(c.tabs.map(\.id.uuidString).joined(separator: ",")))"
        case .split(let s): return "s(\(s.axis.rawValue):\(s.ratio):\(layoutShape(s.first)):\(layoutShape(s.second)))"
        }
    }
}

/// Reads the current git branch of a directory from `.git/HEAD`, without spawning git.
public enum GitHead {
    /// Branch name, `@<short sha>` for a detached HEAD, nil outside a repository.
    public static func branch(at dir: String, fileManager fm: FileManager = .default) -> String? {
        var url = URL(fileURLWithPath: dir).standardizedFileURL
        for _ in 0..<64 {
            let dotgit = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotgit.path, isDirectory: &isDir) {
                var gitDir = dotgit
                if !isDir.boolValue {
                    // worktree / submodule: "gitdir: <path>"
                    guard let s = try? String(contentsOf: dotgit, encoding: .utf8),
                          let line = s.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                    let p = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = p.hasPrefix("/") ? URL(fileURLWithPath: p) : url.appendingPathComponent(p)
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
                return parse(head: head)
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
    }

    public static func parse(head: String) -> String? {
        let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("ref:") {
            let ref = h.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
        }
        guard !h.isEmpty else { return nil }
        return "@" + h.prefix(7)
    }
}
