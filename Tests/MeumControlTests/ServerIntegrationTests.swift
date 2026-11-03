import XCTest
@testable import MeumControl

final class ServerIntegrationTests: XCTestCase {
    var h: Harness!

    override func setUpWithError() throws { h = try Harness() }
    override func tearDown() { h.tearDown() }

    // MARK: basics

    func testPingAndPlainCalls() throws {
        let c = h.client()
        let pong = try c.call("system.ping")
        XCTAssertEqual(pong["api"], "meum.v1")
        XCTAssertEqual(pong["pid"]?.intValue, Int(getpid()))
        XCTAssertEqual(try c.call("echo", ["a": [1, 2, 3]]), ["a": [1, 2, 3]])
        XCTAssertEqual(try c.call("tab.new")["id"]?.stringValue?.count, 36)
        XCTAssertEqual(try c.call("tab.close", ["tab": "x"]), .null)
        XCTAssertEqual(h.handler.calls.map(\.method), ["echo", "tab.new", "tab.close"], "ping is answered by the server, not the handler")
    }

    func testErrorsMapToCodes() throws {
        let c = h.client()
        func code(_ m: String) -> ControlError? {
            do { _ = try c.call(m); return nil } catch { return error as? ControlError }
        }
        XCTAssertEqual(code("missing")?.code, "not_found")
        XCTAssertEqual(code("missing")?.message, "no such thing")
        XCTAssertEqual(code("does.not.exist")?.code, "method_not_found")
        let boom = code("boom")
        XCTAssertEqual(boom?.code, "internal")
        XCTAssertTrue(boom?.message.contains("kaboom") ?? false)
        XCTAssertEqual(try c.call("system.ping")["api"], "meum.v1", "the connection survives errors")
    }

    func testSocketAndStateDirPermissions() throws {
        var st = stat()
        XCTAssertEqual(stat(h.socket, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFSOCK)
        let dir = (h.socket as NSString).deletingLastPathComponent
        XCTAssertEqual(stat(dir, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700, "state dir created by the server is private")
    }

    func testStartRemovesStaleSocketAndRefusesLiveOne() throws {
        let dir = TestSupport.tempDir("stale")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/meum.sock"

        // A stale socket: bound, then abandoned without unlink.
        let fd = try SocketIO.newSocket()
        try SocketIO.withAddress(path) { sa, len in XCTAssertEqual(Darwin.bind(fd, sa, len), 0) }
        close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let s1 = ControlServer(socketPath: path, handler: FakeHandler())
        try s1.start()
        XCTAssertEqual(try ControlClient(socketPath: path).call("system.ping")["api"], "meum.v1")

        let s2 = ControlServer(socketPath: path, handler: FakeHandler())
        XCTAssertThrowsError(try s2.start()) { XCTAssertEqual(($0 as? ControlError)?.code, "conflict") }
        XCTAssertEqual(try ControlClient(socketPath: path).call("system.ping")["api"], "meum.v1", "the live server is not disturbed")
        s1.stop()

        TestSupport.write("not a socket", to: path)
        XCTAssertThrowsError(try ControlServer(socketPath: path, handler: FakeHandler()).start()) {
            XCTAssertEqual(($0 as? ControlError)?.code, "conflict")
        }
        XCTAssertEqual(TestSupport.read(path), "not a socket", "never delete what is not a socket")
    }

    func testTooLongPathIsReported() {
        let long = "/tmp/" + String(repeating: "a", count: 120) + "/meum.sock"
        XCTAssertThrowsError(try ControlServer(socketPath: long, handler: FakeHandler()).start())
    }

    func testStopRemovesSocketAndClientsSeeNotRunning() throws {
        let c = h.client()
        _ = try c.call("system.ping")
        h.server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.socket))
        XCTAssertFalse(h.server.isRunning)
        XCTAssertThrowsError(try c.call("system.ping"), "the open connection was closed")
        XCTAssertThrowsError(try h.client().call("system.ping")) {
            guard case ClientError.notRunning = $0 else { return XCTFail("\($0)") }
        }
        // and it can be started again
        try h.server.start()
        XCTAssertEqual(try h.client().call("system.ping")["api"], "meum.v1")
    }

