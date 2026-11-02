// The `meum` command line, as a library function so it can be tested in-process.
// Sources/meum/main.swift only forwards CommandLine.arguments here.
//
// Exit codes: 0 ok, 1 request or local failure, 2 usage error, 3 meum is not running.
import Foundation

public struct CLIEnvironment {
    public var env: [String: String]
    public var home: String
    public var stdout: (String) -> Void
    public var stderr: (String) -> Void
    public var readStdin: () -> String

    public init(env: [String: String], home: String, stdout: @escaping (String) -> Void,
                stderr: @escaping (String) -> Void, readStdin: @escaping () -> String) {
        self.env = env
        self.home = home
        self.stdout = stdout
        self.stderr = stderr
        self.readStdin = readStdin
    }

    public static var live: CLIEnvironment {
        CLIEnvironment(
            env: ProcessInfo.processInfo.environment, home: NSHomeDirectory(),
            stdout: { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) },
            stderr: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
            readStdin: { String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) })
    }
}

public enum CLI {
    public static let name = "meum"

    public static let usage = """
    usage: meum [--json] [--socket PATH] <command> [args]

    Talk to the running meum app over its control socket ($MEUM_SOCKET, else ~/.local/state/meum/meum.sock).

    commands:
      ping                                    check the server, print the API version
      tree                                    workspaces, cards, tabs and agent state
      workspace list
      workspace new [name] [--cwd DIR] [--color HEX]
      workspace select|close <ws>
      workspace rename <ws> <name>
      workspace color <ws> <HEX|none>
      workspace meta [list] [--workspace WS]  the workspace's key/value labels
      workspace meta set <key> <value> [--workspace WS]   set one ("board.project acme/shop")
      workspace meta unset <key> [--workspace WS]
      workspace icon <ICON|none> [--workspace WS]
                                              the icon in the collapsed sidebar: an emoji or up to two
                                              characters ("🚀", "vi"), or sf:<SF Symbol> ("sf:leaf")
      workspace pin <ws> [--off]
      workspace reorder <ws> <index>
      workspace read|unread <ws>              mark a workspace read / unread
      tab new [--workspace WS] [--card ID] [--cwd DIR] [--command CMD] [--split right|down] [--widget ID]
                                              [--config JSON]
                                              --widget: a widget tab, the widget instead of a terminal;
                                              --config: its settings (e.g. '{"url":"http://localhost:5173"}')
      tab select|close <tab>
      tab send [--enter] <tab> <text|->       type text into a tab ('-' reads stdin)
      tab move <tab> [--card CARD] [--index N] [--split left|right|up|down]
                                              move a tab into a card at a position (default: its own card,
                                              at the end), or split CARD and put the tab in the new card
      split resize <split> <ratio>            set a split's ratio (share of its first child, 0.1-0.9)
      sidebar [toggle|collapse|expand]        collapse the sidebar to the icon rail, or expand it
      settings [get [key]]                    print the settings (or one)
      settings set <key> <value>              change a setting (value is JSON, else a string)
      widget [list]                           the native widgets found, top to bottom as stacked
      widget reload                           load the widget libraries again (after rebuilding one)
      widget enable|disable <id>              show or hide a widget's card
      widget order <id>...                    order the cards, top to bottom (workspace widgets stay on top)
      widget catalog                          the widget library: what can be installed, what has updates
      widget install|update <id>              install a widget from the library (or its newer version)
      widget remove <id> [--data]             remove a widget (--data: also its data folder)
      widget allow <id>                       trust a widget that is not from the library (pins its file)
      widget send <tab> <json>                send a widget tab a message and print its reply
                                              (--widget ID instead of a tab: a sidebar widget)
      widget screenshot <tab> [--out FILE]    a PNG of a widget tab (default FILE: widget-<tab>.png)
      mcp                                     run the meum MCP server on stdio (for Claude Code:
                                              claude mcp add meum -- meum mcp)
      status set <key> <value> [--workspace WS] [--color HEX] [--url URL]
                                              --url: a click on the entry opens it (any scheme)
      status clear <key> [--workspace WS]
      notify <title> [--body TEXT] [--tab TAB]
      events [--after N] [--types a,b.*] [--count N] [--timeout SEC]
                                              stream events (one line each; --json prints raw lines)
      hooks status|install|uninstall [--config-dir DIR]... [--hook-command CMD] [--script FILE] [--yes]
                                              Claude Code hook entries; install is a dry run without --yes
      resume-command <tab-json|->             print the shell command that resumes a tab's Claude session
      call <method> [params-json]             raw API call
      help | version

    <ws>, <tab>, CARD and <split> accept a full id or a unique id prefix; workspaces also a unique name.
    Inside a meum tab $MEUM_WORKSPACE and $MEUM_TAB are the defaults where a workspace or tab is optional.
    """

    public static let version = "meum 0.1 (api \(ControlInfo.apiVersion))"

