import XCTest
@testable import MeumControl

final class MCPServerTests: XCTestCase {
    let ws = "11111111-1111-1111-1111-111111111111"
    let inside = MCPServer.Here(env: ["MEUM_SOCKET": "/tmp/s", "MEUM_WORKSPACE": "11111111-1111-1111-1111-111111111111",
                                      "MEUM_TAB": "22222222-2222-2222-2222-222222222222"])
    var calls: [(String, JSON)] = []

    func fake(_ m: String, _ p: JSON) throws -> JSON {
        calls.append((m, p))
        switch m {
        case MeumMethod.tree:
            return ["selectedWorkspaceID": .string(ws), "workspaces": [[
                "id": .string(ws), "name": "site", "cwd": "/w",
                "root": ["type": "split", "first": ["type": "card", "id": "C1", "selectedTabID": "T2", "tabs": [
                    ["id": "T1", "widget": .null],
                    ["id": "T2", "widget": "browser", "widgetConfig": ["url": "http://localhost:5173"]],
                ]], "second": ["type": "card", "id": "C2", "selectedTabID": "T3", "tabs": [["id": "T3", "widget": .null]]]],
            ], ["id": "33333333-3333-3333-3333-333333333333", "name": "other", "root": .null]]]
        case MeumMethod.widgetList:
            return ["widgets": [["id": "browser", "displayName": "Browser", "scope": "global"]]]
        case MeumMethod.tabNew:
            return ["id": "NEWTAB", "card": "NEWCARD", "workspace": .string(ws)]
        case MeumMethod.widgetScreenshot:
            return ["png": "aGVsbG8="]
        case MeumMethod.widgetSend:
            throw ControlError.notFound("no widget tab 'X'")
        default:
            return .null
        }
    }

    func req(_ method: String, _ params: JSON = .object([:]), id: JSON = 1, here: MCPServer.Here? = nil) -> JSON? {
        MCPServer.handle(["jsonrpc": "2.0", "id": id, "method": .string(method), "params": params],
                         here: here ?? inside, call: { try self.fake($0, $1) })
    }

    func testInitializeAndList() {
        let r = req("initialize", ["protocolVersion": "2025-03-26"])
        XCTAssertEqual(r?["result"]?["protocolVersion"], "2025-03-26")
        XCTAssertEqual(r?["result"]?["serverInfo"]?["name"], "meum")
        let names = req("tools/list")?["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        XCTAssertTrue(names.contains("meum_open_widget"))
        XCTAssertTrue(names.contains("meum_widget_screenshot"))
        // outside meum: no tools
        XCTAssertEqual(req("tools/list", here: MCPServer.Here(env: [:]))?["result"]?["tools"], .array([]))
        // notifications get no answer
        XCTAssertNil(MCPServer.handle(["jsonrpc": "2.0", "method": "notifications/initialized"], here: inside, call: { try self.fake($0, $1) }))
    }

    func testContextListsWidgetTabsOfYourWorkspace() throws {
        let r = req("tools/call", ["name": "meum_context", "arguments": .object([:])])
        let text = r?["result"]?["content"]?[0]?["text"]?.stringValue ?? ""
        let ctx = try JSON.parse(text)
        XCTAssertEqual(ctx["widgetTabsInYourWorkspace"]?.arrayValue?.count, 1)
        XCTAssertEqual(ctx["widgetTabsInYourWorkspace"]?[0]?["config"]?["url"], "http://localhost:5173")
        XCTAssertEqual(ctx["widgetTabsInYourWorkspace"]?[0]?["selectedInCard"], true)
        XCTAssertEqual(ctx["widgets"]?[0]?["id"], "browser")
        XCTAssertEqual(ctx["workspaces"]?[0]?["yours"], true)
    }

    func testOpenWidgetDefaultsToYourWorkspaceAndARightSplit() {
        _ = req("tools/call", ["name": "meum_open_widget", "arguments": ["widget": "browser", "config": ["url": "http://x"]]])
        let (m, p) = calls.last!
        XCTAssertEqual(m, MeumMethod.tabNew)
        XCTAssertEqual(p, ["widget": "browser", "workspace": .string(ws), "split": "right", "config": ["url": "http://x"]])
        _ = req("tools/call", ["name": "meum_open_widget", "arguments": ["widget": "browser", "placement": "tab", "card": "C2"]])
        XCTAssertEqual(calls.last!.1, ["widget": "browser", "workspace": .string(ws), "card": "C2"])
    }

    func testScreenshotIsAnImageAndErrorsAreToolErrors() {
        let img = req("tools/call", ["name": "meum_widget_screenshot", "arguments": ["tab": "T2"]])?["result"]?["content"]?[0]
        XCTAssertEqual(img?["type"], "image")
        XCTAssertEqual(img?["mimeType"], "image/png")
        let err = req("tools/call", ["name": "meum_widget_send", "arguments": ["tab": "X", "message": ["reload": true]]])?["result"]
        XCTAssertEqual(err?["isError"], true)
        XCTAssertTrue(err?["content"]?[0]?["text"]?.stringValue?.contains("not_found") ?? false)
    }
}