    func testClientAgainstMissingSocket() {
        let c = ControlClient(socketPath: h.dir + "/nothing.sock")
        XCTAssertThrowsError(try c.call("system.ping")) {
            XCTAssertEqual($0 as? ClientError, .notRunning(path: h.dir + "/nothing.sock"))
        }
    }

    // MARK: framing and concurrency

    func testRawFramingMalformedAndPipelinedRequests() throws {
        let fd = try ControlClient.connect(path: h.socket)
        SocketIO.setTimeout(fd.fd, option: SO_RCVTIMEO, seconds: 5)
        let payload = "garbage\n" + #"{"id":1,"method":"echo","params":{"n":1}}"# + "\n" + #"{"id":2,"method":"echo","params":{"n":2}}"# + "\r\n" + "[]\n"
        XCTAssertTrue(fd.send(Data(payload.utf8)))
        var lb = LineBuffer()
        var lines: [JSON] = []
        while lines.count < 4 {
            let (chunk, _) = SocketIO.readChunk(fd.fd)
            let data = try XCTUnwrap(chunk)
            lines += try lb.append(data).map { try JSON.parse($0) }
        }
        XCTAssertEqual(lines[0]["error"]?["code"], "parse_error")
        XCTAssertEqual(lines[1]["id"], 1)
        XCTAssertEqual(lines[1]["result"]?["n"], 1)
        XCTAssertEqual(lines[2]["id"], 2, "responses keep request order")
        XCTAssertEqual(lines[3]["error"]?["code"], "invalid_request")
    }

