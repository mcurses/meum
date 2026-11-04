@testable import MeumControl
import MeumCore
import XCTest

final class TabLabelsTests: XCTestCase {
    func testValidLabels() throws {
        XCTAssertEqual(try AgentSnapshot.validLabels([" main ", "owner", "main", ""]), ["main", "owner"])
        XCTAssertEqual(try AgentSnapshot.validLabels([]), [])
        XCTAssertThrowsError(try AgentSnapshot.validLabels(["a", "b", "c", "d", "e"]))
        XCTAssertThrowsError(try AgentSnapshot.validLabels([String(repeating: "x", count: 25)]))
    }

    func testLabelsInSnapshotJSONAndOldStateLoads() throws {
        let snap = AgentSnapshot(sessionID: "s", labels: ["maintainer"])
        XCTAssertEqual(ModelJSON.snapshot(snap)["labels"], ["maintainer"])
        XCTAssertEqual(ModelJSON.snapshot(AgentSnapshot(sessionID: "s"))["labels"], [])
        let old = try JSONDecoder().decode(AgentSnapshot.self, from: Data(#"{"sessionID":"s"}"#.utf8))
        XCTAssertNil(old.labels)
        XCTAssertTrue(MeumMethod.handlerOwned.contains(MeumMethod.tabSetLabels))
    }

    func testMCPOffersTheSelfTools() {
        let names = MCPServer.tools.compactMap { $0["name"]?.stringValue }
        XCTAssertTrue(names.contains("meum_set_labels"))
        XCTAssertTrue(names.contains("meum_set_workspace"))
    }
}
