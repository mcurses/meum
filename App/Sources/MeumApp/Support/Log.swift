import Foundation
import os

/// Logs to os_log and appends to `<state dir>/meum.log`.
enum Log {
    private static let logger = Logger(subsystem: "io.github.mcurses.meum", category: "app")
    nonisolated(unsafe) static var fileURL: URL?
    private static let queue = DispatchQueue(label: "meum.log")
    private static let t0 = Date()

    static func info(_ s: String) { write("info", s); logger.info("\(s, privacy: .public)") }
    static func error(_ s: String) { write("error", s); logger.error("\(s, privacy: .public)") }
    /// Only with the debug interface on (test runs): measurements and other chatter.
    nonisolated(unsafe) static var debugEnabled = false
    static func debug(_ s: @autoclosure () -> String) { if debugEnabled { write("debug", s()) } }

    private static func write(_ level: String, _ s: String) {
        guard let url = fileURL else { return }
        let line = String(format: "%@ [%7.3f] %@ %@\n", ISO8601DateFormatter().string(from: Date()),
                          Date().timeIntervalSince(t0), level, s)
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
