// Self-update from GitHub Releases (the usual approach for a notarized app, plus a signature check before the swap).
//
//   check:   GET the latest release (api.github.com/repos/mcurses/meum/releases/latest); a tag newer than
//            CFBundleShortVersionString with a "-<arch>.dmg" asset is an update.
//   install: download the DMG, mount it read-only, ditto its meum.app next to the running one, verify that copy
//            (valid signature from the Developer ID team, our bundle id, a newer version), swap it in place
//            (the old copy is kept until the new one is in position), relaunch.
//
// Only release builds update themselves: the running app must itself be signed by the team. Builds from source
// (local or ad-hoc signature) report "not a release build". A relaunch keeps every terminal: the zmx sessions
// outlive meum and the new version reattaches them.
//
// Testing: MEUM_UPDATE_FEED (AppOptions.updateFeed) points the check at another URL with the same JSON shape
// (file:// works too), and also lets a non-release build update itself; the downloaded app is verified all the same.
import AppKit
import Foundation
import MeumControl
import MeumCore
import Security

@MainActor
final class Updater {
    static let repo = "mcurses/meum"
    static let team = "XHXWK3RG86"
    static let bundleID = "io.github.mcurses.meum"

    struct Release: Equatable {
        var version: String
        var dmg: URL
        var page: URL?
        var notes: String
    }

    enum Failure: Error, CustomStringConvertible {
        case notReleaseBuild, noAsset(String), http(Int), bad(String)
        var description: String {
            switch self {
            case .notReleaseBuild: return "this meum was built from source; it updates by rebuilding, not from GitHub"
            case .noAsset(let v): return "release \(v) has no DMG for this Mac"
            case .http(let c): return "GitHub answered HTTP \(c)"
            case .bad(let s): return s
            }
        }
    }

    let stateDir: URL
    let feedOverride: URL?
    /// How to come back after an update: the launch variables, and whether this is an isolated instance.
    let launchEnv: [String: String]
    let isolated: Bool
    private var timer: Timer?
    private(set) var busy = false
    /// Last check: the newer release, if any.
    private(set) var available: Release?
    /// Progress for the settings window and the API: (fraction or nil, text).
    var onProgress: ((Double?, String) -> Void)?
    /// Asked before an automatic offer is shown; the settings switch.
    var enabled: () -> Bool = { true }

    init(stateDir: URL, feedOverride: URL? = nil, launchEnv: [String: String] = [:], isolated: Bool = false) {
        self.stateDir = stateDir
        self.feedOverride = feedOverride
        self.launchEnv = launchEnv
        self.isolated = isolated
    }

    var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    private var feed: URL {
        feedOverride ?? URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
    }
    private var arch: String {
        var u = utsname(); uname(&u)
        let m = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return m.hasPrefix("arm") ? "arm64" : "x86_64"
    }

    /// Whether this copy may replace itself: a release build (signed by the team), or a test with a feed override.
    var canUpdate: Bool { feedOverride != nil || Self.signedByTeam(Bundle.main.bundleURL) }

    // MARK: automatic checks