    @discardableResult
    public static func run(_ args: [String], environment: CLIEnvironment = .live) -> Int32 {
        do {
            try dispatch(args, Ctx(env: environment))
            return 0
        } catch let e as CLIError {
            environment.stderr("meum: \(e)")
            if case .usage = e { environment.stderr("run 'meum help' for usage") }
            return e.exitCode
        } catch {
            environment.stderr("meum: \(error)")
            return 1
        }
    }

    // MARK: context

    struct Ctx {
        var env: CLIEnvironment
        var json = false
        var socket: String?

        init(env: CLIEnvironment) { self.env = env }

        var socketPath: String { socket ?? ControlPaths.socketPath(env: env.env, home: env.home) }
        func client() -> ControlClient { ControlClient(socketPath: socketPath, timeout: 15) }
        func out(_ s: String) { env.stdout(s) }

        func rpc(_ method: String, _ params: JSON = .object([:])) throws -> JSON {
            do { return try client().call(method, params) }
            catch let e as ControlError { throw CLIError.failure("\(e.message) [\(e.code)]") }
            catch let e as ClientError {
                if case .notRunning = e { throw CLIError.unreachable("\(e)") }
                throw CLIError.failure("\(e)")
            }
        }

        /// Prints `result` as JSON with --json, otherwise `human` (or nothing when it returns nil).
        func show(_ result: JSON, human: (JSON) -> String?) {
            if json { out(result.prettyString) } else if let s = human(result) { out(s) }
        }
    }

    static func parse(_ ctx: inout Ctx, _ args: [String], values: Set<String> = [], bools: Set<String> = []) throws -> ParsedArgs {
        let p = try ParsedArgs.parse(args, valueOptions: values.union(["socket"]), boolOptions: bools.union(["json"]))
        if p.has("json") { ctx.json = true }
        if let s = p.value("socket") { ctx.socket = s }
        return p
    }

    // MARK: dispatch

    static func dispatch(_ allArgs: [String], _ base: Ctx) throws {
        var ctx = base
        // Global options may precede the command.
        var args = allArgs
        var lead: [String] = []
        while let a = args.first, a.hasPrefix("-"), a != "--help", a != "-h", a != "--version" {
            lead.append(args.removeFirst())
            if a == "--socket", !args.isEmpty { lead.append(args.removeFirst()) }
        }
        _ = try parse(&ctx, lead)
        guard let cmd = args.first else { ctx.out(usage); return }
        let rest = Array(args.dropFirst())

        switch cmd {
        case "help", "--help", "-h": ctx.out(usage)
        case "version", "--version": ctx.out(version)
        case "ping": try ping(&ctx, rest)
        case "tree": try tree(&ctx, rest)
        case "workspace", "ws": try workspace(&ctx, rest)
        case "tab": try tab(&ctx, rest)
        case "status": try status(&ctx, rest)
        case "split": try split(&ctx, rest)
        case "settings": try settings(&ctx, rest)
        case "sidebar": try sidebar(&ctx, rest)
        case "notify": try notify(&ctx, rest)
        case "widget", "widgets": try widget(&ctx, rest)
        case "mcp":
            let p = try parse(&ctx, rest)
            try p.expectPositionals([], command: "meum mcp")
            var here = MCPServer.Here(env: ctx.env.env)
            if here.socket == nil { here.socket = ctx.socket }   // --socket: drive that meum from outside it
            MCPServer.run(socket: ctx.socketPath, here: here)
        case "events": try events(&ctx, rest)
        case "hooks": try hooks(&ctx, rest)
        case "resume-command": try resumeCommand(&ctx, rest)
        case "call": try call(&ctx, rest)
        default: throw CLIError.usage("unknown command '\(cmd)'")
        }
    }

    // MARK: simple commands

    static func ping(_ ctx: inout Ctx, _ args: [String]) throws {
        let p = try parse(&ctx, args)
        try p.expectPositionals([], command: "meum ping")
        let r = try ctx.rpc(MeumMethod.ping)
        ctx.show(r) { "ok \(($0["api"]?.stringValue) ?? "?") pid \($0["pid"]?.intValue.map(String.init) ?? "?")" }
    }

    static func tree(_ ctx: inout Ctx, _ args: [String]) throws {
        let p = try parse(&ctx, args)
        try p.expectPositionals([], command: "meum tree [--json]")
        let r = try ctx.rpc(MeumMethod.tree)
        ctx.show(r) { CLIRender.tree($0) }
    }

    static func call(_ ctx: inout Ctx, _ args: [String]) throws {
        let p = try parse(&ctx, args)
        try p.expectPositionals(["method"], optional: 1, command: "meum call")
        var params: JSON = .object([:])
        if p.positionals.count > 1 {
            let raw = p.positionals[1] == "-" ? ctx.env.readStdin() : p.positionals[1]
            do { params = try JSON.parse(raw) } catch { throw CLIError.usage("params are not valid JSON") }
        }
        let r = try ctx.rpc(p.positionals[0], params)
        ctx.out(ctx.json ? r.prettyString : r.compactString)
    }

