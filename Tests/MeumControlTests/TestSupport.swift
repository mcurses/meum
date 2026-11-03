import Foundation
import XCTest
@testable import MeumControl

enum TestSupport {
    /// A fresh short temp dir (unix socket paths are limited to 103 bytes).
    static func tempDir(_ tag: String = "t") -> String {
        let base = (NSTemporaryDirectory() as NSString).standardizingPath
        let p = "\(base)/mx-\(tag)-\(UInt32.random(in: 0..<0xFFFFFF))"
        try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return URL(fileURLWithPath: p).resolvingSymlinksInPath().path
    }

    static var repoRoot: String {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { u.deleteLastPathComponent() }
        return u.path
    }

    static var meumHookPath: String { repoRoot + "/Resources/bin/meum-hook" }

    static func write(_ text: String, to path: String) {
        try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func read(_ path: String) -> String { try! String(contentsOfFile: path, encoding: .utf8) }

    struct ProcResult { var status: Int32; var stdout: String; var stderr: String; var seconds: Double }

    static func run(_ exe: String, _ args: [String] = [], env: [String: String], stdin: String? = nil) -> ProcResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        let o = Pipe(), e = Pipe(), i = Pipe()
        p.standardOutput = o; p.standardError = e; p.standardInput = i
        let t0 = Date()
        try! p.run()
        if let stdin { i.fileHandleForWriting.write(Data(stdin.utf8)) }
        i.fileHandleForWriting.closeFile()
        let od = o.fileHandleForReading.readDataToEndOfFile()
        let ed = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ProcResult(status: p.terminationStatus, stdout: String(decoding: od, as: UTF8.self),
                          stderr: String(decoding: ed, as: UTF8.self), seconds: Date().timeIntervalSince(t0))
    }

    /// Polls until `cond` holds or the timeout passes.
    static func wait(_ timeout: TimeInterval = 5, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return cond()
    }
}

/// Records every call; answers a few canned methods. Stands in for the app's ControlHandler.
final class FakeHandler: ControlHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(String, JSON)] = []
    let agents: AgentService?

    init(agents: AgentService? = nil) { self.agents = agents }

    var calls: [(method: String, params: JSON)] { lock.lock(); defer { lock.unlock() }; return _calls.map { ($0.0, $0.1) } }

    static let wsA = "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    static let wsB = "22222222-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    static let tab1 = "AAAAAAAA-1111-4111-8111-111111111111"
    static let tab2 = "BBBBBBBB-2222-4222-8222-222222222222"

    static let tree: JSON = [
        "version": "meum.v1",
        "selectedWorkspaceID": .string(wsA),
        "workspaces": [
            ["id": .string(wsA), "name": "api", "pinned": true, "cwd": "/code/api",
             "root": ["id": "cccccccc-0000-4000-8000-000000000001", "selectedTabID": .string(tab1),
                      "tabs": [["id": .string(tab1), "title": "zsh", "cwd": "/code/api"]]]],
            ["id": .string(wsB), "name": "web",
             "root": ["id": "dddddddd-0000-4000-8000-000000000003", "axis": "horizontal", "ratio": 0.5,
                      "first": ["id": "cccccccc-0000-4000-8000-000000000002", "tabs": [["id": .string(tab2), "title": "claude"]]],
                      "second": .null]],
        ],
        "agents": [tab2: ["phase": "needsInput", "unread": true, "sessionID": "5e55105e-0000-0000-0000-000000000000"]],
    ]

    private func record(_ m: String, _ p: JSON) { lock.lock(); _calls.append((m, p)); lock.unlock() }

    func handle(method: String, params: JSON) async throws -> JSON {
        record(method, params)
        switch method {
        case "tree": return Self.tree
        case "workspace.list":
            return [["id": .string(Self.wsA), "name": "api", "selected": true], ["id": .string(Self.wsB), "name": "web"]]
        case "workspace.new": return ["id": "33333333-cccc-4ccc-8ccc-cccccccccccc"]
        case "tab.new": return ["id": "44444444-dddd-4ddd-8ddd-dddddddddddd"]
        case "tab.paste": return ["tab": params["tab"] ?? .null]
        case "tab.focused": return ["workspace": .string(Self.wsA), "tab": .string(Self.tab1), "widget": .null]
        case "workspace.select", "workspace.rename", "workspace.close", "tab.select", "tab.close", "tab.sendText",
             "status.set", "status.clear", "notify", "workspace.markRead", "tab.move", "split.resize":
            return .null
        case "agent.hook":
            guard let agents else { return .null }
            return try agents.handleHook(params: params)
        case "echo", "settings.set": return params
        case "settings.get": return ["settings": ["cardGap": 12, "background": "glass"], "path": "/x/settings.json"]
        case "slow":
            try await Task.sleep(nanoseconds: 100_000_000)
            return "slow-done"
        case "missing": throw ControlError.notFound("no such thing")
        case "boom": throw NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "kaboom"])
        default: throw ControlError.methodNotFound(method)
        }
    }
}

/// Server + client on a temp socket.
final class Harness {
    let dir: String
    let socket: String
    let handler: FakeHandler
    let agents: AgentService
    let server: ControlServer
    var bus: EventBus { server.bus }

    init() throws {
        dir = TestSupport.tempDir("srv")
        socket = dir + "/state/meum.sock"   // state/ does not exist yet: the server must create it 0700
        let bus = EventBus()
        agents = AgentService(bus: bus)
        handler = FakeHandler(agents: agents)
        server = ControlServer(socketPath: socket, handler: handler, bus: bus)
        try server.start()
    }

    func client(timeout: TimeInterval = 5) -> ControlClient { ControlClient(socketPath: socket, timeout: timeout) }

    func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(atPath: dir)
    }
}
