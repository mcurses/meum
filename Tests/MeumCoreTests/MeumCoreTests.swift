import CoreGraphics
import XCTest
@testable import MeumCore

final class MeumCoreTests: XCTestCase {
    func testVersion() { XCTAssertEqual(MeumCore.apiVersion, "meum.v1") }

    func testZmxName() {
        let id = UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!
        XCTAssertEqual(ZmxNaming.sessionName(for: id), "meum-abcdef012345")
        XCTAssertEqual(ZmxNaming.sessionName(for: id, prefix: "meumtest-"), "meumtest-abcdef012345")
    }

    func testStatePaths() {
        let p = StatePaths.default(home: URL(fileURLWithPath: "/Users/x"))
        XCTAssertEqual(p.directory.path, "/Users/x/.local/state/meum")
        XCTAssertEqual(p.socket.lastPathComponent, "meum.sock")
        XCTAssertEqual(p.layout.lastPathComponent, "layout.json")
    }
}

final class LayoutTests: XCTestCase {
    let rect = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func testNewWorkspaceHasOneCardOneTab() {
        let ws = Workspace.make(name: "a", cwd: "/tmp")
        XCTAssertEqual(ws.cards.count, 1)
        XCTAssertEqual(ws.allTabs.count, 1)
        XCTAssertEqual(ws.allTabs[0].cwd, "/tmp")
        XCTAssertEqual(ws.focusedCardID, ws.cards[0].id)
    }

    func testSingleCardFillsRect() {
        let ws = Workspace.make(name: "a")
        XCTAssertEqual(ws.frames(in: rect, gap: 12)[ws.cards[0].id], rect)
    }

    func testSplitRightGeometry() {
        var ws = Workspace.make(name: "a")
        let a = ws.cards[0].id
        let b = ws.split(placement: .right, tab: Tab())!
        XCTAssertEqual(ws.focusedCardID, b)
        let f = ws.frames(in: rect, gap: 12)
        XCTAssertEqual(f[a], CGRect(x: 0, y: 0, width: 494, height: 600))
        XCTAssertEqual(f[b], CGRect(x: 506, y: 0, width: 494, height: 600))
    }

    func testSplitDownGeometryAndNesting() {
        var ws = Workspace.make(name: "a")
        let a = ws.cards[0].id
        let b = ws.split(placement: .right, tab: Tab())!
        let c = ws.split(b, placement: .down, tab: Tab())!
        let f = ws.frames(in: rect, gap: 10)
        XCTAssertEqual(f[a], CGRect(x: 0, y: 0, width: 495, height: 600))
        XCTAssertEqual(f[b], CGRect(x: 505, y: 0, width: 495, height: 295))
        XCTAssertEqual(f[c], CGRect(x: 505, y: 305, width: 495, height: 295))
        XCTAssertEqual(ws.cards.map(\.id), [a, b, c])
    }

    func testGapsAreEvenAndNoOverlap() {
        var ws = Workspace.make(name: "a")
        ws.split(placement: .right, tab: Tab())
        ws.split(placement: .down, tab: Tab())
        ws.split(ws.cards[0].id, placement: .down, tab: Tab())
        let frames = Array(ws.frames(in: rect, gap: 12).values)
        for i in frames.indices { for j in frames.indices where i < j {
            XCTAssertFalse(frames[i].intersects(frames[j]), "\(frames[i]) overlaps \(frames[j])")
        } }
        for f in frames { XCTAssertTrue(rect.contains(f)) }
    }

    func testCloseLastTabCollapsesSplit() {
        var ws = Workspace.make(name: "a")
        let a = ws.cards[0].id
        let b = ws.split(placement: .right, tab: Tab())!
        let tabB = ws.card(b)!.tabs[0].id
        XCTAssertTrue(ws.closeTab(tabB))
        XCTAssertEqual(ws.cards.map(\.id), [a])
        if case .card = ws.root! {} else { XCTFail("split should have collapsed") }
        XCTAssertEqual(ws.focusedCardID, a)
    }

