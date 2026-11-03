import XCTest
@testable import MeumControl

final class AgentTrackerTests: XCTestCase {
    let tab = "TAB-1"
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func hook(_ event: String, sid: String = "s1", extra: [String: JSON] = [:]) -> JSON {
        var o: [String: JSON] = ["hook_event_name": .string(event), "session_id": .string(sid),
                                 "transcript_path": .string("/Users/dev/.claude-work/projects/-x/\(sid).jsonl"), "cwd": "/code/x"]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testFullTurnLifecycle() {
        var t = AgentTracker()
        guard case .changed(let old, let s) = t.apply(tab: tab, configDir: "", payload: hook("SessionStart", extra: ["source": "startup"]), at: at(0)) else { return XCTFail() }
        XCTAssertNil(old)
        XCTAssertEqual(s.phase, .idle)
        XCTAssertEqual(s.sessionID, "s1")
        XCTAssertEqual(s.cwd, "/code/x")
        XCTAssertEqual(s.configDir, "/Users/dev/.claude-work", "derived from the transcript path when the env had none")
        XCTAssertFalse(s.unread)

        t.apply(tab: tab, configDir: "", payload: hook("UserPromptSubmit", extra: ["prompt_id": "p1"]), at: at(1))
        XCTAssertEqual(t.state(of: tab)?.phase, .running)

        t.apply(tab: tab, configDir: "", payload: hook("Stop", extra: ["prompt_id": "p1"]), at: at(2))
        XCTAssertEqual(t.state(of: tab)?.phase, .idle)
        XCTAssertEqual(t.state(of: tab)?.unread, true, "turn finished in an unfocused tab")

        guard case .removed(let gone) = t.apply(tab: tab, configDir: "", payload: hook("SessionEnd"), at: at(3)) else { return XCTFail() }
        XCTAssertEqual(gone.sessionID, "s1")
        XCTAssertNil(t.state(of: tab))
    }

    func testEnvConfigDirWinsOverDerived() {
        var t = AgentTracker()
        t.apply(tab: tab, configDir: "/custom/dir", payload: hook("SessionStart"), at: at(0))
        XCTAssertEqual(t.state(of: tab)?.configDir, "/custom/dir")
        XCTAssertEqual(AgentTracker.configDir(fromTranscript: "/a/b/projects/-x/y.jsonl"), "/a/b")
        XCTAssertNil(AgentTracker.configDir(fromTranscript: "/tmp/y.jsonl"))
    }

    func testStopInFocusedTabIsNotUnread() {
        var t = AgentTracker()
        t.setFocusedTab(tab)
        t.apply(tab: tab, configDir: nil, payload: hook("SessionStart"), at: at(0))
        t.apply(tab: tab, configDir: nil, payload: hook("UserPromptSubmit"), at: at(1))
        t.apply(tab: tab, configDir: nil, payload: hook("Stop"), at: at(2))
        XCTAssertEqual(t.state(of: tab)?.unread, false)
        XCTAssertEqual(t.state(of: tab)?.phase, .idle)
    }

    func testFocusingATabMarksItRead() {
        var t = AgentTracker()
        t.apply(tab: tab, configDir: nil, payload: hook("SessionStart"), at: at(0))
        t.apply(tab: tab, configDir: nil, payload: hook("Stop", extra: ["prompt_id": "a"]), at: at(1))
        XCTAssertEqual(t.state(of: tab)?.unread, true)
        let changed = t.setFocusedTab(tab, at: at(2))
        XCTAssertEqual(changed?.unread, false)
        XCTAssertNil(t.setFocusedTab(tab, at: at(3)), "nothing left to clear")
        XCTAssertNil(t.setFocusedTab(nil))
        XCTAssertNil(t.focusedTab)
    }

    func testNotificationNeedsInput() {
        for kind in ["permission_prompt", "elicitation_dialog"] {
            var t = AgentTracker()
            t.apply(tab: tab, configDir: nil, payload: hook("SessionStart"), at: at(0))
            t.apply(tab: tab, configDir: nil, payload: hook("UserPromptSubmit"), at: at(1))
            t.apply(tab: tab, configDir: nil, payload: hook("Notification", extra: ["notification_type": .string(kind), "message": "m"]), at: at(2))
            XCTAssertEqual(t.state(of: tab)?.phase, .needsInput, kind)
            XCTAssertEqual(t.state(of: tab)?.unread, true, kind)
        }
        var t = AgentTracker()
        t.apply(tab: tab, configDir: nil, payload: hook("SessionStart"), at: at(0))
        XCTAssertEqual(t.apply(tab: tab, configDir: nil, payload: hook("Notification", extra: ["notification_type": "auth_success"]), at: at(1)), .ignored)
        XCTAssertEqual(t.state(of: tab)?.phase, .idle)
    }

    /// Claude Code sends `idle_prompt` 60 s after every finished turn: a read, finished session must stay idle and read.
    func testIdlePromptAfterAFinishedTurnChangesNothing() {
        var t = AgentTracker()
        t.apply(tab: tab, configDir: nil, payload: hook("SessionStart"), at: at(0))
        t.apply(tab: tab, configDir: nil, payload: hook("UserPromptSubmit"), at: at(1))
        t.apply(tab: tab, configDir: nil, payload: hook("Stop", extra: ["prompt_id": "p"]), at: at(2))
        t.markRead(tab: tab, at: at(3))
        XCTAssertEqual(t.apply(tab: tab, configDir: nil, payload: hook("Notification", extra: ["notification_type": "idle_prompt", "message": "waiting"]), at: at(63)), .ignored)
        XCTAssertEqual(t.state(of: tab)?.phase, .idle)
        XCTAssertEqual(t.state(of: tab)?.unread, false)
        XCTAssertEqual(t.summary(tabs: [tab]), WorkspaceSummary(live: 1))
    }

    func testNewPromptAfterNeedsInputRunsAgainAndClearsUnread() {
        var t = AgentTracker()
        t.apply(tab: tab, configDir: nil, payload: hook("Notification", extra: ["notification_type": "permission_prompt"]), at: at(0))
        XCTAssertEqual(t.state(of: tab)?.phase, .needsInput)
        t.apply(tab: tab, configDir: nil, payload: hook("UserPromptSubmit", extra: ["prompt_id": "p2"]), at: at(10))
        XCTAssertEqual(t.state(of: tab)?.phase, .running)
        XCTAssertEqual(t.state(of: tab)?.unread, false)
    }

    func testSessionStartOverwritesSessionId() {
        var t = AgentTracker()
        t.apply(tab: tab, configDir: nil, payload: hook("SessionStart", sid: "old"), at: at(0))
        t.apply(tab: tab, configDir: nil, payload: hook("UserPromptSubmit", sid: "old", extra: ["prompt_id": "1"]), at: at(1))
        t.apply(tab: tab, configDir: nil, payload: hook("SessionStart", sid: "forked", extra: ["source": "fork"]), at: at(2))
        XCTAssertEqual(t.state(of: tab)?.sessionID, "forked")
        XCTAssertEqual(t.state(of: tab)?.phase, .idle, "a fresh session starts idle")
    }

    func testLateSessionEndOfOldSessionKeepsNewOne() {
        var t = AgentTracker()
        t.apply(tab: tab, configDir: nil, payload: hook("SessionStart", sid: "new"), at: at(0))
        XCTAssertEqual(t.apply(tab: tab, configDir: nil, payload: hook("SessionEnd", sid: "old", extra: ["reason": "clear"]), at: at(1)), .ignored)
        XCTAssertEqual(t.state(of: tab)?.sessionID, "new")
        if case .removed = t.apply(tab: tab, configDir: nil, payload: hook("SessionEnd", sid: "new"), at: at(2)) {} else { XCTFail() }
    }

    func testEventsWithoutPriorSessionStartCreateTheAgent() {
        var t = AgentTracker()   // app started mid-session
        t.apply(tab: tab, configDir: nil, payload: hook("UserPromptSubmit", sid: "mid"), at: at(0))
        XCTAssertEqual(t.state(of: tab)?.sessionID, "mid")
        XCTAssertEqual(t.state(of: tab)?.phase, .running)
    }

    func testDedupeIdenticalEventsWithinWindow() {
        var t = AgentTracker()
        let p = hook("Stop", extra: ["prompt_id": "p1"])
        t.apply(tab: tab, configDir: nil, payload: hook("SessionStart"), at: at(0))
        XCTAssertNotEqual(t.apply(tab: tab, configDir: nil, payload: p, at: at(1)), .duplicate)
        XCTAssertEqual(t.apply(tab: tab, configDir: nil, payload: p, at: at(1.2)), .duplicate)
        // same payload on another tab is not a duplicate
        XCTAssertNotEqual(t.apply(tab: "TAB-2", configDir: nil, payload: p, at: at(1.3)), .duplicate)
        // after the window it counts again
        XCTAssertNotEqual(t.apply(tab: tab, configDir: nil, payload: p, at: at(30)), .duplicate)
    }

    func testDuplicateDoesNotFlipStateBack() {
        var t = AgentTracker()
        let stop = hook("Stop", extra: ["prompt_id": "p1"])
        t.apply(tab: tab, configDir: nil, payload: hook("SessionStart"), at: at(0))
        t.apply(tab: tab, configDir: nil, payload: stop, at: at(1))
        t.markRead(tab: tab, at: at(1.1))
        t.apply(tab: tab, configDir: nil, payload: stop, at: at(1.2))   // second hook file fires the same Stop
        XCTAssertEqual(t.state(of: tab)?.unread, false, "the duplicate must not re-raise unread")
    }

    func testUnchangedWhenOnlyTimestampMoves() {
        var t = AgentTracker()
        t.apply(tab: tab, configDir: nil, payload: hook("UserPromptSubmit", extra: ["prompt_id": "1"]), at: at(0))
        XCTAssertEqual(t.apply(tab: tab, configDir: nil, payload: hook("UserPromptSubmit", extra: ["prompt_id": "2"]), at: at(20)), .unchanged)
        XCTAssertEqual(t.state(of: tab)?.updatedAt, t0.timeIntervalSince1970 + 20)
    }

    func testIgnoredShapes() {
        var t = AgentTracker()
        XCTAssertEqual(t.apply(tab: tab, configDir: nil, payload: "nope", at: at(0)), .ignored)
        XCTAssertEqual(t.apply(tab: tab, configDir: nil, payload: ["x": 1], at: at(0)), .ignored)
        XCTAssertEqual(t.apply(tab: tab, configDir: nil, payload: hook("PreToolUse"), at: at(0)), .ignored)
        XCTAssertEqual(t.apply(tab: tab, configDir: nil, payload: ["hook_event_name": "Stop"], at: at(0)), .ignored, "no session id")
        XCTAssertEqual(t.apply(tab: tab, configDir: nil, payload: hook("SessionEnd"), at: at(0)), .ignored, "nothing to end")
        XCTAssertTrue(t.agents.isEmpty)
    }

    func testSummaryAndMarkRead() {
        var t = AgentTracker()
        for (i, id) in ["a", "b", "c", "d"].enumerated() {
            t.apply(tab: id, configDir: nil, payload: hook("SessionStart", sid: "s\(id)"), at: at(Double(i)))
        }
        t.apply(tab: "b", configDir: nil, payload: hook("UserPromptSubmit", sid: "sb"), at: at(10))
        t.apply(tab: "c", configDir: nil, payload: hook("Stop", sid: "sc", extra: ["prompt_id": "x"]), at: at(11))
        t.apply(tab: "d", configDir: nil, payload: hook("Notification", sid: "sd", extra: ["notification_type": "permission_prompt"]), at: at(12))

        XCTAssertEqual(t.summary(tabs: ["a", "b"]), WorkspaceSummary(live: 2, running: 1, anyUnread: false, anyNeedsInput: false))
        XCTAssertEqual(t.summary(tabs: ["c"]), WorkspaceSummary(live: 1, running: 0, anyUnread: true, anyNeedsInput: false, unread: 1))
        XCTAssertEqual(t.summary(tabs: ["a", "b", "c", "d", "ghost"]), WorkspaceSummary(live: 4, running: 1, anyUnread: true, anyNeedsInput: true, needsInput: 1, unread: 1))
        XCTAssertEqual(t.summary(tabs: ["ghost"]), WorkspaceSummary())

        XCTAssertEqual(Set(t.markRead(tabs: ["a", "b", "c", "d"], at: at(20))), ["c", "d"])
        XCTAssertFalse(t.summary(tabs: ["a", "b", "c", "d"]).anyUnread)
        XCTAssertTrue(t.summary(tabs: ["d"]).anyNeedsInput, "reading does not answer the prompt")
        XCTAssertNotNil(t.markUnread(tab: "a", at: at(21)))
        XCTAssertTrue(t.summary(tabs: ["a"]).anyUnread)
    }

    func testForgetClearsFocus() {
        var t = AgentTracker()
        t.apply(tab: tab, configDir: nil, payload: hook("SessionStart"), at: at(0))
        t.setFocusedTab(tab)
        XCTAssertNotNil(t.forget(tab: tab))
        XCTAssertNil(t.focusedTab)
        XCTAssertNil(t.forget(tab: tab))
    }

    func testAgentStateJSONShape() {
        let s = AgentState(sessionID: "x", configDir: "/c", transcriptPath: "/t", cwd: "/w", phase: .needsInput, unread: true, updatedAt: 5)
        XCTAssertEqual(s.json["phase"], "needsInput")
        XCTAssertEqual(s.json["sessionID"], "x")
        XCTAssertEqual(s.json["unread"], true)
        XCTAssertEqual(s.json["updatedAt"]?.intValue, 5)
    }

    // MARK: resume builder

    func testResumeCommand() {
        let home = "/Users/dev"
        XCTAssertEqual(ResumeCommand.build(ResumeInfo(sessionID: "abc-123", configDir: "/Users/dev/.claude-work", cwd: "/Users/dev/code/x"), home: home),
                       "cd /Users/dev/code/x && CLAUDE_CONFIG_DIR=/Users/dev/.claude-work claude --resume abc-123")
        // default dir: the variable is left out (setting it explicitly broke login in the spike)
        for d in ["/Users/dev/.claude", "/Users/dev/.claude/", "~/.claude", "", nil] as [String?] {
            XCTAssertEqual(ResumeCommand.build(ResumeInfo(sessionID: "abc", configDir: d, cwd: "/w"), home: home),
                           "cd /w && claude --resume abc", "configDir=\(d ?? "nil")")
        }
        XCTAssertEqual(ResumeCommand.build(ResumeInfo(sessionID: "abc"), home: home), "claude --resume abc")
        XCTAssertEqual(ResumeCommand.build(ResumeInfo(sessionID: "a", configDir: "/o'k dir", cwd: "/my code"), home: home),
                       "cd '/my code' && CLAUDE_CONFIG_DIR='/o'\\''k dir' claude --resume a")
    }

    func testResumeInfoFromJSON() {
        XCTAssertEqual(ResumeInfo(json: ["sessionID": "s", "configDir": "/c", "cwd": "/w"]), ResumeInfo(sessionID: "s", configDir: "/c", cwd: "/w"))
        XCTAssertEqual(ResumeInfo(json: ["id": "tab", "agent": ["sessionID": "s", "cwd": "/w"]]), ResumeInfo(sessionID: "s", configDir: nil, cwd: "/w"))
        XCTAssertNil(ResumeInfo(json: ["id": "tab"]))
        XCTAssertNil(ResumeInfo(json: ["agent": .null]))
    }

    func testAgentServiceTranslatesHooksIntoEvents() throws {
        let bus = EventBus()
        let svc = AgentService(bus: bus, now: { Date(timeIntervalSince1970: 5) })
        let res = try svc.handleHook(params: ["tab": "T", "configDir": nil, "payload": hook("SessionStart")])
        XCTAssertEqual(res["outcome"], "changed")
        _ = try svc.handleHook(params: ["tab": "T", "payload": hook("SessionStart")])   // duplicate
        let types = bus.backlog(after: 0).events.map(\.type)
        XCTAssertEqual(types, ["agent.hook", "agent.changed"], "duplicates publish nothing")
        XCTAssertEqual(svc.statesJSON["T"]?["phase"], "idle")
        svc.forget(tab: "T")
        XCTAssertEqual(bus.backlog(after: 0).events.last?.data["agent"], .null)
        XCTAssertThrowsError(try svc.handleHook(params: ["payload": hook("Stop")]))
        XCTAssertThrowsError(try svc.handleHook(params: ["tab": "T", "payload": "str"]))
    }
}
