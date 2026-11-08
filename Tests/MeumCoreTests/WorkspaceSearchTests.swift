import XCTest
@testable import MeumCore

final class WorkspaceSearchTests: XCTestCase {
    func ws(_ name: String, cwd: String? = nil, tabs: [Tab] = [Tab()]) -> Workspace {
        Workspace(name: name, cwd: cwd, root: .card(Card(tabs: tabs)))
    }

    func titles(_ hits: [WorkspaceSearch.Hit]) -> [String] { hits.map(\.title) }

    func testFuzzyPrefersPrefixWordStartsAndRuns() {
        let f = { (q: String, t: String) in WorkspaceSearch.fuzzy(q, in: t)?.0 ?? -999 }
        XCTAssertNil(WorkspaceSearch.fuzzy("xyz", in: "meum"))
        XCTAssertGreaterThan(f("me", "meum"), f("me", "homework"))       // start beats middle
        XCTAssertGreaterThan(f("or", "orion"), f("or", "meum-orion"))
        XCTAssertGreaterThan(f("ma", "meum-main"), f("ma", "meum-gamma"))  // word start beats middle
        XCTAssertGreaterThan(f("mm", "meum-main"), -999)                  // scattered still matches
        XCTAssertEqual(WorkspaceSearch.fuzzy("MM", in: "meum-main")?.1, [0, 5])
        XCTAssertEqual(WorkspaceSearch.fuzzy("um", in: "Müller-um")?.1, [7, 8])
        XCTAssertNotNil(WorkspaceSearch.fuzzy("mull", in: "Müller"))     // accents don't matter
        XCTAssertGreaterThan(f("mm", "meum-main"), f("mm", "Summit rev1")) // initials beat letters inside a word
        XCTAssertGreaterThan(f("mm", "meum-main"), f("mm", "Gemma rev1"))
        XCTAssertGreaterThan(f("orion", "Orion rev1"), f("orion", "o-r-i-o-n"))   // a word typed out beats initials
        XCTAssertGreaterThan(f("rev", "Orion rev1"), f("rev", "r-e-v"))           // also at a later word
    }

    func testEmptyQueryListsThePreviousWorkspaceFirstAndTheCurrentLast() {
        let a = ws("alpha"), b = ws("beta"), c = ws("gamma"), d = ws("delta")
        var s = AppState(workspaces: [a, b, c, d], selectedWorkspaceID: b.id)
        XCTAssertEqual(titles(WorkspaceSearch.results(s, query: "", recent: [c.id, b.id])), ["gamma", "alpha", "delta", "beta"])
        s.selectedWorkspaceID = a.id
        XCTAssertEqual(titles(WorkspaceSearch.results(s, query: " ", recent: [UUID()])), ["beta", "gamma", "delta", "alpha"])
    }

    func testWorkspacesRankByMatchThenRecency() {
        let a = ws("meum"), b = ws("meum-site"), c = ws("garden"), d = ws("homework")
        let s = AppState(workspaces: [d, b, a, c], selectedWorkspaceID: c.id)
        XCTAssertEqual(titles(WorkspaceSearch.results(s, query: "meum")), ["meum", "meum-site"])
        XCTAssertEqual(titles(WorkspaceSearch.results(s, query: "me")).prefix(2), ["meum", "meum-site"])
        XCTAssertEqual(titles(WorkspaceSearch.results(s, query: "me")).last, "homework")
        // equal names: the one used last first
        let e = ws("api"), f = ws("api")
        let s2 = AppState(workspaces: [e, f])
        XCTAssertEqual(WorkspaceSearch.results(s2, query: "api", recent: [f.id]).map(\.target), [.workspace(f.id), .workspace(e.id)])
    }

    func testEveryWordMustMatchSomewhere() {
        var a = ws("Orion rev1", cwd: "/Users/x/code/orion_rev1")
        a.labels = ["staging"]
        let b = ws("Orion site")
        let s = AppState(workspaces: [a, b])
        XCTAssertEqual(titles(WorkspaceSearch.results(s, query: "orion staging", home: "/Users/x")), ["Orion rev1"])
        XCTAssertEqual(titles(WorkspaceSearch.results(s, query: "orion", home: "/Users/x")), ["Orion rev1", "Orion site"])
        XCTAssertEqual(WorkspaceSearch.results(s, query: "orion staging", home: "/Users/x")[0].titleMatches, [0, 1, 2, 3, 4])
    }

    func testGroupFolderAndMetadataFindAWorkspace() {
        var a = ws("one", cwd: "/Users/x/code/tools")
        var b = ws("two")
        b.metadata = ["board.project": "harbor"]
        let g = WorkspaceGroup(name: "Partners")
        a.group = g.id
        let s = AppState(workspaces: [a, b], groups: [g])
        XCTAssertEqual(titles(WorkspaceSearch.results(s, query: "tools", home: "/Users/x")), ["one"])
        XCTAssertEqual(titles(WorkspaceSearch.results(s, query: "partners", home: "/Users/x")), ["one"])
        XCTAssertEqual(titles(WorkspaceSearch.results(s, query: "harbor", home: "/Users/x")), ["two"])
        // the folder its focused tab is in, as its sidebar row shows
        let c = ws("three", cwd: "/Users/x", tabs: [Tab(cwd: "/srv/www")])
        XCTAssertEqual(titles(WorkspaceSearch.results(AppState(workspaces: [c]), query: "www", home: "/Users/x")), ["three", "www"])
        XCTAssertEqual(WorkspaceSearch.results(s, query: "", home: "/Users/x")[0].subtitle, "Partners · ~/code/tools")
    }

    func testTabsMatchOnTheirOwnAndComeAfterWorkspaces() {
        let t1 = Tab(title: "deploy logs", cwd: "/srv")
        let t2 = Tab(title: "zsh", cwd: "/Users/x/code/meum", agent: AgentSnapshot(sessionID: "s", name: "build-07", labels: ["review"]))
        let a = ws("deploy", tabs: [Tab(title: "zsh")])
        let b = ws("work", tabs: [t1, t2])
        let s = AppState(workspaces: [a, b])
        let r = WorkspaceSearch.results(s, query: "deploy", home: "/Users/x")
        XCTAssertEqual(r.map(\.target), [.workspace(a.id), .tab(workspace: b.id, tab: t1.id)])
        XCTAssertEqual(r[1].subtitle, "work · /srv")
        let byName = WorkspaceSearch.results(s, query: "07", home: "/Users/x")
        XCTAssertEqual(byName.map(\.target), [.tab(workspace: b.id, tab: t2.id)])
        XCTAssertEqual(byName[0].subtitle, "build-07 · work · ~/code/meum")
        XCTAssertEqual(WorkspaceSearch.results(s, query: "review").map(\.target), [.tab(workspace: b.id, tab: t2.id)])
        // shell titles don't match on scattered letters, only on a run or initials
        let shells = AppState(workspaces: [ws("a", tabs: [Tab(title: "admin@home:~")]), ws("b", tabs: [Tab(title: "my-mac")])])
        XCTAssertEqual(WorkspaceSearch.results(shells, query: "mm").map(\.title), ["my-mac"])
        XCTAssertEqual(WorkspaceSearch.results(shells, query: "home").map(\.title), ["admin@home:~"])
        // a tab does not match through its workspace's name
        XCTAssertFalse(WorkspaceSearch.results(s, query: "work zsh").contains { if case .tab = $0.target { return true }; return false })
    }
}
