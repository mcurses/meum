import AppKit
import MeumControl
import MeumCore

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
    var widgets: WidgetManager!
    var updater: Updater!

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
        menu.install(settings: settings.value)
        controller.start()
        widgets = WidgetManager(controller: controller, control: control, directory: options.widgetsDir)
        control.widgets = widgets
        controller.widgets = widgets
        settingsWindow.widgets = widgets
        widgets.startHelpers()
        widgets.reload()
        NSApp.activate(ignoringOtherApps: true)
        if options.debugDir == nil { updater.startAutomaticChecks() }

        if let dir = options.debugDir {
            debug = DebugControl(dir: dir, controller: controller, control: control)
            controller.openURL = { [weak debug] in debug?.openedURLs.append($0.absoluteString) }
            debug?.settingsWindow = settingsWindow
            debug?.start()
        }
        if let t = options.autoquit {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { NSApp.terminate(nil) }
        }
    }

    static func terminal(_ s: Settings) -> GhosttyApp.TerminalSettings {
        GhosttyApp.TerminalSettings(fontFamily: s.fontFamily, fontSize: s.fontSize, extraConfigPath: s.ghosttyConfigPath)
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
