import XCTest
@testable import MeumControl

final class TerminalLinksTests: XCTestCase {
    // a fake file system: folders end in "/"
    let fs: Set<String> = ["/home/u/proj/", "/home/u/proj/Sources/", "/home/u/proj/Sources/a.swift",
                           "/home/u/proj/README.md", "/home/u/other/", "/home/u/other/b.txt", "/etc/hosts",
                           "/home/u/notes.md", "/home/u/My Docs/c.md"]
    var probe: TerminalLinks.Probe {
        { [fs] p in fs.contains(p + "/") ? true : fs.contains(p) ? false : nil }
    }
    func resolve(_ s: String, bases: [String] = ["/home/u/proj"]) -> TerminalLinks.Target? {
        TerminalLinks.resolve(s, bases: bases, home: "/home/u", exists: probe)
    }

    func testWebLinks() {
        XCTAssertEqual(resolve("https://example.com/a?b=1"), .web(URL(string: "https://example.com/a?b=1")!, local: false))
        for local in ["http://localhost:3000", "http://127.0.0.1:8080/x", "http://0.0.0.0:5173", "http://[::1]:4000",
                      "http://app.localhost:3000"] {
            XCTAssertEqual(resolve(local)?.isLocalWeb, true, local)
        }
        for remote in ["http://127.example.com", "http://127.0.0.1.example.com/", "http://127.0.0/", "http://127.0.0.256/"] {
            XCTAssertEqual(resolve(remote)?.isLocalWeb, false, remote)
        }
        XCTAssertEqual(resolve("http://127.1.2.3:9000")?.isLocalWeb, true)
        XCTAssertEqual(resolve("mailto:someone@example.com"), .mail(URL(string: "mailto:someone@example.com")!))
        XCTAssertNil(resolve("ssh://host/x"))
        XCTAssertNil(resolve("ftp://host/x"))
    }

    func testPaths() {
        XCTAssertEqual(resolve("/etc/hosts"), .file(path: "/etc/hosts", line: nil, column: nil))
        XCTAssertEqual(resolve("~/notes.md"), .file(path: "/home/u/notes.md", line: nil, column: nil))
        XCTAssertEqual(resolve("Sources/a.swift:42"), .file(path: "/home/u/proj/Sources/a.swift", line: 42, column: nil))
        XCTAssertEqual(resolve("./Sources/a.swift:42:7"), .file(path: "/home/u/proj/Sources/a.swift", line: 42, column: 7))
        XCTAssertEqual(resolve("Sources/a.swift(12,3)"), .file(path: "/home/u/proj/Sources/a.swift", line: 12, column: 3))
        XCTAssertEqual(resolve("Sources/a.swift:42:"), .file(path: "/home/u/proj/Sources/a.swift", line: 42, column: nil))
        XCTAssertEqual(resolve("../other/b.txt"), .file(path: "/home/u/other/b.txt", line: nil, column: nil))
        XCTAssertEqual(resolve("Sources"), .folder(path: "/home/u/proj/Sources"))
        XCTAssertEqual(resolve("file:///etc/hosts"), .file(path: "/etc/hosts", line: nil, column: nil))
        XCTAssertEqual(resolve("~/My Docs/c.md"), .file(path: "/home/u/My Docs/c.md", line: nil, column: nil))
        XCTAssertNil(resolve("Sources/missing.swift"))
        XCTAssertNil(resolve("and/or"))
    }

    func testFoldersThatActWhenOpened() {
        // an app bundle or a playground resolves as a folder, but a click must not launch it
        XCTAssertTrue(TerminalLinks.folderActsWhenOpened("/Applications/X.app", isPackage: false))
        XCTAssertTrue(TerminalLinks.folderActsWhenOpened("/home/u/Try.playground", isPackage: false))
        XCTAssertTrue(TerminalLinks.folderActsWhenOpened("/home/u/Some.thing", isPackage: true))
        XCTAssertTrue(TerminalLinks.folderActsWhenOpened("/home/u/Y.APP", isPackage: false))
        XCTAssertFalse(TerminalLinks.folderActsWhenOpened("/home/u/proj/Sources", isPackage: false))
        XCTAssertFalse(TerminalLinks.folderActsWhenOpened("/home/u/v1.2", isPackage: false))
    }

    func testFilesThatActWhenOpenedAreRunnable() {
        for ext in ["dmg", "iso", "img", "cdr", "sparseimage", "jnlp", "action", "mobileconfig", "xip", "zip", "app",
                    "afploc", "ftploc", "vncloc", "mailloc", "wflow", "rdp", "download", "tcl", "tbz", "zst"] {
            XCTAssertTrue(TerminalLinks.runnableSuffixes.contains(ext), ext)
        }
        XCTAssertFalse(TerminalLinks.runnableSuffixes.contains("md"))
        XCTAssertFalse(TerminalLinks.runnableSuffixes.contains("swift"))
    }