    static func resumeCommand(_ ctx: inout Ctx, _ args: [String]) throws {
        let p = try parse(&ctx, args)
        try p.expectPositionals(["tab-json|-"], command: "meum resume-command")
        let raw = p.positionals[0] == "-" ? ctx.env.readStdin() : p.positionals[0]
        guard let j = try? JSON.parse(raw) else { throw CLIError.usage("argument is not valid JSON") }
        guard let info = ResumeInfo(json: j) else {
            throw CLIError.failure("no agent session in that JSON (needs sessionID, directly or under 'agent')")
        }
        let cmd = ResumeCommand.build(info, home: ctx.env.home)
        ctx.out(ctx.json ? JSON.object(["command": .string(cmd)]).prettyString : cmd)
    }

    // MARK: references

    static func resolveWorkspace(_ ctx: Ctx, _ ref: String) throws -> String {
        let list = CLIRender.workspaceList(try ctx.rpc(MeumMethod.workspaceList))
        let rows = list.compactMap { w -> (id: String, name: String)? in
            guard let id = w["id"]?.stringValue else { return nil }
            return (id, w["name"]?.stringValue ?? "")
        }
        if let e = rows.first(where: { $0.id.lowercased() == ref.lowercased() }) { return e.id }
        let byPrefix = rows.filter { $0.id.lowercased().hasPrefix(ref.lowercased()) }
        if byPrefix.count == 1 { return byPrefix[0].id }
        if byPrefix.count > 1 { throw CLIError.failure("'\(ref)' matches \(byPrefix.count) workspaces; use more of the id") }
        let byName = rows.filter { $0.name.lowercased() == ref.lowercased() }
        if byName.count == 1 { return byName[0].id }
        if byName.count > 1 { throw CLIError.failure("name '\(ref)' is ambiguous; use the id") }
        throw CLIError.failure("no workspace '\(ref)'")
    }

    static func resolveTab(_ ctx: Ctx, _ ref: String) throws -> String {
        let all = CLIRender.tabs(in: try ctx.rpc(MeumMethod.tree)).map(\.id)
        if let e = all.first(where: { $0.lowercased() == ref.lowercased() }) { return e }
        let m = all.filter { $0.lowercased().hasPrefix(ref.lowercased()) }
        if m.count == 1 { return m[0] }
        if m.count > 1 { throw CLIError.failure("'\(ref)' matches \(m.count) tabs; use more of the id") }
        throw CLIError.failure("no tab '\(ref)'")
    }

    static func workspaceRef(_ ctx: Ctx, _ p: ParsedArgs, flag: String = "workspace") throws -> String? {
        if let v = p.value(flag) ?? ctx.env.env["MEUM_WORKSPACE"], !v.isEmpty { return try resolveWorkspace(ctx, v) }
        return nil
    }

    static func printID(_ ctx: Ctx, _ r: JSON) {
        ctx.show(r) { r in
            if let id = r["id"]?.stringValue { return id }
            if r.isNull { return nil }
            return r.compactString
        }
    }

    // MARK: sidebar

    static func sidebar(_ ctx: inout Ctx, _ args: [String]) throws {
        let p = try parse(&ctx, args)
        var params: [String: JSON] = [:]
        switch p.positionals.first ?? "toggle" {
        case "toggle": break
        case "collapse": params["collapsed"] = .bool(true)
        case "expand": params["collapsed"] = .bool(false)
        default: throw CLIError.usage("usage: meum sidebar [toggle|collapse|expand]")
        }
        guard p.positionals.count <= 1 else { throw CLIError.usage("usage: meum sidebar [toggle|collapse|expand]") }
        ctx.show(try ctx.rpc(MeumMethod.sidebarSetCollapsed, .object(params))) { r in
            r["collapsed"]?.boolValue == true ? "collapsed" : "expanded"
        }
    }

    // MARK: workspace

