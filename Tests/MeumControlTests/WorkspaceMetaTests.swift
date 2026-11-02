import XCTest
@testable import MeumControl
import MeumCore

final class WorkspaceMetaTests: XCTestCase {
    func testMetadataAndRemotesInWorkspaceJSON() {
        var ws = Workspace(name: "site", cwd: "/w")
        ws.metadata = ["board.project": "acme/shop"]
        var ex = WorkspaceExtras()
        ex.remotes = ["git@github.com:example/shop.git"]
        let o = ModelJSON.workspaceSummary(ws, selected: true, extras: ex)
        XCTAssertEqual(o["metadata"], ["board.project": "acme/shop"])
        XCTAssertEqual(o["remotes"], ["git@github.com:example/shop.git"])
        XCTAssertEqual(ModelJSON.workspaceSummary(Workspace(name: "x"), selected: false, extras: nil)["metadata"], .object([:]))
    }

    func testMetadataChangeIsAWorkspaceChangedField() {
        let ws = Workspace(name: "site")
        var changed = ws
        changed.metadata = ["k": "v"]
        let events = ModelJSON.diff(old: AppState(workspaces: [ws]), new: AppState(workspaces: [changed]))
        let fields = events.first { $0.type == "workspace.changed" }?.data["fields"]
        XCTAssertEqual(fields, ["metadata"])
    }

    func testStateSavedBeforeMetadataLoads() throws {
        let old = #"{"version":1,"workspaces":[{"id":"ABCDEF01-2345-6789-ABCD-EF0123456789","name":"a","pinned":false}]}"#
        let s = try JSONDecoder().decode(AppState.self, from: Data(old.utf8))
        XCTAssertNil(s.workspaces[0].metadata)
        var w = s.workspaces[0]
        w.metadata = ["a.b": "c"]
        XCTAssertEqual(try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(w)).metadata, ["a.b": "c"])
    }
}
