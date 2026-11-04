// The widget library: the catalog meum installs widgets from, the hashes it pins, and the trust decision made
// before a widget library is loaded (docs/design/widget-library.md).
//
// A widget loads if one of these holds:
//   pinned     its dylib matches the sha256 recorded when it was installed from the catalog, or allowed by the user
//   team       it carries a valid Apple-anchored signature from a Team ID in `Settings.widgetTeamIDs`
//   developer  `Settings.widgetDeveloperMode` is on (anything loads; for people building widgets)
// Otherwise it is "unverified" and not loaded; Settings ▸ Widgets (or `meum widget allow <id>`) pins it.

import CryptoKit
import Foundation

/// `catalog.json`: the widgets meum can install.
public struct WidgetCatalog: Codable, Equatable, Sendable {
    public var version: Int
    public var widgets: [Entry]

    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var displayName: String
        public var description: String
        public var author: String?
        /// global | workspace | tile
        public var scope: String
        public var version: String
        /// The MeumKit API the widget speaks ("meum.v1").
        public var apiVersion: String
        /// CPU architectures the dylib contains ("arm64", "x86_64").
        public var archs: [String]
        /// The zip of the `.meumwidget` folder.
        public var url: String
        /// sha256 of the zip, lowercase hex.
        public var sha256: String
        /// sha256 of the widget's signed library inside the zip: an installed library with another hash is not this
        /// version. Optional (older entries lack it).
        public var librarySha256: String?
        /// Whether its sidebar card has a collapsed look (for the library list; the widget itself decides).
        public var collapsedSidebar: Bool?
        /// Whether it ships a background helper (manifest "helper").
        public var helper: Bool?
        /// The oldest meum that runs it (the release whose MeumKit has everything it uses). meum before 0.5
        /// ignores the field; newer ones don't offer the widget to an older meum.
        public var minMeum: String?

        public init(id: String, displayName: String, description: String, author: String? = nil, scope: String,
                    version: String, apiVersion: String, archs: [String], url: String, sha256: String,
                    collapsedSidebar: Bool? = nil, helper: Bool? = nil, librarySha256: String? = nil, minMeum: String? = nil) {
            self.id = id
            self.displayName = displayName
            self.description = description
            self.author = author
            self.scope = scope
            self.version = version
            self.apiVersion = apiVersion
            self.archs = archs
            self.url = url
            self.sha256 = sha256
            self.collapsedSidebar = collapsedSidebar
            self.helper = helper
            self.librarySha256 = librarySha256
            self.minMeum = minMeum
        }

        /// The meum version this entry needs and `meum` (this app's version; nil in a development build) lacks.
        public func needsMeum(_ meum: String?) -> String? {
            guard let minMeum, let meum, widgetVersionIsNewer(minMeum, than: meum) else { return nil }
            return minMeum
        }

        /// Whether this entry is an update for an installed copy. A known installed version decides by version; an
        /// unknown one (installed before the library) by the library's hash when the entry has one, else it counts
        /// as an update, so it can be brought under the library's control.
        public func isUpdate(installedVersion: String?, installedLibrarySha256: String?) -> Bool {
            if let v = installedVersion { return widgetVersionIsNewer(version, than: v) }
            if let want = librarySha256, let have = installedLibrarySha256 { return want != have }
            return true
        }
    }

    public init(version: Int = 1, widgets: [Entry] = []) {
        self.version = version
        self.widgets = widgets
    }

    public func entry(_ id: String) -> Entry? { widgets.first { $0.id == id } }

    /// Whether this meum can run the entry: same API, a matching CPU, and not older than its `minMeum`.
    public static func runs(_ e: Entry, api: String, arch: String, meum: String? = nil) -> Bool {
        e.apiVersion == api && e.archs.contains(arch) && e.needsMeum(meum) == nil
    }
}

/// Versions like "1.2.10": compared numerically by component; a missing component counts as 0.
public func widgetVersionIsNewer(_ a: String, than b: String) -> Bool {
    let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
        if x != y { return x > y }
    }
    return false
}

/// The hashes meum trusts, per widget id: `widget-pins.json` in the state dir (mode 0600).
public struct WidgetPins: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// installed from the catalog (the zip matched the catalog's sha256)
        case catalog
        /// allowed by the user in Settings or with `meum widget allow`
        case allowed
        /// already installed when meum first started pinning (so an upgrade breaks nothing)
        case existing
    }

    public struct Pin: Codable, Equatable, Sendable {
        /// sha256 of the widget's dylib, lowercase hex.
        public var sha256: String
        public var source: Source
        /// The catalog version installed (nil for allowed / existing).
        public var version: String?
        /// sha256 of the widget's background helper executable, if it has one.
        public var helperSha256: String?

        public init(sha256: String, source: Source, version: String? = nil, helperSha256: String? = nil) {
            self.sha256 = sha256
            self.source = source
            self.version = version
            self.helperSha256 = helperSha256
        }
    }

    public var pins: [String: Pin]

    public init(pins: [String: Pin] = [:]) { self.pins = pins }
}

extension StatePaths {
    public var widgetPins: URL { directory.appendingPathComponent("widget-pins.json") }
}

/// Reads and writes `widget-pins.json`.
public struct WidgetPinStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }
    public init(paths: StatePaths) { self.url = paths.widgetPins }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    public func load() -> WidgetPins {
        guard let data = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(WidgetPins.self, from: data) else {
            return WidgetPins()
        }
        return p
    }

    public func save(_ p: WidgetPins) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(p).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Why a widget may (or may not) load.
public enum WidgetTrust: Equatable, Sendable {
    case pinned(WidgetPins.Source)
    case team(String)
    case developer
    case unverified(String)

    public var allowsLoading: Bool { if case .unverified = self { return false } else { return true } }

    /// One word for the API and the CLI: pinned, team, developer, unverified.
    public var kind: String {
        switch self {
        case .pinned: return "pinned"
        case .team: return "team"
        case .developer: return "developer"
        case .unverified: return "unverified"
        }
    }

    /// The decision. `signedTeam` is the Team ID of a valid, Apple-anchored signature (nil if none).
    public static func decide(id: String, sha256: String, signedTeam: String?, pins: WidgetPins,
                              teams: [String], developerMode: Bool) -> WidgetTrust {
        if let p = pins.pins[id], p.sha256 == sha256 { return .pinned(p.source) }
        if let t = signedTeam, teams.contains(t) { return .team(t) }
        if developerMode { return .developer }
        if pins.pins[id] != nil { return .unverified("changed since it was installed or allowed") }
        return .unverified("not from the widget library and not signed by a trusted developer")
    }
}

extension WidgetTrust {
    /// Whether a widget's helper executable may run: the same rules as its library, against the pin's helper hash.
    public static func decideHelper(id: String, sha256: String, signedTeam: String?, pins: WidgetPins,
                                    teams: [String], developerMode: Bool) -> WidgetTrust {
        if let p = pins.pins[id], p.helperSha256 == sha256 { return .pinned(p.source) }
        if let t = signedTeam, teams.contains(t) { return .team(t) }
        if developerMode { return .developer }
        return .unverified("helper not verified")
    }
}

public enum WidgetHash {
    /// sha256 of a file, lowercase hex.
    public static func sha256(of url: URL) throws -> String {
        let h = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe))
        return h.map { String(format: "%02x", $0) }.joined()
    }
}
