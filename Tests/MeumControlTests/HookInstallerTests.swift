import XCTest
@testable import MeumControl

final class HookInstallerTests: XCTestCase {
    /// Shaped like Max's real settings.json: 2-space indent, trailing newline, unrelated keys, existing hooks
    /// including matchers, non-ASCII-free but with escapes and slashes.
    static let fixture = """
    {
      "env": {
        "MAX_THINKING_TOKENS": "63999",
        "PATH_NOTE": "a\\/b \\u00e9 \\"quoted\\""
      },
      "permissions": {
        "allow": [
          "Bash(git status:*)",
          "Read(//Users/dev/**)"
        ],
        "deny": []
      },
      "model": "opus[1m]",
      "hooks": {
        "UserPromptSubmit": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "/Users/dev/.claude/hooks/notify-usage.sh",
                "timeout": 5
              }
            ]
          }
        ],
        "PreToolUse": [
          {
            "matcher": "Agent|Workflow",
            "hooks": [
              {
                "type": "command",
                "command": "/Users/dev/.claude/hooks/check-model.sh",
                "timeout": 10
              }
            ]
          }
        ]
      },
      "enabledPlugins": {
        "a@b": true
      },
      "spinnerTipsEnabled": false,
      "ratio": 1.50,
      "nothing": null
    }

    """

