import MeumCore
import XCTest
@testable import MeumControl

final class MoveResizeEventTests: XCTestCase {
    func types(_ evs: [(type: String, data: JSON)]) -> [String] { evs.map(\.type) }

    func testTabMoveBetweenCardsEmitsMoved() {
        var a = AppState()
        var ws = Workspace.make(name: "w")
        let c1 = ws.cards[0].id
        let t2 = Tab()
        ws.addTab(t2, toCard: c1)
        let c2 = ws.split(c1, placement: .right, tab: Tab())!
        a.addWorkspace(ws)
        var b = a
        XCTAssertTrue(b.moveTab(t2.id, toCard: c2, index: 0))
        let ev = ModelJSON.diff(old: a, new: b)
        let moved = ev.filter { $0.type == "tab.moved" }
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(moved[0].data["id"], .string(t2.id.uuidString))
        XCTAssertEqual(moved[0].data["card"], .string(c2.uuidString))
        XCTAssertEqual(moved[0].data["fromCard"], .string(c1.uuidString))
        XCTAssertEqual(moved[0].data["index"], 0)
        XCTAssertTrue(types(ev).contains("workspace.changed"))
        XCTAssertEqual(ev.first { $0.type == "tab.changed" }?.data["fields"], ["card"])
    }

    func testReorderEmitsMovedOnlyForShiftedTabs() {
        var a = AppState()
        var ws = Workspace.make(name: "w")
        let c = ws.cards[0].id
        let t1 = ws.allTabs[0].id
        ws.addTab(Tab(), toCard: c)
        ws.addTab(Tab(), toCard: c)
        a.addWorkspace(ws)
        var b = a
        b.moveTab(t1, toCard: c, index: 2)
        let moved = ModelJSON.diff(old: a, new: b).filter { $0.type == "tab.moved" }
        // every tab changed position: t1 0->2, the others shift up by one
        XCTAssertEqual(moved.count, 3)
        XCTAssertEqual(moved.first { $0.data["id"] == .string(t1.uuidString) }?.data["index"], 2)
        // closing a tab shifts its neighbours but is not a move
        var d = b
        d.updateWorkspace(ws.id) { $0.closeTab(t1) }
        XCTAssertFalse(types(ModelJSON.diff(old: b, new: d)).contains("tab.moved"))
    }

    func testSplitResizeEmitsResized() {
        var a = AppState()
        var ws = Workspace.make(name: "w")
        ws.split(placement: .down, tab: Tab())
        a.addWorkspace(ws)
        let sid = a.workspaces[0].root!.splits[0].id
        var b = a
        b.setRatio(split: sid, ratio: 0.25)
        let ev = ModelJSON.diff(old: a, new: b)
        XCTAssertEqual(types(ev), ["workspace.changed", "split.resized"])
        XCTAssertEqual(ev[1].data["ratio"], .double(0.25))
        XCTAssertEqual(ev[1].data["previous"], .double(0.5))
        XCTAssertEqual(ev[1].data["axis"], "vertical")
    }
}

final class SettingsJSONTests: XCTestCase {
    func testDefaultsRoundTripAndAllKeys() {
        let s = Settings()
        let o = SettingsJSON.object(s)
        XCTAssertEqual(o.objectValue?.count, SettingsJSON.keys.count)
        XCTAssertEqual(o["cardGap"], 12)
        XCTAssertEqual(o["glassTint"], .double(0.35))
        XCTAssertEqual(o["background"], "glass")
        XCTAssertEqual(o["fontFamily"], .null)
        XCTAssertEqual(o["reattachSessions"], true)
    }

    func testSetValidates() throws {
        var s = Settings()
        try SettingsJSON.set(&s, key: "cardGap", value: 20)
        XCTAssertEqual(s.cardGap, 20)
        try SettingsJSON.set(&s, key: "glassTint", value: "0.5")   // CLI strings are accepted for numbers
        XCTAssertEqual(s.glassTint, 0.5)
        XCTAssertThrowsError(try SettingsJSON.set(&s, key: "cardGap", value: 500))
        XCTAssertThrowsError(try SettingsJSON.set(&s, key: "cardGap", value: "wide"))
        XCTAssertThrowsError(try SettingsJSON.set(&s, key: "nope", value: 1))
        try SettingsJSON.set(&s, key: "widgetHeight", value: "auto")
        XCTAssertTrue(s.widgetHeightAuto)
        XCTAssertEqual(SettingsJSON.value(s, "widgetHeight"), "auto")
        try SettingsJSON.set(&s, key: "widgetHeight", value: 200)
        XCTAssertFalse(s.widgetHeightAuto)
        XCTAssertEqual(SettingsJSON.value(s, "widgetHeight"), 200)
        try SettingsJSON.set(&s, key: "background", value: "Vibrancy")
        XCTAssertEqual(s.background, .vibrancy)
        XCTAssertThrowsError(try SettingsJSON.set(&s, key: "background", value: "plaid"))
        try SettingsJSON.set(&s, key: "solidColor", value: "112233")
        XCTAssertEqual(s.solidColor, "#112233")
        XCTAssertThrowsError(try SettingsJSON.set(&s, key: "solidColor", value: "#12"))
        try SettingsJSON.set(&s, key: "fontFamily", value: "JetBrains Mono")
        XCTAssertEqual(s.fontFamily, "JetBrains Mono")
        try SettingsJSON.set(&s, key: "fontFamily", value: "")
        XCTAssertNil(s.fontFamily)
        try SettingsJSON.set(&s, key: "gapsCatchClicks", value: "on")
        XCTAssertTrue(s.gapsCatchClicks)
        try SettingsJSON.set(&s, key: "resumeClaude", value: false)
        XCTAssertFalse(s.resumeClaude)
        XCTAssertThrowsError(try SettingsJSON.set(&s, key: "resumeClaude", value: 3))
    }