    static func workspace(_ ctx: inout Ctx, _ args: [String]) throws {
        guard let sub = args.first else { throw CLIError.usage("usage: meum workspace list|new|select|rename|close|color|icon|pin|reorder|read|unread") }
        let rest = Array(args.dropFirst())
        switch sub {
        case "list", "ls":
            let p = try parse(&ctx, rest)
            try p.expectPositionals([], command: "meum workspace list")
            ctx.show(try ctx.rpc(MeumMethod.workspaceList)) { CLIRender.workspaceTable($0) }
        case "new":
            let p = try parse(&ctx, rest, values: ["cwd", "color"])
            try p.expectPositionals([], optional: 1, command: "meum workspace new [name]")
            var params: [String: JSON] = [:]
            if let n = p.positionals.first { params["name"] = .string(n) }
            if let c = p.value("cwd") { params["cwd"] = .string(c) }
            if let c = p.value("color") { params["color"] = .string(c) }
            printID(ctx, try ctx.rpc(MeumMethod.workspaceNew, .object(params)))
        case "select", "close":
            let p = try parse(&ctx, rest)
            try p.expectPositionals(["ws"], command: "meum workspace \(sub)")
            let id = try resolveWorkspace(ctx, p.positionals[0])
            let m = sub == "select" ? MeumMethod.workspaceSelect : MeumMethod.workspaceClose
            printOK(ctx, try ctx.rpc(m, ["id": .string(id)]))
        case "rename":
            let p = try parse(&ctx, rest)
            try p.expectPositionals(["ws", "name"], command: "meum workspace rename")
            let id = try resolveWorkspace(ctx, p.positionals[0])
            printOK(ctx, try ctx.rpc(MeumMethod.workspaceRename, ["id": .string(id), "name": .string(p.positionals[1])]))
        case "color":
            let p = try parse(&ctx, rest)
            try p.expectPositionals(["ws", "HEX|none"], command: "meum workspace color")
            let id = try resolveWorkspace(ctx, p.positionals[0])
            let c = p.positionals[1]
            printOK(ctx, try ctx.rpc(MeumMethod.workspaceSetColor, ["id": .string(id), "color": c == "none" ? .null : .string(c)]))
        case "icon":
            let p = try parse(&ctx, rest, values: ["workspace"])
            try p.expectPositionals(["ICON|none"], command: "meum workspace icon")
            guard let ws = try workspaceRef(ctx, p) else { throw CLIError.usage("--workspace is required outside a meum tab") }
            let icon = p.positionals[0]
            printOK(ctx, try ctx.rpc(MeumMethod.workspaceSetIcon, ["id": .string(ws), "icon": icon == "none" ? .null : .string(icon)]))
        case "meta":
            let sub2 = rest.first.flatMap { ["list", "set", "unset"].contains($0) ? $0 : nil } ?? "list"
            let p = try parse(&ctx, rest.first == sub2 ? Array(rest.dropFirst()) : rest, values: ["workspace"])
            guard let ws = try workspaceRef(ctx, p) else { throw CLIError.usage("--workspace is required outside a meum tab") }
            switch sub2 {
            case "set":
                try p.expectPositionals(["key", "value"], command: "meum workspace meta set")
                _ = try ctx.rpc(MeumMethod.workspaceSetMeta, ["id": .string(ws), "key": .string(p.positionals[0]), "value": .string(p.positionals[1])])
            case "unset":
                try p.expectPositionals(["key"], command: "meum workspace meta unset")
                _ = try ctx.rpc(MeumMethod.workspaceSetMeta, ["id": .string(ws), "key": .string(p.positionals[0]), "value": .null])
            default:
                try p.expectPositionals([], command: "meum workspace meta")
            }
            let all = try ctx.rpc(MeumMethod.workspaceList)
            let w = all.arrayValue?.first { $0["id"]?.stringValue?.lowercased() == ws.lowercased() }
            let meta = w?["metadata"] ?? .object([:])
            ctx.show(["metadata": meta, "remotes": w?["remotes"] ?? .array([])]) { r in
                let m = (r["metadata"]?.objectValue ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value.stringValue ?? "")" }
                let rem = (r["remotes"]?.arrayValue ?? []).compactMap(\.stringValue).map { "remote\t\($0)" }
                return (m + rem).isEmpty ? "(no metadata)" : (m + rem).joined(separator: "\n")
            }
        case "pin":
            let p = try parse(&ctx, rest, bools: ["off"])
            try p.expectPositionals(["ws"], command: "meum workspace pin [--off]")
            let id = try resolveWorkspace(ctx, p.positionals[0])
            printOK(ctx, try ctx.rpc(MeumMethod.workspacePin, ["id": .string(id), "pinned": .bool(!p.has("off"))]))
        case "reorder":
            let p = try parse(&ctx, rest)
            try p.expectPositionals(["ws", "index"], command: "meum workspace reorder")
            guard let idx = Int(p.positionals[1]) else { throw CLIError.usage("index must be a number") }
            let id = try resolveWorkspace(ctx, p.positionals[0])
            printOK(ctx, try ctx.rpc(MeumMethod.workspaceReorder, ["id": .string(id), "index": .int(idx)]))
        case "read", "unread":
            let p = try parse(&ctx, rest)
            try p.expectPositionals(["ws"], command: "meum workspace \(sub)")
            let id = try resolveWorkspace(ctx, p.positionals[0])
            let m = sub == "read" ? MeumMethod.workspaceMarkRead : MeumMethod.workspaceMarkUnread
            printOK(ctx, try ctx.rpc(m, ["id": .string(id)]))
        default:
            throw CLIError.usage("unknown workspace command '\(sub)'")
        }
    }

    static func printOK(_ ctx: Ctx, _ r: JSON) {
        ctx.show(r) { $0.isNull ? "ok" : ($0["id"]?.stringValue ?? "ok") }
    }

    // MARK: tab

