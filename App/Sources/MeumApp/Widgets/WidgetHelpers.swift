import Foundation
import MeumControl
import MeumCore

/// Runs widgets' background programs ("helpers", e.g. Tamago's daemon): one per installed, enabled widget whose
/// manifest has `"helper": {"command": "bin/daemon", "args": [...], "keepAlive": true}`.
///
/// - `command` is a path inside the widget folder (an absolute path or one with `..` is refused, as the installer
///   does). It starts when meum launches or the widget becomes enabled, not when the widget's first card or tab
///   appears: a helper may follow things while nothing shows it.
/// - It runs from a private copy (`WidgetInstaller.trustedHelper`): the copy is what was checked, so swapping the
///   file in the widget folder afterwards changes nothing until the next check. A helper that needs files next to
///   it finds its folder in `MEUM_WIDGET_DIR`.
/// - Environment: meum's own, plus `MEUM_SOCKET`, `MEUM_WIDGET_ID`, `MEUM_WIDGET_DIR` (the widget folder) and
///   `MEUM_WIDGET_DATA` (the widget's data folder).
/// - stdout and stderr go to `<state dir>/helpers/<id>.log`.
/// - Each helper runs in its own process group. Stopping it signals only that group: SIGTERM, then SIGKILL after 3 s.
///   When a helper exits by itself, what is left in its group gets the same treatment before any restart.
/// - `keepAlive`: a helper that exits is started again after 1, 2, 4 … 60 s. A run of a minute or more resets the
///   delay.
/// - `sync` (called on every widget reload) leaves a running helper alone unless its command, arguments or file
///   (size, modification time) changed, and stops helpers whose widget is gone or disabled. meum stops all helpers
///   when it quits.
@MainActor
final class WidgetHelpers {
    struct Spec: Equatable {
        var widgetID: String
        /// The file in the widget folder; `trustedHelper` replaces it with the checked private copy.
        var executable: String
        /// The widget folder (`MEUM_WIDGET_DIR`).
        var folder: String
        var args: [String]
        var keepAlive: Bool
        /// Size and modification time of the executable, so a rebuilt helper restarts on reload.
        var fileStamp: String
    }

    final class Running {
        let spec: Spec
        var pid: pid_t = 0
        var startedAt = Date()
        var restarts = 0
        var lastExit: Int32?
        var exitSource: DispatchSourceProcess?
        var restartWork: DispatchWorkItem?
        var stopping = false
        init(spec: Spec) { self.spec = spec }
    }

    let socketPath: String
    let logDirectory: URL
    let dataDirectory: (String) -> URL
    private(set) var running: [String: Running] = [:]

    init(socketPath: String, stateDirectory: URL, dataDirectory: @escaping (String) -> URL) {
        self.socketPath = socketPath
        self.logDirectory = stateDirectory.appendingPathComponent("helpers", isDirectory: true)
        self.dataDirectory = dataDirectory
    }

