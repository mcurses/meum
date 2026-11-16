import XCTest
@testable import MeumControl

final class HookOriginTests: XCTestCase {
    func testOnlyTheTabsOwnTerminalSpeaksForIt() {
        XCTAssertTrue(HookOrigin.accepts(hookTTY: "ttys012", tabTTY: "ttys012"))
        XCTAssertFalse(HookOrigin.accepts(hookTTY: "ttys059", tabTTY: "ttys012"))
        XCTAssertFalse(HookOrigin.accepts(hookTTY: "", tabTTY: "ttys012"))
        // meum can't tell the tab's terminal: the hook is taken, as before the check
        XCTAssertTrue(HookOrigin.accepts(hookTTY: "ttys059", tabTTY: nil))
    }

    func testTTYNameOfAGoneProcessIsNil() {
        XCTAssertNil(HookOrigin.ttyName(of: 999_999))
    }

    func testForeignHookRecordsAndPublishesNothing() throws {
        let agents = AgentService(bus: EventBus())
        agents.originCheck = { _, tty in tty == "ttys012" }
        let payload: JSON = ["session_id": "s1", "hook_event_name": "SessionStart", "cwd": "/tmp/x"]
        XCTAssertEqual(try agents.handleHook(params: ["tab": "T", "tty": "ttys059", "payload": payload])["outcome"], "foreign")
        XCTAssertNil(agents.state(of: "T"))
        XCTAssertNotEqual(try agents.handleHook(params: ["tab": "T", "tty": "ttys012", "payload": payload])["outcome"], "foreign")
        XCTAssertEqual(agents.state(of: "T")?.sessionID, "s1")
        // an older meum-hook sends no tty: taken
        XCTAssertNotEqual(try agents.handleHook(params: ["tab": "U", "payload": payload])["outcome"], "foreign")
    }
}
