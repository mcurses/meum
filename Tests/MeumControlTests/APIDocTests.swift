import Foundation
import MeumControl
import XCTest

/// docs/api.md is generated from the doc comments in ControlHandler.swift (MeumMethod and MeumEvent): every method
/// and event must have one, and the file must match. To regenerate: MEUM_WRITE_API_DOC=1 swift test --filter APIDocTests
final class APIDocTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    struct Entry { var name: String; var doc: String }

    /// The `public static let x = "a.b"` constants of one enum, with the `///` lines above each.
    static func entries(of enumName: String, in text: String) -> [Entry] {
        guard let start = text.range(of: "public enum \(enumName) {") else { return [] }
        var out: [Entry] = []
        var doc: [String] = []
        for raw in text[start.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "}" { break }
            if line.hasPrefix("///") { doc.append(String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)); continue }
            if line.hasPrefix("public static let "), let q = line.range(of: "= \""),
               let end = line[q.upperBound...].firstIndex(of: "\"") {
                out.append(Entry(name: String(line[q.upperBound..<end]), doc: doc.joined(separator: " ")))
            }
            doc = []
        }
        return out
    }

    static func render(methods: [Entry], events: [Entry]) -> String {
        var s = """
        # meum control API (meum.v1)

        Generated from the doc comments in `Sources/MeumControl/ControlHandler.swift` by `Tests/MeumControlTests/APIDocTests.swift`;
        edit those, then run `MEUM_WRITE_API_DOC=1 swift test --filter APIDocTests`.

        Newline-delimited JSON over the Unix socket in `$MEUM_SOCKET` (default `~/.local/state/meum/meum.sock`, mode 0600):
        a request `{"id": 1, "method": "workspace.list", "params": {…}}` gets `{"id": 1, "result": …}` or
        `{"id": 1, "error": {"code", "message"}}`. Error codes: `parse_error`, `invalid_request`, `method_not_found`,
        `invalid_params`, `not_found`, `conflict`, `unavailable`, `forbidden`, `internal`. `system.ping` lists the methods
        a running meum serves; a client should ask before it relies on a newer one. Changes are additions only: a new
        method, a new optional parameter with a default, a new field in an answer.

        ## Methods

        """
        func head(_ m: Entry) -> String { m.name.contains(".") ? String(m.name.split(separator: ".")[0]) : "model" }
        var order: [String] = []
        for m in methods where !order.contains(head(m)) { order.append(head(m)) }
        for g in order {
            s += "\n### \(g)\n\n"
            for m in methods where head(m) == g { s += "- `\(m.name)`: \(m.doc)\n" }
        }
        s += "\n## Events\n\n`events.subscribe` streams `{\"seq\": n, \"type\": \"…\", \"data\": {…}}` lines.\n\n"
        for e in events { s += "- `\(e.name)`: \(e.doc)\n" }
        return s
    }

    func testAPIDocIsCurrent() throws {
        let text = try String(contentsOf: Self.root.appendingPathComponent("Sources/MeumControl/ControlHandler.swift"), encoding: .utf8)
        let methods = Self.entries(of: "MeumMethod", in: text)
        let events = Self.entries(of: "MeumEvent", in: text)
        XCTAssertGreaterThan(methods.count, 40)
        XCTAssertGreaterThan(events.count, 15)
        for e in methods + events where e.doc.isEmpty { XCTFail("\(e.name) has no doc comment in ControlHandler.swift") }
        XCTAssertEqual(Set(methods.map(\.name)), Set(ControlInfo.methods), "MeumMethod constants vs the served list")
        let doc = Self.render(methods: methods, events: events)
        let path = Self.root.appendingPathComponent("docs/api.md")
        if ProcessInfo.processInfo.environment["MEUM_WRITE_API_DOC"] == "1" {
            try doc.write(to: path, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(try? String(contentsOf: path, encoding: .utf8), doc,
                       "docs/api.md is stale: MEUM_WRITE_API_DOC=1 swift test --filter APIDocTests")
    }

    /// Every event type the code publishes is declared (and so documented).
    func testEveryPublishedEventIsDeclared() throws {
        let text = try String(contentsOf: Self.root.appendingPathComponent("Sources/MeumControl/ControlHandler.swift"), encoding: .utf8)
        let declared = Set(Self.entries(of: "MeumEvent", in: text).map(\.name))
        var published = Set<String>()
        let re = try NSRegularExpression(pattern: #"(?:publish\(|\(")"?([a-z]+\.[a-zA-Z]+|notification)"(?=,|\))"#)
        for dir in ["Sources", "App/Sources"] {
            let base = Self.root.appendingPathComponent(dir)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for f in files {
                let s = try String(contentsOf: f, encoding: .utf8)
                for line in s.split(separator: "\n") where line.contains("publish(") || f.lastPathComponent == "ModelJSON.swift" {
                    let l = String(line)
                    guard l.contains("publish(\"") || l.contains("append((\"") else { continue }
                    for m in re.matches(in: l, range: NSRange(l.startIndex..., in: l)) {
                        if let r = Range(m.range(at: 1), in: l) { published.insert(String(l[r])) }
                    }
                }
            }
        }
        XCTAssertGreaterThan(published.count, 10)
        XCTAssertEqual(published.subtracting(declared), [], "published but not in MeumEvent")
    }
}
