// What a click on an existing path may do: the checks that read the file system (symlinks, aliases, packages).
// TerminalLinks itself stays pure; these look at the real files.
import Foundation

extension TerminalLinks {
    /// Whether opening the folder at `path` would launch or act rather than show its contents. Both the path as
    /// written and the folder a symlink in it points to are checked: `docs -> P.app` acts like `P.app`.
    public static func folderActsWhenOpened(atPath path: String) -> Bool {
        let written = URL(fileURLWithPath: path)
        let target = written.resolvingSymlinksInPath()
        return [written, target].contains { u in
            folderActsWhenOpened(u.path, isPackage: (try? u.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true)
        }
    }

    /// The file a click on `path` acts on, symlinks resolved, or nil when it may only be shown in Finder: a Finder
    /// alias, reached directly or through a symlink, would open (and launch) whatever it points to. The caller runs
    /// its own checks on the returned path, so a symlink to an app is judged as the app.
    public static func fileToOpen(atPath path: String) -> String? {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        // the resolved path is no symlink, so isAliasFile here means a Finder alias (it is true for symlinks too)
        if (try? target.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true { return nil }
        return target.path
    }

    /// Folders an app may live in for meum to hand it a file or a link: where installers, the App Store and macOS
    /// put apps. An app anywhere else (inside a cloned repository, Downloads, a build folder) may have come with
    /// the very files it would be handed, and macOS registers such an app as an opener by itself.
    public static func installedAppFolders(home: String) -> [String] {
        // Safari and some other system apps resolve into the sealed system extension (cryptex) volume
        ["/Applications", "/System/Applications", "/System/Library/CoreServices",
         "/System/Volumes/Preboot/Cryptexes/App/System/Applications", home + "/Applications"]
    }

    /// Whether the app at `path` (symlinks already resolved) is installed in one of `installedAppFolders`.
    public static func isInstalledApp(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let p = (path as NSString).standardizingPath
        guard p.hasPrefix("/") else { return false }
        return installedAppFolders(home: home).contains { p.hasPrefix($0 + "/") }
    }
}
