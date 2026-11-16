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

    /// The helper to run for a widget, or nil when it may not run. The executable is copied into `directory`
    /// (meum's own, 0700) first and the copy is checked, by hash and signature; the spec returned runs that copy, so
    /// replacing the file in the widget folder after the check changes nothing. The copy is named after its hash:
    /// an unchanged helper keeps its path, and a running one is left alone on reload.
    func trustedHelper(_ e: WidgetManager.Entry, directory: URL) -> WidgetHelpers.Spec? {
        guard var spec = e.helper else { return nil }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let staging = directory.appendingPathComponent(".\(e.id)-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        // a symlink would be copied as a link, and the check would read whatever it points at: copy the real file,
        // and only one that is inside the widget folder
        guard let source = WidgetHelpers.realFile(URL(fileURLWithPath: spec.executable), inside: e.folder) else {
            Log.error("widget \(e.id): helper \(spec.executable) is not a file inside the widget folder; not started")
            return nil
        }
        guard (try? fm.copyItem(at: source, to: staging)) != nil, WidgetHelpers.isPlainFile(staging),
              let hash = try? WidgetHash.sha256(of: staging) else {
            Log.error("widget \(e.id): helper \(spec.executable) could not be read; not started")
            return nil
        }
        let s = settings()
        let t = WidgetTrust.decideHelper(id: e.id, sha256: hash, signedTeam: Self.signedTeam(staging, allowed: s.widgetTeamIDs),
                                         pins: pins, teams: s.widgetTeamIDs, developerMode: s.widgetDeveloperMode)
        guard t.allowsLoading else {
            Log.error("widget \(e.id): helper not started (not verified)")
            return nil
        }
        let copy = directory.appendingPathComponent("\(e.id)-\(hash)")
        if !fm.fileExists(atPath: copy.path) {
            do { try fm.moveItem(at: staging, to: copy) } catch {
                Log.error("widget \(e.id): helper copy failed: \(error)")
                return nil
            }
        }
        // older copies of this widget's helper (a running one keeps its file open)
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasPrefix("\(e.id)-") && name != copy.lastPathComponent {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        spec.executable = copy.path
        return spec
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
        // https like the zips it lists (or a local file): the catalog names the hashes the zips are checked against
        guard let url = URL(string: urlString), url.scheme == "https" || url.isFileURL else {
            throw InstallError(description: "the widget library address must be https:// (or file://): \(urlString)")
        }
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
        let work = try Self.workFolder()
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
        let checked = try Self.check(folder)
        guard checked.id == w.id else {
            throw InstallError(description: "the zip holds '\(checked.id)', not '\(w.id)'")
        }
        try swapIn(folder, id: w.id, existing: existing, work: work)
        pins.pins[w.id] = .init(sha256: checked.libraryHash, source: .catalog, version: w.version, helperSha256: checked.helperHash)
        save()
        Log.info("widget \(existing == nil ? "installed" : "updated"): \(w.id) \(w.version)")
        widgets.reload()
        return widgets.listJSON()
    }

    // MARK: checking a bundle

    /// A `.meumwidget` folder that passed the checks every install makes.
    struct Checked {
        var id: String
        var displayName: String
        var version: String?
        var library: URL
        var libraryHash: String
        var helperHash: String?
    }

    /// The checks every install makes on a widget folder (a private copy): a manifest naming a library inside it, a
    /// library that is a plain file, no MeumKit of its own, a helper inside the folder.
    nonisolated static func check(_ folder: URL) throws -> Checked {
        let fm = FileManager.default
        let manifestData = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let lib = manifest["library"] as? String, !lib.contains("/"), !lib.hasPrefix(".") else {
            throw InstallError(description: "manifest.json is missing or has no library")
        }
        guard let id = manifest["id"] as? String, !id.isEmpty, !id.contains("/") else {
            throw InstallError(description: "manifest.json has no id")
        }
        let library = folder.appendingPathComponent(lib)
        guard WidgetHelpers.isPlainFile(library) else { throw InstallError(description: "\(lib) is missing or not a plain file") }
        // widgets must use meum's MeumKit, never a copy of their own (the types would not match)
        if let found = fm.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap({ $0 as? URL })
            .first(where: { $0.lastPathComponent == "libMeumKit.dylib" }) {
            throw InstallError(description: "the widget bundles its own \(found.lastPathComponent); it must use meum's")
        }
        var helperHash: String?
        if let h = manifest["helper"] as? [String: Any], let cmd = h["command"] as? String {
            guard WidgetHelpers.isInsideFolder(cmd),
                  let real = WidgetHelpers.realFile(folder.appendingPathComponent(cmd), inside: folder) else {
                throw InstallError(description: "the helper must be a file inside the widget folder (not a link out of it)")
            }
            helperHash = try WidgetHash.sha256(of: real)
        }
        return Checked(id: id, displayName: (manifest["displayName"] as? String) ?? id,
                       version: manifest["version"] as? String, library: library,
                       libraryHash: try WidgetHash.sha256(of: library), helperHash: helperHash)
    }

    /// Moves a checked folder into the widgets directory in place of `existing` (keeping its disabled switch).
    /// `newName`: the folder a new install gets (an offer: named after its id, never a name the offering program
    /// chose); refused when a folder of that name exists, so an install never replaces another widget.
    private func swapIn(_ folder: URL, id: String, existing: WidgetManager.Entry?, work: URL, newName: String? = nil) throws {
        guard let widgets else { throw ControlError.unavailable("no widget host") }
        let fm = FileManager.default
        let dest = widgets.directory.appendingPathComponent(existing?.folder.lastPathComponent ?? newName ?? folder.lastPathComponent)
        if existing == nil, newName != nil, fm.fileExists(atPath: dest.path) {
            throw InstallError(description: "the widgets folder already has a \(dest.lastPathComponent) that is not this widget; not installed")
        }
        try fm.createDirectory(at: widgets.directory, withIntermediateDirectories: true)
        if let existing, fm.fileExists(atPath: existing.folder.appendingPathComponent("disabled").path) {
            fm.createFile(atPath: folder.appendingPathComponent("disabled").path, contents: Data())
        }
        if existing != nil { stopHelper?(id) }
        let old = work.appendingPathComponent("old", isDirectory: true)
        if fm.fileExists(atPath: dest.path) { try fm.moveItem(at: dest, to: old) }
        do {
            try fm.moveItem(at: folder, to: dest)
        } catch {
            if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: dest) }
            throw error
        }
    }

    /// A private work folder (0700), removed by the caller.
    nonisolated static func workFolder() throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("meum-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return work
    }

    /// The Team ID of a valid Developer ID signature on the file, whichever team it is; nil when unsigned or not
    /// Developer ID. (`signedTeam` asks the narrower question: one of the allowed teams.)
    nonisolated static func developerTeam(_ url: URL) -> String? { developerSigner(url)?.team }

    /// The Team ID and the certificate's name ("Name (TEAMID)", from "Developer ID Application: Name (TEAMID)") of a
    /// valid Developer ID signature on the file; nil when unsigned or not Developer ID.
    nonisolated static func developerSigner(_ url: URL) -> (team: String, name: String)? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var req: SecRequirement?
        let text = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and "
            + "certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess, let req,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), req) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        guard let team = dict[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
        var name = team
        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first,
           let summary = SecCertificateCopySubjectSummary(leaf) as String? {
            name = summary.replacingOccurrences(of: "Developer ID Application: ", with: "")
        }
        return (team, name)
    }

    // MARK: offers (docs/design/architecture.md, "First launch and offers")

    /// A widget another program offered (`widget.offer`), waiting for the person's Install or No. In memory only.
    struct Offer: Equatable {
        var id: String
        var displayName: String
        var version: String?
        var team: String
        /// The signing certificate's name with its team ("Name (TEAMID)"), for the card.
        var signer: String
        var path: String
        /// The library's hash when it was offered: Install refuses a bundle that changed since.
        var libraryHash: String
        var isUpdate: Bool
    }

    /// One per widget id, in the order they came.
    private(set) var offers: [Offer] = []
    /// Called when `offers` changes (the sidebar's offer card).
    var onOffersChanged: (() -> Void)?
    /// Opens Settings at a section (the allow step for a widget whose team is not trusted).
    var openSettings: ((String) -> Void)?

    /// The largest offered folder meum copies (a widget is a library, a manifest and maybe a helper).
    nonisolated static let offerMaxBytes = 16 << 20
    /// Longest widget name and version shown on the offer card.
    nonisolated static let offerMaxName = 60

    /// What a private copy of an offered folder holds, or why it was refused.
    struct OfferCheck: Sendable {
        var id = "", displayName = "", version: String?, libraryHash = "", team = "", signer = "", refused: String?
    }

    /// Copies an offered folder into a private work folder and checks it, off the main thread: not a link, at most
    /// `offerMaxBytes`, the install checks, a Developer ID signature.
    nonisolated static func checkOffered(_ url: URL) -> OfferCheck {
        var r = OfferCheck()
        guard url.pathExtension == "meumwidget" else { r.refused = "not a .meumwidget folder: \(url.path)"; return r }
        let fm = FileManager.default
        guard let type = (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType, type == .typeDirectory else {
            r.refused = "not a folder (a link to one is refused): \(url.path)"; return r
        }
        var bytes = 0, items = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: []) {
            for case let f as URL in e {
                bytes += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                items += 1
                if bytes > offerMaxBytes || items > 2000 {
                    r.refused = "the folder is larger than a widget (over \(offerMaxBytes >> 20) MB or 2000 files)"; return r
                }
            }
        }
        guard let work = try? workFolder() else { r.refused = "no work folder"; return r }
        defer { try? fm.removeItem(at: work) }
        let copy = work.appendingPathComponent(url.lastPathComponent, isDirectory: true)
        do { try run("/usr/bin/ditto", [url.path, copy.path]) } catch { r.refused = "cannot read \(url.path)"; return r }
        let c: Checked
        do { c = try check(copy) } catch { r.refused = "\(error)"; return r }
        guard let signer = developerSigner(c.library) else {
            r.refused = "\(c.library.lastPathComponent) is not signed with a Developer ID"; return r
        }
        func cap(_ t: String, _ n: Int) -> String { t.count > n ? String(t.prefix(n - 1)) + "…" : t }
        r.id = c.id
        r.displayName = cap(c.displayName.replacingOccurrences(of: "\n", with: " "), offerMaxName)
        r.version = c.version.map { cap($0, 20) }
        r.libraryHash = c.libraryHash
        r.team = signer.team
        r.signer = cap(signer.name, offerMaxName + 20)
        return r
    }

    /// Checks a bundle another program offers and, when it is new or newer and signed by the installed widget's team,
    /// shows it to the person as a card. Nothing is copied into the widgets folder or trusted here.
    func offer(path: String) async throws -> JSON {
        guard widgets != nil else { throw ControlError.unavailable("no widget host") }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let c = await Task.detached { Self.checkOffered(url) }.value
        if let reason = c.refused { return Self.refused(reason) }
        guard let widgets else { throw ControlError.unavailable("no widget host") }
        let existing = widgets.entry(manifestID: c.id)
        if existing == nil, FileManager.default.fileExists(atPath: widgets.directory.appendingPathComponent(c.id + ".meumwidget").path) {
            return Self.refused("the widgets folder already has a \(c.id).meumwidget that holds another widget")
        }
        if let existing, (try? WidgetHash.sha256(of: existing.library)) == c.libraryHash {
            return ["state": "installed", "id": .string(c.id)]
        }
        if let existing, let have = installedVersion(existing.id), let v = c.version, !widgetVersionIsNewer(v, than: have) {
            return Self.refused("\(c.displayName) \(have) is installed; the offer is \(v), not newer")
        }
        // an update comes from the developer of the installed widget, or not at all
        if let existing, Self.developerTeam(existing.library) != c.team {
            let had = Self.developerTeam(existing.library).map { "team \($0)" } ?? "no Developer ID"
            return Self.refused("\(c.displayName) is installed from \(had); the offer is signed by a different developer (team \(c.team))")
        }
        let o = Offer(id: c.id, displayName: c.displayName, version: c.version, team: c.team, signer: c.signer, path: url.path,
                      libraryHash: c.libraryHash, isUpdate: existing != nil)
        if let i = offers.firstIndex(where: { $0.id == o.id }) { offers[i] = o } else { offers.append(o) }
        Log.info("widget offered: \(o.id) \(o.version ?? "") signed by \(o.signer) from \(o.path)")
        onOffersChanged?()
        return ["state": "offered", "id": .string(o.id), "team": .string(o.team)]
    }

    nonisolated private static func refused(_ reason: String) -> JSON {
        Log.info("widget offer refused: \(reason)")
        return ["state": "refused", "reason": .string(reason)]
    }

    /// The person's No: the card goes, nothing changes.
    func declineOffer(_ id: String) {
        offers.removeAll { $0.id == id }
        onOffersChanged?()
    }

    /// The person's Install: copies the offered bundle again into a private folder, checks it again (it must be what
    /// the card showed), and moves it into the widgets folder. It is not pinned: a team on the allow list loads it,
    /// any other opens Settings ▸ Widgets at the widget, whose Allow is the only place trust is given.
    func acceptOffer(_ id: String) throws {
        guard let widgets else { throw ControlError.unavailable("no widget host") }
        guard let o = offers.first(where: { $0.id == id }) else { throw ControlError.notFound("no offer for '\(id)'") }
        offers.removeAll { $0.id == id }
        onOffersChanged?()
        let url = URL(fileURLWithPath: o.path)
        if let reason = Self.checkOffered(url).refused { throw InstallError(description: "\(o.displayName): \(reason); not installed") }
        let work = try Self.workFolder()
        defer { try? FileManager.default.removeItem(at: work) }
        let copy = work.appendingPathComponent(url.lastPathComponent, isDirectory: true)
        try Self.run("/usr/bin/ditto", [o.path, copy.path])
        let c = try Self.check(copy)
        guard c.id == o.id, c.libraryHash == o.libraryHash, Self.developerTeam(c.library) == o.team else {
            throw InstallError(description: "\(o.displayName) changed since it was offered; not installed")
        }
        let existing = widgets.entry(manifestID: o.id)
        if let existing, Self.developerTeam(existing.library) != o.team {
            throw InstallError(description: "\(o.displayName) is installed from another developer; not installed")
        }
        try swapIn(copy, id: o.id, existing: existing, work: work, newName: o.id + ".meumwidget")
        // an older pin (a library install) is not this bundle's
        pins.pins[o.id] = nil
        save()
        Log.info("widget installed from an offer: \(o.id) \(o.version ?? "") signed by \(o.team)")
        widgets.reload()
        if !settings().widgetTeamIDs.contains(o.team) { openSettings?("widgets") }
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

    nonisolated private static func run(_ tool: String, _ args: [String]) throws {
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
