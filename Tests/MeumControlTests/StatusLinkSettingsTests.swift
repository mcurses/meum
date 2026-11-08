import XCTest
@testable import MeumControl
import MeumCore

final class StatusLinkSettingsTests: XCTestCase {
    func testAllowedSchemesAreReadOnlyOverTheSocketAndValidated() throws {
        XCTAssertTrue(SettingsJSON.socketReadOnly.contains("statusLinkSchemes"))
        XCTAssertTrue(SettingsJSON.socketRefusal("statusLinkSchemes").contains("asks the user"))
        var s = Settings()
        try SettingsJSON.set(&s, key: "statusLinkSchemes", value: .array(["MyBoard", "myboard", "x-tool"]))
        XCTAssertEqual(s.statusLinkSchemes, ["myboard", "x-tool"])
        XCTAssertThrowsError(try SettingsJSON.set(&s, key: "statusLinkSchemes", value: .array(["https"])))
        XCTAssertThrowsError(try SettingsJSON.set(&s, key: "statusLinkSchemes", value: .array(["no spaces"])))
        XCTAssertThrowsError(try SettingsJSON.set(&s, key: "statusLinkSchemes", value: .array(["file"])))
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.statusLinkSchemes, ["myboard", "x-tool"])
    }
}

final class MCPStaleNoteTests: XCTestCase {
    func testNotesAnUpdatedAppOnly() {
        XCTAssertNil(MCPServer.staleNote(running: "0.5.2", mine: "0.5.2"))
        XCTAssertNil(MCPServer.staleNote(running: nil, mine: "0.5.1"))
        XCTAssertNil(MCPServer.staleNote(running: "0.5.2", mine: nil))
        XCTAssertEqual(MCPServer.staleNote(running: "0.5.2", mine: "0.5.1"),
                       "meum was updated to 0.5.2; this session still runs the 0.5.1 tools. Restart Claude Code here for the newer ones.")
    }
}
