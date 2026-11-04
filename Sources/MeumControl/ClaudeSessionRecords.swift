// Claude Code keeps one record per running session in `<configDir>/sessions/<pid>.json` (pid, sessionId, name,
// status, kind, …). meum reads only the name from it, to show which session a tab holds.
import Foundation

public enum ClaudeSessionRecords {
    /// The name Claude Code gives the session `sessionID` (e.g. `meum-05`), or nil when no record for it exists or
    /// the record has no name. `configDir` nil or "" means the default `~/.claude`.
    public static func name(sessionID: String, configDir: String?, home: String = NSHomeDirectory()) -> String? {
        guard !sessionID.isEmpty else { return nil }
        let dir = configDir.flatMap { $0.isEmpty ? nil : $0 } ?? (home as NSString).appendingPathComponent(".claude")
        let sessions = (dir as NSString).appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: sessions) else { return nil }
        // a record's file is a few hundred bytes; skip the matching `.key` files and anything large
        let needle = Data(sessionID.utf8)
        for f in files where f.hasSuffix(".json") {
            let path = (sessions as NSString).appendingPathComponent(f)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int, size < 64 * 1024,
                  let data = FileManager.default.contents(atPath: path), data.range(of: needle) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["sessionId"] as? String == sessionID else { continue }
            let name = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return name?.isEmpty == false ? name : nil
        }
        return nil
    }
}
