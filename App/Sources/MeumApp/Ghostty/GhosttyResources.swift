// adapted from thdxg/macterm (MIT), via umputun/agterm (MIT)
// meum: adapted from agterm agterm/Ghostty/GhosttyResources.swift at 80f822bfe5d697567e18a4ce0f15569a55a729ea

import Foundation

/// Pure selection of the ghostty resources directory for `GHOSTTY_RESOURCES_DIR`.
///
/// meum ships the ghostty resources in its bundle under `Contents/Resources/ghostty` (themes +
/// shell-integration), with the compiled terminfo DB at the sibling `Contents/Resources/terminfo`, the layout
/// a real Ghostty.app uses. libghostty derives `TERMINFO` as `dirname(GHOSTTY_RESOURCES_DIR)/terminfo` at shell
/// spawn, so pointing the env var at `.../Resources/ghostty` resolves terminfo to `.../Resources/terminfo`.
/// Missing or incorrect terminfo breaks key input and TERM=xterm-ghostty.
struct GhosttyResourceResolver {
    /// Candidate resource dirs, highest priority first.
    let candidates: [String]
    /// Filesystem existence probe. Injected so tests don't touch disk.
    let fileExists: (String) -> Bool

    /// The first candidate containing `shell-integration/`. Nil when none qualifies; the caller then unsets
    /// `GHOSTTY_RESOURCES_DIR`.
    func resolve() -> String? {
        candidates.first { fileExists($0 + "/shell-integration") }
    }

    /// The bundle's own resources only: meum never borrows another app's (Ghostty.app, cmux) resources, so an
    /// inherited `GHOSTTY_RESOURCES_DIR` cannot shadow ours.
    static func bundleCandidates(_ bundle: Bundle = .main) -> [String] {
        var out: [String] = []
        if let r = bundle.resourceURL?.path { out.append(r + "/ghostty") }
        return out
    }

    /// Resolves and exports `GHOSTTY_RESOURCES_DIR` (never `TERMINFO`: libghostty sets that at spawn).
    @discardableResult
    static func export() -> String? {
        let resolver = GhosttyResourceResolver(candidates: bundleCandidates(),
                                               fileExists: { FileManager.default.fileExists(atPath: $0) })
        guard let dir = resolver.resolve() else {
            unsetenv("GHOSTTY_RESOURCES_DIR")
            return nil
        }
        setenv("GHOSTTY_RESOURCES_DIR", dir, 1)
        return dir
    }
}
