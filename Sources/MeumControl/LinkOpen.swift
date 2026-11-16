// The decision behind `meum://open?path=<absolute path>`: may this file be opened in its default app?
// Pure (file system reads only); the app calls it, then NSWorkspace.
import Foundation

public enum LinkOpen {
    public static let defaultSuffixes = ["md", "txt", "pdf"]

    /// Suffixes as stored: lowercased, no dots, no blanks, no duplicates; split at commas and whitespace.
    public static func normalizedSuffixes(_ text: String) -> [String] {
        var out: [String] = []
        for part in text.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            var s = part.lowercased()
            while s.hasPrefix(".") { s.removeFirst() }
            if !s.isEmpty, !s.contains("/"), !out.contains(s) { out.append(s) }
        }
        return out
    }

    /// The `path` query item of a meum://open link, or why there is none.
    public static func path(of url: URL) -> Result<String, Refusal> {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let p = items.first(where: { $0.name == "path" })?.value, !p.isEmpty else {
            return .failure(Refusal("no path given"))
        }
        return .success(p)
    }

    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let description: String
        init(_ d: String) { description = d }
    }

    /// The resolved file to open, or the reason it is refused.
    public static func check(path: String, folders: [String], suffixes: [String]) -> Result<URL, Refusal> {
        guard path.hasPrefix("/") else { return .failure(Refusal("the path is not absolute")) }
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) else {
            return .failure(Refusal("no such file"))
        }
        guard !isDir.boolValue,
              (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            return .failure(Refusal("not a regular file"))
        }
        let parts = file.pathComponents
        let inside = folders.contains { f in
            guard f.hasPrefix("/") else { return false }
            let dir = URL(fileURLWithPath: f).resolvingSymlinksInPath().pathComponents
            return parts.count > dir.count && Array(parts.prefix(dir.count)) == dir
        }
        guard inside else { return .failure(Refusal("the file is not under a folder that links may open")) }
        let ext = file.pathExtension.lowercased()
        guard !ext.isEmpty, suffixes.map({ $0.lowercased() }).contains(ext) else {
            return .failure(Refusal("the suffix '\(ext)' is not allowed"))
        }
        return .success(file)
    }

    /// Same, for the link itself.
    public static func check(url: URL, folders: [String], suffixes: [String]) -> Result<URL, Refusal> {
        switch path(of: url) {
        case .failure(let r): return .failure(r)
        case .success(let p): return check(path: p, folders: folders, suffixes: suffixes)
        }
    }
}
