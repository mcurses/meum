import Foundation
import MeumControl
import MeumCore
import MeumKit
import Security

/// The widget library (docs/design/widget-library.md): fetches the catalog, installs, updates and removes widgets,
/// keeps the pinned hashes, and decides whether a widget library may load (`trust(of:id:)`, called by
/// WidgetManager on the copy it is about to dlopen).
@MainActor
final class WidgetInstaller {
    weak var widgets: WidgetManager?
    let paths: StatePaths
    let pinStore: WidgetPinStore
    private(set) var pins: WidgetPins
    var settings: () -> Settings
    /// Stops a widget's background helper before its folder changes (WidgetManager provides it).
    var stopHelper: ((String) -> Void)?
    private(set) var catalog: WidgetCatalog?
    private(set) var catalogURL: String?

    static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    init(paths: StatePaths, settings: @escaping () -> Settings) {
        self.paths = paths
        self.pinStore = WidgetPinStore(paths: paths)
        self.pins = pinStore.load()
        self.settings = settings
    }

    struct InstallError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: first start

    /// The first meum that pins anything trusts the widgets already installed (an upgrade breaks nothing); later
    /// additions outside the library need `allow`.
    func pinExistingOnFirstRun(_ entries: [WidgetManager.Entry]) {
        guard !pinStore.exists else { return }
        for e in entries {
            if let h = try? WidgetHash.sha256(of: e.library) {
                pins.pins[e.id] = .init(sha256: h, source: .existing, helperSha256: Self.helperHash(e))
            }
        }
        save()
        if !entries.isEmpty { Log.info("widget pins: trusted \(entries.count) widget(s) installed before pinning") }
    }

    private func save() {
        do { try pinStore.save(pins) } catch { Log.error("saving widget pins: \(error)") }
    }

    // MARK: trust

    /// Whether the library at `url` (the private copy about to be loaded) may load as widget `id`.
    func trust(of url: URL, id: String) -> WidgetTrust {
        let s = settings()
        guard let hash = try? WidgetHash.sha256(of: url) else { return .unverified("cannot read the library") }
        let team = Self.signedTeam(url, allowed: s.widgetTeamIDs)
        return WidgetTrust.decide(id: id, sha256: hash, signedTeam: team, pins: pins, teams: s.widgetTeamIDs,
                                  developerMode: s.widgetDeveloperMode)
    }

    static func helperHash(_ e: WidgetManager.Entry) -> String? {
        e.helper.flatMap { try? WidgetHash.sha256(of: URL(fileURLWithPath: $0.executable)) }
    }

    /// Whether a widget's background helper may run (checked before every start).
    func helperTrusted(_ e: WidgetManager.Entry) -> Bool {
        guard let spec = e.helper else { return true }
        let url = URL(fileURLWithPath: spec.executable)
        let s = settings()
        guard let hash = try? WidgetHash.sha256(of: url) else { return false }
        let t = WidgetTrust.decideHelper(id: e.id, sha256: hash, signedTeam: Self.signedTeam(url, allowed: s.widgetTeamIDs),
                                         pins: pins, teams: s.widgetTeamIDs, developerMode: s.widgetDeveloperMode)
        if !t.allowsLoading { Log.error("widget \(e.id): helper not started (not verified)") }
        return t.allowsLoading
    }

