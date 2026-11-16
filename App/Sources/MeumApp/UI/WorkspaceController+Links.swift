// Links in terminals: what a ⌘-click (ghostty's OPEN_URL), a ⇧⌘-click, the link menu and the keyboard hints do.
// Finding and resolving is MeumControl's `TerminalLinks`; this file decides the app that opens a target.

import AppKit
import MeumControl
import MeumCore
import UniformTypeIdentifiers

extension WorkspaceController: SurfaceLinkHost {
    static let browserWidgetID = "io.github.mcurses.meum.browser"

    /// Folders a relative path in `tab` is tried against: the shell's folder, then Claude's (where it was started,
    /// where it is now), then the workspace's.
    func linkBases(tab id: UUID) -> [String] {
        guard let ws = store.state.workspace(containingTab: id), let tab = ws.tab(id) else { return [] }
        return [tab.cwd, tab.agent?.cwd, tab.agent?.projectDir, ws.cwd].compactMap { $0 }
    }

    func linkTarget(_ raw: String, tab: UUID) -> TerminalLinks.Target? {
        TerminalLinks.resolve(raw, bases: linkBases(tab: tab))
    }

    /// ⌘-click (`alternate` false) and ⇧⌘-click (true) on a link in `tab`.
    func openLink(_ raw: String, tab: UUID, alternate: Bool) {
        guard let t = linkTarget(raw, tab: tab) else {
            Log.info("link not opened (no such file or an unsupported scheme): \(raw.prefix(200))")
            NSSound.beep()
            return
        }
        perform(t, tab: tab, alternate: alternate)
    }

    func perform(_ t: TerminalLinks.Target, tab: UUID, alternate: Bool) {
        switch t {
        case .web(let u, let local):
            if local != alternate { openBeside(u, from: tab) } else { openChecked(u) }
        case .mail(let u):
            openChecked(u)
        case .file(let p, let l, let c):
            if alternate { revealInFinder(p) } else { openFile(p, line: l, column: c) }
        case .folder(let p):
            if alternate { newTerminalTab(in: p, beside: tab) }
            else if Self.folderActsWhenOpened(p) { revealInFinder(p) }
            else { openURL(URL(fileURLWithPath: p)) }
        }
    }

    /// A folder that is really an app or another package: Finder would launch it, so a click only shows it.
    static func folderActsWhenOpened(_ p: String) -> Bool { TerminalLinks.folderActsWhenOpened(atPath: p) }

    /// Opens a link in its app when that app is installed; otherwise beeps (the hover already says why).
    func openChecked(_ u: URL) {
        if let why = InstalledAppOpen.refusal(for: u) {
            Log.info("link not opened (\(why)): \(u.absoluteString.prefix(200))")
            NSSound.beep()
            return
        }
        openURL(u)
    }

    /// What `perform` does, in a few words (the hover line, the hints, the menu).
    func linkActionTitle(_ t: TerminalLinks.Target, alternate: Bool) -> String {
        switch t {
        case .web(let u, let local):
            if local != alternate { return "Open beside" }
            if let why = InstalledAppOpen.refusal(for: u) { return "Not opened: \(why)" }
            return "Open in \(appName(for: u) ?? "browser")"
        case .mail(let u):
            if let why = InstalledAppOpen.refusal(for: u) { return "Not opened: \(why)" }
            return "Write mail"
        case .file(let p, _, _):
            if alternate { return "Show in Finder" }
            // no app may open it (an alias, an app, a file whose opener is not installed): the click only shows it
            let o = fileOpener(p)
            return o.app == nil ? "Show in Finder" : "Open in \(o.name)"
        case .folder(let p):
            return alternate ? "New tab here" : Self.folderActsWhenOpened(p) ? "Show in Finder" : "Open in Finder"
        }
    }

    // MARK: - Files

    struct FileOpener {
        let app: URL?
        let name: String
        let bundleID: String?
    }