    static func tab(_ ctx: inout Ctx, _ args: [String]) throws {
        guard let sub = args.first else { throw CLIError.usage("usage: meum tab new|select|close|send") }
        let rest = Array(args.dropFirst())
        switch sub {
        case "new":
            let p = try parse(&ctx, rest, values: ["workspace", "card", "cwd", "command", "split", "widget", "config"])
            try p.expectPositionals([], command: "meum tab new")
            var params: [String: JSON] = [:]
            if let w = try workspaceRef(ctx, p) { params["workspace"] = .string(w) }
            if let c = p.value("card") { params["card"] = .string((try? resolveNode(ctx, c, kind: .card)) ?? c) }
            if let c = p.value("cwd") { params["cwd"] = .string(c) }
            if let c = p.value("command") { params["command"] = .string(c) }
            if let w = p.value("widget") { params["widget"] = .string(w) }
            if let c = p.value("config") {
                guard let j = try? JSON.parse(c) else { throw CLIError.usage("--config must be JSON") }
                params["config"] = j
            }
            if let s = p.value("split") {
                guard s == "right" || s == "down" else { throw CLIError.usage("--split must be 'right' or 'down'") }
                params["split"] = .string(s)
            }
            printID(ctx, try ctx.rpc(MeumMethod.tabNew, .object(params)))
        case "select", "close":
            let p = try parse(&ctx, rest)
            try p.expectPositionals(["tab"], command: "meum tab \(sub)")
            let id = try resolveTab(ctx, p.positionals[0])
            printOK(ctx, try ctx.rpc(sub == "select" ? MeumMethod.tabSelect : MeumMethod.tabClose, ["tab": .string(id)]))
        case "send":
            let p = try parse(&ctx, rest, bools: ["enter"])
            try p.expectPositionals(["tab", "text"], command: "meum tab send [--enter]")
            let id = try resolveTab(ctx, p.positionals[0])
            var text = p.positionals[1] == "-" ? ctx.env.readStdin() : p.positionals[1]
            if p.has("enter") { text += "\r" }
            printOK(ctx, try ctx.rpc(MeumMethod.tabSendText, ["tab": .string(id), "text": .string(text)]))
        case "move":
            let p = try parse(&ctx, rest, values: ["card", "index", "split"])
            try p.expectPositionals(["tab"], command: "meum tab move")
            var params: [String: JSON] = ["tab": .string(try resolveTab(ctx, p.positionals[0]))]
            if let c = p.value("card") { params["card"] = .string(try resolveNode(ctx, c, kind: .card)) }
            if let i = try p.int("index") { params["index"] = .int(i) }
            if let s = p.value("split") {
                guard ["left", "right", "up", "down"].contains(s) else {
                    throw CLIError.usage("--split must be left, right, up or down")
                }
                params["split"] = .string(s)
            }
            printOK(ctx, try ctx.rpc(MeumMethod.tabMove, .object(params)))
        default:
            throw CLIError.usage("unknown tab command '\(sub)'")
        }
    }

    // MARK: split and settings

    static func split(_ ctx: inout Ctx, _ args: [String]) throws {
        guard args.first == "resize" else { throw CLIError.usage("usage: meum split resize <split> <ratio>") }
        let p = try parse(&ctx, Array(args.dropFirst()))
        try p.expectPositionals(["split", "ratio"], command: "meum split resize")
        guard let r = Double(p.positionals[1]) else { throw CLIError.usage("ratio must be a number") }
        let id = try resolveNode(ctx, p.positionals[0], kind: .split)
        printOK(ctx, try ctx.rpc(MeumMethod.splitResize, ["split": .string(id), "ratio": .double(r)]))
    }

    static func settings(_ ctx: inout Ctx, _ args: [String]) throws {
        let sub = args.first ?? "get"
        let rest = args.isEmpty ? [] : Array(args.dropFirst())
        switch sub {
        case "get":
            let p = try parse(&ctx, rest)
            try p.expectPositionals([], optional: 1, command: "meum settings get [key]")
            if let key = p.positionals.first {
                let r = try ctx.rpc(MeumMethod.settingsGet, ["key": .string(key)])
                ctx.show(r) { $0["value"]?.compactString }
            } else {
                let r = try ctx.rpc(MeumMethod.settingsGet)
                ctx.show(r) { r in
                    let o = r["settings"]?.objectValue ?? [:]
                    return o.keys.sorted().map { "\($0) = \(o[$0]!.compactString)" }.joined(separator: "\n")
                }
            }
        case "set":
            let p = try parse(&ctx, rest)
            try p.expectPositionals(["key", "value"], command: "meum settings set")
            let raw = p.positionals[1]
            let value = (try? JSON.parse(raw)) ?? .string(raw)
            let r = try ctx.rpc(MeumMethod.settingsSet, ["key": .string(p.positionals[0]), "value": value])
            ctx.show(r) { "\($0["key"]?.stringValue ?? "?") = \($0["value"]?.compactString ?? "?")" }
        default:
            throw CLIError.usage("unknown settings command '\(sub)'")
        }
    }