    func testBasesInOrder() {
        // the shell sits in other/, Claude in proj/: a path that only exists under proj still opens
        XCTAssertEqual(resolve("README.md", bases: ["/home/u/other", "/home/u/proj"]),
                       .file(path: "/home/u/proj/README.md", line: nil, column: nil))
        XCTAssertEqual(resolve("b.txt", bases: ["/home/u/other", "/home/u/proj"]),
                       .file(path: "/home/u/other/b.txt", line: nil, column: nil))
        XCTAssertNil(resolve("README.md", bases: ["relative/base"]))
    }

    func testSplitLocation() {
        XCTAssertTrue(TerminalLinks.splitLocation("a.swift:1:2") == ("a.swift", 1, 2))
        XCTAssertTrue(TerminalLinks.splitLocation("a.swift") == ("a.swift", nil, nil))
        XCTAssertTrue(TerminalLinks.splitLocation("src/a.ts#L9") == ("src/a.ts", 9, nil))
        XCTAssertTrue(TerminalLinks.splitLocation("f(x)") == ("f(x)", nil, nil))
        XCTAssertTrue(TerminalLinks.splitLocation("a:b") == ("a:b", nil, nil))
    }

    func texts(_ line: String) -> [String] { TerminalLinks.find(in: line).map(\.text) }

    func testFind() {
        XCTAssertEqual(texts("see https://example.com/a, then (https://en.wikipedia.org/wiki/Rust_(game))."),
                       ["https://example.com/a", "https://en.wikipedia.org/wiki/Rust_(game)"])
        XCTAssertEqual(texts("[docs](https://example.com/docs) and <http://localhost:3000/>"),
                       ["https://example.com/docs", "http://localhost:3000/"])
        XCTAssertEqual(texts("error: Sources/a.swift:42:7: missing return"), ["Sources/a.swift:42:7"])
        XCTAssertEqual(texts("edit ~/notes.md and ./run.sh or ../x/y, README.md."),
                       ["~/notes.md", "./run.sh", "../x/y", "README.md"])
        XCTAssertEqual(texts("\"/etc/hosts\" 'a/b'"), ["/etc/hosts", "a/b"])
        XCTAssertEqual(texts("version 1.2 or v2.0 and so on"), [])
        XCTAssertEqual(texts("mail mailto:someone@example.com"), ["mailto:someone@example.com"])
    }

    func testFindCells() {
        let f = TerminalLinks.find(in: "ab README.md")
        XCTAssertEqual(f, [.init(text: "README.md", start: 3, end: 12)])
        // a wide character before the link shifts it by two cells
        XCTAssertEqual(TerminalLinks.find(in: "日 a.md").first?.start, 3)
    }

    func testRowsWrap() {
        // 10 columns: "x /home/u/proj/README.md" wraps over three rows
        let rows = ["x /home/u/", "proj/READM", "E.md      ", "next.md   "]
        let placed = TerminalLinks.find(rows: rows, columns: 10)
        XCTAssertEqual(placed.map(\.text), ["/home/u/proj/README.md", "next.md"])
        XCTAssertEqual(placed[0].row, 0)
        XCTAssertEqual(placed[0].column, 2)
        XCTAssertEqual(placed[0].endRow, 2)
        XCTAssertEqual(placed[0].endColumn, 3)
        XCTAssertEqual(placed[1].row, 3)
        XCTAssertEqual(TerminalLinks.link(at: 1, column: 5, rows: rows, columns: 10)?.text, "/home/u/proj/README.md")
        XCTAssertEqual(TerminalLinks.link(at: 3, column: 2, rows: rows, columns: 10)?.text, "next.md")
        XCTAssertNil(TerminalLinks.link(at: 3, column: 8, rows: rows, columns: 10))
    }

    func testDisplay() {
        XCTAssertEqual(TerminalLinks.Target.file(path: "/home/u/a.swift", line: 3, column: 4).display(home: "/home/u"), "~/a.swift:3:4")
        XCTAssertEqual(TerminalLinks.Target.folder(path: "/home/u").display(home: "/home/u"), "~/")
        XCTAssertEqual(TerminalLinks.Target.file(path: "/x", line: nil, column: 4).display(home: "/home/u"), "/x")
    }

    func testEditorURL() {
        XCTAssertEqual(TerminalLinks.editorURL(bundleID: "com.microsoft.VSCode", path: "/a b/c.swift", line: 4, column: 2)?.absoluteString,
                       "vscode://file/a%20b/c.swift:4:2")
        XCTAssertEqual(TerminalLinks.editorURL(bundleID: "dev.zed.Zed", path: "/c.swift", line: nil, column: nil)?.absoluteString,
                       "zed://file/c.swift")
        XCTAssertNil(TerminalLinks.editorURL(bundleID: "com.apple.TextEdit", path: "/c", line: 1, column: nil))
    }
}
