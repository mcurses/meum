// MeumCore: the host-free part of meum (model, BSP layout geometry and mutations, persistence).
// Owned by the app lane. See docs/design/architecture.md. Foundation only.

import Foundation

public enum MeumCore { public static let apiVersion = "meum.v1" }

/// The product name lives here and nowhere else in the core, so a rename is one edit per layer.
public enum Product {
    public static let name = "meum"
    public static let bundleID = "io.github.mcurses.meum"
    /// Prefix of every environment variable meum sets or reads (`MEUM_SOCKET`, `MEUM_TAB`, ...).
    public static let envPrefix = "MEUM_"
    /// Default prefix of the zmx session names meum creates (`meum-<12 hex of the tab id>`).
    public static let zmxPrefix = "meum-"
}

/// Where meum keeps its state. `~/.local/state/meum` by default; tests and debug runs inject another dir.
public struct StatePaths: Sendable, Equatable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func `default`(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> StatePaths {
        StatePaths(directory: home.appendingPathComponent(".local/state/\(Product.name)", isDirectory: true))
    }

    public var socket: URL { directory.appendingPathComponent("\(Product.name).sock") }
    public var layout: URL { directory.appendingPathComponent("layout.json") }
    public var log: URL { directory.appendingPathComponent("\(Product.name).log") }

    /// Creates the directory with mode 0700 (and tightens it if it already exists).
    public func ensureDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}

public enum ZmxNaming {
    /// `<prefix><first 12 hex chars of the tab UUID>`, lower case, dashes dropped.
    public static func sessionName(for tabID: UUID, prefix: String = Product.zmxPrefix) -> String {
        let hex = tabID.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        return prefix + hex.prefix(12)
    }
}
