// Links in terminal output: what a ⌘-click, the link menu, the hover line and the keyboard hints act on. Pure
// except for the file-existence probe, which callers pass in (tests use a fake file system).
import Foundation

public enum TerminalLinks {
    /// What a piece of terminal text points at.
    public enum Target: Equatable, Sendable {
        /// http(s): a page; `local` when it is served from this machine (a dev server).
        case web(URL, local: Bool)
        /// mailto:
        case mail(URL)
        /// An existing file, maybe with a line and column (`Sources/a.swift:42:7`).
        case file(path: String, line: Int?, column: Int?)
        case folder(path: String)

        public var isLocalWeb: Bool { if case .web(_, true) = self { return true } else { return false } }

        /// What the hover line and the link menu show: the URL, or the path with `~` for the home folder.
        public func display(home: String = NSHomeDirectory()) -> String {
            func short(_ p: String) -> String {
                p == home ? "~" : p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
            }
            switch self {
            case .web(let u, _), .mail(let u): return u.absoluteString
            case .folder(let p): return short(p) + "/"
            case .file(let p, let l, let c):
                return short(p) + (l.map { ":\($0)" } ?? "") + (l != nil ? c.map { ":\($0)" } ?? "" : "")
            }
        }
    }

    /// A link candidate in one line of text: `start..<end` in terminal cells (a wide character takes two).
    public struct Found: Equatable, Sendable {
        public let text: String
        public let start: Int
        public let end: Int
        public init(text: String, start: Int, end: Int) { self.text = text; self.start = start; self.end = end }
    }

    // MARK: - Resolving

    /// Whether a path exists, and whether it is a folder (nil: it does not exist).
    public typealias Probe = (String) -> Bool?