    /// The app `path` opens in: the linkEditor setting for text, else the file's default app; a script, an app or
    /// a file without a default app goes to a text editor, so a click never runs anything.
    func fileOpener(_ path: String) -> FileOpener {
        // a Finder alias opens its target; a symlink is judged by the file it points to
        guard let real = TerminalLinks.fileToOpen(atPath: path) else { return FileOpener(app: nil, name: "Finder", bundleID: nil) }
        let url = URL(fileURLWithPath: real)
        let rv = try? url.resourceValues(forKeys: [.contentTypeKey, .isPackageKey, .isExecutableKey])
        let type = rv?.contentType
        let isText = type.map { $0.conforms(to: .text) || $0.conforms(to: .sourceCode) } ?? true
        let runnable = rv?.isPackage == true || rv?.isExecutable == true
            || type.map { $0.conforms(to: .application) || $0.conforms(to: .executable) || $0.conforms(to: .script)
                || $0.conforms(to: .package) || $0.conforms(to: .applicationBundle)
                || $0.conforms(to: .diskImage) || $0.conforms(to: .archive) || $0.conforms(to: .internetLocation)
                || $0.conforms(to: .bundle) } ?? false
            || TerminalLinks.runnableSuffixes.contains(url.pathExtension.lowercased())
        func make(_ candidate: URL?) -> FileOpener {
            // an app that is not installed (one that came inside a cloned folder, say) is never handed the file
            let app = InstalledAppOpen.installed(candidate)
            let b = app.flatMap { Bundle(url: $0)?.bundleIdentifier }
            let name = app.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            return FileOpener(app: app, name: name ?? "Finder", bundleID: b)
        }
        // a terminal app as the editor would run a script it is handed, so it is ignored (the socket refuses it too)
        let chosen = settings.linkEditor.flatMap { TerminalLinks.terminalApps.contains($0) ? nil : $0 }
            .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        if isText, let chosen = InstalledAppOpen.installed(chosen) { return make(chosen) }
        if runnable {
            // a bundle or a binary is shown in Finder; a script opens as text
            guard isText || type?.conforms(to: .script) == true else { return FileOpener(app: nil, name: "Finder", bundleID: nil) }
            return make(InstalledAppOpen.installed(chosen) ?? textEditor)
        }
        if let app = NSWorkspace.shared.urlForApplication(toOpen: url) {
            // a terminal app as the default for a text file would run it, not show it
            if let b = Bundle(url: app)?.bundleIdentifier, TerminalLinks.terminalApps.contains(b) { return make(textEditor) }
            return make(app)
        }
        return make(isText ? textEditor : nil)
    }


    var textEditor: URL? { NSWorkspace.shared.urlForApplication(toOpen: .plainText) }

