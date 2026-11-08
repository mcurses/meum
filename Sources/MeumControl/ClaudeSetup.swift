// The first-launch setup (docs/design/first-launch.md): what meum offers to wire for Claude Code, and the wiring.
//
// Three steps, each offered only when it has something to do:
//   hooks   meum's hook entries in every Claude config folder (the status dots), the same code as `meum hooks install`
//   mcp     meum's MCP server in every Claude config folder (`claude mcp add --scope user`), unless a folder already
//           has it, by that entry or by meum's Claude Code plugin
//   cli     a link ~/.local/bin/meum to this app's CLI, only when ~/.local/bin is already on the login shell's PATH
//
// Nothing here runs without the person's yes; the app's sheet asks.
import Foundation

public struct ClaudeSetup {
    public enum Step: String, CaseIterable, Sendable { case hooks, mcp, cli }

    /// What the login shell knows: where `claude` is, and its PATH.
    public struct Shell: Equatable, Sendable {
        public var claude: String?
        public var path: [String]
        public init(claude: String?, path: [String]) {
            self.claude = claude
            self.path = path
        }
    }

    /// One row of the sheet: a step, the folders or files it would change, and what it would do.
    public struct Offer: Equatable, Sendable {
        public var step: Step
        /// The Claude config folders (hooks, mcp) the step would change; empty for cli.
        public var configDirs: [String]
        public var detail: String
    }

    /// What one step did: a line per file written or command run, and whether everything worked.
    public struct Outcome: Equatable, Sendable {
        public var step: Step
        public var lines: [String]
        public var ok: Bool
    }

    public var home: String
    /// The bundled `meum` CLI (Contents/Resources/bin/meum).
    public var cli: String
    public var configDirs: [String]

    public init(home: String, cli: String, configDirs: [String]? = nil) {
        self.home = home
        self.cli = cli
        self.configDirs = configDirs ?? HookInstaller.discoverConfigDirs(home: home)
    }

    // MARK: what to offer

    public func offers(shell: Shell) -> [Offer] {
        var out: [Offer] = []
        let hookDirs = needHooks()
        if !hookDirs.isEmpty {
            out.append(Offer(step: .hooks, configDirs: hookDirs,
                             detail: "Adds meum's hooks to \(Self.list(hookDirs.map { tilde($0) + "/settings.json" })) (a backup is kept) and puts meum-hook in ~/.local/bin."))
        }
        let mcpDirs = needMCP()
        if shell.claude != nil, !mcpDirs.isEmpty {
            out.append(Offer(step: .mcp, configDirs: mcpDirs,
                             detail: "Runs `claude mcp add --scope user meum -- \(tilde(cli)) mcp` for \(Self.list(mcpDirs.map(tilde)))."))
        }
        if needsCLILink(shell: shell) {
            out.append(Offer(step: .cli, configDirs: [],
                             detail: "Links ~/.local/bin/meum to this app's `meum`, so every shell finds it, not only meum's tabs."))
        }
        return out
    }

    /// The config folders whose hooks are missing or incomplete, or all of them when the hook script is missing.
    public func needHooks() -> [String] {
        let installer = HookInstaller(home: home)
        let targets = installer.targets(for: configDirs)
        let script = installer.scriptState(comparedTo: HookInstaller.bundledScript(nextTo: cli))
        return targets.filter { !installer.status(of: $0).isInstalled || script == .missing || script == .notExecutable }
            .map(\.configDir)
    }

    /// The config folders without meum's MCP server.
    public func needMCP() -> [String] { configDirs.filter { !hasMCP($0) } }

    /// The user-scope `mcpServers.meum` in the folder's `.claude.json` (`~/.claude.json` for `~/.claude`), or meum's
    /// plugin enabled in its settings.json.
    public func hasMCP(_ dir: String) -> Bool {
        let state = isDefault(dir) ? home + "/.claude.json" : dir + "/.claude.json"
        if let o = Self.object(state), let servers = o["mcpServers"] as? [String: Any], servers["meum"] != nil { return true }
        if let o = Self.object(dir + "/settings.json"), let plugins = o["enabledPlugins"] as? [String: Any] {
            return plugins.contains { $0.key.hasPrefix("meum@") && ($0.value as? Bool) == true }
        }
        return false
    }

