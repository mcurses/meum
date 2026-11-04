import XCTest
@testable import MeumControl

final class ProtocolTests: XCTestCase {
    func testJSONRoundTripAndAccessors() throws {
        let j: JSON = ["a": 1, "b": [true, nil, "x", 1.5], "c": ["d": "e/f"]]
        let back = try JSON.parse(j.compactData())
        XCTAssertEqual(back, j)
        XCTAssertEqual(back["a"]?.intValue, 1)
        XCTAssertEqual(back["b"]?[3]?.doubleValue, 1.5)
        XCTAssertEqual(back["c"]?["d"]?.stringValue, "e/f")
        XCTAssertFalse(j.compactString.contains("\\/"), "slashes must not be escaped")
        XCTAssertFalse(j.compactString.contains("\n"))
        XCTAssertEqual(try JSON.parse("{\"n\": 3}")["n"], .int(3))
        XCTAssertEqual(JSON.double(2.0).intValue, 2)
    }

    func testRequestDecode() throws {
        let r = try Request.decode(Data(#"{"id":7,"method":"workspace.list","params":{"x":1}}"#.utf8))
        XCTAssertEqual(r.id, .int(7))
        XCTAssertEqual(r.method, "workspace.list")
        XCTAssertEqual(r.params["x"], .int(1))
        XCTAssertFalse(r.oneshot)

        let noParams = try Request.decode(Data(#"{"id":"abc","method":"tree"}"#.utf8))
        XCTAssertEqual(noParams.id, .string("abc"))
        XCTAssertEqual(noParams.params, .object([:]))

        let one = try Request.decode(Data(#"{"method":"agent.hook","oneshot":true,"params":null}"#.utf8))
        XCTAssertTrue(one.oneshot)
        XCTAssertEqual(one.id, .null)

        XCTAssertEqual(try Request.decode(Request(id: 3, method: "m", params: ["k": "v"]).encoded()).params["k"], "v")
    }

    func testRequestDecodeErrors() {
        func code(_ s: String) -> String? {
            do { _ = try Request.decode(Data(s.utf8)); return nil } catch { return (error as? ControlError)?.code }
        }
        XCTAssertEqual(code("not json"), "parse_error")
        XCTAssertEqual(code("[1,2]"), "invalid_request")
        XCTAssertEqual(code(#"{"id":1}"#), "invalid_request")
        XCTAssertEqual(code(#"{"id":1,"method":""}"#), "invalid_request")
        XCTAssertEqual(code(#"{"id":1,"method":"m","params":[1]}"#), "invalid_request")
    }

    func testResponseEncodeDecode() throws {
        let ok = Response(id: .int(1), result: ["a": 1])
        XCTAssertEqual(Response.decode(try JSON.parse(ok.encoded())), ok)
        let nullResult = Response(id: .int(2), result: .null)
        XCTAssertTrue(nullResult.encoded().starts(with: Data(#"{"id":2,"result":null"#.utf8)))
        XCTAssertEqual(Response.decode(try JSON.parse(nullResult.encoded()))?.result, JSON.null)
        let err = Response(id: .string("x"), error: .notFound("nope"))
        let dec = Response.decode(try JSON.parse(err.encoded()))
        XCTAssertEqual(dec?.error?.code, "not_found")
        XCTAssertEqual(dec?.error?.message, "nope")
        // Events are not responses.
        XCTAssertNil(Response.decode(Event(seq: 1, type: "t", data: .null).json))
    }

    func testEventEncodeDecode() throws {
        let e = Event(seq: 5, type: "tab.added", data: ["id": "x"])
        XCTAssertEqual(Event.decode(try JSON.parse(e.encoded())), e)
    }

    func testLineBufferFraming() throws {
        var lb = LineBuffer()
        XCTAssertEqual(try lb.append(Data("abc".utf8)), [])
        XCTAssertEqual(try lb.append(Data("def\nxy".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["abcdef"])
        XCTAssertEqual(try lb.append(Data("z\r\n\n\nlast\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, ["xyz", "last"])
        XCTAssertEqual(lb.pendingBytes, 0)
    }

    func testLineBufferLimit() {
        var lb = LineBuffer(maxLineBytes: 16)
        XCTAssertThrowsError(try lb.append(Data(repeating: 0x61, count: 40))) {
            XCTAssertEqual(($0 as? ControlError)?.code, "invalid_request")
        }
        XCTAssertEqual(lb.pendingBytes, 0)
    }

    func testSocketPathResolution() {
        XCTAssertEqual(ControlPaths.socketPath(env: ["MEUM_SOCKET": "/x/y.sock"], home: "/h"), "/x/y.sock")
        XCTAssertEqual(ControlPaths.socketPath(env: ["MEUM_SOCKET": ""], home: "/h"), "/h/.local/state/meum/meum.sock")
        XCTAssertEqual(ControlPaths.socketPath(env: [:], home: "/h"), "/h/.local/state/meum/meum.sock")
    }

    func testBundleVersionFromInsideTheApp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meum-bv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let contents = dir.appendingPathComponent("meum.app/Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        (["CFBundleShortVersionString": "0.5.0", "CFBundleIdentifier": "io.github.mcurses.meum"] as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        XCTAssertEqual(ControlInfo.bundleVersion(around: contents.appendingPathComponent("MacOS/meum").path), "0.5.0")
        XCTAssertEqual(ControlInfo.bundleVersion(around: contents.appendingPathComponent("Resources/bin/meum").path), "0.5.0")
        XCTAssertNil(ControlInfo.bundleVersion(around: dir.appendingPathComponent("loose/meum").path))
        XCTAssertNil(ControlInfo.bundleVersion(around: nil))
        (["CFBundleShortVersionString": "27.2", "CFBundleIdentifier": "com.apple.dt.Xcode"] as NSDictionary)
            .write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
        XCTAssertNil(ControlInfo.bundleVersion(around: contents.appendingPathComponent("MacOS/meum").path), "another app's version")
    }

    func testMethodsAreListedOnce() {
        XCTAssertEqual(ControlInfo.methods.count, Set(ControlInfo.methods).count)
    }
}

final class EventBusTests: XCTestCase {
    func testMonotonicSeqAndRing() {
        let bus = EventBus(capacity: 3)
        for i in 1...5 { XCTAssertEqual(bus.publish("t", .int(i)).seq, i) }
        XCTAssertEqual(bus.lastSeq, 5)
        let (events, gap) = bus.backlog(after: 0)
        XCTAssertEqual(events.map(\.seq), [3, 4, 5])
        XCTAssertTrue(gap, "events 1 and 2 were dropped")
        let (tail, gap2) = bus.backlog(after: 3)
        XCTAssertEqual(tail.map(\.seq), [4, 5])
        XCTAssertFalse(gap2)
        XCTAssertEqual(bus.backlog(after: 5).events.count, 0)
        XCTAssertEqual(bus.backlog(after: nil).events.count, 0)
    }

    func testStaleAfterFromPreviousRunIsAGap() {
        let bus = EventBus()
        bus.publish("a"); bus.publish("b")
        let (events, gap) = bus.backlog(after: 500)
        XCTAssertTrue(gap)
        XCTAssertEqual(events.map(\.seq), [1, 2])
    }

    func testSubscribeReplaysThenGoesLiveInOrder() {
        let bus = EventBus()
        for i in 1...3 { bus.publish("t", .int(i)) }
        let got = Locked<[Int]>([])
        let order = Locked<[String]>([])
        let started = Locked<SubscribeInfo?>(nil)
        let sub = bus.subscribe(after: 1, onStart: { info in started.set(info); order.mutate { $0.append("start") } },
                                deliver: { e in got.mutate { $0.append(e.seq) }; order.mutate { $0.append("event") } })
        for i in 4...6 { bus.publish("t", .int(i)) }
        XCTAssertTrue(TestSupport.wait { got.value.count == 5 })
        XCTAssertEqual(got.value, [2, 3, 4, 5, 6], "replay then live, no gap, no duplicate")
        XCTAssertEqual(order.value.first, "start", "onStart (the subscribe response) comes before any event")
        XCTAssertEqual(started.value, SubscribeInfo(seq: 3, gap: false, replayed: 2))
        sub.cancel()
        bus.publish("t", .int(7))
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(got.value.count, 5, "cancelled subscriptions get nothing")
        XCTAssertEqual(bus.subscriberCount, 0)
    }

    func testLiveOnlyWithoutAfterAndFilter() {
        let bus = EventBus()
        bus.publish("old.event")
        let all = Locked<[String]>([])
        let tabs = Locked<[String]>([])
        let s1 = bus.subscribe(after: nil, deliver: { e in all.mutate { $0.append(e.type) } })
        let s2 = bus.subscribe(after: nil, filter: EventFilter(patterns: ["tab.*", "agent.changed"]),
                               deliver: { e in tabs.mutate { $0.append(e.type) } })
        for t in ["workspace.added", "tab.added", "agent.changed", "agent.hook", "tab.removed"] { bus.publish(t) }
        XCTAssertTrue(TestSupport.wait { all.value.count == 5 && tabs.value.count == 3 })
        XCTAssertEqual(tabs.value, ["tab.added", "agent.changed", "tab.removed"])
        s1.cancel(); s2.cancel()
    }

    func testFilterMatching() {
        XCTAssertTrue(EventFilter().matches("anything"))
        XCTAssertTrue(EventFilter(patterns: ["*"]).matches("anything"))
        XCTAssertTrue(EventFilter(patterns: ["tab.*"]).matches("tab.added"))
        XCTAssertFalse(EventFilter(patterns: ["tab.*"]).matches("workspace.added"))
        XCTAssertTrue(EventFilter(patterns: ["status.changed"]).matches("status.changed"))
        XCTAssertFalse(EventFilter(patterns: ["status.changed"]).matches("status.changed2"))
    }

    func testConcurrentPublishKeepsSeqUniqueAndOrderedPerSubscriber() {
        let bus = EventBus(capacity: 5000)
        let got = Locked<[Int]>([])
        let sub = bus.subscribe(after: nil, deliver: { e in got.mutate { $0.append(e.seq) } })
        DispatchQueue.concurrentPerform(iterations: 8) { _ in for _ in 0..<100 { bus.publish("x") } }
        XCTAssertTrue(TestSupport.wait { got.value.count == 800 })
        XCTAssertEqual(got.value, Array(1...800))
        sub.cancel()
    }
}

/// Tiny lock-protected box for test callbacks.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func set(_ n: T) { lock.lock(); v = n; lock.unlock() }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }

}
