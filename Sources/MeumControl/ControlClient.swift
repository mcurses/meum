// Client for the control socket. Used by the `meum` CLI, and later by widgets and Tamago's daemon.
import Foundation

public enum ClientError: Error, CustomStringConvertible, Equatable {
    /// Nothing listening: socket file missing or stale.
    case notRunning(path: String)
    case connectFailed(path: String, reason: String)
    case io(String)
    case timeout
    case protocolError(String)

    public var description: String {
        switch self {
        case .notRunning(let p): return "meum is not running (no server on \(p))"
        case .connectFailed(let p, let r): return "cannot connect to \(p): \(r)"
        case .io(let m): return "connection error: \(m)"
        case .timeout: return "timed out waiting for the server"
        case .protocolError(let m): return "protocol error: \(m)"
        }
    }
}

public final class ControlClient: @unchecked Sendable {
    public let socketPath: String
    public let timeout: TimeInterval
    private var conn: FileDescriptor?
    private var lines = LineBuffer()
    private var pending: [Data] = []
    private var nextID = 1
    private let lock = NSLock()

    public init(socketPath: String = ControlPaths.socketPath(), timeout: TimeInterval = 30) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    deinit { close() }

    static func connect(path: String) throws -> FileDescriptor {
        let fd = try SocketIO.newSocket()
        let rc: Int32
        do {
            rc = try SocketIO.withAddress(path) { sa, len in Darwin.connect(fd, sa, len) }
        } catch {
            Darwin.close(fd)
            throw error
        }
        if rc != 0 {
            let e = errno
            Darwin.close(fd)
            if e == ENOENT || e == ECONNREFUSED { throw ClientError.notRunning(path: path) }
            throw ClientError.connectFailed(path: path, reason: String(cString: strerror(e)))
        }
        return FileDescriptor(fd)
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        conn?.shutdownBoth()
        conn = nil
        lines = LineBuffer()
        pending = []
    }

    /// Calls a method and returns its `result`. Server-side failures throw `ControlError`.
    @discardableResult
    public func call(_ method: String, _ params: JSON = .object([:])) throws -> JSON {
        lock.lock(); defer { lock.unlock() }
        let fd: FileDescriptor
        if let c = conn { fd = c } else {
            fd = try Self.connect(path: socketPath)
            SocketIO.setTimeout(fd.fd, option: SO_RCVTIMEO, seconds: timeout)
            SocketIO.setTimeout(fd.fd, option: SO_SNDTIMEO, seconds: timeout)
            conn = fd
        }
        let id = nextID
        nextID += 1
        let req = Request(id: .int(id), method: method, params: params)
        guard fd.sendLine(req.encoded()) else {
            conn = nil
            throw ClientError.io("write failed")
        }
        while true {
            let line = try nextLine(fd)
            guard let json = try? JSON.parse(line), let resp = Response.decode(json) else { continue }
            guard resp.id == .int(id) else { continue }
            if let e = resp.error { throw e }
            return resp.result ?? .null
        }
    }

    public func callAsync(_ method: String, _ params: JSON = .object([:])) async throws -> JSON {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                do { cont.resume(returning: try self.call(method, params)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    private func nextLine(_ fd: FileDescriptor) throws -> Data {
        while pending.isEmpty {
            let (chunk, timedOut) = SocketIO.readChunk(fd.fd)
            guard let chunk else {
                conn = nil
                throw timedOut ? ClientError.timeout : ClientError.io("server closed the connection")
            }
            do { pending.append(contentsOf: try lines.append(chunk)) } catch {
                conn = nil
                throw ClientError.protocolError("\(error)")
            }
        }
        return pending.removeFirst()
    }

    /// Opens a dedicated connection and switches it to the event stream. Replays events after `after`
    /// (if given), then streams live ones.
    public func subscribe(after: Int? = nil, types: [String] = [], timeout: TimeInterval? = nil) throws -> EventStream {
        let fd = try Self.connect(path: socketPath)
        var params: [String: JSON] = [:]
        if let after { params["after"] = .int(after) }
        if !types.isEmpty { params["types"] = .array(types.map { .string($0) }) }
        SocketIO.setTimeout(fd.fd, option: SO_SNDTIMEO, seconds: self.timeout)
        SocketIO.setTimeout(fd.fd, option: SO_RCVTIMEO, seconds: timeout ?? self.timeout)
        guard fd.sendLine(Request(id: .int(1), method: MeumMethod.eventsSubscribe, params: .object(params)).encoded()) else {
            throw ClientError.io("write failed")
        }
        let stream = EventStream(fd: fd)
        // The first line is the response; the replay follows.
        stream.info = try stream.readSubscribeResponse()
        // After the handshake, wait as long as the caller asked (nil: forever).
        SocketIO.setTimeout(fd.fd, option: SO_RCVTIMEO, seconds: timeout ?? 0)
        return stream
    }
}

/// A live event subscription. `next()` blocks until the next event, the stream ends (nil) or the timeout hits.
public final class EventStream: @unchecked Sendable {
    private let fd: FileDescriptor
    private var lines = LineBuffer()
    private var pending: [Data] = []
    /// The subscribe result: `seq`, `gap`, `replayed`.
    public fileprivate(set) var info: JSON = .null

    init(fd: FileDescriptor) { self.fd = fd }
    deinit { close() }

    /// Unblocks a pending `next()` (from any thread) and ends the stream.
    public func close() { fd.shutdownBoth() }

    private func line() throws -> Data? {
        while pending.isEmpty {
            let (chunk, timedOut) = SocketIO.readChunk(fd.fd)
            guard let chunk else {
                if timedOut { throw ClientError.timeout }
                return nil
            }
            do { pending.append(contentsOf: try lines.append(chunk)) } catch {
                throw ClientError.protocolError("\(error)")
            }
        }
        return pending.removeFirst()
    }

    fileprivate func readSubscribeResponse() throws -> JSON {
        guard let l = try line() else { throw ClientError.io("server closed the connection") }
        guard let json = try? JSON.parse(l), let resp = Response.decode(json) else {
            throw ClientError.protocolError("bad subscribe response")
        }
        if let e = resp.error { throw e }
        return resp.result ?? .null
    }

    /// nil when the server closed the stream.
    public func next() throws -> Event? {
        while true {
            guard let l = try line() else { return nil }
            if let json = try? JSON.parse(l), let e = Event.decode(json) { return e }
        }
    }

    /// Raw line variant for tools that just forward the stream.
    public func nextRaw() throws -> Data? { try line() }
}
