import XCTest
@testable import MeumControl

final class ClaudeSetupTests: XCTestCase {
    var home: String!
    var cli: String!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "meum-setup-\(UUID().uuidString)"
        let bin = home + "/App/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        cli = bin + "/meum"
        FileManager.default.createFile(atPath: cli, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        FileManager.default.createFile(atPath: bin + "/meum-hook", contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        for d in [".claude", ".claude-work"] {
            try FileManager.default.createDirectory(atPath: home + "/" + d, withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: URL(fileURLWithPath: home + "/" + d + "/settings.json"))
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: home) }

    func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: home + "/" + path))
    }

    func testFreshMacOffersAllThreeSteps() {
        let s = ClaudeSetup(home: home, cli: cli)
        let shell = ClaudeSetup.Shell(claude: "/usr/local/bin/claude", path: ["/usr/bin", home + "/.local/bin"])
        let offers = s.offers(shell: shell)
        XCTAssertEqual(offers.map(\.step), [.hooks, .mcp, .cli])
        XCTAssertEqual(offers[0].configDirs, [home + "/.claude", home + "/.claude-work"])
        XCTAssertTrue(offers[1].detail.contains("~/.claude and ~/.claude-work"), offers[1].detail)
    }

    func testNoClaudeMeansNoMCPRowAndNoLocalBinMeansNoLink() {
        let s = ClaudeSetup(home: home, cli: cli)
        XCTAssertEqual(s.offers(shell: .init(claude: nil, path: ["/usr/bin"])).map(\.step), [.hooks])
    }

    func testMCPCountsAsThereByEntryOrByPlugin() throws {
        try write(".claude.json", #"{"mcpServers":{"meum":{"command":"x"}}}"#)
        try write(".claude-work/settings.json", #"{"enabledPlugins":{"meum@meum":true}}"#)
        let s = ClaudeSetup(home: home, cli: cli)
        XCTAssertEqual(s.needMCP(), [])
        try write(".claude-work/settings.json", #"{"enabledPlugins":{"meum@meum":false}}"#)
        XCTAssertEqual(s.needMCP(), [home + "/.claude-work"])
    }

    func testAddMCPSetsTheConfigDirOnlyForOtherProfiles() {
        let s = ClaudeSetup(home: home, cli: cli)
        var calls: [([String], String?)] = []
        let out = s.addMCP(shell: .init(claude: "/bin/claude", path: ["/bin"]), dirs: [home + "/.claude", home + "/.claude-work"]) {
            _, args, env in
            calls.append((args, env["CLAUDE_CONFIG_DIR"]))
            return (0, "")
        }
        XCTAssertTrue(out.ok)
        XCTAssertEqual(calls.map(\.1), [nil, home + "/.claude-work"])
        XCTAssertEqual(calls[0].0, ["mcp", "add", "--scope", "user", "meum", "--", cli, "mcp"])
        XCTAssertEqual(out.lines, ["~/.claude: ran claude mcp add --scope user meum", "~/.claude-work: ran claude mcp add --scope user meum"])
    }

    func testAddMCPReportsAFailure() {
        let s = ClaudeSetup(home: home, cli: cli)
        let out = s.addMCP(shell: .init(claude: "/bin/claude", path: []), dirs: [home + "/.claude"]) { _, _, _ in (1, "boom\nnot logged in") }
        XCTAssertFalse(out.ok)
        XCTAssertEqual(out.lines, ["~/.claude: claude mcp add failed: not logged in"])
    }

    func testLinkCLIReplacesOnlyALink() throws {
        let s = ClaudeSetup(home: home, cli: cli)
        let shell = ClaudeSetup.Shell(claude: nil, path: [home + "/.local/bin"])
        XCTAssertTrue(s.linkCLI().ok)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: home + "/.local/bin/meum"), cli)
        XCTAssertFalse(s.needsCLILink(shell: shell))
        // a link to another meum is offered again; a real file of the person's is left alone
        try FileManager.default.removeItem(atPath: home + "/.local/bin/meum")
        try FileManager.default.createSymbolicLink(atPath: home + "/.local/bin/meum", withDestinationPath: "/elsewhere/meum")
        XCTAssertTrue(s.needsCLILink(shell: shell))
        try FileManager.default.removeItem(atPath: home + "/.local/bin/meum")
        try write(".local/bin/meum", "mine")
        XCTAssertFalse(s.needsCLILink(shell: shell))
    }

    func testHooksAreNotOfferedOnceInstalled() throws {
        let installer = HookInstaller(home: home)
        for t in installer.targets(for: HookInstaller.discoverConfigDirs(home: home)) {
            _ = try installer.apply(installer.plan(.install, target: t))
        }
        _ = try installer.installScript(from: home + "/App/bin/meum-hook")
        XCTAssertEqual(ClaudeSetup(home: home, cli: cli).needHooks(), [])
    }

    func testParseProbeSkipsShellNoise() {
        let s = ClaudeSetup.parseProbe("Welcome!\n__meum_probe__/a:/b\n", isExecutable: { $0 == "/b/claude" })
        XCTAssertEqual(s, .init(claude: "/b/claude", path: ["/a", "/b"]))
        XCTAssertEqual(ClaudeSetup.parseProbe("__meum_probe__/a\n", isExecutable: { _ in false }).claude, nil)
        XCTAssertEqual(ClaudeSetup.parseProbe("no marker").path, [])
    }
}