    static func widget(_ ctx: inout Ctx, _ args: [String]) throws {
        let sub = args.first ?? "list"
        let p = try parse(&ctx, args.isEmpty ? [] : Array(args.dropFirst()), values: ["widget", "out"], bools: ["data"])
        let human: (JSON) -> String? = { r in
            var lines = ["widgets: \(r["directory"]?.stringValue ?? "?") (\(r["apiVersion"]?.stringValue ?? "?"))"]
            let ws = (r["widgets"]?.arrayValue ?? []).sorted {
                ($0["position"]?.intValue ?? Int.max) < ($1["position"]?.intValue ?? Int.max)
            }
            for w in ws {
                let mark = w["loaded"]?.boolValue == true ? (w["shown"]?.boolValue == true ? "*" : "~")
                    : (w["disabled"]?.boolValue == true ? "-" : "!")
                let trust = w["trust"]?.stringValue.map { $0 == "unverified" ? "  UNVERIFIED" : "  (\($0))" } ?? ""
                lines.append("\(mark) \(w["id"]?.stringValue ?? "?")  \(w["displayName"]?.stringValue ?? "")  [\(w["scope"]?.stringValue ?? "global")]\(trust)  \(w["folder"]?.stringValue ?? "")")
            }
            if r["widgets"]?.arrayValue?.isEmpty ?? true { lines.append("  (none)") }
            if let e = r["error"]?.stringValue { lines.append("error: \(e)") }
            return lines.joined(separator: "\n")
        }
        switch sub {
        case "list", "reload":
            try p.expectPositionals([], command: "meum widget \(sub)")
            ctx.show(try ctx.rpc(sub == "list" ? MeumMethod.widgetList : MeumMethod.widgetReload), human: human)
        case "enable", "disable":
            guard p.positionals.count == 1 else { throw CLIError.usage("meum widget \(sub) <id>") }
            ctx.show(try ctx.rpc(MeumMethod.widgetEnable, ["id": .string(p.positionals[0]), "enabled": .bool(sub == "enable")]),
                     human: human)
        case "send":
            var params: [String: JSON] = [:]
            var rest = p.positionals
            if let w = p.value("widget") { params["widget"] = .string(w) } else {
                guard !rest.isEmpty else { throw CLIError.usage("meum widget send <tab> <json> (or --widget ID <json>)") }
                params["tab"] = .string(try resolveTab(ctx, rest.removeFirst()))
            }
            guard rest.count == 1 else { throw CLIError.usage("meum widget send <tab> <json>") }
            let raw = rest[0] == "-" ? ctx.env.readStdin() : rest[0]
            params["message"] = (try? JSON.parse(raw)) ?? .string(raw)
            let r = try ctx.rpc(MeumMethod.widgetSend, .object(params))
            ctx.out(ctx.json ? r.prettyString : r.compactString)
        case "screenshot":
            var params: [String: JSON] = [:]
            if let w = p.value("widget") { params["widget"] = .string(w) } else {
                guard p.positionals.count == 1 else { throw CLIError.usage("meum widget screenshot <tab> [--out FILE]") }
                params["tab"] = .string(try resolveTab(ctx, p.positionals[0]))
            }
            let name = (params["tab"]?.stringValue ?? params["widget"]?.stringValue ?? "widget").prefix(8)
            let out = p.value("out") ?? "widget-\(name).png"
            let path = out.hasPrefix("/") ? out : FileManager.default.currentDirectoryPath + "/" + out
            params["path"] = .string(path)
            let r = try ctx.rpc(MeumMethod.widgetScreenshot, .object(params))
            ctx.show(r) { $0["path"]?.stringValue }
        case "catalog":
            try p.expectPositionals([], command: "meum widget catalog")
            ctx.show(try ctx.rpc(MeumMethod.widgetCatalog)) { r in
                var lines = ["catalog: \(r["url"]?.stringValue ?? "?")"]
                for w in r["widgets"]?.arrayValue ?? [] {
                    let state = w["runs"]?.boolValue == false ? "not for this meum"
                        : w["update"]?.boolValue == true ? "update \(w["installedVersion"]?.stringValue ?? "?") -> \(w["version"]?.stringValue ?? "?")"
                        : w["installed"]?.boolValue == true ? "installed" : "available"
                    lines.append("\(w["id"]?.stringValue ?? "?")  \(w["displayName"]?.stringValue ?? "")  \(w["version"]?.stringValue ?? "")  [\(state)]")
                    if let d = w["description"]?.stringValue, !d.isEmpty { lines.append("    \(d)") }
                }
                if r["widgets"]?.arrayValue?.isEmpty ?? true { lines.append("  (empty)") }
                return lines.joined(separator: "\n")
            }
        case "install", "update", "allow":
            guard p.positionals.count == 1 else { throw CLIError.usage("meum widget \(sub) <id>") }
            let m = sub == "install" ? MeumMethod.widgetInstall : sub == "update" ? MeumMethod.widgetUpdate : MeumMethod.widgetAllow
            ctx.show(try ctx.rpc(m, ["id": .string(p.positionals[0])]), human: human)
        case "remove", "uninstall":
            guard p.positionals.count == 1 else { throw CLIError.usage("meum widget remove <id> [--data]") }
            ctx.show(try ctx.rpc(MeumMethod.widgetRemove, ["id": .string(p.positionals[0]), "data": .bool(p.has("data"))]),
                     human: human)
        case "order":
            _ = try ctx.rpc(MeumMethod.settingsSet, ["key": "widgetOrder", "value": .array(p.positionals.map { .string($0) })])
            ctx.show(try ctx.rpc(MeumMethod.widgetList), human: human)
        default: throw CLIError.usage("unknown widget command '\(sub)'")
        }
    }

    enum NodeKind { case card, split }

