// Persistence of the model as JSON (`layout.json` in the state dir), atomic writes.

import Foundation

public enum PersistenceError: Error, Equatable {
    case unsupportedVersion(Int)
}

public struct LayoutStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }
    public init(paths: StatePaths) { self.url = paths.layout }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    /// Loads the state. Nil when there is no file yet. Throws on a corrupt file or a newer version, so the
    /// caller can keep the bad file aside instead of overwriting it.
    public func load() throws -> AppState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        var state = try JSONDecoder().decode(AppState.self, from: data)
        guard state.version <= AppState.currentVersion else {
            throw PersistenceError.unsupportedVersion(state.version)
        }
        state.version = AppState.currentVersion
        state.normalize()
        return state
    }

    /// Writes atomically (temp file + rename), mode 0600, creating the directory (0700) if needed.
    public func save(_ state: AppState) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try Self.encoder().encode(state)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Moves an unreadable file aside (`layout.json.corrupt-<unix time>`) and returns the new path.
    @discardableResult
    public func quarantine(now: Date = Date()) -> URL? {
        let dest = url.appendingPathExtension("corrupt-\(Int(now.timeIntervalSince1970))")
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }
}
