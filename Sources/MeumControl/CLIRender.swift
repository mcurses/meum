// Human-readable renderings for the `meum` CLI. Tolerant of the exact model JSON: it looks for the
// documented keys (workspaces, root, tabs, first/second, agents) and skips what it does not know.
import Foundation

enum CLIRender {
    static func short(_ id: String) -> String { String(id.prefix(8)) }

    static func workspaceList(_ json: JSON) -> [JSON] {
        if let a = json.arrayValue { return a }
        return json["workspaces"]?.arrayValue ?? []
    }

    struct TabRef {
        var id: String
        var title: String?
        var cwd: String?
        var workspaceID: String?
        var workspaceName: String?
        var selected: Bool
    }

    /// Every tab in a `tree` result, in layout order.
    static func tabs(in tree: JSON) -> [TabRef] {
        var out: [TabRef] = []
        for ws in workspaceList(tree) {
            collectTabs(ws["root"] ?? .null, ws: ws, into: &out)
        }
        return out
    }

    private static func collectTabs(_ node: JSON, ws: JSON, into out: inout [TabRef]) {
        guard case .object(let o) = node else { return }
        if let tabs = o["tabs"]?.arrayValue {
            let sel = o["selectedTabID"]?.stringValue
            for t in tabs {
                guard let id = t["id"]?.stringValue else { continue }
                out.append(TabRef(id: id, title: t["title"]?.stringValue, cwd: t["cwd"]?.stringValue,
                                  workspaceID: ws["id"]?.stringValue, workspaceName: ws["name"]?.stringValue,
                                  selected: id == sel))
            }
            return
        }
        if o["first"] != nil || o["second"] != nil {
            if let f = o["first"] { collectTabs(f, ws: ws, into: &out) }
            if let s = o["second"] { collectTabs(s, ws: ws, into: &out) }
            return
        }
        for k in o.keys.sorted() { collectTabs(o[k]!, ws: ws, into: &out) }
    }

    static func tree(_ tree: JSON) -> String {
        let wss = workspaceList(tree)
        let agents = tree["agents"]?.objectValue ?? [:]
        let selected = tree["selectedWorkspaceID"]?.stringValue
        var lines: [String] = []
        let api = tree["version"]?.stringValue ?? ControlInfo.apiVersion
        lines.append("\(api): \(wss.count) workspace\(wss.count == 1 ? "" : "s")")
        for ws in wss {
            let id = ws["id"]?.stringValue ?? "?"
            var head = (id == selected ? "* " : "  ") + (ws["name"]?.stringValue ?? "(unnamed)") + "  " + short(id)
            if ws["pinned"]?.boolValue == true { head += "  [pinned]" }
            if let c = ws["color"]?.stringValue, !c.isEmpty { head += "  \(c)" }
            if let cwd = ws["cwd"]?.stringValue, !cwd.isEmpty { head += "  \(cwd)" }
            let wsTabs = tabs(in: .object(["workspaces": .array([ws])]))
            let states = wsTabs.compactMap { agents[$0.id] }
            if !states.isEmpty {
                let unread = states.contains { $0["unread"]?.boolValue == true }
                let needs = states.contains { $0["phase"]?.stringValue == "needsInput" }
                head += "  agents: \(states.count) live" + (needs ? ", needs input" : "") + (unread ? ", unread" : "")
            }
            lines.append(head)
            if let root = ws["root"], !root.isNull {
                walk(root, agents: agents, indent: "    ", into: &lines)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func walk(_ node: JSON, agents: [String: JSON], indent: String, into lines: inout [String]) {
        guard case .object(let o) = node else { return }
        if let tabs = o["tabs"]?.arrayValue {
            lines.append(indent + "card " + short(o["id"]?.stringValue ?? "?"))
            let sel = o["selectedTabID"]?.stringValue
            for t in tabs {
                let id = t["id"]?.stringValue ?? "?"
                var l = indent + "  " + (id == sel ? "> " : "  ") + "tab " + short(id)
                l += "  " + (t["title"]?.stringValue ?? "(untitled)")
                if let cwd = t["cwd"]?.stringValue, !cwd.isEmpty { l += "  \(cwd)" }
                if let a = agents[id] { l += "  " + agentSummary(a) }
                lines.append(l)
            }
            return
        }
        if o["first"] != nil || o["second"] != nil {
            var l = indent + "split"
            if let axis = o["axis"]?.stringValue { l += " \(axis)" }
            if let r = o["ratio"]?.doubleValue { l += String(format: " %.2f", r) }
            lines.append(l)
            if let f = o["first"] { walk(f, agents: agents, indent: indent + "  ", into: &lines) }
            if let s = o["second"] { walk(s, agents: agents, indent: indent + "  ", into: &lines) }
            return
        }
        for k in o.keys.sorted() { walk(o[k]!, agents: agents, indent: indent, into: &lines) }
    }

    static func agentSummary(_ a: JSON) -> String {
        var s = "claude " + (a["phase"]?.stringValue ?? "?")
        if a["unread"]?.boolValue == true { s += " (unread)" }
        if let sid = a["sessionID"]?.stringValue { s += " " + short(sid) }
        return s
    }

    static func workspaceTable(_ json: JSON) -> String {
        let rows = workspaceList(json)
        if rows.isEmpty { return "no workspaces" }
        return rows.map { w in
            var l = (w["selected"]?.boolValue == true ? "* " : "  ") + short(w["id"]?.stringValue ?? "?") + "  " + (w["name"]?.stringValue ?? "(unnamed)")
            if w["pinned"]?.boolValue == true { l += "  [pinned]" }
            if let cwd = w["cwd"]?.stringValue, !cwd.isEmpty { l += "  \(cwd)" }
            return l
        }.joined(separator: "\n")
    }

    static func event(_ e: Event) -> String {
        "#\(e.seq) \(e.type) \(e.data.compactString)"
    }
}