    /// Card or split ids from the tree, by full id or unique prefix.
    static func resolveNode(_ ctx: Ctx, _ ref: String, kind: NodeKind) throws -> String {
        var ids: [String] = []
        func walk(_ n: JSON) {
            guard case .object(let o) = n else { return }
            if let id = o["id"]?.stringValue, (o["tabs"] != nil) == (kind == .card) { ids.append(id) }
            if let f = o["first"] { walk(f) }
            if let s = o["second"] { walk(s) }
        }
        for ws in CLIRender.workspaceList(try ctx.rpc(MeumMethod.tree)) { walk(ws["root"] ?? .null) }
        let what = kind == .card ? "card" : "split"
        if let e = ids.first(where: { $0.lowercased() == ref.lowercased() }) { return e }
        let m = ids.filter { $0.lowercased().hasPrefix(ref.lowercased()) }
        if m.count == 1 { return m[0] }
        if m.count > 1 { throw CLIError.failure("'\(ref)' matches \(m.count) \(what)s; use more of the id") }
        throw CLIError.failure("no \(what) '\(ref)'")
    }

    // MARK: status and notify

    static func status(_ ctx: inout Ctx, _ args: [String]) throws {
        guard let sub = args.first else { throw CLIError.usage("usage: meum status set|clear") }
        let rest = Array(args.dropFirst())
        switch sub {
        case "set":
            let p = try parse(&ctx, rest, values: ["workspace", "color", "url"])
            try p.expectPositionals(["key", "value"], command: "meum status set")
            guard let ws = try workspaceRef(ctx, p) else { throw CLIError.usage("--workspace is required outside a meum tab") }
            var params: [String: JSON] = ["workspace": .string(ws), "key": .string(p.positionals[0]), "value": .string(p.positionals[1])]
            if let c = p.value("color") { params["color"] = .string(c) }
            if let u = p.value("url") { params["url"] = .string(u) }
            printOK(ctx, try ctx.rpc(MeumMethod.statusSet, .object(params)))
        case "clear":
            let p = try parse(&ctx, rest, values: ["workspace"])
            try p.expectPositionals(["key"], command: "meum status clear")
            guard let ws = try workspaceRef(ctx, p) else { throw CLIError.usage("--workspace is required outside a meum tab") }
            printOK(ctx, try ctx.rpc(MeumMethod.statusClear, ["workspace": .string(ws), "key": .string(p.positionals[0])]))
        default:
            throw CLIError.usage("unknown status command '\(sub)'")
        }
    }

    static func notify(_ ctx: inout Ctx, _ args: [String]) throws {
        let p = try parse(&ctx, args, values: ["body", "tab"])
        try p.expectPositionals(["title"], command: "meum notify")
        var params: [String: JSON] = ["title": .string(p.positionals[0])]
        if let b = p.value("body") { params["body"] = .string(b) }
        if let t = p.value("tab") ?? ctx.env.env["MEUM_TAB"], !t.isEmpty {
            params["tab"] = .string(p.value("tab") != nil ? try resolveTab(ctx, t) : t)
        }
        printOK(ctx, try ctx.rpc(MeumMethod.notify, .object(params)))
    }

    // MARK: events

    static func events(_ ctx: inout Ctx, _ args: [String]) throws {
        let p = try parse(&ctx, args, values: ["after", "types", "count", "timeout"])
        try p.expectPositionals([], command: "meum events")
        let after = try p.int("after")
        let count = try p.int("count")
        let types = p.value("types")?.split(separator: ",").map(String.init) ?? []
        var timeout: TimeInterval?
        if let t = try p.int("timeout") { timeout = TimeInterval(t) }
        let stream: EventStream
        do { stream = try ctx.client().subscribe(after: after, types: types, timeout: timeout) }
        catch let e as ControlError { throw CLIError.failure("\(e.message) [\(e.code)]") }
        catch let e as ClientError {
            if case .notRunning = e { throw CLIError.unreachable("\(e)") }
            throw CLIError.failure("\(e)")
        }
        if stream.info["gap"]?.boolValue == true {
            ctx.env.stderr("meum: some events were missed (the history does not reach back to --after)")
        }
        var n = 0
        while count == nil || n < count! {
            do {
                guard let raw = try stream.nextRaw() else { break }
                if ctx.json { ctx.out(String(decoding: raw, as: UTF8.self)) }
                else if let j = try? JSON.parse(raw), let e = Event.decode(j) { ctx.out(CLIRender.event(e)) }
                else { continue }
                n += 1
            } catch ClientError.timeout {
                break
            }
        }
        stream.close()
    }

    // MARK: hooks

