// adapted from thdxg/macterm (MIT), via umputun/agterm (MIT)
// meum: adapted from agterm agterm/Ghostty/GhosttyApp.swift at 80f822bfe5d697567e18a4ce0f15569a55a729ea
// (trimmed to init, config and the tick; agterm's settings, themes and appearance plumbing removed).

import AppKit
import Foundation
import GhosttyKit
import MeumCore

/// The libghostty application: init, config, tick. One per process.
@MainActor
final class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private(set) var resourcesDir: String?
    private(set) var diagnostics: [String] = []

    /// meum's defaults. Max's `~/.config/ghostty` is deliberately not read; an optional
    /// `<state dir>/ghostty.conf` is loaded after these.
    static let defaultConfig = """
    font-size = 13
    background = #0f1115
    background-opacity = 0.62
    window-padding-x = 8
    window-padding-y = 6
    window-padding-balance = true
    cursor-style-blink = false
    confirm-close-surface = false
    macos-option-as-alt = false
    keybind = alt+backspace=text:\\x1b\\x7f
    """

    private init() {}

    /// The terminal part of the settings that goes into the Ghostty config.
    struct TerminalSettings: Equatable {
        var fontFamily: String?
        var fontSize: Double = 13
        var extraConfigPath: String?
        var theme: String?
    }

    /// The colour themes bundled with meum (Ghostty's), by name.
    var themeNames: [String] {
        guard let dir = resourcesDir.map({ $0 + "/themes" }),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var configDir: URL?
    private(set) var terminal = TerminalSettings()
    /// Replaced configs stay alive: surfaces may still point into them (libghostty does not say when it is done).
    private var retiredConfigs: [ghostty_config_t] = []

    /// Builds a config. Load order: meum's defaults, `<state dir>/ghostty.conf`, the extra config file, then the
    /// font settings from the settings window (the explicit UI choice wins).
    private func makeConfig(_ t: TerminalSettings) -> ghostty_config_t? {
        guard let configDir, let cfg = ghostty_config_new() else { return nil }
        let generated = configDir.appendingPathComponent("ghostty.generated.conf")
        // an explicit background beats a theme's in Ghostty: with a theme, meum's own background stays out
        let base = t.theme?.isEmpty == false
            ? Self.defaultConfig.split(separator: "\n").filter { !$0.hasPrefix("background =") }.joined(separator: "\n")
            : Self.defaultConfig
        try? base.write(to: generated, atomically: true, encoding: .utf8)
        generated.path.withCString { ghostty_config_load_file(cfg, $0) }
        let user = configDir.appendingPathComponent("ghostty.conf")
        if FileManager.default.fileExists(atPath: user.path) {
            user.path.withCString { ghostty_config_load_file(cfg, $0) }
        }
        if let extra = t.extraConfigPath, !extra.isEmpty {
            if FileManager.default.isReadableFile(atPath: extra) {
                extra.withCString { ghostty_config_load_file(cfg, $0) }
            } else {
                Log.error("extra ghostty config not readable: \(extra)")
            }
        }
        var font = "font-size = \(t.fontSize)\n"
        if let f = t.fontFamily.map(Settings.configSafe), !f.isEmpty {
            // an empty font-family first resets the list the earlier files may have built up
            font += "font-family = \"\"\nfont-family = \"\(f)\"\n"
        }
        // only a bundled theme by name: a path would make Ghostty load that file as config
        if let theme = t.theme, Settings.isThemeName(theme), themeNames.contains(theme) {
            font += "theme = \"\(theme)\"\n"
        } else if let theme = t.theme, !theme.isEmpty {
            Log.error("terminal theme '\(Settings.configSafe(theme))' is not a bundled theme; ignored")
        }
        let fontFile = configDir.appendingPathComponent("ghostty.settings.conf")
        try? font.write(to: fontFile, atomically: true, encoding: .utf8)
        fontFile.path.withCString { ghostty_config_load_file(cfg, $0) }
        ghostty_config_finalize(cfg)
        diagnostics = []
        let n = ghostty_config_diagnostics_count(cfg)
        for i in 0..<n {
            let d = ghostty_config_get_diagnostic(cfg, i)
            let msg = d.message.map { String(cString: $0) } ?? "?"
            diagnostics.append(msg)
            Log.info("ghostty config diagnostic: \(msg)")
        }
        return cfg
    }

    /// Rebuilds the config with new terminal settings and hands it to the app and every surface (live).
    /// `force` rebuilds even when the settings are the same: the config files on disk may have changed.
    func apply(_ t: TerminalSettings, force: Bool = false) {
        guard force || t != terminal else { return }
        terminal = t
        guard let app, let cfg = makeConfig(t) else { return }
        ghostty_app_update_config(app, cfg)
        if let old = config { retiredConfigs.append(old) }
        config = cfg
        Log.info("ghostty config \(force ? "reloaded from disk" : "reloaded"): font=\(t.fontFamily ?? "default") size=\(t.fontSize) theme=\(t.theme ?? "-") extra=\(t.extraConfigPath ?? "-")")
    }

    /// Reads the config files again (meum's `ghostty.conf`, the extra config) with the current settings.
    func reloadFromDisk() { apply(terminal, force: true) }

    /// Boots libghostty. Must run before any surface is created; `configDir` holds the generated config.
    func start(configDir: URL, terminal t: TerminalSettings = TerminalSettings()) {
        guard app == nil else { return }
        self.configDir = configDir
        terminal = t
        resourcesDir = GhosttyResourceResolver.export()
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            Log.error("ghostty_init failed")
            return
        }
        // libghostty adopts the user's numeric locale; CoreSVG mis-sizes symbols with decimal commas.
        setlocale(LC_NUMERIC, "C")
        guard let cfg = makeConfig(t) else {
            Log.error("ghostty_config_new failed")
            return
        }

        var rt = ghostty_runtime_config_s()
        rt.userdata = nil
        rt.supports_selection_clipboard = true
        rt.wakeup_cb = { _ in GhosttyApp.callbacksRef.wakeup() }
        rt.action_cb = { _, target, action in GhosttyApp.callbacksRef.action(target: target, action: action) }
        rt.read_clipboard_cb = { ud, loc, state, mimes, mimesLen, list in
            GhosttyApp.callbacksRef.readClipboard(.init(userdata: ud, location: loc, state: state,
                                                        mimes: mimes, mimesLen: UInt(mimesLen), list: list))
        }
        rt.confirm_read_clipboard_cb = { ud, _, state, _ in
            GhosttyApp.callbacksRef.denyClipboard(ud: ud, state: state)
        }
        rt.write_clipboard_cb = { _, location, content, len, _ in
            GhosttyApp.callbacksRef.writeClipboard(location: location, content: content, len: UInt(len))
        }
        rt.close_surface_cb = { ud, _ in GhosttyApp.callbacksRef.closeSurface(ud: ud) }

        guard let created = ghostty_app_new(&rt, cfg) else {
            Log.error("ghostty_app_new failed")
            ghostty_config_free(cfg)
            return
        }
        app = created
        config = cfg
        // A host-built config resolves LIGHT; set the scheme before the first surface so a conditional theme
        // in the user's ghostty.conf cannot trigger a config rebuild that drops the surface's env/command.
        ghostty_app_set_color_scheme(created, GHOSTTY_COLOR_SCHEME_DARK)
        ghostty_app_update_config(created, cfg)
        ghostty_app_set_focus(created, NSApp.isActive)
    }

    /// The callback router, reachable from the C closures (which may not capture context).
    nonisolated static let callbacksRef = GhosttyCallbacks()

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func setFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }
}