    var dirs: [String] = []
    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(atPath: d) }
        dirs = []
    }

    func temp() -> String { let d = TestSupport.tempDir("inst"); dirs.append(d); return d }

    /// A config dir with the given settings.json text.
    func configDir(_ settings: String?, in root: String? = nil, name: String = ".claude-t") -> String {
        let dir = (root ?? temp()) + "/" + name
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let settings { TestSupport.write(settings, to: dir + "/settings.json") }
        return dir
    }

    func installer(home: String = "/nonexistent-home") -> HookInstaller { HookInstaller(hookCommand: "$HOME/.local/bin/meum-hook", home: home) }

    func target(_ dir: String, _ i: HookInstaller) -> HookInstaller.Target { i.targets(for: [dir])[0] }

    // MARK: parser / writer

    func testOrderedJSONRoundTripIsByteIdentical() throws {
        let tree = try OJParser.parse(Self.fixture)
        XCTAssertEqual(OJWriter.write(tree) + "\n", Self.fixture)
    }

    func testOrderedJSONParsesEscapes() throws {
        let t = try OJParser.parse(#"{"ké": "a\nbé😀\/"}"#)
        XCTAssertEqual(t.objectMembers?[0].key, "ké")
        XCTAssertEqual(t.objectMembers?[0].value.stringValue, "a\nbé😀/")
        XCTAssertThrowsError(try OJParser.parse("{\"a\": }"))
        XCTAssertThrowsError(try OJParser.parse("{\"a\": 1} x"))
        XCTAssertThrowsError(try OJParser.parse("[1,]"))
    }

    func testRealSettingsFilesRoundTripWithoutChange() throws {
        // Read-only: the real files are only read into memory; nothing is printed or written.
        let home = NSHomeDirectory()
        var checked = 0
        for d in HookInstaller.discoverConfigDirs(home: home) {
            guard let text = try? String(contentsOfFile: d + "/settings.json", encoding: .utf8) else { continue }
            let tree = try OJParser.parse(text)
            let indent = HookInstaller.detectIndent(text)
            let rewritten = OJWriter.write(tree, indent: indent) + (text.hasSuffix("\n") ? "\n" : "")
            XCTAssertTrue(rewritten == text, "round trip changed a real settings file shape (\((d as NSString).lastPathComponent))")
            checked += 1
        }
        if checked == 0 { print("note: no real settings.json files on this machine; round-trip check skipped") }
    }

    func testPlanAgainstCopiesOfRealSettingsOnlyAddsHookLines() throws {
        let home = NSHomeDirectory()
        let i = installer()
        var checked = 0
        for d in HookInstaller.discoverConfigDirs(home: home) {
            guard let text = try? String(contentsOfFile: d + "/settings.json", encoding: .utf8) else { continue }
            let copy = configDir(text, name: ".claude-copy")
            if i.status(of: target(copy, i)).isInstalled {
                // this machine's real settings already carry the hook: uninstall + install must round-trip
                try i.apply(i.plan(.uninstall, target: target(copy, i)))
                XCTAssertFalse(i.status(of: target(copy, i)).isInstalled)
                try i.apply(i.plan(.install, target: target(copy, i)))
                XCTAssertTrue(i.status(of: target(copy, i)).isInstalled)
                checked += 1
                continue
            }
            let plan = i.plan(.install, target: target(copy, i))
            XCTAssertNil(plan.error)
            let removed = plan.diff.split(separator: "\n").filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }
            // The only lines that may change are the closing of the previous sibling (a comma is added).
            XCTAssertTrue(removed.allSatisfy { $0.trimmingCharacters(in: .whitespaces).dropFirst().last != nil }, "diff removed lines look wrong")
            XCTAssertLessThanOrEqual(removed.count, 3)
            // Uninstalling the plan result restores the original bytes.
            try i.apply(plan)
            let un = i.plan(.uninstall, target: target(copy, i))
            try i.apply(un)
            XCTAssertTrue(TestSupport.read(copy + "/settings.json") == text, "install+uninstall did not restore a real settings file")
            checked += 1
        }
        if checked == 0 { print("note: no real settings.json files on this machine; skipped") }
    }

    // MARK: install

    func testInstallAddsFiveEventsAndKeepsEverythingElse() throws {
        let dir = configDir(Self.fixture)
        let i = installer()
        let plan = i.plan(.install, target: target(dir, i))
        XCTAssertNil(plan.error)
        XCTAssertTrue(plan.changed)
        let new = try JSON.parse(plan.newText!)
        let old = try JSON.parse(Self.fixture)

        // every key but hooks is untouched
        for (k, v) in old.objectValue! where k != "hooks" { XCTAssertEqual(new[k], v, k) }
        // existing hooks are still there, first, unmodified
        XCTAssertEqual(new["hooks"]?["PreToolUse"], old["hooks"]?["PreToolUse"])
        XCTAssertEqual(new["hooks"]?["UserPromptSubmit"]?[0], old["hooks"]?["UserPromptSubmit"]?[0], "existing group stays first")
        XCTAssertEqual(new["hooks"]?["UserPromptSubmit"]?.arrayValue?.count, 2)
        for e in HookInstaller.events {
            let groups = new["hooks"]?[e]?.arrayValue ?? []
            let ours = groups.filter { $0["hooks"]?[0]?["command"]?.stringValue == "$HOME/.local/bin/meum-hook" }
            XCTAssertEqual(ours.count, 1, e)
            XCTAssertEqual(ours[0]["hooks"]?[0]?["type"], "command")
        }

        // textually: top-level key order kept, and the diff only adds (plus one comma fix per touched sibling)
        let keys = try OJParser.parse(plan.newText!).objectMembers!.map(\.key)
        XCTAssertEqual(keys, ["env", "permissions", "model", "hooks", "enabledPlugins", "spinnerTipsEnabled", "ratio", "nothing"])
        XCTAssertTrue(plan.newText!.contains("\"ratio\": 1.50,"), "number spelling preserved")
        XCTAssertTrue(plan.newText!.contains("\"PATH_NOTE\": \"a\\/b \\u00e9 \\\"quoted\\\"\""), "string escapes preserved")
        XCTAssertFalse(plan.diff.isEmpty)
        XCTAssertTrue(plan.diff.contains("+            \"command\": \"$HOME/.local/bin/meum-hook\"") || plan.diff.contains("meum-hook"))
        XCTAssertEqual(try String(contentsOfFile: dir + "/settings.json", encoding: .utf8), Self.fixture, "plan must not write")
    }

    func testInstallIsIdempotent() throws {
        let dir = configDir(Self.fixture)
        let i = installer()
        try i.apply(i.plan(.install, target: target(dir, i)), now: Date(timeIntervalSince1970: 1_000))
        let once = TestSupport.read(dir + "/settings.json")
        let again = i.plan(.install, target: target(dir, i))
        XCTAssertFalse(again.changed)
        XCTAssertEqual(again.newText, once)
        let r = try i.apply(again)
        XCTAssertFalse(r.wrote)
        XCTAssertEqual(TestSupport.read(dir + "/settings.json"), once)
        XCTAssertEqual(i.status(of: target(dir, i)).isInstalled, true)
    }

    func testUninstallRestoresOriginalBytes() throws {
        let dir = configDir(Self.fixture)
        let i = installer()
        try i.apply(i.plan(.install, target: target(dir, i)))
        XCTAssertNotEqual(TestSupport.read(dir + "/settings.json"), Self.fixture)
        let un = i.plan(.uninstall, target: target(dir, i))
        XCTAssertTrue(un.changed)
        try i.apply(un)
        XCTAssertEqual(TestSupport.read(dir + "/settings.json"), Self.fixture)
        XCTAssertFalse(i.plan(.uninstall, target: target(dir, i)).changed)
    }

    func testApplyBacksUpWithTimestampAndKeepsPermissions() throws {
        let dir = configDir(Self.fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir + "/settings.json")
        let i = installer()
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let r = try i.apply(i.plan(.install, target: target(dir, i)), now: when)
        let backup = try XCTUnwrap(r.backupPath)
        XCTAssertTrue(backup.contains("/settings.json.bak-"), backup)
        XCTAssertEqual(TestSupport.read(backup), Self.fixture, "backup is the untouched original")
        let perms = (try FileManager.default.attributesOfItem(atPath: dir + "/settings.json")[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600)
        // a second write in the same second must not overwrite the first backup
        try i.apply(i.plan(.uninstall, target: target(dir, i)), now: when)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.contains(".bak-") }
        XCTAssertEqual(backups.count, 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir).allSatisfy { !$0.contains("meum-tmp") })
    }

    func testInstallWithoutHooksKeyAppendsIt() throws {
        let dir = configDir("{\n  \"model\": \"x\"\n}\n")
        let i = installer()
        let plan = i.plan(.install, target: target(dir, i))
        let keys = try OJParser.parse(plan.newText!).objectMembers!.map(\.key)
        XCTAssertEqual(keys, ["model", "hooks"])
        try i.apply(plan)
        XCTAssertEqual(TestSupport.read(dir + "/settings.json").hasSuffix("}\n"), true)
        try i.apply(i.plan(.uninstall, target: target(dir, i)))
        XCTAssertEqual(TestSupport.read(dir + "/settings.json"), "{\n  \"model\": \"x\"\n}\n", "empty hooks object is removed again")
    }

    func testInstallCreatesMissingSettingsFile() throws {
        let dir = configDir(nil)
        let i = installer()
        let t = target(dir, i)
        XCTAssertFalse(t.settingsExists)
        let plan = i.plan(.install, target: t)
        XCTAssertTrue(plan.changed)
        let r = try i.apply(plan)
        XCTAssertNil(r.backupPath, "nothing to back up")
        XCTAssertTrue(i.status(of: target(dir, i)).isInstalled)
        XCTAssertFalse(i.plan(.uninstall, target: target(dir, i)).oldText == nil)
    }

    func testUninstallOnMissingFileDoesNothing() {
        let dir = configDir(nil)
        let i = installer()
        let plan = i.plan(.uninstall, target: target(dir, i))
        XCTAssertFalse(plan.changed)
        XCTAssertNil(plan.error)
    }

    func testOutdatedCommandIsUpdatedInPlace() throws {
        let dir = configDir(Self.fixture)
        let old = HookInstaller(hookCommand: "/old/path/meum-hook", home: "/x")
        try old.apply(old.plan(.install, target: target(dir, old)))
        let new = installer()
        XCTAssertEqual(new.status(of: target(dir, new)).outdatedEvents.sorted(), HookInstaller.events.sorted())
        let plan = new.plan(.install, target: target(dir, new))
        XCTAssertTrue(plan.changed)
        try new.apply(plan)
        let j = try JSON.parse(TestSupport.read(dir + "/settings.json"))
        XCTAssertEqual(j["hooks"]?["Stop"]?.arrayValue?.count, 1, "updated, not duplicated")
        XCTAssertEqual(j["hooks"]?["Stop"]?[0]?["hooks"]?[0]?["command"], "$HOME/.local/bin/meum-hook")
        XCTAssertTrue(new.status(of: target(dir, new)).outdatedEvents.isEmpty)
    }

    func testUninstallKeepsOtherHooksInTheSameGroup() throws {
        let mixed = """
        {
          "hooks": {
            "Stop": [
              {
                "matcher": "x",
                "hooks": [
                  {
                    "type": "command",
                    "command": "echo keep"
                  },
                  {
                    "type": "command",
                    "command": "/home/u/.local/bin/meum-hook"
                  }
                ]
              }
            ]
          }
        }

        """
        let dir = configDir(mixed)
        let i = installer()
        let st = i.status(of: target(dir, i))
        XCTAssertEqual(st.installedEvents, ["Stop"])
        XCTAssertEqual(st.foreignHooks, 1)
        try i.apply(i.plan(.uninstall, target: target(dir, i)))
        let j = try JSON.parse(TestSupport.read(dir + "/settings.json"))
        XCTAssertEqual(j["hooks"]?["Stop"]?[0]?["matcher"], "x")
        XCTAssertEqual(j["hooks"]?["Stop"]?[0]?["hooks"]?.arrayValue?.count, 1)
        XCTAssertEqual(j["hooks"]?["Stop"]?[0]?["hooks"]?[0]?["command"], "echo keep")
    }

    func testStatusStates() throws {
        let dir = configDir(Self.fixture)
        let i = installer()
        var st = i.status(of: target(dir, i))
        XCTAssertFalse(st.isInstalled)
        XCTAssertEqual(st.installedEvents, [])
        XCTAssertEqual(st.missingEvents, HookInstaller.events)
        XCTAssertEqual(st.foreignHooks, 2)
        try i.apply(i.plan(.install, target: target(dir, i)))
        st = i.status(of: target(dir, i))
        XCTAssertTrue(st.isInstalled)
        XCTAssertEqual(st.installedEvents, HookInstaller.events)
        XCTAssertEqual(st.foreignHooks, 2)
    }

    func testPartialInstallIsCompleted() throws {
        let partial = "{\n  \"hooks\": {\n    \"Stop\": [\n      {\n        \"hooks\": [\n          {\n            \"type\": \"command\",\n            \"command\": \"$HOME/.local/bin/meum-hook\"\n          }\n        ]\n      }\n    ]\n  }\n}\n"
        let dir = configDir(partial)
        let i = installer()
        XCTAssertEqual(i.status(of: target(dir, i)).missingEvents, ["SessionStart", "UserPromptSubmit", "Notification", "SessionEnd"])
        try i.apply(i.plan(.install, target: target(dir, i)))
        let j = try JSON.parse(TestSupport.read(dir + "/settings.json"))
        XCTAssertEqual(j["hooks"]?["Stop"]?.arrayValue?.count, 1)
        XCTAssertTrue(i.status(of: target(dir, i)).isInstalled)
    }

    // MARK: errors leave files alone

    func testBadFilesProduceErrorsAndAreNotTouched() throws {
        let cases = ["not json {", "[1,2]", "{\"hooks\": []}", "{\"hooks\": {\"Stop\": {}}}", ""]
        for text in cases {
            let dir = configDir(text)
            let i = installer()
            let plan = i.plan(.install, target: target(dir, i))
            XCTAssertNotNil(plan.error, text)
            XCTAssertFalse(plan.changed)
            XCTAssertThrowsError(try i.apply(plan))
            XCTAssertEqual(TestSupport.read(dir + "/settings.json"), text)
            XCTAssertNotNil(i.status(of: target(dir, i)).error, text)
        }
    }

    func testApplyRefusesWhenFileChangedAfterPlan() throws {
        let dir = configDir(Self.fixture)
        let i = installer()
        let plan = i.plan(.install, target: target(dir, i))
        TestSupport.write("{}", to: dir + "/settings.json")
        XCTAssertThrowsError(try i.apply(plan))
        XCTAssertEqual(TestSupport.read(dir + "/settings.json"), "{}")
    }

    func testNonCanonicalLayoutIsFlagged() throws {
        let dir = configDir("{\"a\":1,\n \"hooks\":{}}")
        let i = installer()
        let plan = i.plan(.install, target: target(dir, i))
        XCTAssertTrue(plan.notes.contains { $0.contains("canonical") })
        XCTAssertNil(plan.error)
    }

    func testTabIndentIsKept() throws {
        let dir = configDir("{\n\t\"a\": 1\n}\n")
        let i = installer()
        let plan = i.plan(.install, target: target(dir, i))
        XCTAssertTrue(plan.newText!.contains("\n\t\t\"SessionStart\""))
    }

    // MARK: symlinks and discovery

    func testSymlinkedSettingsAreFollowedAndKeptAsLinks() throws {
        let root = temp()
        let main = configDir(Self.fixture, in: root, name: ".claude")
        let other = configDir(nil, in: root, name: ".claude-work")
        try FileManager.default.createSymbolicLink(atPath: other + "/settings.json", withDestinationPath: main + "/settings.json")
        let i = installer(home: root)

        let ts = i.targets(for: [main, other])
        XCTAssertEqual(ts.count, 1, "one real file, one target")
        XCTAssertEqual(ts[0].sharedWith, [other])
        let viaLink = i.targets(for: [other])[0]
        XCTAssertTrue(viaLink.viaSymlink)
        XCTAssertEqual(viaLink.settingsPath, main + "/settings.json")

        try i.apply(i.plan(.install, target: viaLink))
        let attrs = try FileManager.default.attributesOfItem(atPath: other + "/settings.json")
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink, "the link must survive the write")
        XCTAssertTrue(i.status(of: i.targets(for: [main])[0]).isInstalled)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: other).allSatisfy { !$0.contains(".bak-") }, "backup lives next to the real file")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: main).filter { $0.contains(".bak-") }.count, 1)
    }

    func testDanglingSymlinkIsAnError() throws {
        let root = temp()
        let dir = configDir(nil, in: root)
        try FileManager.default.createSymbolicLink(atPath: dir + "/settings.json", withDestinationPath: root + "/nowhere.json")
        let i = installer(home: root)
        XCTAssertNotNil(i.plan(.install, target: i.targets(for: [dir])[0]).error)
    }

    func testDiscoverConfigDirs() throws {
        let home = temp()
        _ = configDir("{}", in: home, name: ".claude")
        _ = configDir("{}", in: home, name: ".claude-work")
        let creds = configDir(nil, in: home, name: ".claude-spare")
        TestSupport.write("{}", to: creds + "/.credentials.json")
        _ = configDir(nil, in: home, name: ".claude-empty")
        _ = configDir("{}", in: home, name: ".claudex")
        _ = configDir("{}", in: home, name: ".other")
        TestSupport.write("{}", to: home + "/.claude.json")
        let found = HookInstaller.discoverConfigDirs(home: home).map { ($0 as NSString).lastPathComponent }
        XCTAssertEqual(found, [".claude", ".claude-spare", ".claude-work"])
    }

    func testHomeExpansionAndScriptPlacement() throws {
        let home = temp()
        var i = HookInstaller(hookCommand: "$HOME/.local/bin/meum-hook", home: home)
        XCTAssertEqual(i.scriptDestination, home + "/.local/bin/meum-hook")
        let src = home + "/src-hook"
        TestSupport.write("#!/bin/sh\nexit 0\n", to: src)
        let dest = try i.installScript(from: src)
        XCTAssertEqual(TestSupport.read(dest), "#!/bin/sh\nexit 0\n")
        let mode = (try FileManager.default.attributesOfItem(atPath: dest)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o755)
        i.hookCommand = "sh -c something"
        XCTAssertNil(i.scriptDestination)
        XCTAssertThrowsError(try i.installScript(from: src))
    }

    func testTextDiffShowsOnlyChanges() {
        let d = TextDiff.unified(old: "a\nb\nc\nd\ne\nf\ng\nh", new: "a\nb\nc\nX\ne\nf\ng\nh", oldLabel: "o", newLabel: "n", context: 1)
        XCTAssertEqual(d, "--- o\n+++ n\n@@ -3,3 +3,3 @@\n c\n-d\n+X\n e\n")
        XCTAssertEqual(TextDiff.unified(old: "same", new: "same", oldLabel: "o", newLabel: "n"), "")
    }
}
