import XCTest
@testable import MeumControl

final class CLITests: XCTestCase {
    var h: Harness!
    var home: String!

    override func setUpWithError() throws {
        h = try Harness()
        home = TestSupport.tempDir("home")
    }

    override func tearDown() {
        h.tearDown()
        try? FileManager.default.removeItem(atPath: home)
    }

    struct Out { var code: Int32; var out: String; var err: String }

    func meum(_ args: [String], env extra: [String: String] = [:], stdin: String = "", socket: Bool = true) -> Out {
        var env = ["HOME": home!]
        if socket { env["MEUM_SOCKET"] = h.socket }
        for (k, v) in extra { env[k] = v }
        let o = Locked<[String]>([]), e = Locked<[String]>([])
        let environment = CLIEnvironment(env: env, home: home, stdout: { s in o.mutate { $0.append(s) } },
                                         stderr: { s in e.mutate { $0.append(s) } }, readStdin: { stdin })
        let code = CLI.run(args, environment: environment)
        return Out(code: code, out: o.value.joined(separator: "\n"), err: e.value.joined(separator: "\n"))
    }

    var lastCall: (method: String, params: JSON)? { h.handler.calls.last }

    // MARK: basics and exit codes

    func testPingAndVersionAndHelp() {
        let r = meum(["ping"])
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.hasPrefix("ok meum.v1 pid "), r.out)
        let j = meum(["--json", "ping"])
        XCTAssertEqual(try JSON.parse(j.out)["api"], "meum.v1")
        XCTAssertEqual(meum(["ping", "--json"]).code, 0, "--json works after the command too")
        XCTAssertTrue(meum(["version"]).out.contains("meum.v1"))
        XCTAssertTrue(meum(["help"]).out.contains("usage: meum"))
        XCTAssertTrue(meum([]).out.contains("usage: meum"))
    }

    func testExitCodes() {
        XCTAssertEqual(meum(["bogus"]).code, 2)
        XCTAssertEqual(meum(["ping", "--nope"]).code, 2)
        XCTAssertEqual(meum(["ping", "extra"]).code, 2)
        XCTAssertEqual(meum(["workspace"]).code, 2)
        XCTAssertEqual(meum(["workspace", "rename", "api"]).code, 2)
        XCTAssertEqual(meum(["tab", "new", "--split", "sideways"]).code, 2)
        XCTAssertEqual(meum(["events", "--after", "x"]).code, 2)
        let down = meum(["ping"], env: ["MEUM_SOCKET": h.dir + "/none.sock"])
        XCTAssertEqual(down.code, 3)
        XCTAssertTrue(down.err.contains("not running"), down.err)
        XCTAssertEqual(meum(["--socket", h.dir + "/none.sock", "ping"]).code, 3, "--socket before the command")
        XCTAssertEqual(meum(["ping", "--socket", h.dir + "/none.sock"]).code, 3, "--socket after the command")
        let srvErr = meum(["call", "missing"])
        XCTAssertEqual(srvErr.code, 1)
        XCTAssertTrue(srvErr.err.contains("not_found"), srvErr.err)
        XCTAssertEqual(meum(["workspace", "select", "nonesuch"]).code, 1)
    }

    func testSocketDefaultsToTheStateDirUnderHome() {
        // No MEUM_SOCKET: the default is $HOME/.local/state/meum/meum.sock, which does not exist in the temp home.
        let r = meum(["ping"], socket: false)
        XCTAssertEqual(r.code, 3)
        XCTAssertTrue(r.err.contains(home + "/.local/state/meum/meum.sock"), r.err)
    }

    // MARK: reading

    func testTreeHumanAndJSON() throws {
        let r = meum(["tree"])
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.contains("meum.v1: 2 workspaces"), r.out)
        XCTAssertTrue(r.out.contains("* api  11111111  [pinned]  /code/api"), r.out)
        XCTAssertTrue(r.out.contains("  web  22222222  agents: 1 live, needs input, unread"), r.out)
        XCTAssertTrue(r.out.contains("> tab AAAAAAAA  zsh"), r.out)
        XCTAssertTrue(r.out.contains("tab BBBBBBBB  claude  claude needsInput (unread) 5e55105e"), r.out)
        XCTAssertTrue(r.out.contains("split horizontal 0.50"), r.out)
        XCTAssertEqual(try JSON.parse(meum(["tree", "--json"]).out), FakeHandler.tree)
    }

    func testWorkspaceList() throws {
        let r = meum(["workspace", "list"])
        XCTAssertTrue(r.out.contains("* 11111111  api"), r.out)
        XCTAssertTrue(r.out.contains("  22222222  web"), r.out)
        XCTAssertEqual(try JSON.parse(meum(["workspace", "list", "--json"]).out).arrayValue?.count, 2)
    }

    // MARK: acting

    func testWorkspaceResolutionByNameAndPrefix() throws {
        XCTAssertEqual(meum(["workspace", "select", "web"]).code, 0)
        XCTAssertEqual(lastCall?.method, "workspace.select")
        XCTAssertEqual(lastCall?.params["id"], .string(FakeHandler.wsB))
        XCTAssertEqual(meum(["workspace", "select", "WEB"]).code, 0, "names are case-insensitive")
        XCTAssertEqual(meum(["workspace", "close", "1111"]).code, 0)
        XCTAssertEqual(lastCall?.method, "workspace.close")
        XCTAssertEqual(lastCall?.params["id"], .string(FakeHandler.wsA))
        XCTAssertEqual(meum(["workspace", "rename", "api", "backend"]).code, 0)
        XCTAssertEqual(lastCall?.params, ["id": .string(FakeHandler.wsA), "name": "backend"])
        // a prefix shared by both ids would be ambiguous: wsA and wsB start differently, so test a 1-char shared one
        XCTAssertEqual(meum(["workspace", "select", "zzz"]).code, 1)
    }

    func testWorkspaceNewAndOtherVerbs() throws {
        let r = meum(["workspace", "new", "docs", "--cwd", "/code/docs", "--color", "#ff8800"])
        XCTAssertEqual(r.code, 0)
        XCTAssertEqual(r.out, "33333333-cccc-4ccc-8ccc-cccccccccccc")
        XCTAssertEqual(lastCall?.method, "workspace.new")
        XCTAssertEqual(lastCall?.params, ["name": "docs", "cwd": "/code/docs", "color": "#ff8800"])
        XCTAssertEqual(meum(["workspace", "new"]).code, 0)
        XCTAssertEqual(lastCall?.params, .object([:]))

        _ = meum(["workspace", "color", "api", "none"])
        XCTAssertEqual(lastCall?.method, "workspace.setColor"); XCTAssertEqual(lastCall?.params["color"], .null)
        _ = meum(["workspace", "pin", "api"])
        XCTAssertEqual(lastCall?.method, "workspace.pin"); XCTAssertEqual(lastCall?.params["pinned"], true)
        _ = meum(["workspace", "pin", "api", "--off"])
        XCTAssertEqual(lastCall?.params["pinned"], false)
        _ = meum(["workspace", "reorder", "web", "0"])
        XCTAssertEqual(lastCall?.method, "workspace.reorder"); XCTAssertEqual(lastCall?.params["index"], 0)
        _ = meum(["workspace", "read", "web"])
        XCTAssertEqual(lastCall?.method, "workspace.markRead")
    }

    func testTabCommands() throws {
        XCTAssertEqual(meum(["tab", "new", "--workspace", "web", "--cwd", "/x", "--command", "htop", "--split", "right", "--card", "c1"]).code, 0)
        XCTAssertEqual(lastCall?.method, "tab.new")
        XCTAssertEqual(lastCall?.params, ["workspace": .string(FakeHandler.wsB), "cwd": "/x", "command": "htop", "split": "right", "card": "c1"])

        // inside a tab, $MEUM_WORKSPACE is the default workspace
        _ = meum(["tab", "new"], env: ["MEUM_WORKSPACE": FakeHandler.wsA])
        XCTAssertEqual(lastCall?.params["workspace"], .string(FakeHandler.wsA))

        XCTAssertEqual(meum(["tab", "select", "bbbbbbbb"]).code, 0)
        XCTAssertEqual(lastCall?.method, "tab.select")
        XCTAssertEqual(lastCall?.params["tab"], .string(FakeHandler.tab2), "id prefix resolves via the tree, case-insensitively")
        XCTAssertEqual(meum(["tab", "close", FakeHandler.tab1]).code, 0)
        XCTAssertEqual(meum(["tab", "close", "ffff"]).code, 1)

        XCTAssertEqual(meum(["tab", "send", "--enter", "AAAA", "ls -la"]).code, 0)
        XCTAssertEqual(lastCall?.method, "tab.sendText")
        XCTAssertEqual(lastCall?.params, ["tab": .string(FakeHandler.tab1), "text": "ls -la\r"])
        _ = meum(["tab", "send", "AAAA", "-"], stdin: "from stdin\n")
        XCTAssertEqual(lastCall?.params["text"], "from stdin\n")
        _ = meum(["tab", "send", "AAAA", "--", "-dash"])
        XCTAssertEqual(lastCall?.params["text"], "-dash")
    }

    func testStatusAndNotify() throws {
        XCTAssertEqual(meum(["status", "set", "build", "passing", "--workspace", "api", "--color", "#00ff00"]).code, 0)
        XCTAssertEqual(lastCall?.method, "status.set")
        XCTAssertEqual(lastCall?.params, ["workspace": .string(FakeHandler.wsA), "key": "build", "value": "passing", "color": "#00ff00"])
        XCTAssertEqual(meum(["status", "set", "health", "ok", "--workspace", "api", "--url", "myboard://p/api"]).code, 0)
        XCTAssertEqual(lastCall?.params, ["workspace": .string(FakeHandler.wsA), "key": "health", "value": "ok", "url": "myboard://p/api"])
        XCTAssertEqual(meum(["status", "set", "k", "v"]).code, 2, "needs a workspace outside a meum tab")
        XCTAssertEqual(meum(["status", "clear", "build"], env: ["MEUM_WORKSPACE": FakeHandler.wsB]).code, 0)
        XCTAssertEqual(lastCall?.method, "status.clear")
        XCTAssertEqual(lastCall?.params, ["workspace": .string(FakeHandler.wsB), "key": "build"])

        XCTAssertEqual(meum(["notify", "Done", "--body", "tests green"], env: ["MEUM_TAB": FakeHandler.tab1]).code, 0)
        XCTAssertEqual(lastCall?.method, "notify")
        XCTAssertEqual(lastCall?.params, ["title": "Done", "body": "tests green", "tab": .string(FakeHandler.tab1)])
        _ = meum(["notify", "No tab"])
        XCTAssertNil(lastCall?.params["tab"])
    }

    func testTabPasteAndFocused() throws {
        XCTAssertEqual(meum(["tab", "paste", FakeHandler.tab1, "line one\nline two"]).code, 0)
        XCTAssertEqual(lastCall?.method, "tab.paste")
        XCTAssertEqual(lastCall?.params, ["tab": .string(FakeHandler.tab1), "text": "line one\nline two"])
        _ = meum(["tab", "focused"])
        XCTAssertEqual(lastCall?.method, "tab.focused")
    }

    func testCallPassesRawParams() throws {
        let r = meum(["call", "echo", #"{"x":[1,2]}"#])
        XCTAssertEqual(r.out, #"{"x":[1,2]}"#)
        XCTAssertEqual(meum(["call", "echo", "-"], stdin: #"{"y":true}"#).out, #"{"y":true}"#)
        XCTAssertEqual(meum(["call", "echo", "{bad"]).code, 2)
    }

    func testEventsStreamWithCountAndAfter() throws {
        for i in 1...4 { h.bus.publish("tab.added", ["n": .int(i)]) }
        let r = meum(["events", "--after", "1", "--count", "3"])
        XCTAssertEqual(r.code, 0)
        XCTAssertEqual(r.out, "#2 tab.added {\"n\":2}\n#3 tab.added {\"n\":3}\n#4 tab.added {\"n\":4}")
        let j = meum(["events", "--after", "3", "--count", "1", "--json"])
        XCTAssertEqual(try JSON.parse(j.out)["seq"], 4)
        XCTAssertEqual(meum(["events", "--after", "0", "--types", "nothing.*", "--timeout", "1"]).out, "", "filter + idle timeout ends the stream")
    }

    func testEventsWarnOnGap() throws {
        let small = EventBus(capacity: 2)
        let dir = TestSupport.tempDir("gapcli")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = ControlServer(socketPath: dir + "/s.sock", handler: FakeHandler(), bus: small)
        try s.start()
        defer { s.stop() }
        for _ in 1...5 { small.publish("x") }
        let r = meum(["events", "--after", "1", "--count", "1"], env: ["MEUM_SOCKET": dir + "/s.sock"])
        XCTAssertTrue(r.err.contains("missed"), r.err)
        XCTAssertTrue(r.out.hasPrefix("#4 x"), r.out)
    }

    func testResumeCommand() throws {
        let tabJSON = #"{"id":"t","agent":{"sessionID":"abc-123","configDir":"\#(home!)/.claude-work","cwd":"/Users/dev/code/meum"}}"#
        let r = meum(["resume-command", tabJSON])
        XCTAssertEqual(r.out, "cd /Users/dev/code/meum && CLAUDE_CONFIG_DIR=\(home!)/.claude-work claude --resume abc-123")
        let def = meum(["resume-command", "-"], stdin: #"{"sessionID":"s","configDir":"\#(home!)/.claude","cwd":"/w"}"#)
        XCTAssertEqual(def.out, "cd /w && claude --resume s")
        XCTAssertEqual(meum(["resume-command", #"{"id":"t"}"#]).code, 1)
        XCTAssertEqual(meum(["resume-command", "nope"]).code, 2)
        XCTAssertEqual(try JSON.parse(meum(["resume-command", "--json", #"{"sessionID":"s"}"#]).out)["command"], "claude --resume s")
    }

    // MARK: hooks (temp dirs only)

    func writeSettings(_ name: String, _ text: String) -> String {
        let dir = home + "/" + name
        TestSupport.write(text, to: dir + "/settings.json")
        return dir
    }

    func testHooksStatusInstallUninstallOnTempDirs() throws {
        let a = writeSettings(".claude", HookInstallerTests.fixture)
        let b = writeSettings(".claude-alt", "{\n  \"model\": \"x\"\n}\n")
        let beforeA = TestSupport.read(a + "/settings.json")

        // discovery from $HOME
        var r = meum(["hooks", "status"])
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.contains("\(a): not installed; 2 other hook(s) untouched"), r.out)
        XCTAssertTrue(r.out.contains("\(b): not installed"), r.out)

        // dry run writes nothing
        r = meum(["hooks", "install"])
        XCTAssertEqual(r.code, 0)
        XCTAssertTrue(r.out.contains("+++ "), r.out)
        XCTAssertTrue(r.out.contains("meum-hook"), r.out)
        XCTAssertTrue(r.out.contains("dry run: nothing written"), r.out)
        XCTAssertEqual(TestSupport.read(a + "/settings.json"), beforeA)
        XCTAssertEqual(TestSupport.read(b + "/settings.json"), "{\n  \"model\": \"x\"\n}\n")

        // explicit dir, --yes, with the script placed under the temp home
        let script = home + "/meum-hook-src"
        TestSupport.write("#!/bin/sh\nexit 0\n", to: script)
        r = meum(["hooks", "install", "--config-dir", a, "--yes", "--script", script])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.out.contains("backup \(a)/settings.json.bak-"), r.out)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: home + "/.local/bin/meum-hook"))
        XCTAssertEqual(TestSupport.read(b + "/settings.json"), "{\n  \"model\": \"x\"\n}\n", "other dirs untouched")
        XCTAssertTrue(meum(["hooks", "status", "--config-dir", a]).out.contains("installed"))
        XCTAssertTrue(meum(["hooks", "install", "--config-dir", a]).out.contains("nothing to do"))

        let js = try JSON.parse(meum(["hooks", "status", "--config-dir", a, "--json"]).out)
        XCTAssertEqual(js[0]?["installed"], true)
        XCTAssertEqual(js[0]?["foreignHooks"], 2)

        // uninstall restores the file
        r = meum(["hooks", "uninstall", "--config-dir", a, "--yes"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertEqual(TestSupport.read(a + "/settings.json"), beforeA)
    }

    func testHooksInstallReportsErrorsAndExitsNonZero() {
        let bad = writeSettings(".claude-bad", "{ nope")
        let r = meum(["hooks", "install", "--config-dir", bad, "--yes"])
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.out.contains("ERROR"), r.out)
        XCTAssertEqual(TestSupport.read(bad + "/settings.json"), "{ nope")
    }

    func testHooksWithNoDirsFound() {
        let r = meum(["hooks", "status"])
        XCTAssertEqual(r.code, 1)
        XCTAssertTrue(r.err.contains("no Claude config directories"), r.err)
    }

    func testHooksSymlinkedDirsAreReportedOnceAndFollowed() throws {
        let a = writeSettings(".claude", HookInstallerTests.fixture)
        let w = home + "/.claude-work"
        try FileManager.default.createDirectory(atPath: w, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: w + "/settings.json", withDestinationPath: a + "/settings.json")
        let st = meum(["hooks", "status"])
        XCTAssertEqual(st.out.split(separator: "\n").count, 1, st.out)
        XCTAssertTrue(st.out.contains("(also \(w))"), st.out)
        XCTAssertEqual(meum(["hooks", "install", "--yes"]).code, 0)
        let attrs = try FileManager.default.attributesOfItem(atPath: w + "/settings.json")
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)
    }

    /// The real executable, as built next to the test bundle: argv, stdout, exit codes.
    func testBuiltBinaryEndToEnd() throws {
        let bin = Bundle(for: CLITests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("meum").path
        guard FileManager.default.isExecutableFile(atPath: bin) else { throw XCTSkip("meum binary not built next to the tests") }
        let env = ["HOME": home!, "MEUM_SOCKET": h.socket, "PATH": "/usr/bin:/bin"]
        let ping = TestSupport.run(bin, ["ping"], env: env)
        XCTAssertEqual(ping.status, 0, ping.stderr)
        XCTAssertTrue(ping.stdout.hasPrefix("ok meum.v1"), ping.stdout)
        let tree = TestSupport.run(bin, ["tree"], env: env)
        XCTAssertTrue(tree.stdout.contains("needs input"), tree.stdout)
        let sent = TestSupport.run(bin, ["tab", "send", "--enter", "AAAA", "echo hi"], env: env)
        XCTAssertEqual(sent.status, 0, sent.stderr)
        XCTAssertEqual(lastCall?.params["text"], "echo hi\r")
        XCTAssertEqual(TestSupport.run(bin, ["ping"], env: ["HOME": home!, "MEUM_SOCKET": h.dir + "/x.sock"]).status, 3)
        XCTAssertEqual(TestSupport.run(bin, ["nonsense"], env: env).status, 2)
    }
}
