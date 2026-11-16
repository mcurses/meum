// Every hand-off from meum to another app goes through here: the app macOS names for a file or a link is used
// only when it is installed (TerminalLinks.isInstalledApp), and then it is named explicitly, so the check and
// the open see the same app.
import AppKit
import MeumControl

enum InstalledAppOpen {
    /// `app` with symlinks resolved, when it is an installed app; nil otherwise.
    static func installed(_ app: URL?) -> URL? {
        guard let app else { return nil }
        return TerminalLinks.isInstalledApp(app.resolvingSymlinksInPath().path) ? app : nil
    }

    /// The installed app macOS would open `url` in, or nil (none, or one that is not installed).
    static func app(for url: URL) -> URL? { installed(NSWorkspace.shared.urlForApplication(toOpen: url)) }

    /// Why `url` is not opened, in a few words for a hover or the log; nil when it would open.
    static func refusal(for url: URL) -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return "no app opens it" }
        if installed(app) != nil { return nil }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        return "\(name) is not an installed app"
    }

    /// Opens `url` in its installed app; false (and a log line) when there is none.
    @discardableResult static func open(_ url: URL) -> Bool {
        guard let app = app(for: url) else {
            Log.info("not opened (\(refusal(for: url) ?? "no app")): \(url.absoluteString.prefix(200))")
            return false
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
