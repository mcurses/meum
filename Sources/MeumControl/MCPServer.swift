// `meum mcp`: an MCP server on stdio (newline-delimited JSON-RPC 2.0) for Claude Code sessions running in meum.
// Every tool is a thin call to meum's control socket. A session inside a meum tab has MEUM_SOCKET, MEUM_WORKSPACE
// and MEUM_TAB in its environment, so it knows where it is; outside meum the server offers no tools.
//
// Install: claude mcp add meum -- meum mcp   (the meum CLI is on PATH in every meum tab)
import Foundation

public enum MCPServer {
    public static let protocolVersion = "2025-06-18"

    /// Where the session runs (from its environment).
    public struct Here: Sendable {
        public var socket: String?
        public var workspace: String?
        public var tab: String?
        public init(env: [String: String]) {
            socket = env["MEUM_SOCKET"]
            workspace = env["MEUM_WORKSPACE"]
            tab = env["MEUM_TAB"]
        }
        public var insideMeum: Bool { socket != nil }
    }

    static let instructions = """
    You are running inside meum, the user's terminal workspace app: a sidebar of workspaces, each with tiled \
    cards of terminal tabs. These tools control meum. Besides terminals, a card can hold widget tabs: native \
    widgets such as a browser, shown next to the terminals and saved with the workspace. Call meum_context first: \
    it says which workspace and tab you are in, which widgets are installed, and which widget tabs your workspace \
    already has. You decide whether to reuse an existing widget tab (meum_widget_send, e.g. {"navigate": URL}) or \
    open a new one (meum_open_widget). Opening one in your own workspace is fine without asking; it never takes \
    the keyboard from the user. To check what a widget shows (e.g. a page you built), use meum_widget_screenshot. \
    meum_set_labels puts short labels on your own tab (what you do here), and meum_set_workspace changes your \
    workspace's name, icon and colour.
    """

    static func schema(_ props: [String: JSON], required: [String] = []) -> JSON {
        ["type": "object", "properties": .object(props), "required": .array(required.map { .string($0) })]
    }

    static let tools: [JSON] = [
        ["name": "meum_context",
         "description": "Where you are in meum (workspace, tab), all workspaces, the installed widgets, and the widget tabs of your workspace (with their settings).",
         "inputSchema": schema([:])],
        ["name": "meum_open_widget",
         "description": "Open a widget as a tab in a workspace (default: yours), as a new card next to your terminal or as a tab in an existing card. Returns the new tab's id. For the browser widget pass config {\"url\": \"http://localhost:5173\"}.",
         "inputSchema": schema([
            "widget": ["type": "string", "description": "Widget id from meum_context"],
            "config": ["type": "object", "description": "The widget's settings, saved with the tab"],
            "placement": ["type": "string", "enum": ["right", "down", "tab"],
                          "description": "right/down: a new card split off the workspace's focused card (default right); tab: a tab in `card`"],
            "card": ["type": "string", "description": "Card id for placement tab (default: the focused card)"],
            "workspace": ["type": "string", "description": "Workspace id or name (default: yours)"],
         ], required: ["widget"])],
        ["name": "meum_widget_send",
         "description": "Send a widget tab a JSON message and get its reply. The browser widget takes {\"navigate\": URL}, {\"reload\": true}, {\"back\": true}, {\"forward\": true}, {\"state\": true} (url, title, loading, console errors).",
         "inputSchema": schema([
            "tab": ["type": "string", "description": "The widget tab's id (or a unique prefix)"],
            "message": ["type": "object"],
         ], required: ["tab", "message"])],
        ["name": "meum_widget_screenshot",
         "description": "A PNG of what a widget tab shows right now (also when its workspace is not on screen).",
         "inputSchema": schema(["tab": ["type": "string"]], required: ["tab"])],
        ["name": "meum_close_tab",
         "description": "Close a tab (a widget tab, or a terminal tab: that ends its shell).",
         "inputSchema": schema(["tab": ["type": "string"]], required: ["tab"])],
        ["name": "meum_set_status",
         "description": "Show a key/value status entry on a workspace's sidebar row (default: yours). With url, a click on it opens the URL.",
         "inputSchema": schema([
            "key": ["type": "string"], "value": ["type": "string"],
            "color": ["type": "string", "description": "#rrggbb"], "url": ["type": "string"],
            "workspace": ["type": "string"],
         ], required: ["key", "value"])],
        ["name": "meum_set_labels",
         "description": "Attach short labels to your own session (e.g. what you do here); meum shows them as chips on your tab. At most 4, each at most 24 characters; an empty list removes them. They go away when your session ends.",
         "inputSchema": schema(["labels": ["type": "array", "items": ["type": "string"]]], required: ["labels"])],
        ["name": "meum_set_workspace",
         "description": "Change your own workspace's name, icon, colour or sidebar labels (only the fields you pass). icon: preferably an SF Symbol as sf:<name> (e.g. sf:hammer, sf:leaf; calmer than emoji), else up to two characters; \"none\" removes it. color: #rrggbb, or \"none\". labels: chips on the workspace's sidebar row (at most 4, 24 characters each; [] removes them), about the workspace as a whole, not about your session.",
         "inputSchema": schema([
            "name": ["type": "string"], "icon": ["type": "string"], "color": ["type": "string"],
            "labels": ["type": "array", "items": ["type": "string"]],
         ])],
        ["name": "meum_notify",
         "description": "A macOS notification from meum; a click takes the user to your tab.",
         "inputSchema": schema(["title": ["type": "string"], "body": ["type": "string"]], required: ["title"])],
    ]

