import Foundation
import MeumCore
import XCTest

final class WorkspaceGroupTests: XCTestCase {
    private func state(_ names: String...) -> AppState {
        AppState(workspaces: names.map { Workspace(name: $0) })
    }
    private func order(_ s: AppState) -> String {
        s.workspaces.map { ws in ws.group.flatMap { g in s.group(g)?.name }.map { "\($0):\(ws.name)" } ?? ws.name }
            .joined(separator: " ")
    }
    private func id(_ s: AppState, _ name: String) -> UUID { s.workspaces.first { $0.name == name }!.id }

    func testCreateGathersAtFirstMember() {
        var s = state("a", "b", "c", "d")
        let g = s.createGroup(name: "G", workspaces: [id(s, "d"), id(s, "b")])
        XCTAssertNotNil(g)
        XCTAssertEqual(order(s), "a G:b G:d c")
    }

    func testMoveIntoAndOutOfGroupsAndEmptyGroupsVanish() {
        var s = state("a", "b", "c", "d")
        let g = s.createGroup(name: "G", workspaces: [id(s, "a"), id(s, "b")])!
        s.setGroup([id(s, "d")], to: g)
        XCTAssertEqual(order(s), "G:a G:b G:d c")
        s.setGroup([id(s, "a")], to: nil)
        XCTAssertEqual(order(s), "G:b G:d a c")
        s.setGroup([id(s, "b"), id(s, "d")], to: nil)
        XCTAssertEqual(order(s), "b d a c")
        XCTAssertTrue(s.groups.isEmpty, "a group without members is dropped")
    }

    func testCreatingFromMembersOfAnotherGroupTakesThemOut() {
        var s = state("a", "b", "c")
        _ = s.createGroup(name: "G", workspaces: [id(s, "a"), id(s, "b")])
        _ = s.createGroup(name: "H", workspaces: [id(s, "b"), id(s, "c")])
        XCTAssertEqual(order(s), "G:a H:b H:c")
    }

    func testBlockDroppedInsideAnotherGroupLandsAfterIt() {
        var s = state("a", "b", "c", "d")
        let g = s.createGroup(name: "G", workspaces: [id(s, "a"), id(s, "b")])!
        _ = g
        let h = s.createGroup(name: "H", workspaces: [id(s, "d")])!
        s.moveGroup(h, before: id(s, "b"))
        XCTAssertEqual(order(s), "H:d G:a G:b c", "an anchor inside another group means before that group")
        s.moveWorkspaces([id(s, "c")], before: id(s, "b"), group: nil)
        XCTAssertEqual(order(s), "H:d G:a G:b c", "an ungrouped workspace cannot split a group")
    }

    func testLegacyMoveJoinsOrLeaves() {
        var s = state("a", "b", "c", "d")
        _ = s.createGroup(name: "G", workspaces: [id(s, "a"), id(s, "b")])
        s.moveWorkspace(id(s, "d"), to: 1)   // between a and b
        XCTAssertEqual(order(s), "G:a G:d G:b c")
        s.moveWorkspace(id(s, "a"), to: 3)   // to the end, away from G
        XCTAssertEqual(order(s), "G:d G:b c a")
    }

    func testRenameCollapseUngroupCloseAndDecodeOldState() throws {
        var s = state("a", "b")
        let g = s.createGroup(name: "G", workspaces: [id(s, "a"), id(s, "b")])!
        XCTAssertFalse(s.renameGroup(g, to: "  "))
        XCTAssertTrue(s.renameGroup(g, to: "Work"))
        XCTAssertTrue(s.setGroupCollapsed(g, true))
        XCTAssertEqual(s.group(g)?.collapsed, true)
        let back = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        s.closeWorkspace(id(s, "a")); s.closeWorkspace(id(s, "b"))
        XCTAssertTrue(s.groups.isEmpty)

        var t = state("x", "y")
        let h = t.createGroup(name: "H", workspaces: [id(t, "x")])!
        XCTAssertTrue(t.ungroup(h))
        XCTAssertEqual(order(t), "x y")
        let old = try JSONDecoder().decode(AppState.self, from: Data(#"{"version":1,"workspaces":[]}"#.utf8))
        XCTAssertEqual(old.groups, [])
    }
}
