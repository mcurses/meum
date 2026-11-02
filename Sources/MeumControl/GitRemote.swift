// The origin remote of the repository a directory belongs to, read from the repository's config file (no git
// process), with credentials stripped. Widgets and tools use it to match a workspace to a project.
import Foundation

public enum GitRemote {
    /// `remote "origin"`'s url (else the first remote's), nil outside a repository or without remotes.
    public static func origin(at dir: String, fileManager fm: FileManager = .default) -> String? {
        guard let config = configFile(at: dir, fileManager: fm),
              let text = try? String(contentsOf: config, encoding: .utf8) else { return nil }
        return parse(config: text).map(stripCredentials)
    }

    /// The repository's `config`: `.git/config`, or for a worktree or submodule (`.git` is a file) the config of the
    /// directory it points to, following `commondir` for worktrees.
    static func configFile(at dir: String, fileManager fm: FileManager) -> URL? {
        var url = URL(fileURLWithPath: dir).standardizedFileURL
        for _ in 0..<64 {
            let dotgit = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotgit.path, isDirectory: &isDir) {
                var gitDir = dotgit
                if !isDir.boolValue {
                    guard let s = try? String(contentsOf: dotgit, encoding: .utf8),
                          let line = s.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                    let p = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = p.hasPrefix("/") ? URL(fileURLWithPath: p) : url.appendingPathComponent(p)
                }
                let common = gitDir.appendingPathComponent("commondir")
                if let c = try? String(contentsOf: common, encoding: .utf8) {
                    let p = c.trimmingCharacters(in: .whitespacesAndNewlines)
                    gitDir = p.hasPrefix("/") ? URL(fileURLWithPath: p) : gitDir.appendingPathComponent(p).standardizedFileURL
                }
                return gitDir.appendingPathComponent("config")
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
    }

    /// The url of `[remote "origin"]`, else of the first remote section.
    public static func parse(config: String) -> String? {
        var section: String?
        var urls: [(String, String)] = []
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                // [remote "origin"]
                let inner = line.dropFirst().prefix { $0 != "]" }
                let parts = inner.split(separator: " ", maxSplits: 1)
                if parts.first == "remote", parts.count == 2 {
                    section = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                } else {
                    section = nil
                }
                continue
            }
            guard let name = section, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0].lowercased() == "url", !kv[1].isEmpty { urls.append((name, kv[1])) }
        }
        return urls.first(where: { $0.0 == "origin" })?.1 ?? urls.first?.1
    }

    /// `https://user:token@host/x` -> `https://host/x`. scp-like `git@host:x` keeps its user (no secret there).
    public static func stripCredentials(_ url: String) -> String {
        guard url.contains("://"), var c = URLComponents(string: url), c.user != nil || c.password != nil else { return url }
        c.user = nil
        c.password = nil
        return c.string ?? url
    }
}
