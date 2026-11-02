// Thin POSIX helpers shared by server and client. Foundation/Darwin only.
import Foundation

enum SocketIO {
    /// sun_path is 104 bytes on macOS including the NUL.
    static let maxPathBytes = 103

    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathBytes else {
            throw ControlError.invalidParams("socket path is too long (\(bytes.count) > \(maxPathBytes) bytes): \(path)")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: &addr) { p in
            try p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                try body(sp, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func newSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw ControlError.internalError("socket(): \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func setTimeout(_ fd: Int32, option: Int32, seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Writes all bytes; false on any error (peer gone, timeout).
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { return false }
                off += n
            }
            return true
        }
    }

    /// Reads up to 64 KiB. nil on EOF, error or timeout (see `timedOut`).
    static func readChunk(_ fd: Int32) -> (data: Data?, timedOut: Bool) {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 { return (Data(buf[0..<n]), false) }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return (nil, true) }
            }
            return (nil, false)
        }
    }
}

/// Owns a file descriptor; closes it when the last reference goes away.
final class FileDescriptor: @unchecked Sendable {
    let fd: Int32
    private let writeLock = NSLock()

    init(_ fd: Int32) { self.fd = fd }
    deinit { close(fd) }

    /// Serialized, so responses and event lines never interleave.
    func send(_ data: Data) -> Bool {
        writeLock.lock(); defer { writeLock.unlock() }
        return SocketIO.writeAll(fd, data)
    }

    func sendLine(_ data: Data) -> Bool {
        var d = data
        d.append(0x0A)
        return send(d)
    }

    /// Wakes a blocked reader and makes later writes fail. Does not release the descriptor.
    func shutdownBoth() { shutdown(fd, SHUT_RDWR) }
}
