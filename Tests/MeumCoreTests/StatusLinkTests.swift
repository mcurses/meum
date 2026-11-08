import XCTest
@testable import MeumCore

final class StatusLinkTests: XCTestCase {
    func testWebLinksOpenOtherSchemesAskUntilAllowed() {
        XCTAssertEqual(StatusLink.decide(URL(string: "https://example.com")!, allowed: []), .open)
        XCTAssertEqual(StatusLink.decide(URL(string: "HTTP://example.com")!, allowed: []), .open)
        XCTAssertEqual(StatusLink.decide(URL(string: "file:///Applications/Calculator.app")!, allowed: []), .ask("file"))
        XCTAssertEqual(StatusLink.decide(URL(string: "shortcuts://run-shortcut?name=x")!, allowed: []), .ask("shortcuts"))
        XCTAssertEqual(StatusLink.decide(URL(string: "myboard://card/1")!, allowed: ["myboard"]), .open)
        XCTAssertEqual(StatusLink.decide(URL(string: "relative/path")!, allowed: []), .refuse)
        // schemes that can run things are asked about every time, even if a list names them
        XCTAssertEqual(StatusLink.decide(URL(string: "file:///tmp/x.command")!, allowed: ["file"]), .ask("file"))
        XCTAssertEqual(StatusLink.decide(URL(string: "shortcuts://run-shortcut?name=x")!, allowed: ["shortcuts"]), .ask("shortcuts"))
        XCTAssertFalse(StatusLink.mayRemember("FILE"))
        XCTAssertTrue(StatusLink.mayRemember("myboard"))
    }
}

final class ClaudeSessionLookupTests: XCTestCase {
    func testFindsTheTabByWholeIdOrUniquePrefix() {
        var a = Tab(cwd: "/tmp"); a.agent = AgentSnapshot(sessionID: "e6893ae3-43f6-425b-bc3e-e1a618fdfb37")
        var b = Tab(cwd: "/tmp"); b.agent = AgentSnapshot(sessionID: "e6893ae9-0000-0000-0000-000000000000")
        var s = AppState()
        var ws = Workspace.make(name: "w", cwd: "/tmp")
        ws.split(placement: .right, tab: a)
        ws.split(placement: .right, tab: b)
        s.addWorkspace(ws)
        XCTAssertEqual(s.tab(claudeSession: "E6893AE3-43F6-425B-BC3E-E1A618FDFB37"), .found(a.id))
        XCTAssertEqual(s.tab(claudeSession: "e6893ae3-43"), .found(a.id))
        XCTAssertEqual(s.tab(claudeSession: "e6893ae"), .none)          // under 8 characters: whole ids only
        XCTAssertEqual(s.tab(claudeSession: "e6893ae"+"3"), .found(a.id))
        XCTAssertEqual(s.tab(claudeSession: "e6893a"+"e"+"x"), .none)
        if case .ambiguous(2) = s.tab(claudeSession: "e6893ae") { XCTFail("short prefixes never match") }
        XCTAssertEqual(s.tab(claudeSession: "nothing-like-it"), .none)
    }
}

final class NextWaitingTests: XCTestCase {
    func testWaitingFirstThenUnreadInSidebarOrderAfterTheCurrentTab() {
        let t = (0..<5).map { _ in UUID() }
        // waiting beats unread, even when the unread one comes first
        XCTAssertEqual(NextWaiting.pick(order: t, current: t[0], waiting: [t[3]], unread: [t[1]]), t[3])
        // wraps around past the end
        XCTAssertEqual(NextWaiting.pick(order: t, current: t[3], waiting: [t[1], t[3]], unread: []), t[1])
        // the current tab comes last: another waiting one first
        XCTAssertEqual(NextWaiting.pick(order: t, current: t[2], waiting: [t[2], t[4]], unread: []), t[4])
        // only the current one waits: it is the answer
        XCTAssertEqual(NextWaiting.pick(order: t, current: t[2], waiting: [t[2]], unread: []), t[2])
        XCTAssertEqual(NextWaiting.pick(order: t, current: nil, waiting: [], unread: [t[4]]), t[4])
        XCTAssertNil(NextWaiting.pick(order: t, current: t[0], waiting: [], unread: []))
    }
}
