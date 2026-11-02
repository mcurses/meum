import Foundation
import MeumCore

/// Builds the shell command that resumes an agent session after its zmx session is gone (after a reboot).
/// The integration step plugs in MeumControl's resume builder; v1 core ships a stub that resumes nothing.
protocol ResumeProvider: AnyObject {
    /// A shell command line to run in the tab's new session, or nil for a plain shell.
    func resumeCommand(for snapshot: AgentSnapshot, tab: Tab) -> String?
}

final class NoResumeProvider: ResumeProvider {
    func resumeCommand(for snapshot: AgentSnapshot, tab: Tab) -> String? { nil }
}

/// Debug stand-in (`MEUM_DEBUG_RESUME=1`): prints what would be resumed, so the seam can be checked end to end
/// before the integration step plugs in the real builder.
final class EchoResumeProvider: ResumeProvider {
    func resumeCommand(for snapshot: AgentSnapshot, tab: Tab) -> String? {
        "echo " + ZmxSessions.quote("meum-resume: session=\(snapshot.sessionID) cwd=\(snapshot.cwd ?? "-")")
    }
}

/// The bundled zmx: session names, listing, killing, and the surface command for a tab.
final class ZmxSessions {
    let binary: String
    let prefix: String
    /// Builds resume commands for tabs whose session is gone. The integration step replaces the stub.
    var resume: ResumeProvider

    init(binary: String, prefix: String, resume: ResumeProvider = NoResumeProvider()) {
        self.binary = binary
        self.prefix = prefix
        self.resume = resume
    }

    /// The bundled binary (`Contents/Resources/bin/zmx`), else `MEUM_ZMX` / PATH as a development fallback.
    static func locate(bundle: Bundle = .main) -> String {
        if let r = bundle.resourceURL?.appendingPathComponent("bin/zmx").path,
           FileManager.default.isExecutableFile(atPath: r) { return r }
        if let e = ProcessInfo.processInfo.environment["MEUM_ZMX"], FileManager.default.isExecutableFile(atPath: e) {
            return e
        }
        return "zmx"
    }

    func name(for tabID: UUID) -> String { ZmxNaming.sessionName(for: tabID, prefix: prefix) }

    /// Names of the live sessions (all prefixes). Empty on error.
    func list() -> Set<String> {
        guard let out = run(["list", "--short"]) else { return [] }
        return Set(out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.contains(" ") }) // drops "no sessions found in ..."
    }

    /// Kills the sessions of these tabs, off the main thread. Only names with our prefix are ever killed.
    func kill(tabs: [UUID]) {
        let names = tabs.map(name(for:)).filter { $0.hasPrefix(prefix) }
        guard !names.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [binary] in
            _ = Self.run(binary: binary, ["kill"] + names)
        }
    }

    /// Kills the live sessions of these tabs and waits for zmx (launch with `reattachSessions` off, before any
    /// surface attaches). Only names with our prefix. Returns how many were killed.
    @discardableResult
    func killNow(tabs: [UUID]) -> Int {
        let live = list()
        let names = tabs.map(name(for:)).filter { $0.hasPrefix(prefix) && live.contains($0) }
        guard !names.isEmpty else { return 0 }
        _ = run(["kill"] + names)
        return names.count
    }

    /// What a tab's surface runs.
    ///
    /// - The session exists: plain `zmx attach <name>` (zmx ignores a command for an existing session).
    /// - It is gone and the tab carries an agent snapshot: create it running the resume command, then a shell.
    /// - Otherwise: create it with the tab's command if it has one, else the login shell.
    func command(for tab: Tab, live: Set<String>) -> (command: String, resumed: Bool) {
        let n = name(for: tab.id)
        let attach = "\(Self.quote(binary)) attach \(Self.quote(n))"
        if live.contains(n) { return (attach, false) }
        var startup: String?
        var resumed = false
        if let agent = tab.agent, let cmd = resume.resumeCommand(for: agent, tab: tab) {
            startup = cmd
            resumed = true
        } else if let cmd = tab.command, !cmd.isEmpty {
            startup = cmd
        }
        guard let startup else { return (attach, false) }
        // An interactive login shell runs the startup command, so the user's PATH, functions and aliases from
        // the rc files apply (`claude` is often on a PATH set in .zshrc, or wrapped in a shell function).
        let shell = ProcessEnvironment.shell
        let script = "\(startup); exec \(Self.quote(shell)) -l"
        return ("\(attach) \(Self.quote(shell)) -ilc \(Self.quote(script))", resumed)
    }

    static func quote(_ s: String) -> String { GhosttyCallbacks.shellEscape(s) }

    private func run(_ args: [String]) -> String? { Self.run(binary: binary, args) }

    static func run(binary: String, _ args: [String]) -> String? {
        let p = Process()
        if binary.contains("/") {
            p.executableURL = URL(fileURLWithPath: binary)
            p.arguments = args
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = [binary] + args
        }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