    public static let fileSystem: Probe = { path in
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) ? dir.boolValue : nil
    }

    /// The target of `raw` (ghostty's link text, a found candidate, an OSC 8 URI), or nil when it points at
    /// nothing meum opens: a scheme other than http, https, mailto and file, or a path that does not exist.
    /// A relative path is tried against each of `bases` in order (the shell's folder, then Claude's).
    public static func resolve(_ raw: String, bases: [String], home: String = NSHomeDirectory(),
                               exists: Probe = fileSystem) -> Target? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let u = URL(string: s), u.host != nil else { return nil }
            return .web(u, local: isLocal(u))
        }
        if lower.hasPrefix("mailto:") { return URL(string: s).map { .mail($0) } }
        var path = s
        if lower.hasPrefix("file:") {
            guard let u = URL(string: s), u.isFileURL else { return nil }
            path = u.path
        } else if hasScheme(s) {
            return nil
        }
        let loc = splitLocation(path)
        guard let (abs, isDir) = locate(loc.path, bases: bases, home: home, exists: exists) else { return nil }
        return isDir ? .folder(path: abs) : .file(path: abs, line: loc.line, column: loc.column)
    }

    /// `scheme://…` or a known `scheme:` link; a `file.swift:42` location is not a scheme.
    static func hasScheme(_ s: String) -> Bool {
        guard let colon = s.firstIndex(of: ":") else { return false }
        let scheme = s[..<colon]
        guard let first = scheme.first, first.isLetter,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else { return false }
        let rest = s[s.index(after: colon)...]
        return rest.hasPrefix("//") || ["tel", "news", "magnet", "ssh", "ftp"].contains(scheme.lowercased())
    }

    /// A path with a trailing location split off: `a.swift:42`, `a.swift:42:7`, `a.swift(42,7)`, `a.swift:42:`.
    public static func splitLocation(_ text: String) -> (path: String, line: Int?, column: Int?) {
        var s = Substring(text)
        while s.last == ":" { s = s.dropLast() }
        // a.swift(42,7) / a.swift(42)
        if s.last == ")", let open = s.lastIndex(of: "(") {
            let nums = s[s.index(after: open)..<s.index(before: s.endIndex)].split(separator: ",")
            if (1...2).contains(nums.count), let l = Int(nums[0].trimmingCharacters(in: .whitespaces)) {
                let c = nums.count == 2 ? Int(nums[1].trimmingCharacters(in: .whitespaces)) : nil
                if nums.count == 1 || c != nil { return (String(s[..<open]), l, c) }
            }
        }
        var numbers: [Int] = []
        while numbers.count < 2, let colon = s.lastIndex(of: ":") {
            let tail = s[s.index(after: colon)...]
            guard !tail.isEmpty, tail.allSatisfy(\.isASCII), let n = Int(tail) else { break }
            numbers.insert(n, at: 0)
            s = s[..<colon]
        }
        // `#L42` from a code host link copied as a path
        if numbers.isEmpty, let hash = s.lastIndex(of: "#"), s[s.index(after: hash)...].hasPrefix("L"),
           let n = Int(s[s.index(hash, offsetBy: 2)...]) {
            return (String(s[..<hash]), n, nil)
        }
        guard !s.isEmpty else { return (text, nil, nil) }
        return (String(s), numbers.first, numbers.count > 1 ? numbers[1] : nil)
    }

    /// The absolute, standardized path `p` names and whether it is a folder; nil when nothing is there.
    static func locate(_ p: String, bases: [String], home: String, exists: Probe) -> (String, Bool)? {
        var p = p
        if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
        else if p.hasPrefix("$HOME/") { p = home + p.dropFirst(5) }
        let candidates: [String]
        if p.hasPrefix("/") {
            candidates = [p]
        } else {
            var seen = Set<String>()
            candidates = bases.filter { $0.hasPrefix("/") && seen.insert($0).inserted }.map { $0 + "/" + p }
        }
        for c in candidates {
            let std = (c as NSString).standardizingPath
            if let dir = exists(std) { return (std, dir) }
        }
        return nil
    }

    /// Served from this machine: localhost, *.localhost, a loopback or unspecified address.
    public static func isLocal(_ url: URL) -> Bool {
        guard let h = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return false }
        return h == "localhost" || h.hasSuffix(".localhost") || h == "0.0.0.0" || h == "::1" || h == "::"
            || isLoopbackIPv4(h)
    }

    /// 127.x.y.z with four numbers 0-255; a name such as `127.example.com` is not loopback.
    static func isLoopbackIPv4(_ h: String) -> Bool {
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127"
            && parts.allSatisfy { !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) && Int($0)! <= 255 }
    }

    /// Suffixes of files and bundles that run, install or act when opened: a click shows them in Finder instead.
    public static let runnableSuffixes: Set<String> = [
        "app", "command", "tool", "terminal", "pkg", "mpkg", "dmg", "webloc", "inetloc", "fileloc", "url", "workflow",
        "scpt", "scptd", "applescript", "prefpane", "saver", "kext", "plugin", "shortcut", "jar", "sh", "zsh", "bash",
        "fish", "py", "rb", "pl", "playground", "xcodeproj", "xcworkspace", "bundle", "framework", "appex", "qlgenerator",
        "mdimporter", "service", "wdgt", "mailbundle", "photoslibrary", "musiclibrary", "fcpbundle",
        // disk images, archives and installers mount, unpack or install on open
        "iso", "img", "cdr", "sparseimage", "sparsebundle", "dmgpart", "jnlp", "action", "mobileconfig",
        "mobileprovision", "provisionprofile", "xip", "zip", "tar", "tgz", "gz", "bz2", "xz", "7z", "rar", "cpio",
        "aar", "safariextz", "itermcolors", "configprofile",
        // location files connect to a server; workflows, remote desktops and scripts act too
        "afploc", "ftploc", "vncloc", "mailloc", "smbloc", "nntploc", "atloc", "wflow", "rdp", "download", "tcl",
        "tbz", "tbz2", "txz", "lz", "lzma", "zst", "z", "lha", "lzh", "sit", "sitx", "cab", "arj", "pax", "xar",
        "pkpass", "systemextension", "dext", "installer", "osax", "component", "vst", "vst3", "au",
    ]

    /// Terminal apps: as the app a text file opens in they would run it, not show it.
    public static let terminalApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "io.github.mcurses.meum",
        "net.kovidgoyal.kitty", "dev.warp.Warp-Stable", "org.alacritty", "com.github.wez.wezterm",
    ]

    /// Whether opening the folder at `path` would launch or act rather than show its contents: a package
    /// (`X.app`, a `.playground`) or a folder with a runnable suffix. Such a folder is shown in Finder.
    public static func folderActsWhenOpened(_ path: String, isPackage: Bool) -> Bool {
        isPackage || runnableSuffixes.contains((path as NSString).pathExtension.lowercased())
    }

    // MARK: - Finding

    /// Link candidates in one line, left to right: scheme URLs anywhere, and words that look like paths
    /// (`/abs`, `~/x`, `./x`, `../x`, `dir/x`, `name.ext`, each with an optional `:line:col`). Callers keep the
    /// ones `resolve` accepts, so a word that only looks like a path (`and/or`) drops out there.
    public static func find(in line: String) -> [Found] {
        var out: [Found] = []
        var cell = 0
        var word: [Character] = []
        var wordStart = 0
        func flush() {
            defer { word = [] }
            guard !word.isEmpty else { return }
            out.append(contentsOf: candidates(in: word, startCell: wordStart))
        }
        for ch in line {
            if ch.isWhitespace || "\"'`<>|".contains(ch) {
                flush()
                cell += cellWidth(ch)
                wordStart = cell
            } else {
                if word.isEmpty { wordStart = cell }
                word.append(ch)
                cell += cellWidth(ch)
            }
        }
        flush()
        return out
    }

    /// The candidate inside one whitespace-free word, trimmed of brackets and sentence punctuation.
    static func candidates(in word: [Character], startCell: Int) -> [Found] {
        let widths = word.map(cellWidth)
        func cells(_ r: Range<Int>) -> Range<Int> {
            let s = startCell + widths[..<r.lowerBound].reduce(0, +)
            return s..<(s + widths[r].reduce(0, +))
        }
        var lo = 0, hi = word.count
        // a URL inside markup: [title](https://…), <https://…>, href=https://…
        let text = String(word).lowercased()
        var isURL = false
        for scheme in ["https://", "http://", "file://", "mailto:"] {
            if let r = text.range(of: scheme) {
                lo = text.distance(from: text.startIndex, to: r.lowerBound)
                isURL = true
                break
            }
        }
        if !isURL {
            while lo < hi, "([{".contains(word[lo]) { lo += 1 }
        }
        // trailing punctuation, and closing brackets that have no opening one inside the link
        while hi > lo {
            let c = word[hi - 1]
            if ".,;:!?".contains(c) { hi -= 1; continue }
            if let open = ["]": "[", ")": "(", "}": "{"][String(c)] {
                let inner = word[lo..<(hi - 1)]
                let opens = inner.filter { String($0) == open }.count
                let closes = inner.filter { $0 == c }.count
                if opens <= closes { hi -= 1; continue }
            }
            break
        }
        guard hi > lo else { return [] }
        let t = String(word[lo..<hi])
        if !isURL && !looksLikePath(t) { return [] }
        let r = cells(lo..<hi)
        return [Found(text: t, start: r.lowerBound, end: r.upperBound)]
    }

    static func looksLikePath(_ t: String) -> Bool {
        if t.hasPrefix("/") || t.hasPrefix("~/") || t.hasPrefix("./") || t.hasPrefix("../") || t == "~" { return true }
        if hasScheme(t) { return false }
        let p = splitLocation(t).path
        if p.contains("/") { return !p.hasPrefix("//") }
        // a bare file name with an extension: README.md, main.swift:12
        guard let dot = p.lastIndex(of: "."), dot != p.startIndex else { return false }
        let ext = p[p.index(after: dot)...]
        return (1...10).contains(ext.count) && ext.allSatisfy({ $0.isLetter || $0.isNumber })
            && ext.contains(where: \.isLetter)
    }

    /// Terminal cells a character takes: two for East Asian wide characters and emoji, else one.
    public static func cellWidth(_ c: Character) -> Int {
        for s in c.unicodeScalars {
            let v = s.value
            if s.properties.isEmojiPresentation { return 2 }
            if (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
                || (0xFFE0...0xFFE6).contains(v) || (0x20000...0x3FFFD).contains(v) { return 2 }
        }
        return 1
    }

    // MARK: - Screen rows

    /// A link on screen: its rows may be several when the line wrapped.
    public struct Placed: Equatable, Sendable {
        public let text: String
        /// The first cell: row and column in the viewport.
        public let row: Int
        public let column: Int
        public let endRow: Int
        public let endColumn: Int
    }

    /// Link candidates on a screen of `rows` (the viewport, one string per row, `columns` wide). A row whose text
    /// fills the width runs on into the next (the terminal wrapped it), so a long path is found whole.
    public static func find(rows: [String], columns: Int) -> [Placed] {
        guard columns > 0 else { return [] }
        var out: [Placed] = []
        var i = 0
        while i < rows.count {
            let first = i
            var text = rows[i]
            while i + 1 < rows.count, width(of: rows[i].trimmingTrailingWhitespace) >= columns {
                i += 1
                text += rows[i]
            }
            for f in find(in: text) {
                let end = max(f.start, f.end - 1)
                out.append(Placed(text: f.text, row: first + f.start / columns, column: f.start % columns,
                                  endRow: first + end / columns, endColumn: end % columns))
            }
            i += 1
        }
        return out
    }

    /// The candidate covering cell `column` of `row`, if any.
    public static func link(at row: Int, column: Int, rows: [String], columns: Int) -> Placed? {
        find(rows: rows, columns: columns).first { p in
            let start = p.row * columns + p.column, end = p.endRow * columns + p.endColumn
            let at = row * columns + column
            return at >= start && at <= end
        }
    }

    static func width(of s: Substring) -> Int { s.reduce(0) { $0 + cellWidth($1) } }

    // MARK: - Editors

    /// Editors whose URL scheme opens a file at a line, by bundle id.
    public static let lineEditors: [String: String] = [
        "com.microsoft.VSCode": "vscode",
        "com.microsoft.VSCodeInsiders": "vscode-insiders",
        "com.todesktop.230313mzl4w4u92": "cursor",
        "com.exafunction.windsurf": "windsurf",
        "com.vscodium": "vscodium",
        "dev.zed.Zed": "zed",
        "dev.zed.Zed-Preview": "zed",
    ]

    /// `vscode://file/<path>:<line>:<col>` (and the same for its forks and Zed), or nil for an editor without
    /// such a scheme.
    public static func editorURL(bundleID: String, path: String, line: Int?, column: Int?) -> URL? {
        guard let scheme = lineEditors[bundleID] else { return nil }
        var loc = ""
        if let line { loc = ":\(line)" + (column.map { ":\($0)" } ?? "") }
        let enc = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "\(scheme)://file\(enc)\(loc)")
    }
}

extension String {
    var trimmingTrailingWhitespace: Substring {
        var s = Substring(self)
        while let l = s.last, l.isWhitespace { s = s.dropLast() }
        return s
    }
}
