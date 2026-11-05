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
    }
}
