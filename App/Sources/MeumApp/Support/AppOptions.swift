import Foundation
import MeumCore

/// Launch options. Every option has an env form so `open --env` and direct launches both work.
///
///   --state-dir DIR    / MEUM_STATE_DIR    state dir (default ~/.local/state/meum)
///   --zmx-prefix P     / MEUM_ZMX_PREFIX   zmx session name prefix (default "meum-"); tests use "meumtest-"
///   --debug-dir DIR    / MEUM_DEBUG_DIR    enables the debug control file interface (see DebugControl)
///   --widgets-dir DIR  / MEUM_WIDGETS_DIR  native widgets (default ~/.local/share/meum/widgets)
///   --autoquit SECONDS / MEUM_AUTOQUIT     quit after N seconds (test runs)
///   --frame x,y,w,h    / MEUM_FRAME        container frame in AppKit screen coords instead of the visible frame
///   ZMX_DIR                               passed through to zmx (an isolated socket dir for tests)
struct AppOptions {
    var stateDir: URL
    var zmxPrefix: String
    var debugDir: URL?
    var widgetsDir: URL?
    var autoquit: TimeInterval?
    var frame: CGRect?
    /// `MEUM_DEBUG_RESUME=1`: resume via EchoResumeProvider (prints instead of starting claude).
    var debugResume = false

    static func parse(arguments: [String] = CommandLine.arguments,
                      env: [String: String] = ProcessInfo.processInfo.environment) -> AppOptions {
        func arg(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        func value(_ flag: String, _ envKey: String) -> String? {
            arg(flag) ?? env[envKey].flatMap { $0.isEmpty ? nil : $0 }
        }
        let state = value("--state-dir", "MEUM_STATE_DIR").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? StatePaths.default().directory
        var frame: CGRect?
        if let f = value("--frame", "MEUM_FRAME") {
            let p = f.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if p.count == 4 { frame = CGRect(x: p[0], y: p[1], width: p[2], height: p[3]) }
        }
        return AppOptions(stateDir: state,
                          zmxPrefix: value("--zmx-prefix", "MEUM_ZMX_PREFIX") ?? Product.zmxPrefix,
                          debugDir: value("--debug-dir", "MEUM_DEBUG_DIR").map { URL(fileURLWithPath: $0) },
                          widgetsDir: value("--widgets-dir", "MEUM_WIDGETS_DIR").map { URL(fileURLWithPath: $0, isDirectory: true) },
                          autoquit: value("--autoquit", "MEUM_AUTOQUIT").flatMap(Double.init),
                          frame: frame,
                          debugResume: env["MEUM_DEBUG_RESUME"] == "1")
    }
}
