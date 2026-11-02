import Foundation
import MeumCore
import XCTest
@testable import MeumControl

/// The widget library's model: catalog format, versions, pins and the trust decision.
final class WidgetLibraryTests: XCTestCase {
    let teams = ["XHXWK3RG86"]

    func testTrustDecision() {
        var pins = WidgetPins()
        pins.pins["a"] = .init(sha256: "aaa", source: .catalog, version: "1.0")
        XCTAssertEqual(WidgetTrust.decide(id: "a", sha256: "aaa", signedTeam: nil, pins: pins, teams: teams, developerMode: false),
                       .pinned(.catalog))
        // a changed file is not trusted any more, unless signed by a trusted team or in developer mode
        XCTAssertFalse(WidgetTrust.decide(id: "a", sha256: "bbb", signedTeam: nil, pins: pins, teams: teams, developerMode: false).allowsLoading)
        XCTAssertEqual(WidgetTrust.decide(id: "a", sha256: "bbb", signedTeam: "XHXWK3RG86", pins: pins, teams: teams, developerMode: false),
                       .team("XHXWK3RG86"))
        XCTAssertFalse(WidgetTrust.decide(id: "b", sha256: "x", signedTeam: "OTHERTEAM1", pins: pins, teams: teams, developerMode: false).allowsLoading)
        XCTAssertEqual(WidgetTrust.decide(id: "b", sha256: "x", signedTeam: nil, pins: pins, teams: teams, developerMode: true), .developer)
        // a pin for another id does not count
        XCTAssertFalse(WidgetTrust.decide(id: "b", sha256: "aaa", signedTeam: nil, pins: pins, teams: teams, developerMode: false).allowsLoading)
    }

    func testHelperTrust() {
        var pins = WidgetPins()
        pins.pins["t"] = .init(sha256: "lib", source: .catalog, helperSha256: "help")
        XCTAssertTrue(WidgetTrust.decideHelper(id: "t", sha256: "help", signedTeam: nil, pins: pins, teams: teams, developerMode: false).allowsLoading)
        XCTAssertFalse(WidgetTrust.decideHelper(id: "t", sha256: "lib", signedTeam: nil, pins: pins, teams: teams, developerMode: false).allowsLoading)
    }

    func testVersions() {
        XCTAssertTrue(widgetVersionIsNewer("1.10", than: "1.9"))
        XCTAssertTrue(widgetVersionIsNewer("2", than: "1.9.9"))
        XCTAssertFalse(widgetVersionIsNewer("1.0", than: "1"))
        XCTAssertFalse(widgetVersionIsNewer("0.9", than: "1.0"))
    }

    func testCatalogDecodesAndPinsRoundTrip() throws {
        let json = """
        {"version": 1, "widgets": [{"id": "io.github.mcurses.meum.browser", "displayName": "Browser",
          "description": "A web page as a tab", "scope": "tile", "version": "1.0", "apiVersion": "meum.v1",
          "archs": ["arm64"], "url": "https://example.invalid/b.zip", "sha256": "00ff", "helper": false}]}
        """
        let c = try JSONDecoder().decode(WidgetCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(c.entry("io.github.mcurses.meum.browser")?.displayName, "Browser")
        XCTAssertTrue(WidgetCatalog.runs(c.widgets[0], api: "meum.v1", arch: "arm64"))
        XCTAssertFalse(WidgetCatalog.runs(c.widgets[0], api: "meum.v1", arch: "x86_64"))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WidgetPinStore(url: dir.appendingPathComponent("widget-pins.json"))
        XCTAssertFalse(store.exists)
        try store.save(WidgetPins(pins: ["x": .init(sha256: "s", source: .allowed)]))
        XCTAssertEqual(store.load().pins["x"]?.source, .allowed)
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testSettingsKeys() throws {
        var s = Settings()
        try SettingsJSON.set(&s, key: "widgetDeveloperMode", value: true)
        XCTAssertTrue(s.widgetDeveloperMode)
        try SettingsJSON.set(&s, key: "widgetTeamIDs", value: "xhxwk3rg86, ABCDE12345")
        XCTAssertEqual(s.widgetTeamIDs, ["XHXWK3RG86", "ABCDE12345"])
        XCTAssertThrowsError(try SettingsJSON.set(&s, key: "widgetTeamIDs", value: "short"))
        XCTAssertThrowsError(try SettingsJSON.set(&s, key: "widgetCatalogURL", value: "http://insecure.example/c.json"))
        try SettingsJSON.set(&s, key: "widgetCatalogURL", value: .null)
        XCTAssertEqual(s.widgetCatalogURL, Settings.defaultWidgetCatalogURL)
        XCTAssertTrue(MeumMethod.handlerOwned.contains(MeumMethod.widgetInstall))
    }
}
