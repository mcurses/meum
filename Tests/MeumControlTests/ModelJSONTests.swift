import MeumCore
import XCTest
@testable import MeumControl

final class ModelJSONTests: XCTestCase {
    func types(_ evs: [(type: String, data: JSON)]) -> [String] { evs.map(\.type) }

    func testTreeUsesFlatNodes() {
        var s = AppState()
        var ws = Workspace.make(name: "api", cwd: "/code/api")
        ws.split(placement: .right, tab: Tab(cwd: "/code/api/web"))
        s.addWorkspace(ws)
        var ex = WorkspaceExtras(branch: "main")
        ex.set("build", StatusEntry(value: "ok", color: "#00ff00"))
        let t = ModelJSON.tree(s, extras: [ws.id: ex], agents: .object([:]))
        XCTAssertEqual(t["version"], "meum.v1")
        let w = t["workspaces"]?[0]
        XCTAssertEqual(w?["branch"], "main")
        XCTAssertEqual(w?["status"]?["build"]?["value"], "ok")
        XCTAssertEqual(w?["cwds"], ["/code/api", "/code/api/web"])
        XCTAssertEqual(w?["selected"], true)
        let root = w?["root"]
        XCTAssertEqual(root?["type"], "split")
        XCTAssertEqual(root?["axis"], "horizontal")
        XCTAssertEqual(root?["first"]?["type"], "card")
        XCTAssertEqual(root?["second"]?["tabs"]?[0]?["cwd"], "/code/api/web")
        // the CLI renderer understands it
        XCTAssertEqual(CLIRender.tabs(in: t).count, 2)
    }

    func testDiffEmitsStructureAndSelectionEvents() {
        var a = AppState()
        a.addWorkspace(.make(name: "one", cwd: "/a"))
        var b = a
        b.addWorkspace(.make(name: "two", cwd: "/b"))   // selects it
        XCTAssertEqual(types(ModelJSON.diff(old: a, new: b)), ["workspace.added", "tab.added", "workspace.selected", "tab.selected"])

        var c = b
        let wsID = c.workspaces[1].id
        c.updateWorkspace(wsID) { $0.split(placement: .down, tab: Tab(cwd: "/b")) }
        XCTAssertEqual(types(ModelJSON.diff(old: b, new: c)), ["tab.added", "workspace.changed", "tab.selected"])

        var d = c
        let tab = c.workspaces[1].allTabs[0].id
        d.updateTab(tab) { $0.title = "vim"; $0.agent = AgentSnapshot(sessionID: "s1") }
        let ev = ModelJSON.diff(old: c, new: d)
        XCTAssertEqual(types(ev), ["tab.changed"])
        XCTAssertEqual(ev[0].data["fields"], ["title", "agent"])

        var e = d
        e.closeWorkspace(wsID)
        let ev2 = types(ModelJSON.diff(old: d, new: e))
        XCTAssertEqual(ev2.filter { $0 == "tab.removed" }.count, 2)
        XCTAssertTrue(ev2.contains("workspace.removed"))
        XCTAssertTrue(ev2.contains("workspace.selected"))

        XCTAssertTrue(ModelJSON.diff(old: e, new: e).isEmpty)
    }

    func testReorderIsAWorkspaceChange() {
        var a = AppState()
        a.addWorkspace(.make(name: "one"))
        a.addWorkspace(.make(name: "two"))
        var b = a
        b.moveWorkspace(a.workspaces[1].id, to: 0)
        let ev = ModelJSON.diff(old: a, new: b)
        XCTAssertEqual(types(ev), ["workspace.changed", "workspace.changed"])
        XCTAssertEqual(ev[0].data["fields"], ["index"])
    }

    func testGitHead() throws {
        XCTAssertEqual(GitHead.parse(head: "ref: refs/heads/feature/x\n"), "feature/x")
        XCTAssertEqual(GitHead.parse(head: "0123456789abcdef\n"), "@0123456")
        let dir = TestSupport.tempDir("git")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir + "/repo/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir + "/repo/sub/deeper", withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(toFile: dir + "/repo/.git/HEAD", atomically: true, encoding: .utf8)
        XCTAssertEqual(GitHead.branch(at: dir + "/repo/sub/deeper"), "main")
        // a worktree: .git is a file pointing elsewhere
        try FileManager.default.createDirectory(atPath: dir + "/wt", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir + "/repo/.git/worktrees/wt", withIntermediateDirectories: true)
        try "ref: refs/heads/topic\n".write(toFile: dir + "/repo/.git/worktrees/wt/HEAD", atomically: true, encoding: .utf8)
        try "gitdir: \(dir)/repo/.git/worktrees/wt\n".write(toFile: dir + "/wt/.git", atomically: true, encoding: .utf8)
        XCTAssertEqual(GitHead.branch(at: dir + "/wt"), "topic")
    }
}
