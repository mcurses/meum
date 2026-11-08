import Foundation
import MeumCore
import XCTest
@testable import MeumControl

/// The collapsed sidebar's model side: workspace icons and the `sidebarCollapsed` setting.
final class SidebarCollapseTests: XCTestCase {
    func testIconParsing() {
        XCTAssertEqual(WorkspaceIcon("🚀"), .text("🚀"))
        XCTAssertEqual(WorkspaceIcon("vi"), .text("vi"))
        XCTAssertEqual(WorkspaceIcon(" 👩‍💻 "), .text("👩‍💻"))   // one grapheme, many scalars
        XCTAssertEqual(WorkspaceIcon("sf:leaf.fill"), .symbol("leaf.fill"))
        XCTAssertEqual(WorkspaceIcon("sf:leaf.fill")?.raw, "sf:leaf.fill")
        XCTAssertNil(WorkspaceIcon(""))
        XCTAssertNil(WorkspaceIcon("abc"))
        XCTAssertNil(WorkspaceIcon("sf:"))
        XCTAssertNil(WorkspaceIcon("sf:bad name"))
        XCTAssertEqual(WorkspaceIcon.fallback(forName: "meum"), .text("M"))
        XCTAssertEqual(WorkspaceIcon.fallback(forName: "  "), .text("?"))
    }

    func testWorkspaceWithoutIconStillDecodes() throws {
        // state files written before icons existed
        let json = #"{"id":"6F8C1E5A-1D6B-4C3E-9C1A-2B3C4D5E6F70","name":"old","pinned":false}"#
        let ws = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        XCTAssertNil(ws.icon)
        var a = AppState()
        a.addWorkspace(ws)
        var b = a
        XCTAssertTrue(b.setIcon(ws.id, "sf:leaf"))
        let changed = ModelJSON.diff(old: a, new: b).filter { $0.type == "workspace.changed" }
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed.first?.data["fields"], .array([.string("icon")]))
        XCTAssertEqual(ModelJSON.workspaceSummary(b.workspaces[0], selected: true, extras: nil)["icon"], .string("sf:leaf"))
    }

    func testSidebarCollapsedSetting() throws {
        var s = Settings()
        XCTAssertEqual(SettingsJSON.value(s, "sidebarCollapsed"), .bool(false))
        try SettingsJSON.set(&s, key: "sidebarCollapsed", value: true)
        XCTAssertTrue(s.sidebarCollapsed)
        let data = try JSONEncoder().encode(s)
        XCTAssertTrue(try JSONDecoder().decode(Settings.self, from: data).sidebarCollapsed)
        XCTAssertTrue(SettingsJSON.keys.contains("sidebarCollapsed"))
    }

    func testToggleSidebarShortcut() {
        XCTAssertEqual(Shortcuts.combo("toggleSidebar", in: Settings())?.text, "ctrl+cmd+s")
        XCTAssertTrue(Shortcuts.conflicts(KeyCombo("ctrl+cmd+s")!, except: "toggleSidebar", in: Settings()).isEmpty)
    }

    func testNewMethodsAreHandlerOwned() {
        XCTAssertTrue(MeumMethod.handlerOwned.contains(MeumMethod.workspaceSetIcon))
        XCTAssertTrue(MeumMethod.handlerOwned.contains(MeumMethod.sidebarSetCollapsed))
    }

    func testSidebarShowSwitches() throws {
        var s = Settings()
        XCTAssertTrue(s.sidebarShowBranch && s.sidebarShowShortcuts && s.sidebarShowAgentDots && s.sidebarShowStatus && s.sidebarShowPin)
        XCTAssertFalse(s.sidebarShowDirectory || s.sidebarShowMetadata || s.sidebarShowIcons)
        for k in SettingsJSON.sidebarShowKeys {
            let before = try XCTUnwrap(SettingsJSON.value(s, k)?.boolValue, k)
            try SettingsJSON.set(&s, key: k, value: .bool(!before))
            XCTAssertEqual(SettingsJSON.value(s, k)?.boolValue, !before, k)
        }
        XCTAssertThrowsError(try SettingsJSON.set(&s, key: "sidebarShowBranch", value: "maybe"))
        // an older settings.json without the keys gets the defaults; a stored false survives a round trip
        let old = try JSONDecoder().decode(Settings.self, from: Data(#"{"cardGap": 10}"#.utf8))
        XCTAssertTrue(old.sidebarShowShortcuts)
        var off = Settings(); off.sidebarShowShortcuts = false
        XCTAssertFalse(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(off)).sidebarShowShortcuts)
    }
}