    /// The helper spec of a widget folder's manifest, nil without a `helper` field (or with a bad one).
    static func spec(widgetID: String, folder: URL, manifest: [String: Any]) -> Spec? {
        guard let h = manifest["helper"] as? [String: Any], let cmd = h["command"] as? String, !cmd.isEmpty else { return nil }
        guard isInsideFolder(cmd) else {
            Log.error("widget \(widgetID): helper \(cmd) is outside the widget folder; not started")
            return nil
        }
        let exe = folder.appendingPathComponent(cmd).path
        let attrs = try? FileManager.default.attributesOfItem(atPath: exe)
        let stamp = "\((attrs?[.size] as? NSNumber)?.int64Value ?? -1)-\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        return Spec(widgetID: widgetID, executable: exe, folder: folder.path, args: (h["args"] as? [String]) ?? [],
                    keepAlive: (h["keepAlive"] as? Bool) ?? true, fileStamp: stamp)
    }

    /// A helper command that stays inside the widget folder: relative, without `..`.
    static func isInsideFolder(_ command: String) -> Bool {
        !command.hasPrefix("/") && !command.split(separator: "/").contains("..")
    }

    /// Brings the running helpers in line with `wanted` (the enabled widgets' specs).
    func sync(_ wanted: [Spec]) {
        let byID = Dictionary(wanted.map { ($0.widgetID, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, r) in running where byID[id] != r.spec { stop(id) }
        for spec in wanted where running[spec.widgetID] == nil { start(spec) }
    }

    func start(_ spec: Spec) {
        let r = Running(spec: spec)
        running[spec.widgetID] = r
        launch(r)
    }

    private func launch(_ r: Running) {
        let spec = r.spec
        let fm = FileManager.default
        try? fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let data = dataDirectory(spec.widgetID)
        try? fm.createDirectory(at: data, withIntermediateDirectories: true)
        let log = logDirectory.appendingPathComponent("\(spec.widgetID).log")
        if !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: nil) }
        guard fm.isExecutableFile(atPath: spec.executable) else {
            Log.error("widget helper \(spec.widgetID): \(spec.executable) is not executable")
            appendLog(log, "meum: \(spec.executable) is not executable; not started")
            return
        }
        var env = ProcessInfo.processInfo.environment
        env["MEUM_SOCKET"] = socketPath
        env["MEUM_WIDGET_ID"] = spec.widgetID
        env["MEUM_WIDGET_DIR"] = spec.folder
        env["MEUM_WIDGET_DATA"] = data.path
        appendLog(log, "meum: starting \(spec.executable) \(spec.args.joined(separator: " "))")

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        posix_spawn_file_actions_addchdir_np(&actions, data.path)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // its own process group (pgid = its pid), so stopping it reaches its children and nothing else
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigmask(&attr, &empty)

        let argv = [spec.executable] + spec.args
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, spec.executable, &actions, &attr, cArgs, cEnv)
        guard rc == 0 else {
            Log.error("widget helper \(spec.widgetID): posix_spawn failed: \(String(cString: strerror(rc)))")
            appendLog(log, "meum: start failed: \(String(cString: strerror(rc)))")
            scheduleRestart(r)
            return
        }
        r.pid = pid
        r.startedAt = Date()
        Log.info("widget helper \(spec.widgetID) started, pid \(pid)")
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self, weak r] in
            MainActor.assumeIsolated {
                guard let self, let r else { return }
                var status: Int32 = 0
                waitpid(pid, &status, 0)
                r.exitSource?.cancel()
                r.exitSource = nil
                r.lastExit = status
                r.pid = 0
                // whatever it started is still in its process group: end that too before any restart
                kill(-pid, SIGTERM)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { kill(-pid, SIGKILL) }
                self.appendLog(log, "meum: exited (status \(status))")
                guard !r.stopping, self.running[r.spec.widgetID] === r else { return }
                self.scheduleRestart(r)
            }
        }
        r.exitSource = src
        src.resume()
    }

    private func scheduleRestart(_ r: Running) {
        guard r.spec.keepAlive, !r.stopping else { return }
        if Date().timeIntervalSince(r.startedAt) >= 60 { r.restarts = 0 }
        let delay = min(60, pow(2, Double(r.restarts)))
        r.restarts += 1
        let w = DispatchWorkItem { [weak self, weak r] in
            MainActor.assumeIsolated {
                guard let self, let r, !r.stopping, self.running[r.spec.widgetID] === r else { return }
                self.launch(r)
            }
        }
        r.restartWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// Stops a widget's helper: SIGTERM to its process group, SIGKILL after up to 3 s. Blocks at most 3 s.
    func stop(_ id: String) {
        guard let r = running.removeValue(forKey: id) else { return }
        r.stopping = true
        r.restartWork?.cancel()
        r.exitSource?.cancel()
        r.exitSource = nil
        let pid = r.pid
        guard pid > 0 else { return }
        kill(-pid, SIGTERM)   // the group meum created for it (pgid == pid)
        let deadline = Date().addingTimeInterval(3)
        var status: Int32 = 0
        while Date() < deadline {
            if waitpid(pid, &status, WNOHANG) == pid { break }
            usleep(50_000)
        }
        if kill(pid, 0) == 0 { kill(-pid, SIGKILL); waitpid(pid, &status, 0) }
        kill(-pid, SIGKILL)   // children that outlived the leader
        Log.info("widget helper \(id) stopped")
        appendLog(logDirectory.appendingPathComponent("\(id).log"), "meum: stopped")
    }

    func stopAll() { for id in Array(running.keys) { stop(id) } }

    func json(_ id: String) -> JSON {
        guard let r = running[id] else { return .null }
        return ["running": .bool(r.pid > 0), "pid": r.pid > 0 ? .int(Int(r.pid)) : .null, "restarts": .int(r.restarts),
                "lastExit": r.lastExit.map { .int(Int($0)) } ?? .null,
                "log": .string(logDirectory.appendingPathComponent("\(id).log").path)]
    }

    private func appendLog(_ url: URL, _ line: String) {
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? h.write(contentsOf: Data("\(stamp) \(line)\n".utf8))
    }
}