    /// A check shortly after launch and then once a day; each version is offered once.
    func startAutomaticChecks() {
        guard canUpdate else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.automaticCheck() }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.automaticCheck() }
        }
    }

    private var offeredFile: URL { stateDir.appendingPathComponent("update-offered") }

    private func automaticCheck() {
        guard enabled(), !busy else { return }
        Task {
            guard let r = try? await check() else { return }
            let offered = (try? String(contentsOf: offeredFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard offered != r.version else { return }
            try? r.version.write(to: offeredFile, atomically: true, encoding: .utf8)
            offer(r)
        }
    }

    // MARK: check

    /// The newer release, or nil when this is the latest.
    func check() async throws -> Release? {
        var req = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("meum-updater", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw Failure.http(h.statusCode) }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = o["tag_name"] as? String else {
            throw Failure.bad("unexpected answer from the release feed")
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard widgetVersionIsNewer(version, than: currentVersion) else { available = nil; return nil }
        let assets = o["assets"] as? [[String: Any]] ?? []
        guard let a = assets.first(where: { ($0["name"] as? String)?.hasSuffix("-\(arch).dmg") == true }),
              let s = a["browser_download_url"] as? String, let url = URL(string: s) else { throw Failure.noAsset(version) }
        let r = Release(version: version, dmg: url, page: (o["html_url"] as? String).flatMap(URL.init(string:)),
                        notes: o["body"] as? String ?? "")
        available = r
        return r
    }

    // MARK: UI

    /// The menu's "Check for Updates…": always answers, also when there is nothing new.
    func checkInteractively() {
        guard canUpdate else { return alert("Updates", Failure.notReleaseBuild.description) }
        Task {
            do {
                if let r = try await check() { offer(r) } else { alert("meum is up to date", "You have version \(currentVersion).") }
            } catch {
                alert("Could not check for updates", "\(error)")
            }
        }
    }

    private func offer(_ r: Release) {
        let a = NSAlert()
        a.messageText = "meum \(r.version) is available"
        var info = "You have \(currentVersion). Installing restarts meum; your terminals keep running and come back as they were."
        let notes = r.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { info += "\n\n" + String(notes.prefix(1200)) }
        a.informativeText = info
        a.addButton(withTitle: "Install and Relaunch")
        a.addButton(withTitle: "Later")
        if r.page != nil { a.addButton(withTitle: "Release Notes") }
        switch a.runModal() {
        case .alertFirstButtonReturn:
            Task {
                do { try await install(r) } catch { alert("The update did not install", "\(error)") }
            }
        case .alertThirdButtonReturn:
            if let p = r.page { NSWorkspace.shared.open(p) }
        default: break
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    // MARK: install

    /// Downloads, verifies and swaps in `r`, then relaunches (unless `relaunch` is false). Throws before touching
    /// the installed app if anything does not check out.
    func install(_ r: Release, relaunch: Bool = true) async throws {
        guard canUpdate else { throw Failure.notReleaseBuild }
        guard !busy else { throw Failure.bad("an update is already being installed") }
        busy = true
        defer { busy = false }
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw Failure.bad("cannot write to \(parent.path); download the new version from GitHub instead")
        }
        onProgress?(0, "Downloading \(r.version)…")
        let (tmp, resp) = try await URLSession.shared.download(from: r.dmg)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw Failure.http(h.statusCode) }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("meum-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let dmg = work.appendingPathComponent("update.dmg")
        try FileManager.default.moveItem(at: tmp, to: dmg)

        onProgress?(0.6, "Checking \(r.version)…")
        let staged = parent.appendingPathComponent(".\(target.lastPathComponent).update-\(getpid())")
        try? FileManager.default.removeItem(at: staged)
        let mount = work.appendingPathComponent("mnt")
        try await Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        do {
            let apps = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "app" } ?? []
            guard apps.count == 1 else { throw Failure.bad("the DMG holds \(apps.count) apps, expected one") }
            try await Self.run("/usr/bin/ditto", [apps[0].path, staged.path])
        } catch {
            _ = try? await Self.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path])
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        _ = try? await Self.run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path])

        do {
            try Self.verify(staged, newerThan: currentVersion)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }

        onProgress?(0.9, "Installing \(r.version)…")
        let old = parent.appendingPathComponent(".\(target.lastPathComponent).old-\(getpid())")
        try? FileManager.default.removeItem(at: old)
        try FileManager.default.moveItem(at: target, to: old)
        do {
            try FileManager.default.moveItem(at: staged, to: target)
        } catch {
            try? FileManager.default.moveItem(at: old, to: target)   // roll back
            try? FileManager.default.removeItem(at: staged)
            throw Failure.bad("could not put the new version in place: \(error)")
        }
        try? FileManager.default.removeItem(at: old)
        Log.info("updated to \(r.version) at \(target.path)")
        onProgress?(1, "Installed \(r.version)")
        if relaunch { self.relaunch(target) }
    }

    /// The staged app must carry a valid signature from the team, our bundle id, and a newer version.
    static func verify(_ app: URL, newerThan current: String) throws {
        guard signedByTeam(app) else { throw Failure.bad("the downloaded app is not signed by meum's developer; not installed") }
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleID else {
            throw Failure.bad("the downloaded app is not meum; not installed")
        }
        let v = info["CFBundleShortVersionString"] as? String ?? "0"
        guard widgetVersionIsNewer(v, than: current) else { throw Failure.bad("the downloaded app is version \(v), not newer") }
    }

    /// A valid (all architectures, nested code too) Apple-anchored signature from the team, for our identifier.
    static func signedByTeam(_ app: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var req: SecRequirement?
        let text = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess, let req else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }

    /// Quits and starts `app` again once this process is gone. An isolated instance (its own state dir) is
    /// started directly with its launch variables and arguments, so it comes back as the same isolated instance and
    /// never as the user's meum.
    func relaunch(_ app: URL) {
        let pid = getpid()
        var env = ProcessInfo.processInfo.environment
        let start: String
        if isolated {
            env.merge(launchEnv) { _, launch in launch }
            let args = CommandLine.arguments.dropFirst().map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            start = "\"\(app.path)/Contents/MacOS/meum\" \(args.joined(separator: " ")) >/dev/null 2>&1 &"
        } else {
            start = "/usr/bin/open \"\(app.path)\""
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; \(start)"]
        p.environment = env
        try? p.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: tool)
                p.arguments = args
                let err = Pipe()
                p.standardError = err
                p.standardOutput = FileHandle.nullDevice
                do {
                    try p.run()
                    p.waitUntilExit()
                    if p.terminationStatus == 0 { c.resume() } else {
                        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        c.resume(throwing: Failure.bad("\((tool as NSString).lastPathComponent) failed: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))"))
                    }
                } catch { c.resume(throwing: error) }
            }
        }
    }

    // MARK: API

    func statusJSON(_ r: Release?) -> JSON {
        var o: [String: JSON] = ["current": .string(currentVersion), "available": .bool(r != nil), "canUpdate": .bool(canUpdate)]
        if let r { o["latest"] = .string(r.version); o["url"] = .string(r.dmg.absoluteString); o["page"] = r.page.map { .string($0.absoluteString) } ?? .null }
        if !canUpdate { o["reason"] = .string(Failure.notReleaseBuild.description) }
        return .object(o)
    }
}