    func openFile(_ path: String, line: Int?, column: Int?) {
        let o = fileOpener(path)
        guard let app = o.app, let real = TerminalLinks.fileToOpen(atPath: path) else { revealInFinder(path); return }
        let path = real
        let file = URL(fileURLWithPath: path)
        if let b = o.bundleID, let u = TerminalLinks.editorURL(bundleID: b, path: path, line: line, column: column) {
            NSWorkspace.shared.open([u], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        if o.bundleID == "com.apple.dt.Xcode", let line {
            // xed opens the file in the running Xcode at the line
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xed")
            p.arguments = ["--line", String(line), path]
            if (try? p.run()) != nil { return }
        }
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func appName(for url: URL) -> String? {
        NSWorkspace.shared.urlForApplication(toOpen: url).map {
            FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
        }
    }

    // MARK: - Beside

    /// Shows `url` in a browser tab beside `tab`: the workspace's browser tab in another card if it has one,
    /// else a new card to the right. The keyboard stays in the terminal. Without the browser widget: the browser.
    func openBeside(_ url: URL, from tabID: UUID) {
        guard let ws = store.state.workspace(containingTab: tabID), let card = ws.card(containingTab: tabID),
              let widgets, let entry = widgets.entry(Self.browserWidgetID) else {
            openURL(url)
            return
        }
        let prior = ws.focusedCardID
        let message = (try? JSONSerialization.data(withJSONObject: ["navigate": url.absoluteString]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        if let other = ws.cards.first(where: { $0.id != card.id && $0.tabs.contains { $0.widget == Self.browserWidgetID } }),
           let existing = other.tabs.first(where: { $0.widget == Self.browserWidgetID }) {
            store.mutate(.structure(animate: false)) { s in
                s.updateWorkspace(ws.id) { w in
                    _ = w.selectTab(existing.id)
                    if let prior { w.focusCard(prior) }
                }
            }
            if let (w, _) = try? widgets.target(tab: existing.id, widget: nil) { w.receive(message) { _ in } }
        } else {
            let config = (try? JSONSerialization.data(withJSONObject: ["url": url.absoluteString]))
                .flatMap { String(data: $0, encoding: .utf8) }
            let tab = Tab(title: entry.displayName, cwd: ws.tab(tabID)?.cwd ?? ws.cwd, widget: entry.id, widgetConfig: config)
            store.mutate { s in
                s.updateWorkspace(ws.id) { w in
                    w.split(card.id, placement: .right, tab: tab)
                    if let prior { w.focusCard(prior) }
                }
            }
        }
        focusTerminal()
    }

    /// A terminal tab in `folder`, in the card of `tab`.
    func newTerminalTab(in folder: String, beside tabID: UUID) {
        guard let ws = store.state.workspace(containingTab: tabID), let card = ws.card(containingTab: tabID) else { return }
        let tab = Tab(cwd: folder)
        store.mutate { $0.updateWorkspace(ws.id) { $0.addTab(tab, toCard: card.id) } }
        focusTerminal()
    }

    // MARK: - Menu

    /// The right-click menu for a link: both actions, Finder, copy.
    func linkMenu(_ t: TerminalLinks.Target, tab: UUID) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let header = NSMenuItem(title: t.display(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(linkActionTitle(t, alternate: false), key: "⌘") { [weak self] in
            self?.perform(t, tab: tab, alternate: false)
        })
        m.addItem(ClosureMenuItem(linkActionTitle(t, alternate: true), key: "⇧⌘") { [weak self] in
            self?.perform(t, tab: tab, alternate: true)
        })
        switch t {
        case .web(let u, _):
            m.addItem(.separator())
            m.addItem(ClosureMenuItem("Copy Link") { Self.copy(u.absoluteString) })
        case .mail(let u):
            m.addItem(.separator())
            m.addItem(ClosureMenuItem("Copy Address") { Self.copy(String(u.absoluteString.dropFirst("mailto:".count))) })
        case .file(let p, let l, _):
            m.addItem(.separator())
            m.addItem(ClosureMenuItem("Copy Path") { Self.copy(p) })
            if let l { m.addItem(ClosureMenuItem("Copy Path with Line") { Self.copy("\(p):\(l)") }) }
        case .folder(let p):
            m.addItem(ClosureMenuItem("Show in Finder") { [weak self] in self?.revealInFinder(p) })
            m.addItem(.separator())
            m.addItem(ClosureMenuItem("Copy Path") { Self.copy(p) })
        }
        return m
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// A menu item that runs a closure (the link menu's items have no responder to send to).
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, key: String? = nil, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let key {
            // the modifier that does this on a click, shown on the right like a shortcut
            let a = NSMutableAttributedString(string: title + "\t")
            a.append(NSAttributedString(string: key + "-click", attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            let style = NSMutableParagraphStyle()
            style.tabStops = [NSTextTab(textAlignment: .right, location: 260)]
            a.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: a.length))
            a.addAttribute(.font, value: NSFont.menuFont(ofSize: 0), range: NSRange(location: 0, length: a.length))
            attributedTitle = a
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { run() }
}