    var linkPath: String { home + "/.local/bin/meum" }

    /// ~/.local/bin is on PATH, and ~/.local/bin/meum is missing or a link to another meum (never a file of its own).
    public func needsCLILink(shell: Shell) -> Bool {
        let bin = home + "/.local/bin"
        guard shell.path.contains(where: { $0 == bin || $0 == bin + "/" || $0 == "~/.local/bin" }) else { return false }
        let fm = FileManager.default
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: linkPath) else {
            return !fm.fileExists(atPath: linkPath)
        }
        return dest != cli
    }

    // MARK: doing it

    /// Runs `claude mcp add` for each folder that lacks the entry. `run(executable, args, env)` returns the exit code
    /// and the output.
    public func addMCP(shell: Shell, dirs: [String],
                       run: (String, [String], [String: String]) -> (Int32, String)) -> Outcome {
        guard let claude = shell.claude else { return Outcome(step: .mcp, lines: ["`claude` was not found"], ok: false) }
        var lines: [String] = [], ok = true
        for dir in dirs {
            var env = ["PATH": shell.path.joined(separator: ":"), "HOME": home]
            // the default folder is left unset: an explicit CLAUDE_CONFIG_DIR=~/.claude is a different profile to Claude
            if !isDefault(dir) { env["CLAUDE_CONFIG_DIR"] = dir }
            let (code, output) = run(claude, ["mcp", "add", "--scope", "user", "meum", "--", cli, "mcp"], env)
            if code == 0 || hasMCP(dir) {
                lines.append("\(tilde(dir)): ran claude mcp add --scope user meum")
            } else {
                ok = false
                let why = output.split(separator: "\n").last.map(String.init) ?? "exit \(code)"
                lines.append("\(tilde(dir)): claude mcp add failed: \(why)")
            }
        }
        return Outcome(step: .mcp, lines: lines, ok: ok)
    }

    /// Links ~/.local/bin/meum to the bundled CLI (replacing only a link).
    public func linkCLI() -> Outcome {
        let fm = FileManager.default
        do {
            if (try? fm.destinationOfSymbolicLink(atPath: linkPath)) != nil { try fm.removeItem(atPath: linkPath) }
            try fm.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: cli)
            return Outcome(step: .cli, lines: ["linked ~/.local/bin/meum → \(tilde(cli))"], ok: true)
        } catch {
            return Outcome(step: .cli, lines: ["could not link ~/.local/bin/meum: \(error.localizedDescription)"], ok: false)
        }
    }

    // MARK: the login shell

    /// Asks the person's login shell (interactive, so ~/.zshrc counts too) where `claude` is and what PATH is.
    public static func probeShell(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                                  timeout: TimeInterval = 8) -> Shell {
        let mark = "__meum_probe__"
        // only PATH: `command -v` answers with an alias or a function's name where the person has one for claude
        let script = "printf '\\n\(mark)%s\\n' \"$PATH\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-i", "-l", "-c", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Shell(claude: nil, path: []) }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return Shell(claude: nil, path: []) }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return parseProbe(text, mark: mark)
    }

    static func parseProbe(_ text: String, mark: String = "__meum_probe__",
                           isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> Shell {
        guard let line = text.components(separatedBy: "\n").last(where: { $0.hasPrefix(mark) }) else {
            return Shell(claude: nil, path: [])
        }
        let path = line.dropFirst(mark.count).split(separator: ":").map(String.init)
        let claude = path.lazy.map { $0 + "/claude" }.first(where: isExecutable)
        return Shell(claude: claude, path: path)
    }

    // MARK: helpers

    func isDefault(_ dir: String) -> Bool {
        URL(fileURLWithPath: dir).standardizedFileURL.path == URL(fileURLWithPath: home + "/.claude").standardizedFileURL.path
    }

    func tilde(_ p: String) -> String { p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p }

    static func object(_ path: String) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2, 3: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        default: return "\(items.count) Claude config folders"
        }
    }
}