    public typealias Call = (String, JSON) throws -> JSON

    /// Answers one JSON-RPC message; nil for notifications (no id).
    public static func handle(_ req: JSON, here: Here, call: Call) -> JSON? {
        let id = req["id"]
        guard let id, !id.isNull else { return nil }
        let method = req["method"]?.stringValue ?? ""
        let params = req["params"] ?? .object([:])
        func ok(_ result: JSON) -> JSON { ["jsonrpc": "2.0", "id": id, "result": result] }
        switch method {
        case "initialize":
            let v = params["protocolVersion"]?.stringValue ?? protocolVersion
            return ok(["protocolVersion": .string(v), "capabilities": ["tools": .object([:])],
                       "serverInfo": ["name": "meum", "version": "1"],
                       "instructions": .string(here.insideMeum ? instructions : "Not running inside meum: no tools.")])
        case "ping":
            return ok(.object([:]))
        case "tools/list":
            return ok(["tools": .array(here.insideMeum ? tools : [])])
        case "tools/call":
            let name = params["name"]?.stringValue ?? ""
            let args = params["arguments"] ?? .object([:])
            do {
                return ok(try tool(name, args, here: here, call: call))
            } catch {
                let msg = (error as? ControlError).map { "\($0.message) [\($0.code)]" } ?? "\(error)"
                return ok(["content": [["type": "text", "text": .string(msg)]], "isError": true])
            }
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": .string("unknown method \(method)")]]
        }
    }

    static func text(_ j: JSON) -> JSON { ["content": [["type": "text", "text": .string(j.prettyString)]]] }

