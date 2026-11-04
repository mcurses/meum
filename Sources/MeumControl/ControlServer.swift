// Unix socket server: accepts connections, frames lines, dispatches to the injected ControlHandler,
// and streams events. Knows nothing about AppKit or the model.
import Foundation

public final class ControlServer: @unchecked Sendable {
    public let socketPath: String
    public let bus: EventBus
    private let handler: ControlHandler
    private let log: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var listener: FileDescriptor?
    private var acceptThread: Thread?
    private var acceptDone: DispatchSemaphore?
    private var running = false
    private var connections: [ObjectIdentifier: Connection] = [:]

    public init(socketPath: String, handler: ControlHandler, bus: EventBus = EventBus(),
                log: (@Sendable (String) -> Void)? = nil) {
        self.socketPath = socketPath
        self.handler = handler
        self.bus = bus
        self.log = log
    }

    deinit { stop() }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    public var connectionCount: Int { lock.lock(); defer { lock.unlock() }; return connections.count }

    // MARK: lifecycle

    public func start() throws {
        lock.lock()
        if running { lock.unlock(); return }
        lock.unlock()

        let dir = (socketPath as NSString).deletingLastPathComponent
        try createStateDir(dir)
        try removeStaleSocket()

        let fd = try SocketIO.newSocket()
        do {
            try SocketIO.withAddress(socketPath) { sa, len in
                if bind(fd, sa, len) != 0 {
                    throw ControlError.unavailable("bind \(socketPath): \(String(cString: strerror(errno)))")
                }
            }
            chmod(socketPath, 0o600)
            if listen(fd, 64) != 0 {
                throw ControlError.unavailable("listen: \(String(cString: strerror(errno)))")
            }
        } catch {
            close(fd)
            unlink(socketPath)
            throw error
        }

        let l = FileDescriptor(fd)
        let done = DispatchSemaphore(value: 0)
        lock.lock()
        listener = l
        acceptDone = done
        running = true
        lock.unlock()

        let t = Thread { [weak self] in
            self?.acceptLoop(l)
            done.signal()
        }
        t.name = "meum.control.accept"
        t.start()
        lock.lock(); acceptThread = t; lock.unlock()
        log?("listening on \(socketPath)")
    }

    /// Stops accepting, closes every connection, removes the socket file. Safe to call twice.
    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        let done = acceptDone
        lock.unlock()