    static func hooks(_ ctx: inout Ctx, _ args: [String]) throws {
        guard let sub = args.first, ["status", "install", "uninstall"].contains(sub) else {
            throw CLIError.usage("usage: meum hooks status|install|uninstall [--config-dir DIR]...")
        }
        let p = try parse(&ctx, Array(args.dropFirst()), values: ["config-dir", "hook-command", "script"], bools: ["yes"])
        try p.expectPositionals([], command: "meum hooks \(sub)")
        var installer = HookInstaller(home: ctx.env.home)
        if let c = p.value("hook-command") { installer.hookCommand = c }
        let dirs = p.all("config-dir").isEmpty ? HookInstaller.discoverConfigDirs(home: ctx.env.home) : p.all("config-dir")
        if dirs.isEmpty { throw CLIError.failure("no Claude config directories found (looked for ~/.claude*); pass --config-dir") }
        let targets = installer.targets(for: dirs)

        if sub == "status" {
            let sts = targets.map { installer.status(of: $0) }
            if ctx.json {
                ctx.out(JSON.array(sts.map(statusJSON)).prettyString)
            } else {
                for s in sts { ctx.out(statusLine(s)) }
            }
            return
        }

        let action: HookInstaller.Action = sub == "install" ? .install : .uninstall
        let plans = targets.map { installer.plan(action, target: $0) }
        let yes = p.has("yes")
        var results: [JSON] = []
        var failed = false

        for plan in plans {
            let path = plan.target.settingsPath
            var entry: [String: JSON] = ["configDir": .string(plan.target.configDir), "settings": .string(path),
                                         "sharedWith": .array(plan.target.sharedWith.map { .string($0) }),
                                         "changed": .bool(plan.changed), "applied": false]
            if let e = plan.error {
                failed = true
                entry["error"] = .string(e)
                if !ctx.json { ctx.out("\(path): ERROR \(e)") }
            } else if !plan.changed {
                if !ctx.json { ctx.out("\(path): nothing to do (\(action == .install ? "already installed" : "not installed"))") }
            } else {
                if !ctx.json {
                    ctx.out("\(path)" + (plan.target.sharedWith.isEmpty ? "" : " (shared with \(plan.target.sharedWith.joined(separator: ", ")))"))
                    for n in plan.notes { ctx.out("note: \(n)") }
                    if !yes { ctx.out(plan.diff.trimmingCharacters(in: .newlines)) }
                }
                if yes {
                    do {
                        let r = try installer.apply(plan)
                        entry["applied"] = true
                        if let b = r.backupPath { entry["backup"] = .string(b) }
                        if !ctx.json { ctx.out("  \(action == .install ? "installed" : "removed")" + (r.backupPath.map { "; backup \($0)" } ?? "")) }
                    } catch {
                        failed = true
                        entry["error"] = .string("\(error)")
                        if !ctx.json { ctx.out("  ERROR \(error)") }
                    }
                } else {
                    entry["diff"] = .string(plan.diff)
                }
            }
            results.append(.object(entry))
        }

        if action == .install, let script = p.value("script") {
            if let dest = installer.scriptDestination {
                if yes {
                    do { _ = try installer.installScript(from: script); if !ctx.json { ctx.out("script: copied to \(dest)") } }
                    catch { failed = true; ctx.env.stderr("meum: \(error)") }
                } else if !ctx.json {
                    ctx.out("script: would copy \(script) to \(dest)")
                }
            } else {
                failed = true
                ctx.env.stderr("meum: hook command '\(installer.hookCommand)' is not a plain path; cannot place the script")
            }
        }

        if ctx.json { ctx.out(JSON.array(results).prettyString) }
        else if !yes, plans.contains(where: \.changed) { ctx.out("dry run: nothing written. Re-run with --yes to apply.") }
        if failed { throw CLIError.failure("some targets failed") }
    }

    static func statusJSON(_ s: HookInstaller.Status) -> JSON {
        var o: [String: JSON] = [
            "configDir": .string(s.target.configDir), "settings": .string(s.target.settingsPath),
            "settingsExists": .bool(s.target.settingsExists), "symlink": .bool(s.target.viaSymlink),
            "sharedWith": .array(s.target.sharedWith.map { .string($0) }),
            "installed": .bool(s.isInstalled),
            "installedEvents": .array(s.installedEvents.map { .string($0) }),
            "missingEvents": .array(s.missingEvents.map { .string($0) }),
            "outdatedEvents": .array(s.outdatedEvents.map { .string($0) }),
            "foreignHooks": .int(s.foreignHooks),
        ]
        if let e = s.error { o["error"] = .string(e) }
        return .object(o)
    }

    public static func statusLine(_ s: HookInstaller.Status) -> String {
        let shared = s.target.sharedWith.isEmpty ? "" : " (also \(s.target.sharedWith.joined(separator: ", ")))"
        let link = s.target.viaSymlink ? " -> \(s.target.settingsPath)" : ""
        var state: String
        if let e = s.error { state = "ERROR \(e)" }
        else if !s.target.settingsExists { state = "no settings.json (install would create it)" }
        else if s.isInstalled { state = "installed" + (s.outdatedEvents.isEmpty ? "" : " (command differs for \(s.outdatedEvents.joined(separator: ", ")))") }
        else if s.installedEvents.isEmpty { state = "not installed" }
        else { state = "partly installed (missing \(s.missingEvents.joined(separator: ", ")))" }
        return "\(s.target.configDir)\(link)\(shared): \(state)" + (s.foreignHooks > 0 ? "; \(s.foreignHooks) other hook(s) untouched" : "")
    }
}