    static func tool(_ name: String, _ a: JSON, here: Here, call: Call) throws -> JSON {
        func s(_ k: String) -> String? { a[k]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        func need(_ k: String) throws -> String {
            guard let v = s(k) else { throw ControlError.invalidParams("needs '\(k)'") }
            return v
        }
        switch name {
        case "meum_context":
            return text(try context(here: here, call: call))
        case "meum_open_widget":
            var p: [String: JSON] = ["widget": .string(try need("widget"))]
            if let w = s("workspace") ?? here.workspace { p["workspace"] = .string(w) }
            if let c = a["config"], !c.isNull { p["config"] = c }
            switch s("placement") ?? "right" {
            case "tab": if let c = s("card") { p["card"] = .string(c) }
            case "down": p["split"] = "down"
            default: p["split"] = "right"
            }
            let r = try call(MeumMethod.tabNew, .object(p))
            return text(["tab": r["id"] ?? .null, "card": r["card"] ?? .null, "workspace": r["workspace"] ?? .null])
        case "meum_widget_send":
            let r = try call(MeumMethod.widgetSend, ["tab": .string(try need("tab")), "message": a["message"] ?? .object([:])])
            return text(r)
        case "meum_widget_screenshot":
            let r = try call(MeumMethod.widgetScreenshot, ["tab": .string(try need("tab"))])
            guard let png = r["png"]?.stringValue else { throw ControlError.internalError("no image") }
            return ["content": [["type": "image", "data": .string(png), "mimeType": "image/png"]]]
        case "meum_close_tab":
            _ = try call(MeumMethod.tabClose, ["tab": .string(try need("tab"))])
            return text("closed")
        case "meum_set_status":
            guard let ws = s("workspace") ?? here.workspace else { throw ControlError.invalidParams("needs 'workspace'") }
            var p: [String: JSON] = ["workspace": .string(ws), "key": .string(try need("key")), "value": .string(try need("value"))]
            if let c = s("color") { p["color"] = .string(c) }
            if let u = s("url") { p["url"] = .string(u) }
            _ = try call(MeumMethod.statusSet, .object(p))
            return text("ok")
        case "meum_set_labels":
            guard let t = here.tab else { throw ControlError.unavailable("not inside a meum tab") }
            let labels = a["labels"]?.arrayValue ?? []
            return text(try call(MeumMethod.tabSetLabels, ["tab": .string(t), "labels": .array(labels)]))
        case "meum_set_workspace":
            guard let w = here.workspace else { throw ControlError.unavailable("not inside a meum workspace") }
            var done: [String] = []
            if let n = s("name") { _ = try call(MeumMethod.workspaceRename, ["id": .string(w), "name": .string(n)]); done.append("name") }
            if let i = s("icon") { _ = try call(MeumMethod.workspaceSetIcon, ["id": .string(w), "icon": i == "none" ? .null : .string(i)]); done.append("icon") }
            if let c = s("color") { _ = try call(MeumMethod.workspaceSetColor, ["id": .string(w), "color": c == "none" ? .null : .string(c)]); done.append("color") }
            if let l = a["labels"]?.arrayValue { _ = try call(MeumMethod.workspaceSetLabels, ["id": .string(w), "labels": .array(l)]); done.append("labels") }
            guard !done.isEmpty else { throw ControlError.invalidParams("pass name, icon, color or labels") }
            return text(.string("set " + done.joined(separator: ", ")))
        case "meum_notify":
            var p: [String: JSON] = ["title": .string(try need("title"))]
            if let b = s("body") { p["body"] = .string(b) }
            if let t = here.tab { p["tab"] = .string(t) }
            _ = try call(MeumMethod.notify, .object(p))
            return text("ok")
        default:
            throw ControlError.invalidParams("unknown tool '\(name)'")
        }
    }

    /// meum_context: the session's place, the workspaces, the widgets, and the widget tabs of its workspace.
    static func context(here: Here, call: Call) throws -> JSON {
        let tree = try call(MeumMethod.tree, .object([:]))
        let widgets = (try? call(MeumMethod.widgetList, .object([:])))?["widgets"]?.arrayValue ?? []
        let mine = here.workspace?.lowercased()
        var workspaces: [JSON] = []
        var widgetTabs: [JSON] = []
        for ws in tree["workspaces"]?.arrayValue ?? [] {
            let wid = ws["id"]?.stringValue ?? ""
            workspaces.append(["id": ws["id"] ?? .null, "name": ws["name"] ?? .null, "cwd": ws["cwd"] ?? .null,
                               "selected": .bool(tree["selectedWorkspaceID"]?.stringValue == wid),
                               "yours": .bool(wid.lowercased() == mine)])
            guard wid.lowercased() == mine else { continue }
            func walk(_ n: JSON?) {
                guard let n, !n.isNull else { return }
                if n["type"]?.stringValue == "card" {
                    for t in n["tabs"]?.arrayValue ?? [] where !(t["widget"]?.isNull ?? true) {
                        widgetTabs.append(["tab": t["id"] ?? .null, "widget": t["widget"] ?? .null, "card": n["id"] ?? .null,
                                           "config": t["widgetConfig"] ?? .null,
                                           "selectedInCard": .bool(n["selectedTabID"] == t["id"])])
                    }
                } else {
                    walk(n["first"]); walk(n["second"])
                }
            }
            walk(ws["root"])
        }
        var result: [String: JSON] = [
            "you": ["workspace": here.workspace.map { .string($0) } ?? .null, "tab": here.tab.map { .string($0) } ?? .null],
            "workspaces": .array(workspaces),
            "widgets": .array(widgets.map { w in
                ["id": w["id"] ?? .null, "name": w["displayName"] ?? .null, "scope": w["scope"] ?? .null]
            }),
            "widgetTabsInYourWorkspace": .array(widgetTabs),
        ]
        // a session keeps the meum tools it started with: say so when meum has been updated since
        if let note = staleNote(running: (try? call(MeumMethod.ping, .object([:])))?["version"]?.stringValue,
                                mine: ControlInfo.appVersion) {
            result["note"] = .string(note)
        }
        return .object(result)
    }

    /// The line for a session whose MCP server is older than the meum app it talks to; nil when they match or either
    /// is a development build.
    static func staleNote(running: String?, mine: String?) -> String? {
        guard let running, let mine, running != mine else { return nil }
        return "meum was updated to \(running); this session still runs the \(mine) tools. Restart Claude Code here for the newer ones."
    }

    /// Runs the server on stdin/stdout until stdin closes.
    public static func run(socket: String, here: Here) {
        let client = ControlClient(socketPath: socket, timeout: 60)
        let call: Call = { m, p in try client.call(m, p) }
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            let req: JSON
            do { req = try JSON.parse(line) } catch {
                emit(["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "parse error"]])
                continue
            }
            if let r = handle(req, here: here, call: call) { emit(r) }
        }
    }

    static func emit(_ j: JSON) {
        FileHandle.standardOutput.write(j.compactData() + Data("\n".utf8))
    }
}