    func testCloseMiddleCardFocusesSibling() {
        var ws = Workspace.make(name: "a")
        let b = ws.split(placement: .right, tab: Tab())!
        let c = ws.split(b, placement: .down, tab: Tab())!
        ws.focusCard(b)
        XCTAssertTrue(ws.removeCard(b))
        XCTAssertEqual(ws.focusedCardID, c)
        XCTAssertEqual(ws.cards.count, 2)
    }

    func testCloseOnlyTabEmptiesWorkspace() {
        var ws = Workspace.make(name: "a")
        XCTAssertTrue(ws.closeTab(ws.allTabs[0].id))
        XCTAssertNil(ws.root)
        XCTAssertNil(ws.focusedCardID)
        // a new tab in an empty workspace creates a card again
        let card = ws.addTab(Tab())
        XCTAssertEqual(ws.focusedCardID, card)
        XCTAssertEqual(ws.allTabs.count, 1)
    }

    func testCloseTabInMultiTabCardSelectsNeighbour() {
        var ws = Workspace.make(name: "a")
        let t1 = ws.allTabs[0].id
        let t2 = Tab(), t3 = Tab()
        ws.addTab(t2)
        ws.addTab(t3)
        XCTAssertEqual(ws.cards[0].tabs.map(\.id), [t1, t2.id, t3.id])
        XCTAssertEqual(ws.cards[0].selectedTabID, t3.id)
        ws.selectTab(t2.id)
        XCTAssertTrue(ws.closeTab(t2.id))
        XCTAssertEqual(ws.cards[0].selectedTabID, t3.id)
        XCTAssertTrue(ws.closeTab(t3.id))
        XCTAssertEqual(ws.cards[0].selectedTabID, t1)
        XCTAssertFalse(ws.closeTab(UUID()))
    }

    func testAddTabInsertsAfterSelected() {
        var ws = Workspace.make(name: "a")
        let t1 = ws.allTabs[0].id
        let t2 = Tab(), t3 = Tab()
        ws.addTab(t2)
        ws.selectTab(t1)
        ws.addTab(t3)
        XCTAssertEqual(ws.cards[0].tabs.map(\.id), [t1, t3.id, t2.id])
    }

    func testSelectAdjacentTabWraps() {
        var ws = Workspace.make(name: "a")
        let t1 = ws.allTabs[0].id
        let t2 = Tab()
        ws.addTab(t2)
        ws.selectAdjacentTab(1)
        XCTAssertEqual(ws.cards[0].selectedTabID, t1)
        ws.selectAdjacentTab(-1)
        XCTAssertEqual(ws.cards[0].selectedTabID, t2.id)
    }

    func testMoveFocusByDirection() {
        // a | b
        //   | c
        var ws = Workspace.make(name: "a")
        let a = ws.cards[0].id
        let b = ws.split(placement: .right, tab: Tab())!
        let c = ws.split(b, placement: .down, tab: Tab())!
        ws.focusCard(a)
        XCTAssertTrue(ws.moveFocus(.right, in: rect, gap: 12))
        XCTAssertEqual(ws.focusedCardID, b) // the top one wins the overlap tie by distance then overlap
        XCTAssertTrue(ws.moveFocus(.down, in: rect, gap: 12))
        XCTAssertEqual(ws.focusedCardID, c)
        XCTAssertFalse(ws.moveFocus(.down, in: rect, gap: 12))
        XCTAssertTrue(ws.moveFocus(.left, in: rect, gap: 12))
        XCTAssertEqual(ws.focusedCardID, a)
        XCTAssertFalse(ws.moveFocus(.left, in: rect, gap: 12))
        XCTAssertFalse(ws.moveFocus(.up, in: rect, gap: 12))
    }