    func testRequestSplitAcrossWrites() throws {
        let fd = try ControlClient.connect(path: h.socket)
        SocketIO.setTimeout(fd.fd, option: SO_RCVTIMEO, seconds: 5)
        XCTAssertTrue(fd.send(Data(#"{"id":9,"meth"#.utf8)))
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(fd.send(Data(#"od":"echo","params":{"k":"v"}}"#.utf8)))
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertTrue(fd.send(Data("\n".utf8)))
        let (chunk, _) = SocketIO.readChunk(fd.fd)
        let resp = try JSON.parse(try XCTUnwrap(chunk))
        XCTAssertEqual(resp["id"], 9)
        XCTAssertEqual(resp["result"]?["k"], "v")
    }

    func testOneshotClosesTheConnectionAfterTheResponse() throws {
        let fd = try ControlClient.connect(path: h.socket)
        SocketIO.setTimeout(fd.fd, option: SO_RCVTIMEO, seconds: 5)
        XCTAssertTrue(fd.sendLine(Request(id: 1, method: "echo", params: ["a": 1], oneshot: true).encoded()))
        let (first, _) = SocketIO.readChunk(fd.fd)
        XCTAssertEqual(try JSON.parse(try XCTUnwrap(first))["result"]?["a"], 1)
        let (eof, timedOut) = SocketIO.readChunk(fd.fd)
        XCTAssertNil(eof)
        XCTAssertFalse(timedOut, "server closed the connection")
    }

    func testManyConcurrentClients() throws {
        let failures = Locked(0)
        DispatchQueue.concurrentPerform(iterations: 24) { worker in
            let c = h.client()
            for i in 0..<25 {
                do {
                    let r = try c.call("echo", ["w": .int(worker), "i": .int(i)])
                    if r["w"]?.intValue != worker || r["i"]?.intValue != i { failures.mutate { $0 += 1 } }
                } catch { failures.mutate { $0 += 1 } }
            }
        }
        XCTAssertEqual(failures.value, 0)
        XCTAssertEqual(h.handler.calls.count, 24 * 25)
    }

    func testSlowHandlersDoNotBlockOtherConnections() throws {
        let t0 = Date()
        let done = Locked(0)
        for _ in 0..<10 {
            Thread.detachNewThread { [self] in
                if (try? h.client().call("slow")) == "slow-done" { done.mutate { $0 += 1 } }
            }
        }
        XCTAssertEqual(try h.client().call("system.ping")["api"], "meum.v1")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.09, "a ping returns while slow calls are in flight")
        XCTAssertTrue(TestSupport.wait { done.value == 10 })
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.9, "slow calls ran in parallel")
    }

    // MARK: events

    func testSubscribeReplaysAfterSeqThenStreamsLive() throws {
        for i in 1...5 { h.bus.publish("tab.added", ["n": .int(i)]) }
        let stream = try h.client().subscribe(after: 2, timeout: 5)
        defer { stream.close() }
        XCTAssertEqual(stream.info["subscribed"], true)
        XCTAssertEqual(stream.info["seq"], 5)
        XCTAssertEqual(stream.info["gap"], false)
        XCTAssertEqual(stream.info["replayed"], 3)
        var seqs: [Int] = []
        for _ in 0..<3 { seqs.append(try XCTUnwrap(try stream.next()).seq) }
        XCTAssertEqual(seqs, [3, 4, 5])
        h.bus.publish("workspace.selected", ["id": "w"])
        let live = try XCTUnwrap(try stream.next())
        XCTAssertEqual(live.seq, 6)
        XCTAssertEqual(live.type, "workspace.selected")
        XCTAssertEqual(live.data["id"], "w")
    }

    func testSubscribeWithoutAfterIsLiveOnlyAndFilters() throws {
        h.bus.publish("old.event")
        let stream = try h.client().subscribe(after: nil, types: ["tab.*"], timeout: 5)
        defer { stream.close() }
        XCTAssertEqual(stream.info["replayed"], 0)
        h.bus.publish("workspace.added")
        h.bus.publish("tab.added")
        h.bus.publish("status.changed")
        h.bus.publish("tab.removed")
        XCTAssertEqual(try stream.next()?.type, "tab.added")
        XCTAssertEqual(try stream.next()?.type, "tab.removed")
    }

    func testSubscribeReportsGapWhenHistoryWasDropped() throws {
        let small = EventBus(capacity: 3)
        let dir = TestSupport.tempDir("gap")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let s = ControlServer(socketPath: dir + "/s.sock", handler: FakeHandler(), bus: small)
        try s.start()
        defer { s.stop() }
        for _ in 1...10 { small.publish("x") }
        let stream = try ControlClient(socketPath: dir + "/s.sock").subscribe(after: 1, timeout: 5)
        defer { stream.close() }
        XCTAssertEqual(stream.info["gap"], true)
        XCTAssertEqual(try stream.next()?.seq, 8)
    }

    func testSubscribersDoNotSeeEachOthersLossAndGetDroppedOnClose() throws {
        let a = try h.client().subscribe(timeout: 5)
        let b = try h.client().subscribe(timeout: 5)
        XCTAssertTrue(TestSupport.wait { self.h.bus.subscriberCount == 2 })
        a.close()
        XCTAssertTrue(TestSupport.wait { self.h.bus.subscriberCount == 1 }, "closing a subscriber unsubscribes it")
        h.bus.publish("still.works")
        XCTAssertEqual(try b.next()?.type, "still.works")
        b.close()
        XCTAssertTrue(TestSupport.wait { self.h.bus.subscriberCount == 0 })
    }

    func testServerStopEndsStreams() throws {
        let s = try h.client().subscribe(timeout: 5)
        h.server.stop()
        XCTAssertNil(try s.next(), "stream ends cleanly")
    }

    func testSubscribeTwiceOnOneConnectionIsRefused() throws {
        let fd = try ControlClient.connect(path: h.socket)
        SocketIO.setTimeout(fd.fd, option: SO_RCVTIMEO, seconds: 5)
        XCTAssertTrue(fd.sendLine(Request(id: 1, method: "events.subscribe").encoded()))
        XCTAssertTrue(fd.sendLine(Request(id: 2, method: "events.subscribe").encoded()))
        var lb = LineBuffer()
        var got: [JSON] = []
        while got.count < 2 {
            let (chunk, _) = SocketIO.readChunk(fd.fd)
            got += try lb.append(try XCTUnwrap(chunk)).map { try JSON.parse($0) }
        }
        XCTAssertEqual(got[0]["result"]?["subscribed"], true)
        XCTAssertEqual(got[1]["error"]?["code"], "conflict")
    }

    // MARK: agent.hook through the whole stack

    static let sessionStart = #"{"session_id":"910c9ccf-0000-4000-8000-000000000001","transcript_path":"/Users/dev/.claude-work/projects/-Users-dev-code-app/910c9ccf-0000-4000-8000-000000000001.jsonl","cwd":"/Users/dev/code/meum","hook_event_name":"SessionStart","source":"startup"}"#

    func testAgentHookRequestUpdatesTrackerAndEmitsEvents() throws {
        let stream = try h.client().subscribe(types: ["agent.*"], timeout: 5)
        defer { stream.close() }
        let tab = FakeHandler.tab1
        let payload = try JSON.parse(Self.sessionStart)
        let r = try h.client().call("agent.hook", ["tab": .string(tab), "configDir": "", "payload": payload])
        XCTAssertEqual(r["outcome"], "changed")
        let raw = try XCTUnwrap(try stream.next())
        XCTAssertEqual(raw.type, "agent.hook")
        XCTAssertEqual(raw.data["tab"], .string(tab))
        XCTAssertEqual(raw.data["payload"]?["hook_event_name"], "SessionStart")
        let changed = try XCTUnwrap(try stream.next())
        XCTAssertEqual(changed.type, "agent.changed")
        XCTAssertEqual(changed.data["agent"]?["configDir"], "/Users/dev/.claude-work")
        XCTAssertEqual(h.agents.state(of: tab)?.phase, .idle)
    }

    // MARK: the real meum-hook script

    func hookEnv(tab: String? = FakeHandler.tab1, socket: String? = nil, config: String? = nil) -> [String: String] {
        var e = ["PATH": "/usr/bin:/bin", "HOME": h.dir]
        if let tab { e["MEUM_TAB"] = tab }
        e["MEUM_SOCKET"] = socket ?? h.socket
        if let config { e["CLAUDE_CONFIG_DIR"] = config }
        return e
    }

    func fire(_ json: String, env: [String: String]) -> TestSupport.ProcResult {
        TestSupport.run("/bin/sh", [TestSupport.meumHookPath], env: env, stdin: json)
    }

    func testMuxHookScriptDrivesTheTrackerEndToEnd() throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: TestSupport.meumHookPath), "Resources/bin/meum-hook must be executable")
        let stream = try h.client().subscribe(types: ["agent.changed"], timeout: 10)
        defer { stream.close() }
        let tab = FakeHandler.tab1
        let sid = "910c9ccf-0000-4000-8000-000000000001"

        func event(_ name: String, _ extra: String = "") -> String {
            #"{"session_id":"\#(sid)","transcript_path":"/Users/dev/.claude-work/projects/-x/\#(sid).jsonl","cwd":"/Users/dev/code/meum","hook_event_name":"\#(name)"\#(extra)}"#
        }

        let r1 = fire(event("SessionStart", #","source":"startup""#), env: hookEnv(config: "/Users/dev/.claude-work"))
        XCTAssertEqual(r1.status, 0)
        XCTAssertEqual(r1.stdout, "", "stdout would be injected into Claude's context")
        XCTAssertEqual(r1.stderr, "")
        XCTAssertLessThan(r1.seconds, 1.0)
        XCTAssertEqual(try stream.next()?.data["agent"]?["phase"], "idle")

        // The state is visible and the env var arrived.
        XCTAssertEqual(h.agents.state(of: tab)?.configDir, "/Users/dev/.claude-work")
        XCTAssertEqual(h.agents.state(of: tab)?.sessionID, sid)

        XCTAssertEqual(fire(event("UserPromptSubmit", #","prompt_id":"p1","prompt":"say \"ok\" and a \\ backslash""#), env: hookEnv()).status, 0)
        XCTAssertEqual(try stream.next()?.data["agent"]?["phase"], "running")

        // Pretty-printed (multi-line) JSON on stdin must still be one request line.
        let pretty = "{\n  \"session_id\": \"\(sid)\",\n  \"hook_event_name\": \"Stop\",\n  \"prompt_id\": \"p1\",\n  \"last_assistant_message\": \"line1\\nline2\"\n}\n"
        XCTAssertEqual(fire(pretty, env: hookEnv()).status, 0)
        let stopped = try XCTUnwrap(try stream.next())
        XCTAssertEqual(stopped.data["agent"]?["phase"], "idle")
        XCTAssertEqual(stopped.data["agent"]?["unread"], true)

        // A needs-input notification, then the session ends.
        XCTAssertEqual(fire(event("Notification", #","notification_type":"permission_prompt","message":"Claude needs your permission""#), env: hookEnv()).status, 0)
        XCTAssertEqual(try stream.next()?.data["agent"]?["phase"], "needsInput")
        XCTAssertEqual(h.agents.summary(tabs: [tab]), WorkspaceSummary(live: 1, running: 0, anyUnread: true, anyNeedsInput: true, needsInput: 1))
        XCTAssertEqual(fire(event("SessionEnd", #","reason":"other""#), env: hookEnv()).status, 0)
        XCTAssertEqual(try stream.next()?.data["agent"], JSON.null)
        XCTAssertNil(h.agents.state(of: tab))

        // The handler saw exactly those agent.hook requests, with the env values filled in.
        let hooks = h.handler.calls.filter { $0.method == "agent.hook" }
        XCTAssertEqual(hooks.count, 5)
        XCTAssertEqual(hooks[0].params["tab"], .string(tab))
        XCTAssertEqual(hooks[0].params["configDir"], "/Users/dev/.claude-work")
        XCTAssertEqual(hooks[1].params["configDir"], .null, "unset CLAUDE_CONFIG_DIR is sent as null")
        XCTAssertEqual(hooks[1].params["payload"]?["prompt"], "say \"ok\" and a \\ backslash")
    }

    func testMuxHookDoesNothingOutsideAMuxTabOrWithoutASocket() throws {
        // not a meum tab
        let r1 = fire(Self.sessionStart, env: hookEnv(tab: nil))
        XCTAssertEqual(r1.status, 0); XCTAssertEqual(r1.stdout, ""); XCTAssertEqual(r1.stderr, "")
        // socket missing
        let r2 = fire(Self.sessionStart, env: hookEnv(socket: h.dir + "/gone.sock"))
        XCTAssertEqual(r2.status, 0); XCTAssertEqual(r2.stdout, ""); XCTAssertEqual(r2.stderr, "")
        XCTAssertLessThan(r2.seconds, 0.5)
        // stale socket file with nobody listening
        let stale = h.dir + "/stale.sock"
        let fd = try SocketIO.newSocket()
        try SocketIO.withAddress(stale) { sa, len in XCTAssertEqual(Darwin.bind(fd, sa, len), 0) }
        close(fd)
        let r3 = fire(Self.sessionStart, env: hookEnv(socket: stale))
        XCTAssertEqual(r3.status, 0); XCTAssertEqual(r3.stdout, ""); XCTAssertEqual(r3.stderr, "")
        XCTAssertLessThan(r3.seconds, 1.0)
        // unsafe tab token is refused locally
        let r4 = fire(Self.sessionStart, env: hookEnv(tab: "x\",\"evil\":\"1"))
        XCTAssertEqual(r4.status, 0)
        XCTAssertTrue(h.handler.calls.isEmpty, "none of the above may reach the server")
        // garbage on stdin: still silent, exit 0
        let r5 = fire("this is not json", env: hookEnv())
        XCTAssertEqual(r5.status, 0); XCTAssertEqual(r5.stdout, "")
        let r6 = fire("", env: hookEnv())
        XCTAssertEqual(r6.status, 0)
    }

    func testMuxHookIsCutOffWhenTheServerHangs() throws {
        // A server whose agent.hook handler never returns in time.
        let dir = TestSupport.tempDir("hang")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let slow = ClosureHandler { _, _ in try await Task.sleep(nanoseconds: 4_000_000_000); return .null }
        let s = ControlServer(socketPath: dir + "/h.sock", handler: slow)
        try s.start()
        defer { s.stop() }
        let r = fire(Self.sessionStart, env: hookEnv(socket: dir + "/h.sock"))
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.stdout, "")
        XCTAssertLessThan(r.seconds, 2.5, "nc -w 1 must cut a stuck server off")
    }

    func testMuxHookLatencyAgainstALiveServer() throws {
        func median(_ f: () -> Double) -> Double {
            var t: [Double] = []
            for _ in 0..<15 { t.append(f()) }
            t.sort()
            return t[7]
        }
        let live = median { fire(#"{"session_id":"s","hook_event_name":"UserPromptSubmit","prompt_id":"p"}"#, env: hookEnv()).seconds }
        let missing = median { fire(Self.sessionStart, env: hookEnv(socket: h.dir + "/gone.sock")).seconds }
        let baseline = median { TestSupport.run("/bin/sh", ["-c", "exit 0"], env: ["PATH": "/usr/bin:/bin"]).seconds }
        print("meum-hook latency incl. process spawn from the test: live server \(Int(live * 1000)) ms, socket missing \(Int(missing * 1000)) ms, bare `sh -c exit` \(Int(baseline * 1000)) ms")
        XCTAssertLessThan(live, 0.5)
    }
}