    func testStoreToleratesMissingAndUnknownKeys() throws {
        let dir = TestSupport.tempDir("settings")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = SettingsStore(url: URL(fileURLWithPath: dir + "/settings.json"))
        XCTAssertEqual(try store.load(), Settings())
        try #"{"cardGap": 20, "someFutureKey": [1], "background": "plaid"}"#
            .write(toFile: dir + "/settings.json", atomically: true, encoding: .utf8)
        let s = try store.load()
        XCTAssertEqual(s.cardGap, 20)
        XCTAssertEqual(s.background, .glass, "an unknown enum value falls back to the default")
        var t = s
        t.fontFamily = "Menlo"
        try store.save(t)
        XCTAssertEqual(try store.load(), t)
    }
}

final class MoveResizeSettingsCLITests: XCTestCase {
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

    func meum(_ args: [String]) -> (code: Int32, out: String) {
        let o = Locked<[String]>([])
        let env = CLIEnvironment(env: ["HOME": home!, "MEUM_SOCKET": h.socket], home: home,
                                 stdout: { s in o.mutate { $0.append(s) } }, stderr: { _ in }, readStdin: { "" })
        let code = CLI.run(args, environment: env)
        return (code, o.value.joined(separator: "\n"))
    }

    var lastCall: (method: String, params: JSON)? { h.handler.calls.last }

    func testTabMove() {
        XCTAssertEqual(meum(["tab", "move", "bbbb", "--card", "cccccccc-0000-4000-8000-000000000001", "--index", "0"]).code, 0)
        XCTAssertEqual(lastCall?.method, "tab.move")
        XCTAssertEqual(lastCall?.params, ["tab": .string(FakeHandler.tab2), "card": "cccccccc-0000-4000-8000-000000000001",
                                          "index": 0])
        XCTAssertEqual(meum(["tab", "move", "aaaa", "--split", "left", "--card", "cccccccc-0000-4000-8000-000000000002"]).code, 0)
        XCTAssertEqual(lastCall?.params["split"], "left")
        XCTAssertEqual(meum(["tab", "move", "aaaa", "--split", "sideways"]).code, 2)
        XCTAssertEqual(meum(["tab", "move", "aaaa", "--card", "cccc"]).code, 1, "ambiguous card prefix")
        XCTAssertEqual(meum(["tab", "move", "aaaa", "--card", "dddd"]).code, 1, "a split is not a card")
    }

    func testSplitResize() {
        XCTAssertEqual(meum(["split", "resize", "dddd", "0.3"]).code, 0)
        XCTAssertEqual(lastCall?.method, "split.resize")
        XCTAssertEqual(lastCall?.params, ["split": "dddddddd-0000-4000-8000-000000000003", "ratio": .double(0.3)])
        XCTAssertEqual(meum(["split", "resize", "dddd", "wide"]).code, 2)
        XCTAssertEqual(meum(["split", "resize", "cccc", "0.3"]).code, 1)
    }

    func testSettings() {
        let all = meum(["settings"])
        XCTAssertEqual(all.code, 0)
        XCTAssertEqual(all.out, "background = \"glass\"\ncardGap = 12")
        XCTAssertEqual(meum(["settings", "set", "cardGap", "16"]).code, 0)
        XCTAssertEqual(lastCall?.params, ["key": "cardGap", "value": 16])
        _ = meum(["settings", "set", "fontFamily", "JetBrains Mono"])
        XCTAssertEqual(lastCall?.params["value"], "JetBrains Mono")
        _ = meum(["settings", "set", "gapsCatchClicks", "true"])
        XCTAssertEqual(lastCall?.params["value"], true)
        XCTAssertEqual(meum(["settings", "frobnicate"]).code, 2)
    }

    func testWidgetOrder() throws {
        var s = Settings()
        XCTAssertEqual(SettingsJSON.value(s, "widgetOrder"), .array([]))
        try SettingsJSON.set(&s, key: "widgetOrder", value: .array(["board", "tamago"]))
        XCTAssertEqual(s.widgetOrder, ["board", "tamago"])
        try SettingsJSON.set(&s, key: "widgetOrder", value: "a, b")
        XCTAssertEqual(s.widgetOrder, ["a", "b"])
        XCTAssertThrowsError(try SettingsJSON.set(&s, key: "widgetOrder", value: .array([1])))
        // round trip through settings.json; an old file without the key loads with the default
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data).widgetOrder, ["a", "b"])
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).widgetOrder, [])
    }
}