    func testResizeMovesNearestMatchingSplit() {
        var ws = Workspace.make(name: "a")
        let b = ws.split(placement: .right, tab: Tab())!
        _ = ws.split(b, placement: .down, tab: Tab())
        ws.focusCard(b)
        XCTAssertTrue(ws.resizeFocused(.right, delta: 0.1))
        guard case .split(let outer) = ws.root! else { return XCTFail() }
        XCTAssertEqual(outer.ratio, 0.6, accuracy: 1e-9)
        XCTAssertTrue(ws.resizeFocused(.up, delta: 0.1))
        guard case .split(let inner) = outer.second else { return XCTFail() }
        XCTAssertEqual(inner.ratio, 0.5, accuracy: 1e-9) // unchanged in `outer` snapshot
        guard case .split(let outer2) = ws.root!, case .split(let inner2) = outer2.second else { return XCTFail() }
        XCTAssertEqual(inner2.ratio, 0.4, accuracy: 1e-9)
    }

    func testResizeClamps() {
        var ws = Workspace.make(name: "a")
        ws.split(placement: .right, tab: Tab())
        for _ in 0..<30 { ws.resizeFocused(.right, delta: 0.1) }
        guard case .split(let s) = ws.root! else { return XCTFail() }
        XCTAssertEqual(s.ratio, Split.maxRatio, accuracy: 1e-9)
        XCTAssertFalse(ws.resizeFocused(.down))
    }

    func testUpdateTab() {
        var ws = Workspace.make(name: "a")
        let t = ws.allTabs[0].id
        XCTAssertTrue(ws.updateTab(t) { $0.title = "zsh" })
        XCTAssertEqual(ws.tab(t)?.title, "zsh")
    }
}

final class AppStateTests: XCTestCase {
    func make(_ n: Int) -> AppState {
        var s = AppState()
        for i in 0..<n { s.addWorkspace(.make(name: "w\(i)"), select: i == 0) }
        return s
    }

    func testAddAndSelect() {
        var s = make(3)
        XCTAssertEqual(s.selectedWorkspace?.name, "w0")
        XCTAssertTrue(s.selectWorkspace(at: 2))
        XCTAssertEqual(s.selectedWorkspace?.name, "w2")
        XCTAssertFalse(s.selectWorkspace(at: 9))
        s.selectAdjacentWorkspace(1)
        XCTAssertEqual(s.selectedWorkspace?.name, "w0")
        s.selectAdjacentWorkspace(-1)
        XCTAssertEqual(s.selectedWorkspace?.name, "w2")
    }

    func testCloseSelectedSelectsNeighbour() {
        var s = make(3)
        s.selectWorkspace(at: 1)
        s.closeWorkspace(s.workspaces[1].id)
        XCTAssertEqual(s.selectedWorkspace?.name, "w2")
        s.closeWorkspace(s.selectedWorkspaceID!)
        XCTAssertEqual(s.selectedWorkspace?.name, "w0")
        s.closeWorkspace(s.selectedWorkspaceID!)
        XCTAssertNil(s.selectedWorkspaceID)
    }

    func testReorder() {
        var s = make(4)
        let id = s.workspaces[0].id
        XCTAssertTrue(s.moveWorkspace(id, to: 2))
        XCTAssertEqual(s.workspaces.map(\.name), ["w1", "w2", "w0", "w3"])
        XCTAssertTrue(s.moveWorkspace(id, to: 99))
        XCTAssertEqual(s.workspaces.map(\.name), ["w1", "w2", "w3", "w0"])
        XCTAssertTrue(s.moveWorkspace(id, to: -3))
        XCTAssertEqual(s.workspaces.map(\.name), ["w0", "w1", "w2", "w3"])
    }

    func testRenameColorPin() {
        var s = make(1)
        let id = s.workspaces[0].id
        XCTAssertFalse(s.renameWorkspace(id, to: "  "))
        XCTAssertTrue(s.renameWorkspace(id, to: " api "))
        XCTAssertEqual(s.workspaces[0].name, "api")
        s.setColor(id, "#ff8800")
        s.setPinned(id, true)
        XCTAssertEqual(s.workspaces[0].color, "#ff8800")
        XCTAssertTrue(s.workspaces[0].pinned)
    }

