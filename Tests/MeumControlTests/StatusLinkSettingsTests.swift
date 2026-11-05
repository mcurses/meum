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
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.statusLinkSchemes, ["myboard", "x-tool"])
    }
}
