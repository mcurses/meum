import AppKit
import MeumControl
import MeumCore

/// Quits meum. AppKit ignores `terminate` while a window has a sheet attached (the setup sheet): those are closed
/// first, the same as Not Now. Every quit goes through here (the menu, an update's restart, tests).
@MainActor
enum AppQuit {
    static func now() {
        for w in NSApp.windows { if let s = w.attachedSheet { w.endSheet(s) } }
        (NSApp.delegate as? AppDelegate)?.setup.dismiss()
        NSApp.terminate(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: AppOptions
    var controller: WorkspaceController!
    var menu: MainMenu!
    var debug: DebugControl?
    var store: WorkspaceStore!
    var control: AppControl!
    var settings: AppSettings!
    var settingsWindow: SettingsWindowController!
    var help: HelpWindowController!
    let setup = SetupSheetController()
    var widgets: WidgetManager!
    var updater: Updater!
    var updates: UpdateCenter!

    init(options: AppOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let paths = StatePaths(directory: options.stateDir)
        do { try paths.ensureDirectory() } catch { NSLog("meum: cannot create state dir: \(error)") }
        Log.fileURL = paths.log
        Log.info("launch pid=\(getpid()) state=\(paths.directory.path) prefix=\(options.zmxPrefix)")

        Log.debugEnabled = options.debugDir != nil
        settings = AppSettings(store: SettingsStore(paths: paths))
        let s = settings.value
        GhosttyApp.shared.start(configDir: paths.directory, terminal: Self.terminal(s))
        if GhosttyApp.shared.app == nil { Log.error("libghostty did not start") }

        store = WorkspaceStore(persistence: LayoutStore(paths: paths))
        let sessions = ZmxSessions(binary: ZmxSessions.locate(), prefix: options.zmxPrefix)
        sessions.resume = resumeProvider(s)
        Log.info("zmx=\(sessions.binary) ghostty resources=\(GhosttyApp.shared.resourcesDir ?? "none")")
        if !s.reattachSessions {
            let n = sessions.killNow(tabs: Array(store.state.allTabIDs))
            Log.info("reattachSessions off: ended \(n) running session(s); tabs start fresh shells")
        }
        Wallpaper.shared.blur = CGFloat(s.glassBlur)
        controller = WorkspaceController(store: store, sessions: sessions, agents: NoAgentState(), paths: paths,
                                         frame: options.frame)
        controller.applySettings(s, old: nil)
        controller.tabBinDir = Bundle.main.resourceURL?.appendingPathComponent("bin").path
        control = AppControl(controller: controller)
        control.settings = settings
        control.attach()
        control.start(socket: paths.socket)
        settings.onChange = { [weak self] old, new, keys in self?.settingsChanged(old: old, new: new, keys: keys) }
        settingsWindow = SettingsWindowController(settings: settings)
        updater = Updater(stateDir: paths.directory, feedOverride: options.updateFeed, launchEnv: options.launchEnv,
                          isolated: options.isolated)
        updater.enabled = { [weak self] in self?.settings.value.checkUpdates ?? false }
        control.updater = updater
        settingsWindow.checkForUpdates = { [weak self] in self?.updater.checkInteractively() }
        menu = MainMenu(controller: controller)
        menu.onSettings = { [weak self] in self?.settingsWindow.show() }
        menu.onCheckForUpdates = { [weak self] in self?.updater.checkInteractively() }
        help = HelpWindowController(socket: paths.socket.path)
        menu.onHelp = { [weak self] in self?.help.show($0) }
        menu.onSettingsSection = { [weak self] in self?.settingsWindow.show(section: $0) }
        menu.onSetup = { [weak self] in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.setup.show(on: self.controller.window)
        }
        setup.onUninstallHelp = { [weak self] in self?.help.show(.uninstall) }
        WidgetSlotCardView.onGetWidgets = { [weak self] in self?.settingsWindow.show(section: "widgets") }
        SettingsJSON.themeNames = { GhosttyApp.shared.themeNames }
        control.onOpenSettings = { [weak self] in self?.settingsWindow.show(section: $0) }
        updates = UpdateCenter { [weak self] in self?.control.installer }
        updates.onChange = { [weak self] n in self?.menu.setUpdateCount(n) }
        updater.onAvailable = { [weak self] v in self?.updates.setAppUpdate(v) }
        settingsWindow.updates = updates
        menu.install(settings: settings.value)
        controller.background = options.background
        controller.start()
        widgets = WidgetManager(controller: controller, control: control, directory: options.widgetsDir)
        control.widgets = widgets
        control.installer.openSettings = { [weak self] section in
            Log.info("opening Settings at \(section)")
            // a background test instance never puts a window in front of the person at the Mac
            guard let self, !self.controller.background else { return }
            self.settingsWindow.show(section: section)
        }
        control.installer.onOffersChanged = { [weak self] in self?.showOffers() }
        controller.offerView.onAnswer = { [weak self] id, install in self?.answerOffer(id, install: install) }
        controller.widgets = widgets
        settingsWindow.widgets = widgets
        widgets.startHelpers()
        widgets.reload()
        if !options.background { NSApp.activate(ignoringOtherApps: true) }
        if options.debugDir == nil { updater.startAutomaticChecks() }
        if HookInstaller.mayRefreshScript(bundlePath: Bundle.main.bundlePath, home: NSHomeDirectory(),
                                          isolated: options.isolated, debug: options.debugDir != nil) {
            Self.refreshHookScript()
        }
        updates.start()
        // the first-launch sheet: once, on the real state only (a test instance would wire the real Claude config)
        if !options.isolated && options.debugDir == nil { setup.offerOnce(on: controller.window, settings: settings) }

        if let dir = options.debugDir {
            debug = DebugControl(dir: dir, controller: controller, control: control)
            controller.openURL = { [weak debug] in debug?.openedURLs.append($0.absoluteString) }
            controller.confirmLinkScheme = { [weak debug] scheme, _, _ in
                debug?.linkSchemeQuestions.append(scheme)
                return debug?.linkSchemeAnswer ?? false
            }
            debug?.settingsWindow = settingsWindow
            debug?.help = help
            debug?.setup = setup
            debug?.setupWindow = controller.window
            debug?.start()
        }
        if let t = options.autoquit {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { AppQuit.now() }
        }
    }

    /// The widgets other programs offered, on the card under the sidebar.
    func showOffers() {
        let teams = settings.value.widgetTeamIDs
        controller.showOffers(control.installer.offers.map {
            OfferView.Item(id: $0.id, displayName: $0.displayName, version: $0.version, team: $0.team, signer: $0.signer,
                           teamTrusted: teams.contains($0.team), isUpdate: $0.isUpdate)
        })
    }

    /// Install or No on an offer card. A failed install says why in a sheet on the window.
    func answerOffer(_ id: String, install: Bool) {
        guard install else { control.installer.declineOffer(id); return }
        do {
            try control.installer.acceptOffer(id)
        } catch {
            Log.error("widget offer \(id): \(error)")
            if controller.background { return }
            let a = NSAlert()
            a.messageText = "The widget was not installed"
            a.informativeText = "\(error)"
            a.beginSheetModal(for: controller.window)
        }
    }

    /// When meum's Claude hooks are installed, keeps the script they call (~/.local/bin/meum-hook) the same as this
    /// version's copy, so a fresh or updated meum never leaves the hooks calling a missing or old file. Only the
    /// installed meum does this (`HookInstaller.mayRefreshScript`).
    static func refreshHookScript() {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("bin/meum-hook").path else { return }
        DispatchQueue.global(qos: .utility).async {
            let installer = HookInstaller()
            guard installer.anyInstalled() else { return }
            do {
                if try installer.refreshScript(from: src) { Log.info("hooks: refreshed \(installer.scriptDestination ?? "")") }
            } catch {
                Log.error("hooks: could not refresh the hook script: \(error)")
            }
        }
    }

    static func terminal(_ s: Settings) -> GhosttyApp.TerminalSettings {
        GhosttyApp.TerminalSettings(fontFamily: s.fontFamily, fontSize: s.fontSize, extraConfigPath: s.ghosttyConfigPath,
                                    theme: s.terminalTheme)
    }

    private func resumeProvider(_ s: Settings) -> ResumeProvider {
        guard s.resumeClaude else { return NoResumeProvider() }
        return options.debugResume ? EchoResumeProvider() : ClaudeResumeProvider()
    }

    /// Every settings change, from the API or the settings window: apply it live and publish it.
    private func settingsChanged(old: Settings, new: Settings, keys: [String]) {
        controller.applySettings(new, old: old)
        if old.widgetOrder != new.widgetOrder { widgets?.reorder() }
        widgets?.hostStateChanged()
        if old.shortcuts != new.shortcuts { menu?.applyShortcuts(new) }
        GhosttyApp.shared.apply(Self.terminal(new))
        controller.sessions.resume = resumeProvider(new)
        for k in keys {
            control.bus.publish("settings.changed", ["key": .string(k), "value": SettingsJSON.value(new, k) ?? .null])
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        GhosttyApp.shared.setFocus(true)
        control?.setAppActive(true)
        controller?.focusTerminal()
    }

    func applicationDidResignActive(_ notification: Notification) {
        GhosttyApp.shared.setFocus(false)
        control?.setAppActive(false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // the zmx sessions keep running; only the model is flushed. Widget helpers stop with meum.
        widgets?.stopAllHelpers()
        store?.saveNow()
        settings?.saveNow()
        control?.stop()
        Log.info("quit")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }


    /// meum:// links from other apps. `meum://focus?claude=<session id>`: the tab running that Claude Code session,
    /// its workspace shown and meum in front (as `meum tab focus --claude-id`). `meum://open?path=<absolute path>`:
    /// the file in its default app, only when it lies under a folder of Settings ▸ Folders that links may open and has an
    /// allowed suffix (`LinkOpen`); meum stays where it is. Anything else is logged and ignored.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openLink(url) }
    }

    func openLink(_ url: URL) {
        guard let controller else { return }
        if url.scheme == "meum", url.host == "open" {
            let s = settings.value
            switch LinkOpen.check(url: url, folders: s.boardOpenFolders, suffixes: s.boardOpenSuffixes) {
            case .success(let file): InstalledAppOpen.open(file)
            case .failure(let why): Log.error("link \(url.absoluteString): refused, \(why)")
            }
            return
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard url.scheme == "meum", url.host == "focus", let ref = query.first(where: { $0.name == "claude" })?.value,
              !ref.isEmpty else {
            // no focus change: a link from anywhere must not pull the user's keystrokes into meum
            Log.error("link \(url.absoluteString): not one meum knows (meum://focus?claude=<session id> or meum://open?path=<absolute path>)")
            return
        }
        // the same lookup as tab.select {claude}: a whole id or a unique prefix
        // meum comes to the front only when the link named a tab it showed
        switch controller.store.state.tab(claudeSession: ref) {
        case .found(let tab): if controller.selectTab(tab) { controller.bringToFront() }
        case .none: Log.error("link \(url.absoluteString): no tab runs that Claude session")
        case .ambiguous(let n): Log.error("link \(url.absoluteString): '\(ref)' matches \(n) Claude sessions; use more of the id")
        }
    }

    /// Clicking the Dock icon brings the workspace forward.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.window.makeKeyAndOrderFront(nil)
        return true
    }
}

/// Placeholder until AppControl installs the live source.
@MainActor
final class NoAgentState: AgentStateSource {
    var onChange: (() -> Void)?
    func state(forTab tab: UUID) -> TabAgentState? { nil }
    func summary(forWorkspace ws: Workspace) -> WorkspaceAgentSummary { WorkspaceAgentSummary() }
}

MainActor.assumeIsolated {
    let options = AppOptions.parse()
    ProcessEnvironment.scrub()
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate(options: options)
    app.delegate = delegate
    app.run()
}