    func testWorkspaceContainingTab() {
        var s = make(2)
        let t = s.workspaces[1].allTabs[0].id
        XCTAssertEqual(s.workspace(containingTab: t)?.name, "w1")
        XCTAssertTrue(s.updateTab(t) { $0.cwd = "/x" })
        XCTAssertEqual(s.workspaces[1].tab(t)?.cwd, "/x")
        XCTAssertEqual(s.allTabIDs.count, 2)
    }

    func testNormalizeFixesStaleIDs() {
        var s = make(1)
        s.selectedWorkspaceID = UUID()
        s.workspaces[0].focusedCardID = UUID()
        s.normalize()
        XCTAssertEqual(s.selectedWorkspaceID, s.workspaces[0].id)
        XCTAssertEqual(s.workspaces[0].focusedCardID, s.workspaces[0].cards[0].id)
    }
}

final class PersistenceTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("meumcore-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testRoundTrip() throws {
        var s = AppState()
        var ws = Workspace.make(name: "a", cwd: "/tmp", color: "#123456")
        ws.split(placement: .right, tab: Tab(title: "t", cwd: "/x", command: "htop",
                                              agent: AgentSnapshot(sessionID: "abc", configDir: "/c")))
        ws.split(placement: .down, tab: Tab(), ratio: 0.3)
        s.addWorkspace(ws)
        s.addWorkspace(.make(name: "b"), select: false)
        let store = LayoutStore(url: dir.appendingPathComponent("layout.json"))
        XCTAssertNil(try store.load())
        try store.save(s)
        let back = try store.load()
        XCTAssertEqual(back, s)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testJSONHasVersionAndReadableShape() throws {
        let s = AppState(workspaces: [.make(name: "a")])
        let json = String(data: try LayoutStore.encoder().encode(s), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"version\" : 1"))
        XCTAssertTrue(json.contains("\"card\""))
    }

    func testNewerVersionIsRejected() throws {
        let store = LayoutStore(url: dir.appendingPathComponent("layout.json"))
        var s = AppState()
        s.version = 99
        try store.save(s)
        XCTAssertThrowsError(try store.load()) { e in
            XCTAssertEqual(e as? PersistenceError, .unsupportedVersion(99))
        }
    }

    func testCorruptFileThrowsAndQuarantines() throws {
        let store = LayoutStore(url: dir.appendingPathComponent("layout.json"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{nope".utf8).write(to: store.url)
        XCTAssertThrowsError(try store.load())
        let moved = store.quarantine(now: Date(timeIntervalSince1970: 42))
        XCTAssertEqual(moved?.lastPathComponent, "layout.json.corrupt-42")
        XCTAssertNil(try store.load())
    }

    func testRatioIsClampedOnDecode() throws {
        let json = """
        {"id":"\(UUID().uuidString)","axis":"horizontal","ratio":5,
         "first":{"card":{"id":"\(UUID().uuidString)","selectedTabID":"\(UUID().uuidString)","tabs":[{"id":"\(UUID().uuidString)"}]}},
         "second":{"card":{"id":"\(UUID().uuidString)","selectedTabID":"\(UUID().uuidString)","tabs":[{"id":"\(UUID().uuidString)"}]}}}
        """
        let s = try JSONDecoder().decode(Split.self, from: Data(json.utf8))
        XCTAssertEqual(s.ratio, Split.maxRatio)
    }

    func testWidgetTabRoundTripsAndOldTabsDecode() throws {
        let t = Tab(title: "Hello", widget: "io.example.hello")
        XCTAssertTrue(t.isWidget)
        let back = try JSONDecoder().decode(Tab.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(back, t)
        // a tab saved before widget tabs existed has no "widget" key
        let old = try JSONDecoder().decode(Tab.self, from: Data(#"{"id":"ABCDEF01-2345-6789-ABCD-EF0123456789","cwd":"/tmp"}"#.utf8))
        XCTAssertNil(old.widget)
        XCTAssertFalse(old.isWidget)
    }
}
