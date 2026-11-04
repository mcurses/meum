// Wire protocol: newline-delimited JSON, one request per line.
//   request : {"id":1,"method":"workspace.list","params":{...}}
//   response: {"id":1,"result":...}  or  {"id":1,"error":{"code":"not_found","message":"..."}}
//   event   : {"seq":7,"type":"tab.added","data":{...}}   (only on an events.subscribe connection)
import Foundation

public enum ControlInfo {
    /// Returned by `system.ping`. Bump only on breaking changes.
    public static let apiVersion = "meum.v1"
    public static let maxLineBytes = 16 * 1024 * 1024

    /// The meum release this binary belongs to: the CFBundleShortVersionString of the app bundle around it (the
    /// app's own executable, or bin/meum inside it). nil outside meum's bundle (swift build, tests).
    public static let appVersion: String? = bundleVersion(around: Bundle.main.executablePath)

    static let bundleID = "io.github.mcurses.meum"

    static func bundleVersion(around path: String?) -> String? {
        guard let path else { return nil }
        var url = URL(fileURLWithPath: path).resolvingSymlinksInPath().deletingLastPathComponent()
        while url.path != "/" && !url.path.isEmpty {
            if url.lastPathComponent == "Contents",
               let d = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist")) {
                // inside some other app (Xcode's test runner, say) this is not a meum release
                guard d["CFBundleIdentifier"] as? String == bundleID else { return nil }
                return d["CFBundleShortVersionString"] as? String
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// Every method this build answers, sorted (`system.ping` lists them, so a client can ask before it uses one).
    public static var methods: [String] { (Array(MeumMethod.serverOwned) + MeumMethod.handlerOwned).sorted() }
}

public struct ControlError: Error, Equatable, Sendable, Codable, CustomStringConvertible {
    public var code: String
    public var message: String
    public var data: JSON?

    public init(code: String, message: String, data: JSON? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var description: String { "\(code): \(message)" }

    public static func parseError(_ m: String) -> ControlError { .init(code: "parse_error", message: m) }
    public static func invalidRequest(_ m: String) -> ControlError { .init(code: "invalid_request", message: m) }
    public static func methodNotFound(_ method: String) -> ControlError {
        .init(code: "method_not_found", message: "unknown method '\(method)'")
    }
    public static func invalidParams(_ m: String) -> ControlError { .init(code: "invalid_params", message: m) }
    public static func notFound(_ m: String) -> ControlError { .init(code: "not_found", message: m) }
    public static func conflict(_ m: String) -> ControlError { .init(code: "conflict", message: m) }
    public static func unavailable(_ m: String) -> ControlError { .init(code: "unavailable", message: m) }
    public static func internalError(_ m: String) -> ControlError { .init(code: "internal", message: m) }
}

public struct Request: Equatable, Sendable {
    /// Echoed back verbatim in the response (number, string or null).
    public var id: JSON
    public var method: String
    public var params: JSON
    /// When true the server closes the connection after answering. `meum-hook` uses this so that
    /// `nc` returns immediately instead of waiting for its idle timeout.
    public var oneshot: Bool

    public init(id: JSON = .null, method: String, params: JSON = .object([:]), oneshot: Bool = false) {
        self.id = id
        self.method = method
        self.params = params
        self.oneshot = oneshot
    }

    public static func decode(_ line: Data) throws -> Request {
        let json: JSON
        do { json = try JSON.parse(line) } catch { throw ControlError.parseError("request is not valid JSON") }
        guard case .object(let o) = json else { throw ControlError.invalidRequest("request must be a JSON object") }
        guard let method = o["method"]?.stringValue, !method.isEmpty else {
            throw ControlError.invalidRequest("missing 'method'")
        }
        let params = o["params"] ?? .object([:])
        if !params.isNull, params.objectValue == nil {
            throw ControlError.invalidRequest("'params' must be an object")
        }
        return Request(id: o["id"] ?? .null, method: method,
                       params: params.isNull ? .object([:]) : params,
                       oneshot: o["oneshot"]?.boolValue ?? false)
    }

    public func encoded() -> Data {
        var o: [String: JSON] = ["id": id, "method": .string(method), "params": params]
        if oneshot { o["oneshot"] = true }
        return JSON.object(o).compactData()
    }
}

public struct Response: Equatable, Sendable {
    public var id: JSON
    public var result: JSON?
    public var error: ControlError?

    public init(id: JSON, result: JSON) { self.id = id; self.result = result; self.error = nil }
    public init(id: JSON, error: ControlError) { self.id = id; self.result = nil; self.error = error }

    public func encoded() -> Data {
        if let error {
            var e: [String: JSON] = ["code": .string(error.code), "message": .string(error.message)]
            if let d = error.data { e["data"] = d }
            return JSON.object(["id": id, "error": .object(e)]).compactData()
        }
        return JSON.object(["id": id, "result": result ?? .null]).compactData()
    }

    public static func decode(_ json: JSON) -> Response? {
        guard case .object(let o) = json, o["seq"] == nil else { return nil }
        let id = o["id"] ?? .null
        if let e = o["error"]?.objectValue {
            return Response(id: id, error: ControlError(code: e["code"]?.stringValue ?? "internal",
                                                        message: e["message"]?.stringValue ?? "",
                                                        data: e["data"]))
        }
        if let r = o["result"] { return Response(id: id, result: r) }
        return nil
    }
}

public struct Event: Equatable, Sendable {
    public var seq: Int
    public var type: String
    public var data: JSON

    public init(seq: Int, type: String, data: JSON) {
        self.seq = seq
        self.type = type
        self.data = data
    }

    public var json: JSON { .object(["seq": .int(seq), "type": .string(type), "data": data]) }
    public func encoded() -> Data { json.compactData() }

    public static func decode(_ json: JSON) -> Event? {
        guard let seq = json["seq"]?.intValue, let type = json["type"]?.stringValue else { return nil }
        return Event(seq: seq, type: type, data: json["data"] ?? .null)
    }
}

/// Splits a byte stream into newline-terminated lines. Empty lines are skipped, a trailing CR is stripped.
public struct LineBuffer {
    private var buffer = Data()
    public let maxLineBytes: Int

    public init(maxLineBytes: Int = ControlInfo.maxLineBytes) { self.maxLineBytes = maxLineBytes }

    public var pendingBytes: Int { buffer.count }

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            var line = buffer[buffer.startIndex..<nl]
            buffer = Data(buffer[buffer.index(after: nl)...])
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty { lines.append(Data(line)) }
        }
        if buffer.count > maxLineBytes {
            buffer.removeAll()
            throw ControlError.invalidRequest("line exceeds \(maxLineBytes) bytes")
        }
        return lines
    }
}

/// Default locations. The state dir is shared with the app (architecture.md, "Paths and environment").
public enum ControlPaths {
    public static func stateDir(home: String = NSHomeDirectory()) -> String { home + "/.local/state/meum" }
    public static func defaultSocket(home: String = NSHomeDirectory()) -> String { stateDir(home: home) + "/meum.sock" }

    /// `$MEUM_SOCKET` if set and non-empty, else the default path.
    public static func socketPath(env: [String: String] = ProcessInfo.processInfo.environment,
                                  home: String = NSHomeDirectory()) -> String {
        if let s = env["MEUM_SOCKET"], !s.isEmpty { return s }
        return defaultSocket(home: home)
    }
}