        done?.wait()   // accept loop polls with a short timeout and exits once `running` is false
        lock.lock()
        let conns = Array(connections.values)
        lock.unlock()
        for c in conns { c.shutdown() }
        lock.lock()
        listener = nil
        acceptThread = nil
        lock.unlock()
        unlink(socketPath)
        log?("stopped")
    }

    private func createStateDir(_ dir: String) throws {
        guard !dir.isEmpty else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) {
            if !isDir.boolValue { throw ControlError.unavailable("\(dir) exists and is not a directory") }
            return
        }
        // Create each missing component with 0700 (only directories we create get that mode).
        var missing: [String] = []
        var p = dir
        while !p.isEmpty, p != "/", !FileManager.default.fileExists(atPath: p) {
            missing.append(p)
            p = (p as NSString).deletingLastPathComponent
        }
        for d in missing.reversed() {
            if mkdir(d, 0o700) != 0 && errno != EEXIST {
                throw ControlError.unavailable("mkdir \(d): \(String(cString: strerror(errno)))")
            }
            chmod(d, 0o700)
        }
    }

    private func removeStaleSocket() throws {
        var st = stat()
        guard lstat(socketPath, &st) == 0 else { return }
        guard (st.st_mode & S_IFMT) == S_IFSOCK else {
            throw ControlError.conflict("\(socketPath) exists and is not a socket")
        }
        // A live server answers connect(); a stale file refuses it.
        let probe = try SocketIO.newSocket()
        defer { close(probe) }
        let rc = try SocketIO.withAddress(socketPath) { sa, len in connect(probe, sa, len) }
        if rc == 0 {
            throw ControlError.conflict("another server is already listening on \(socketPath)")
        }
        unlink(socketPath)
        log?("removed stale socket \(socketPath)")
    }

    // MARK: accept

    private func acceptLoop(_ l: FileDescriptor) {
        while isRunning {
            var pfd = pollfd(fd: l.fd, events: Int16(POLLIN), revents: 0)
            let rc = poll(&pfd, 1, 100)
            if rc <= 0 { continue }
            let cfd = accept(l.fd, nil, nil)
            if cfd < 0 { continue }
            var one: Int32 = 1
            setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            SocketIO.setTimeout(cfd, option: SO_SNDTIMEO, seconds: 5)
            let conn = Connection(fd: FileDescriptor(cfd))
            lock.lock()
            connections[ObjectIdentifier(conn)] = conn
            lock.unlock()
            serve(conn)
        }
    }

    private func finish(_ conn: Connection) {
        lock.lock()
        connections[ObjectIdentifier(conn)] = nil
        lock.unlock()
    }

    // MARK: per connection

    private final class Connection: @unchecked Sendable {
        let fd: FileDescriptor
        var subscription: EventBus.Subscription?
        init(fd: FileDescriptor) { self.fd = fd }
        func shutdown() { subscription?.cancel(); fd.shutdownBoth() }
    }

    private func serve(_ conn: Connection) {
        // Reader thread: blocking reads, framed into lines, fed to an async consumer.
        var continuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data> { continuation = $0 }
        let cont = continuation!
        let fdRef = conn.fd
        let reader = Thread {
            var lb = LineBuffer()
            readLoop: while true {
                let (chunk, _) = SocketIO.readChunk(fdRef.fd)
                guard let chunk else { break }
                do {
                    for line in try lb.append(chunk) { cont.yield(line) }
                } catch let e as ControlError {
                    _ = fdRef.sendLine(Response(id: .null, error: e).encoded())
                    break readLoop
                } catch { break readLoop }
            }
            cont.finish()
        }
        reader.name = "meum.control.conn"
        reader.start()

        let handler = self.handler
        let bus = self.bus
        Task { [weak self] in
            for await line in stream {
                let req: Request
                do { req = try Request.decode(line) } catch {
                    let e = (error as? ControlError) ?? .parseError("bad request")
                    _ = fdRef.sendLine(Response(id: .null, error: e).encoded())
                    continue
                }
                switch req.method {
                case MeumMethod.ping:
                    let r: JSON = ["api": .string(ControlInfo.apiVersion), "pid": .int(Int(getpid())),
                                   "seq": .int(bus.lastSeq), "version": ControlInfo.appVersion.map { .string($0) } ?? .null,
                                   "methods": .array(ControlInfo.methods.map { .string($0) })]
                    _ = fdRef.sendLine(Response(id: req.id, result: r).encoded())
                case MeumMethod.eventsSubscribe:
                    if conn.subscription != nil {
                        _ = fdRef.sendLine(Response(id: req.id, error: .conflict("already subscribed")).encoded())
                        continue
                    }
                    let after = req.params["after"]?.intValue
                    let types = req.params["types"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    let id = req.id
                    // Wait until the subscribe response is on the wire, so a pipelined next request
                    // can never be answered before it.
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        conn.subscription = bus.subscribe(
                            after: after, filter: EventFilter(patterns: types),
                            onStart: { info in
                                let r: JSON = ["subscribed": true, "seq": .int(info.seq), "gap": .bool(info.gap),
                                               "replayed": .int(info.replayed)]
                                _ = fdRef.sendLine(Response(id: id, result: r).encoded())
                                done.resume()
                            },
                            deliver: { [weak c = conn] event in
                                if !fdRef.sendLine(event.encoded()) {
                                    c?.shutdown()
                                }
                            })
                    }
                default:
                    let resp: Response
                    do {
                        let result = try await handler.handle(method: req.method, params: req.params)
                        resp = Response(id: req.id, result: result)
                    } catch let e as ControlError {
                        resp = Response(id: req.id, error: e)
                    } catch {
                        resp = Response(id: req.id, error: .internalError("\(error)"))
                    }
                    _ = fdRef.sendLine(resp.encoded())
                }
                if req.oneshot { break }
            }
            conn.shutdown()
            self?.finish(conn)
        }
    }
}
