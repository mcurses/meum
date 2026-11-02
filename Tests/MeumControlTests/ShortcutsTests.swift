@testable import MeumControl
import MeumCore
import XCTest

final class ShortcutsTests: XCTestCase {
    func testParseAndText() {
        let c = KeyCombo("shift+cmd+R")
        XCTAssertEqual(c, KeyCombo(key: "r", command: true, shift: true))
        XCTAssertEqual(c?.text, "shift+cmd+r")
        XCTAssertEqual(c?.display, "⇧⌘R")
        XCTAssertEqual(KeyCombo("opt+cmd+left")?.display, "⌥⌘←")
        XCTAssertEqual(KeyCombo("cmd+plus")?.key, "+")
        XCTAssertNil(KeyCombo("hyper+r"))
        XCTAssertNil(KeyCombo("cmd+rr"))
        XCTAssertNil(KeyCombo(""))
    }

    func testRenameWorkspaceDefault() {
        XCTAssertEqual(Shortcuts.combo("renameWorkspace", in: Settings())?.text, "shift+cmd+r")
        XCTAssertEqual(Shortcuts.conflicts(KeyCombo("shift+cmd+r")!, except: "renameWorkspace", in: Settings()), [])
    }

    func testDefaultsHaveNoConflicts() {
        let s = Settings()
        for a in Shortcuts.actions {
            guard let c = a.defaultCombo else { continue }
            XCTAssertEqual(Shortcuts.conflicts(c, except: a.id, in: s).map(\.id), [], a.id)
        }
    }

    func testSetOverrideNoneAndDefault() throws {
        var s = Settings()
        try SettingsJSON.set(&s, key: "shortcut.renameWorkspace", value: "ctrl+cmd+e")
        XCTAssertEqual(s.shortcuts, ["renameWorkspace": "ctrl+cmd+e"])
        XCTAssertEqual(SettingsJSON.value(s, "shortcut.renameWorkspace"), "ctrl+cmd+e")
        try SettingsJSON.set(&s, key: "shortcut.renameWorkspace", value: "none")
        XCTAssertNil(Shortcuts.combo("renameWorkspace", in: s))
        XCTAssertEqual(SettingsJSON.value(s, "shortcut.renameWorkspace"), .null)
        try SettingsJSON.set(&s, key: "shortcut.renameWorkspace", value: .null)
        XCTAssertEqual(s.shortcuts, [:])
        // setting the default stores no override
        try SettingsJSON.set(&s, key: "shortcut.newTab", value: "cmd+t")
        XCTAssertEqual(s.shortcuts, [:])
        try SettingsJSON.set(&s, key: "shortcuts", value: ["newTab": "ctrl+cmd+t", "closeTab": "none"])
        XCTAssertEqual(s.shortcuts, ["newTab": "ctrl+cmd+t", "closeTab": ""])
        XCTAssertEqual(SettingsJSON.value(s, "shortcuts")?["newTab"], "ctrl+cmd+t")
    }

    func testSetRejectsBadInput() {
        var s = Settings()
        XCTAssertThrowsError(try SettingsJSON.set(&s, key: "shortcut.nope", value: "cmd+x"))
        XCTAssertThrowsError(try SettingsJSON.set(&s, key: "shortcut.newTab", value: "t"))
        XCTAssertThrowsError(try SettingsJSON.set(&s, key: "shortcut.newTab", value: "cmd+"))
    }

    func testSettingsFileRoundTrip() throws {
        var s = Settings()
        s.shortcuts = ["renameWorkspace": "ctrl+cmd+e"]
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.shortcuts, s.shortcuts)
        let old = try JSONDecoder().decode(Settings.self, from: Data("{\"cardGap\": 8}".utf8))
        XCTAssertEqual(old.shortcuts, [:])
    }
}
