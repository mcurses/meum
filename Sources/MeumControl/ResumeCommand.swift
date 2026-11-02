// Builds the shell command that resumes a Claude Code session after a reboot.
import Foundation

/// The fields of the app's `AgentSnapshot` that matter for resuming. Decodes from the snapshot JSON
/// (`sessionID`, `configDir`, `cwd`), and from a whole tab JSON that carries it under `agent`.
public struct ResumeInfo: Equatable, Sendable {
    public var sessionID: String
    public var configDir: String?
    public var cwd: String?

    public init(sessionID: String, configDir: String? = nil, cwd: String? = nil) {
        self.sessionID = sessionID
        self.configDir = configDir
        self.cwd = cwd
    }

    public init?(json: JSON) {
        let o = (json["agent"]?.objectValue != nil) ? json["agent"]! : json
        guard let sid = (o["sessionID"] ?? o["session_id"])?.stringValue, !sid.isEmpty else { return nil }
        sessionID = sid
        configDir = (o["configDir"] ?? o["config_dir"])?.stringValue
        cwd = o["cwd"]?.stringValue
    }
}

public enum ResumeCommand {
    /// `cd <cwd> && CLAUDE_CONFIG_DIR=<dir> claude --resume <id>`.
    /// `CLAUDE_CONFIG_DIR=` is left out for the default dir (`~/.claude`): setting it explicitly broke
    /// login in the hooks spike. `cd` is left out when there is no cwd.
    public static func build(_ info: ResumeInfo, home: String = NSHomeDirectory(), binary: String = "claude") -> String {
        var parts: [String] = []
        if let cwd = info.cwd, !cwd.isEmpty { parts.append("cd \(quote(cwd)) &&") }
        var cmd = ""
        if let dir = info.configDir, !dir.isEmpty, !isDefaultConfigDir(dir, home: home) {
            cmd += "CLAUDE_CONFIG_DIR=\(quote(dir)) "
        }
        cmd += "\(binary) --resume \(quote(info.sessionID))"
        parts.append(cmd)
        return parts.joined(separator: " ")
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