    /// The first allowed team whose valid, Apple-anchored Developer ID signature the file carries.
    static func signedTeam(_ url: URL, allowed: [String]) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        for team in allowed where team.allSatisfy({ $0.isLetter || $0.isNumber }) {
            var req: SecRequirement?
            let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
            guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess, let req else { continue }
            if SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), req) == errSecSuccess {
                return team
            }
        }
        return nil
    }

    /// Trusts the widget's library as it is now (Settings ▸ Widgets "Allow"; never over the socket).
    func allow(_ id: String) throws -> JSON {
        guard let widgets, let e = widgets.entry(id) else { throw ControlError.notFound("no installed widget '\(id)'") }
        pins.pins[e.id] = .init(sha256: try WidgetHash.sha256(of: e.library), source: .allowed, helperSha256: Self.helperHash(e))
        save()
        widgets.reload()
        return widgets.listJSON()
    }

    // MARK: catalog

    func fetchCatalog() async throws -> WidgetCatalog {
        let urlString = settings().widgetCatalogURL
        guard let url = URL(string: urlString) else { throw InstallError(description: "bad catalog URL \(urlString)") }
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url)
        } else {
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            req.setValue("meum", forHTTPHeaderField: "User-Agent")
            let (d, resp) = try await URLSession.shared.data(for: req)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                throw InstallError(description: "catalog: HTTP \(h.statusCode) from \(urlString)")
            }
            data = d
        }
        let c: WidgetCatalog
        do { c = try JSONDecoder().decode(WidgetCatalog.self, from: data) } catch {
            throw InstallError(description: "catalog at \(urlString) is not a meum widget catalog: \(error)")
        }
        catalog = c
        catalogURL = urlString
        return c
    }

    /// The installed version of a widget: what the library installed, else the manifest's.
    func installedVersion(_ id: String) -> String? {
        if let v = pins.pins[id]?.version { return v }
        guard let e = widgets?.entry(id),
              let data = try? Data(contentsOf: e.folder.appendingPathComponent("manifest.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["version"] as? String
    }

    func catalogJSON() async throws -> JSON {
        let c = try await fetchCatalog()
        let entries: [JSON] = c.widgets.map { w in
            let installed = widgets?.entry(w.id) != nil
            let iv = installed ? installedVersion(w.id) : nil
            var o: [String: JSON] = [
                "id": .string(w.id), "displayName": .string(w.displayName), "description": .string(w.description),
                "author": w.author.map { .string($0) } ?? .null, "scope": .string(w.scope), "version": .string(w.version),
                "apiVersion": .string(w.apiVersion), "archs": .array(w.archs.map { .string($0) }),
                "installed": .bool(installed), "installedVersion": iv.map { .string($0) } ?? .null,
                "runs": .bool(WidgetCatalog.runs(w, api: MeumKit.apiVersion, arch: Self.arch, meum: ControlInfo.appVersion)),
                "minMeum": w.minMeum.map { .string($0) } ?? .null,
                "needsMeum": w.needsMeum(ControlInfo.appVersion).map { .string($0) } ?? .null,
            ]
            let libSha = installed ? widgets?.entry(w.id).flatMap { try? WidgetHash.sha256(of: $0.library) } : nil
            o["update"] = .bool(installed && w.isUpdate(installedVersion: iv, installedLibrarySha256: libSha))
            o["collapsedSidebar"] = w.collapsedSidebar.map { .bool($0) } ?? .null
            o["helper"] = w.helper.map { .bool($0) } ?? .null
            return .object(o)
        }
        return ["url": .string(catalogURL ?? ""), "widgets": .array(entries)]
    }

    // MARK: install

    /// Installs (or updates to) the catalog's version of a widget.
    func install(_ id: String, updateOnly: Bool = false) async throws -> JSON {
        guard let widgets else { throw ControlError.unavailable("no widget host") }
        let c = try await fetchCatalog()
        guard let w = c.entry(id) ?? c.widgets.first(where: { $0.displayName.lowercased() == id.lowercased() }) else {
            throw ControlError.notFound("no widget '\(id)' in the catalog")
        }
        let existing = widgets.entry(w.id)
        if updateOnly {
            guard existing != nil else { throw ControlError.notFound("'\(w.id)' is not installed") }
            if let v = installedVersion(w.id), !widgetVersionIsNewer(w.version, than: v) {
                throw InstallError(description: "\(w.displayName) \(v) is already the newest")
            }
        }
        guard w.apiVersion == MeumKit.apiVersion else {
            throw InstallError(description: "\(w.displayName) speaks \(w.apiVersion), this meum speaks \(MeumKit.apiVersion)")
        }
        if let need = w.needsMeum(ControlInfo.appVersion) {
            throw InstallError(description: "\(w.displayName) \(w.version) needs meum \(need) or later; update meum first")
        }
        guard w.archs.contains(Self.arch) else {
            throw InstallError(description: "\(w.displayName) has no build for \(Self.arch) (only \(w.archs.joined(separator: ", ")))")
        }
        guard let url = URL(string: w.url), url.scheme == "https" || url.isFileURL else {
            throw InstallError(description: "bad download URL \(w.url)")
        }

        // a private work folder
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("meum-install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }

        // download and check the zip against the catalog
        let zip = work.appendingPathComponent("widget.zip")
        if url.isFileURL {
            try fm.copyItem(at: url, to: zip)
        } else {
            var req = URLRequest(url: url, timeoutInterval: 60)
            req.setValue("meum", forHTTPHeaderField: "User-Agent")
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
                throw InstallError(description: "download: HTTP \(h.statusCode) from \(w.url)")
            }
            try fm.moveItem(at: tmp, to: zip)
        }
        let zipHash = try WidgetHash.sha256(of: zip)
        guard zipHash == w.sha256.lowercased() else {
            throw InstallError(description: "the download does not match the catalog (sha256 \(zipHash.prefix(12))…, expected \(w.sha256.prefix(12))…); not installed")
        }

        // unpack and check the folder
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        let folders = (try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "meumwidget" }
        guard folders.count == 1, let folder = folders.first else {
            throw InstallError(description: "the zip must hold exactly one .meumwidget folder")
        }
        let manifestData = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let lib = manifest["library"] as? String, !lib.contains("/") else {
            throw InstallError(description: "manifest.json is missing or has no library")
        }
        guard (manifest["id"] as? String) == w.id else {
            throw InstallError(description: "the zip holds '\(manifest["id"] as? String ?? "?")', not '\(w.id)'")
        }
        let library = folder.appendingPathComponent(lib)
        guard fm.fileExists(atPath: library.path) else { throw InstallError(description: "\(lib) is missing from the zip") }
        // widgets must use meum's MeumKit, never a copy of their own (the types would not match)
        if let found = fm.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap({ $0 as? URL })
            .first(where: { $0.lastPathComponent == "libMeumKit.dylib" }) {
            throw InstallError(description: "the widget bundles its own \(found.lastPathComponent); it must use meum's")
        }
        let libHash = try WidgetHash.sha256(of: library)
        var helperHash: String?
        if let h = manifest["helper"] as? [String: Any], let cmd = h["command"] as? String {
            guard !cmd.hasPrefix("/"), !cmd.contains("..") else { throw InstallError(description: "the helper must live inside the widget folder") }
            helperHash = try WidgetHash.sha256(of: folder.appendingPathComponent(cmd))
        }

        // swap it in, keeping the disabled switch
        let dest = widgets.directory.appendingPathComponent(existing?.folder.lastPathComponent ?? folder.lastPathComponent)
        try fm.createDirectory(at: widgets.directory, withIntermediateDirectories: true)
        if let existing, fm.fileExists(atPath: existing.folder.appendingPathComponent("disabled").path) {
            fm.createFile(atPath: folder.appendingPathComponent("disabled").path, contents: Data())
        }
        if existing != nil { stopHelper?(w.id) }
        let old = work.appendingPathComponent("old", isDirectory: true)
        if fm.fileExists(atPath: dest.path) { try fm.moveItem(at: dest, to: old) }
        do {
            try fm.moveItem(at: folder, to: dest)
        } catch {
            if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: dest) }
            throw error
        }
        pins.pins[w.id] = .init(sha256: libHash, source: .catalog, version: w.version, helperSha256: helperHash)
        save()
        Log.info("widget \(existing == nil ? "installed" : "updated"): \(w.id) \(w.version)")
        widgets.reload()
        return widgets.listJSON()
    }

    /// Removes a widget: its tabs show "not installed", its card goes; `data` also deletes its data folder.
    func remove(_ id: String, data: Bool) throws -> JSON {
        guard let widgets, let e = widgets.entry(id) else { throw ControlError.notFound("no installed widget '\(id)'") }
        stopHelper?(e.id)
        try FileManager.default.removeItem(at: e.folder)
        pins.pins[e.id] = nil
        save()
        if data {
            try? FileManager.default.removeItem(at: widgets.dataDirectory(for: e.id))
        }
        Log.info("widget removed: \(e.id)\(data ? " (with its data)" : "")")
        widgets.reload()
        return widgets.listJSON()
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw InstallError(description: "\((tool as NSString).lastPathComponent) failed: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
