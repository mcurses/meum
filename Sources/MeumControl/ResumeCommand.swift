// Builds the shell command that resumes a Claude Code session after a reboot.
import Foundation

/// The fields of the app's `AgentSnapshot` that matter for resuming. Decodes from the snapshot JSON
/// (`sessionID`, `configDir`, `projectDir`, `cwd`), and from a whole tab JSON that carries it under `agent`.
public struct ResumeInfo: Equatable, Sendable {
    public var sessionID: String
    public var configDir: String?
    /// Where the session was last seen (follows the agent's `cd`). Used only when `projectDir` is unknown.
    public var cwd: String?
    /// The folder the session was started in. Claude Code finds a session by this folder, so it resumes here.
    public var projectDir: String?

    public init(sessionID: String, configDir: String? = nil, cwd: String? = nil, projectDir: String? = nil) {
        self.sessionID = sessionID
        self.configDir = configDir
        self.cwd = cwd
        self.projectDir = projectDir
    }

    /// The folder to resume in: the project folder, else the last known one.
    public var directory: String? {
        if let d = projectDir, !d.isEmpty { return d }
        if let c = cwd, !c.isEmpty { return c }
        return nil
    }

    public init?(json: JSON) {
        let o = (json["agent"]?.objectValue != nil) ? json["agent"]! : json
        guard let sid = (o["sessionID"] ?? o["session_id"])?.stringValue, !sid.isEmpty else { return nil }
        sessionID = sid
        configDir = (o["configDir"] ?? o["config_dir"])?.stringValue
        cwd = o["cwd"]?.stringValue
        projectDir = (o["projectDir"] ?? o["project_dir"])?.stringValue
    }
}

public enum ResumeCommand {
    /// `cd <dir> && CLAUDE_CONFIG_DIR=<dir> claude --resume <id>`, `<dir>` being `info.directory`.
    /// `CLAUDE_CONFIG_DIR=` is left out for the default dir (`~/.claude`): setting it explicitly broke
    /// login in the hooks spike. `cd` is left out when no folder is known.
    public static func build(_ info: ResumeInfo, home: String = NSHomeDirectory(), binary: String = "claude") -> String {
        var parts: [String] = []
        if let dir = info.directory { parts.append("cd \(quote(dir)) &&") }
        var cmd = ""
        if let dir = info.configDir, !dir.isEmpty, !isDefaultConfigDir(dir, home: home) {
            cmd += "CLAUDE_CONFIG_DIR=\(quote(dir)) "
        }
        cmd += "\(binary) --resume \(quote(info.sessionID))"
        parts.append(cmd)
        return parts.joined(separator: " ")
    }

    /// The line a tab shows instead of resuming when the session's transcript is gone: nothing to resume.
    public static func notFound(_ info: ResumeInfo) -> String {
        "printf '%s\\n' " + quote("meum: the Claude session \(info.sessionID) was not found, so it was not resumed.")
    }

    /// The folder a session was started in, from its transcript: the first `"cwd"` of its first lines (Claude Code
    /// writes it into every entry). For snapshots saved before meum learned `projectDir`.
    public static func transcriptCwd(path: String, maxBytes: Int = 256 * 1024) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: maxBytes) else { return nil }
        // the cut at maxBytes can split a character: decode line by line and skip what doesn't parse
        for line in data.split(separator: UInt8(ascii: "\n")).prefix(200) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty else { continue }
            return cwd
        }
        return nil
    }

    public static func isDefaultConfigDir(_ dir: String, home: String) -> Bool {
        func norm(_ s: String) -> String {
            var p = s
            if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + String(p.dropFirst(1)) }
            while p.count > 1, p.hasSuffix("/") { p.removeLast() }
            return p
        }
        return norm(dir) == norm(home + "/.claude")
    }

    /// POSIX single-quote unless the string is plainly safe.
    public static func quote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
