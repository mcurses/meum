import XCTest
@testable import MeumControl

/// The link checks that read real files: symlinks and aliases to app bundles must never launch them.
final class TerminalLinksFilesTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("links-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    /// A fake app bundle (a folder named .app with a Contents folder).
    func makeApp(_ name: String) throws -> URL {
        let app = root.appendingPathComponent(name)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        return app
    }

    func testSymlinkedFolderToAnAppActsLikeTheApp() throws {
        let app = try makeApp("P.app")
        let docs = root.appendingPathComponent("docs")
        try fm.createSymbolicLink(at: docs, withDestinationURL: app)
        XCTAssertTrue(TerminalLinks.folderActsWhenOpened(atPath: docs.path))
        XCTAssertTrue(TerminalLinks.folderActsWhenOpened(atPath: app.path))

        let plain = root.appendingPathComponent("plain")
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("toplain")
        try fm.createSymbolicLink(at: link, withDestinationURL: plain)
        XCTAssertFalse(TerminalLinks.folderActsWhenOpened(atPath: plain.path))
        XCTAssertFalse(TerminalLinks.folderActsWhenOpened(atPath: link.path))
    }

    func makeAlias(_ name: String, to target: URL) throws -> URL {
        let alias = root.appendingPathComponent(name)
        let data = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(data, to: alias)
        return alias
    }

    func testAliasesAreNeverOpenedAndSymlinksResolve() throws {
        let app = try makeApp("Q.app")
        let alias = try makeAlias("Q alias", to: app)
        XCTAssertNil(TerminalLinks.fileToOpen(atPath: alias.path))

        // symlink -> alias -> app: still only shown
        let chain = root.appendingPathComponent("chain")
        try fm.createSymbolicLink(at: chain, withDestinationURL: alias)
        XCTAssertNil(TerminalLinks.fileToOpen(atPath: chain.path))

        // a symlink to a text file opens that file; a symlink to an app hands back the app for the runs check
        let notes = root.appendingPathComponent("notes.md")
        try "x".write(to: notes, atomically: true, encoding: .utf8)
        let toNotes = root.appendingPathComponent("NOTES")
        try fm.createSymbolicLink(at: toNotes, withDestinationURL: notes)
        XCTAssertEqual(TerminalLinks.fileToOpen(atPath: toNotes.path), notes.path)
        XCTAssertEqual(TerminalLinks.fileToOpen(atPath: notes.path), notes.path)
        let toApp = root.appendingPathComponent("tool")
        try fm.createSymbolicLink(at: toApp, withDestinationURL: app)
        XCTAssertEqual(TerminalLinks.fileToOpen(atPath: toApp.path), app.path)
        XCTAssertTrue(TerminalLinks.runnableSuffixes.contains(URL(fileURLWithPath: app.path).pathExtension))
    }

    func testOnlyInstalledAppsAreOpeners() {
        let home = "/Users/u"
        for p in ["/Applications/Editor.app", "/Applications/Utilities/Tool.app", "/System/Applications/Preview.app",
                  "/System/Library/CoreServices/Finder.app", "/Users/u/Applications/IDE.app",
                  "/Applications/Xcode.app/Contents/Applications/Helper.app",
                  "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"] {
            XCTAssertTrue(TerminalLinks.isInstalledApp(p, home: home), p)
        }
        for p in ["/Users/u/code/repo/vendor/Preview.app", "/Users/u/Downloads/Editor.app", "/Applications.evil/X.app",
                  "/Applications/../Users/u/code/X.app", "/Volumes/Stick/Applications/X.app", "/tmp/X.app",
                  "Applications/X.app", "/Users/u/ApplicationsX/X.app", "/Applications"] {
            XCTAssertFalse(TerminalLinks.isInstalledApp(p, home: home), p)
        }
    }
}
