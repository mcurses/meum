import Darwin
import Foundation
import MeumCore

/// The app's own environment is what every tab inherits (libghostty spawns `zmx attach` with it, and the zmx
/// daemon passes it on to the shell). So the scrub happens once, here, before libghostty starts.
enum ProcessEnvironment {
    /// Removes inherited terminal-host variables (the app may be launched from a cmux or Ghostty terminal,
    /// or from inside a zmx session) and makes sure SHELL is set (a Finder launch may not have it).
    static func scrub() {
        // CLAUDE*: a launch from inside Claude Code (CLAUDECODE, CLAUDE_CODE_*, CLAUDE_CONFIG_DIR) must not make
        // a `claude` in a tab believe it is nested or bind it to another profile; shell rc files re-set their own.
        let removePrefixes = ["CMUX_", "GHOSTTY_", "MEUM_", "CLAUDE"]
        let removeExact: Set<String> = [
            "TERMINFO", "CLAUDE_CONFIG_DIR", "ZMX_SESSION", "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
            "TMUX", "TMUX_PANE", "ITERM_SESSION_ID", "TERM_SESSION_ID",
        ]
        // keep our own launch options readable by AppOptions before this runs; they are not tab env
        for key in ProcessInfo.processInfo.environment.keys {
            if removeExact.contains(key) || removePrefixes.contains(where: { key.hasPrefix($0) }) {
                unsetenv(key)
            }
        }
        if ProcessInfo.processInfo.environment["SHELL"]?.isEmpty ?? true, let pw = getpwuid(getuid()),
           let sh = pw.pointee.pw_shell {
            setenv("SHELL", String(cString: sh), 1)
        }
        setenv("COLORTERM", "truecolor", 1)
    }

    static var shell: String {
        ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
    }

    static var home: String { NSHomeDirectory() }
}
