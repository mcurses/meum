// Installs the `meum-hook` entry into Claude Code settings.json files without disturbing anything else.
//
//  - merges into the existing "hooks" object, never replaces other hooks, keeps member order and spelling
//  - idempotent: an existing meum-hook entry is left alone (or has its command path updated in place)
//  - settings.json symlinks (e.g. ~/.claude-work pointing at ~/.claude/settings.json) are followed:
//    the real file is edited once, never replaced by a regular file
//  - every write is preceded by a timestamped backup next to the real file
//  - `plan` never touches the disk; only `apply` writes
import Foundation

public struct HookInstaller {
    public static let events = ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "SessionEnd"]
    public static let defaultHookCommand = "$HOME/.local/bin/meum-hook"
    /// Substring that marks a hook command as ours.
    public static let marker = "meum-hook"

    public var hookCommand: String
    /// Seconds Claude Code waits for the hook (meum-hook itself caps at about 1 s). nil omits the field.
    public var timeout: Int?
    public var home: String

    public init(hookCommand: String = HookInstaller.defaultHookCommand, timeout: Int? = 5, home: String = NSHomeDirectory()) {
        self.hookCommand = hookCommand
        self.timeout = timeout
        self.home = home
    }

    // MARK: targets

    public struct Target: Equatable, Sendable {
        /// The config dir as given or discovered.
        public var configDir: String
        /// Real path of the settings file (symlinks resolved); where reads and writes happen.
        public var settingsPath: String
        public var viaSymlink: Bool
        public var settingsExists: Bool
        /// Other config dirs whose settings.json is the same file.
        public var sharedWith: [String]
    }

    /// Every `~/.claude` or `~/.claude-*` directory holding a settings.json or a .credentials.json.
    public static func discoverConfigDirs(home: String = NSHomeDirectory()) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: home) else { return [] }
        var out: [String] = []
        for n in names.sorted() where n == ".claude" || n.hasPrefix(".claude-") {
            let p = home + "/" + n
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
            if fm.fileExists(atPath: p + "/settings.json") || fm.fileExists(atPath: p + "/.credentials.json") {
                out.append(p)
            }
        }
        return out
    }

    /// One target per distinct settings file; dirs that share a file are merged into `sharedWith`.
    public func targets(for dirs: [String]) -> [Target] {
        var result: [Target] = []
        for raw in dirs {
            let dir = Self.expandHome(raw, home: home)
            let link = dir + "/settings.json"
            let resolved = URL(fileURLWithPath: link).resolvingSymlinksInPath().path
            var st = stat()
            let isLink = lstat(link, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
            let exists = FileManager.default.fileExists(atPath: resolved)
            if let i = result.firstIndex(where: { $0.settingsPath == resolved }) {
                result[i].sharedWith.append(dir)
            } else {
                result.append(Target(configDir: dir, settingsPath: resolved, viaSymlink: isLink,
                                     settingsExists: exists, sharedWith: []))
            }
        }
        return result
    }

    // MARK: status

    public struct Status: Equatable, Sendable {
        public var target: Target
        public var installedEvents: [String]
        public var missingEvents: [String]
        /// Events whose meum-hook entry points at a different command than `hookCommand`.
        public var outdatedEvents: [String]
        /// Hook commands that are not ours (left untouched).
        public var foreignHooks: Int
        public var error: String?

        public var isInstalled: Bool { error == nil && missingEvents.isEmpty }
    }

    public func status(of target: Target) -> Status {
        var st = Status(target: target, installedEvents: [], missingEvents: Self.events, outdatedEvents: [], foreignHooks: 0, error: nil)
        guard target.settingsExists else { return st }
        do {
            let root = try Self.load(target.settingsPath).root
            guard case .object = root else { throw InstallError.badShape("top level is not an object") }
            let hooks = root.member("hooks")
            if let hooks, hooks.objectMembers == nil { throw InstallError.badShape("'hooks' is not an object") }
            st.installedEvents = []
            st.missingEvents = []
            for e in Self.events {
                var ours = 0, outdated = false
                for g in try Self.groups(hooks?.member(e), event: e) {
                    for h in g.member("hooks")?.arrayItems ?? [] {
                        if Self.isOurs(h) {
                            ours += 1
                            if h.member("command")?.stringValue != hookCommand { outdated = true }
                        }
                    }
                }
                if ours > 0 { st.installedEvents.append(e) } else { st.missingEvents.append(e) }
                if outdated { st.outdatedEvents.append(e) }
            }
            for (name, v) in (hooks?.objectMembers ?? []).map({ ($0.key, $0.value) }) {
                for g in v.arrayItems ?? [] {
                    for h in g.member("hooks")?.arrayItems ?? [] where !Self.isOurs(h) { st.foreignHooks += 1; _ = name }
                }
            }
        } catch {
            st.error = "\(error)"
        }
        return st
    }

    // MARK: plan and apply

    public enum Action: String, Sendable { case install, uninstall }

    public struct Plan: Equatable, Sendable {
        public var target: Target
        public var action: Action
        public var oldText: String?
        public var newText: String?
        /// Unified diff of settings.json; empty when nothing changes.
        public var diff: String
        public var notes: [String]
        public var error: String?
        public var changed: Bool { error == nil && newText != nil && newText != oldText }
    }

    public func plan(_ action: Action, target: Target) -> Plan {
        var plan = Plan(target: target, action: action, oldText: nil, newText: nil, diff: "", notes: [], error: nil)
        do {
            if target.viaSymlink, !target.settingsExists {
                throw InstallError.badShape("settings.json is a dangling symlink")
            }
            var root: OJ
            var indent = "  "
            var trailingNewline = true
            if target.settingsExists {
                let loaded = try Self.load(target.settingsPath)
                plan.oldText = loaded.text
                root = loaded.root
                indent = loaded.indent
                trailingNewline = loaded.trailingNewline
                if OJWriter.write(root, indent: indent) + (trailingNewline ? "\n" : "") != loaded.text {
                    plan.notes.append("settings.json is not in canonical JSON layout; the whole file will be re-laid-out (content unchanged)")
                }
            } else {
                if action == .uninstall { return plan }  // nothing to do
                root = .object([])
                plan.notes.append("settings.json does not exist; it will be created")
            }
            guard case .object(var members) = root else { throw InstallError.badShape("top level is not an object") }

            var hooksIdx = members.firstIndex { $0.key == "hooks" }
            var hooks: [OMember] = []
            if let i = hooksIdx {
                guard let h = members[i].value.objectMembers else { throw InstallError.badShape("'hooks' is not an object") }
                hooks = h
            }
            var removedAny = false
            switch action {
            case .install: try installInto(&hooks)
            case .uninstall: removedAny = try uninstallFrom(&hooks)
            }

            if action == .uninstall {
                if !removedAny { return plan }
                if hooks.isEmpty, let i = hooksIdx { members.remove(at: i); hooksIdx = nil }
                else if let i = hooksIdx { members[i].value = .object(hooks) }
            } else if let i = hooksIdx {
                members[i].value = .object(hooks)
            } else {
                members.append(OMember("hooks", .object(hooks)))
            }
            root = .object(members)
            var text = OJWriter.write(root, indent: indent)
            if trailingNewline { text += "\n" }
            plan.newText = text
            plan.diff = TextDiff.unified(old: plan.oldText ?? "", new: text,
                                         oldLabel: target.settingsPath, newLabel: target.settingsPath + " (planned)")
        } catch {
            plan.error = "\(error)"
        }
        return plan
    }

    public struct ApplyResult: Equatable, Sendable {
        public var wrote: Bool
        public var backupPath: String?
    }

    /// Writes the planned text atomically after copying the current file to `settings.json.bak-<timestamp>`.
    @discardableResult
    public func apply(_ plan: Plan, now: Date = Date()) throws -> ApplyResult {
        if let e = plan.error { throw InstallError.badShape(e) }
        guard plan.changed, let newText = plan.newText else { return ApplyResult(wrote: false, backupPath: nil) }
        let path = plan.target.settingsPath
        let fm = FileManager.default

        var backup: String?
        var perms: NSNumber = 0o644
        if fm.fileExists(atPath: path) {
            let current = try String(contentsOfFile: path, encoding: .utf8)
            guard current == plan.oldText else {
                throw InstallError.changedUnderneath(path)
            }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            var b = path + ".bak-" + f.string(from: now)
            var n = 1
            while fm.fileExists(atPath: b) { b = path + ".bak-" + f.string(from: now) + "-\(n)"; n += 1 }
            try fm.copyItem(atPath: path, toPath: b)
            backup = b
            if let a = try? fm.attributesOfItem(atPath: path), let p = a[.posixPermissions] as? NSNumber { perms = p }
        } else {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
        }
        let tmp = path + ".meum-tmp-\(getpid())"
        try newText.write(toFile: tmp, atomically: false, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp)
        if rename(tmp, path) != 0 {
            let e = String(cString: strerror(errno))
            try? fm.removeItem(atPath: tmp)
            throw InstallError.badShape("rename failed: \(e)")
        }
        return ApplyResult(wrote: true, backupPath: backup)
    }

    // MARK: script placement

    /// Where `hookCommand` points, when it is a plain path (optionally starting with $HOME or ~).
    public var scriptDestination: String? {
        let c = hookCommand.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty, !c.contains(" "), !c.contains("\"") else { return nil }
        let p = Self.expandHome(c, home: home)
        return p.hasPrefix("/") ? p : nil
    }

    /// The hook script shipped next to a `meum` executable (the app bundle's Resources/bin), if it is there.
    public static func bundledScript(nextTo executable: String?) -> String? {
        guard let executable, !executable.isEmpty else { return nil }
        let p = URL(fileURLWithPath: executable).resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent("meum-hook").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// Copies `source` to the hook command path when the file there is missing or differs (an older meum's copy).
    /// Returns whether it wrote.
    @discardableResult
    public func refreshScript(from source: String) throws -> Bool {
        guard let dest = scriptDestination else { return false }
        let fm = FileManager.default
        if let have = fm.contents(atPath: dest), have == fm.contents(atPath: source), fm.isExecutableFile(atPath: dest) {
            return false
        }
        _ = try installScript(from: source)
        return true
    }

    /// The hook script the settings point at, compared with this meum's own copy.
    public enum ScriptState: String, Sendable {
        case current          // the same bytes as `source`, executable
        case differs          // another meum's copy (or edited): `meum hooks install --yes` replaces it
        case missing          // nothing there: the hooks run nothing, so meum hears nothing
        case notExecutable = "not-executable"
        case unchecked        // no own copy to compare with, or a hook command that isn't a file path
    }

    public func scriptState(comparedTo source: String?) -> ScriptState {
        guard let dest = scriptDestination else { return .unchecked }
        let fm = FileManager.default
        guard let have = fm.contents(atPath: dest) else { return .missing }
        guard fm.isExecutableFile(atPath: dest) else { return .notExecutable }
        guard let source, let want = fm.contents(atPath: source) else { return .unchecked }
        return have == want ? .current : .differs
    }

    /// Whether any discovered config dir has meum's hooks (fully or partly).
    public func anyInstalled() -> Bool {
        targets(for: Self.discoverConfigDirs(home: home)).contains { !status(of: $0).installedEvents.isEmpty }
    }

    /// Copies `source` to the hook command path with mode 0755 (creating the directory).
    public func installScript(from source: String) throws -> String {
        guard let dest = scriptDestination else {
            throw InstallError.badShape("hook command '\(hookCommand)' is not a plain path; cannot place the script")
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: source) else { throw InstallError.badShape("script not found: \(source)") }
        try fm.createDirectory(atPath: (dest as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = try Data(contentsOf: URL(fileURLWithPath: source))
        let tmp = dest + ".meum-tmp-\(getpid())"
        try data.write(to: URL(fileURLWithPath: tmp))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp)
        if rename(tmp, dest) != 0 { throw InstallError.badShape("rename failed: \(String(cString: strerror(errno)))") }
        return dest
    }

    // MARK: JSON surgery

    public enum InstallError: Error, CustomStringConvertible {
        case badShape(String)
        case changedUnderneath(String)
        public var description: String {
            switch self {
            case .badShape(let m): return m
            case .changedUnderneath(let p): return "\(p) changed since the plan was made; re-run"
            }
        }
    }

    static func expandHome(_ p: String, home: String) -> String {
        if p == "~" || p == "$HOME" { return home }
        if p.hasPrefix("~/") { return home + String(p.dropFirst(1)) }
        if p.hasPrefix("$HOME/") { return home + String(p.dropFirst(5)) }
        return p
    }

    static func isOurs(_ hook: OJ) -> Bool {
        hook.member("command")?.stringValue?.contains(marker) == true
    }

    /// The matcher groups of one event; nil means absent, anything but an array is an error.
    static func groups(_ v: OJ?, event: String) throws -> [OJ] {
        guard let v else { return [] }
        guard let a = v.arrayItems else { throw InstallError.badShape("hooks.\(event) is not an array") }
        return a
    }

    private func newGroup() -> OJ {
        var entry: [OMember] = [OMember("type", .str("command")), OMember("command", .str(hookCommand))]
        if let timeout { entry.append(OMember("timeout", .number(String(timeout)))) }
        return .object([OMember("hooks", .array([.object(entry)]))])
    }

    private func installInto(_ hooks: inout [OMember]) throws {
        for event in Self.events {
            let idx = hooks.firstIndex { $0.key == event }
            var groups = try Self.groups(idx.map { hooks[$0].value }, event: event)
            var found = false
            for gi in groups.indices {
                guard case .object(var gm) = groups[gi],
                      let hi = gm.firstIndex(where: { $0.key == "hooks" }),
                      var list = gm[hi].value.arrayItems else { continue }
                var touched = false
                for k in list.indices where Self.isOurs(list[k]) {
                    found = true
                    guard case .object(var hm) = list[k],
                          let ci = hm.firstIndex(where: { $0.key == "command" }),
                          hm[ci].value.stringValue != hookCommand else { continue }
                    hm[ci].value = .str(hookCommand)
                    list[k] = .object(hm)
                    touched = true
                }
                if touched { gm[hi].value = .array(list); groups[gi] = .object(gm) }
            }
            if !found { groups.append(newGroup()) }
            if let idx { hooks[idx].value = .array(groups) } else { hooks.append(OMember(event, .array(groups))) }
        }
    }

    /// Returns whether anything was removed.
    private func uninstallFrom(_ hooks: inout [OMember]) throws -> Bool {
        var removed = false
        var i = 0
        while i < hooks.count {
            guard let groups = hooks[i].value.arrayItems else { i += 1; continue }
            var newGroups: [OJ] = []
            var removedHere = false
            for g in groups {
                guard case .object(var gm) = g,
                      let hi = gm.firstIndex(where: { $0.key == "hooks" }),
                      let list = gm[hi].value.arrayItems else { newGroups.append(g); continue }
                let kept = list.filter { !Self.isOurs($0) }
                if kept.count == list.count { newGroups.append(g); continue }
                removedHere = true
                if kept.isEmpty { continue }   // the group only held our hook
                gm[hi].value = .array(kept)
                newGroups.append(.object(gm))
            }
            if removedHere {
                removed = true
                if newGroups.isEmpty { hooks.remove(at: i); continue }
                hooks[i].value = .array(newGroups)
            }
            i += 1
        }
        return removed
    }

    struct Loaded {
        var text: String
        var root: OJ
        var indent: String
        var trailingNewline: Bool
    }

    static func load(_ path: String) throws -> Loaded {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let root: OJ
        do { root = try OJParser.parse(text) } catch { throw InstallError.badShape("not valid JSON: \(error)") }
        return Loaded(text: text, root: root, indent: detectIndent(text), trailingNewline: text.hasSuffix("\n"))
    }

    static func detectIndent(_ text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst() {
            if line.hasPrefix("\t") { return "\t" }
            if line.hasPrefix(" ") {
                let n = line.prefix { $0 == " " }.count
                return String(repeating: " ", count: n)
            }
        }
        return "  "
    }
}
