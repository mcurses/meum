import XCTest
@testable import MeumControl

final class GitRemoteTests: XCTestCase {
    func testParsePrefersOrigin() {
        let cfg = """
        [core]
        \tbare = false
        [remote "upstream"]
        \turl = https://github.com/other/x.git
        [remote "origin"]
        \turl = git@github.com:mcurses/meum.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [branch "main"]
        \tremote = origin
        """
        XCTAssertEqual(GitRemote.parse(config: cfg), "git@github.com:mcurses/meum.git")
        XCTAssertEqual(GitRemote.parse(config: "[remote \"gitlab\"]\n url = https://gitlab.com/a/b\n"), "https://gitlab.com/a/b")
        XCTAssertNil(GitRemote.parse(config: "[core]\n bare = false\n"))
    }

    func testStripsCredentials() {
        XCTAssertEqual(GitRemote.stripCredentials("https://max:ghp_secret@github.com/a/b.git"), "https://github.com/a/b.git")
        XCTAssertEqual(GitRemote.stripCredentials("https://github.com/a/b.git"), "https://github.com/a/b.git")
        XCTAssertEqual(GitRemote.stripCredentials("git@github.com:a/b.git"), "git@github.com:a/b.git")
    }

    func testReadsRepoAndWorktree() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("gitremote-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo"), git = repo.appendingPathComponent(".git")
        try fm.createDirectory(at: git.appendingPathComponent("worktrees/wt"), withIntermediateDirectories: true)
        try "[remote \"origin\"]\n\turl = https://u:p@example.com/r.git\n".write(to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let sub = repo.appendingPathComponent("src/deep")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertEqual(GitRemote.origin(at: sub.path), "https://example.com/r.git")
        // a worktree: .git is a file pointing at .git/worktrees/wt, whose commondir leads back to .git
        let wt = root.appendingPathComponent("wt")
        try fm.createDirectory(at: wt, withIntermediateDirectories: true)
        try "gitdir: \(git.path)/worktrees/wt\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: git.appendingPathComponent("worktrees/wt/commondir"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GitRemote.origin(at: wt.path), "https://example.com/r.git")
        XCTAssertNil(GitRemote.origin(at: fm.temporaryDirectory.path))
    }
}
