import XCTest
@testable import MeumControl

final class ClaudeSessionRecordsTests: XCTestCase {
    private var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "csr-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir + "/sessions", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: dir) }

    private func write(_ file: String, _ obj: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: dir + "/sessions/" + file))
    }

    func testFindsTheNameOfTheMatchingSession() throws {
        try write("100.json", ["pid": 100, "sessionId": "aaa", "name": "other-1a", "kind": "interactive"])
        try write("200.json", ["pid": 200, "sessionId": "bbb", "name": "meum-05", "kind": "interactive"])
        try "bbb".write(toFile: dir + "/sessions/200.abc.key", atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeSessionRecords.name(sessionID: "bbb", configDir: dir), "meum-05")
    }

    func testNilWithoutARecordOrName() throws {
        try write("100.json", ["pid": 100, "sessionId": "aaa", "name": "  "])
        try write("300.json", ["pid": 300, "sessionId": "ccc"])
        XCTAssertNil(ClaudeSessionRecords.name(sessionID: "aaa", configDir: dir))
        XCTAssertNil(ClaudeSessionRecords.name(sessionID: "ccc", configDir: dir))
        XCTAssertNil(ClaudeSessionRecords.name(sessionID: "zzz", configDir: dir))
        XCTAssertNil(ClaudeSessionRecords.name(sessionID: "", configDir: dir))
    }

    func testDefaultConfigDirIsDotClaudeUnderHome() throws {
        let home = dir + "/home"
        try FileManager.default.createDirectory(atPath: home + "/.claude/sessions", withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["sessionId": "ddd", "name": "x-2b"])
            .write(to: URL(fileURLWithPath: home + "/.claude/sessions/1.json"))
        XCTAssertEqual(ClaudeSessionRecords.name(sessionID: "ddd", configDir: nil, home: home), "x-2b")
        XCTAssertEqual(ClaudeSessionRecords.name(sessionID: "ddd", configDir: "", home: home), "x-2b")
    }
}
