// User settings: `settings.json` in the state dir. Every field has a default, and a file with missing or
// unknown keys still loads, so settings can be added without a version bump. The key/value view the control
// API uses (`settings.get` / `settings.set`) is MeumControl's `SettingsJSON`.

import Foundation

public struct Settings: Codable, Equatable, Sendable {
    /// The cards' material. Every material but `solid` can sit over the pinned wallpaper (`wallpaper`).
    public enum Background: String, Codable, Sendable, CaseIterable {
        /// A dark tint (`glassTint`) and nothing else: over the pinned wallpaper this is the "wallpaper glass" look.
        case glass
        /// The system's frosted vibrancy material.
        case vibrancy
        /// macOS 26 Liquid Glass (`NSGlassEffectView`); vibrancy on older systems.
        case liquid
        /// One solid colour (`solidColor`).
        case solid
    }

    public enum LiquidStyle: String, Codable, Sendable, CaseIterable {
        /// Frosted: what is behind is blurred enough for text in front of it.
        case regular
        /// Clear: lets more through, with stronger refraction.
        case clear
    }

    /// Points between cards and around the edges.
    public var cardGap: Double = 12
    public var cornerRadius: Double = 12
    public var sidebarWidth: Double = 240
    /// The sidebar is collapsed to a narrow rail: workspace icons, and the widgets' collapsed looks.
    public var sidebarCollapsed: Bool = false
    /// What a sidebar row shows besides the workspace name (Settings ▸ Sidebar).
    public var sidebarShowBranch: Bool = true   // git branch of the focused tab's folder
    public var sidebarShowDirectory: Bool = false   // the focused tab's folder
    public var sidebarShowStatus: Bool = true   // `status.set` entries
    public var sidebarShowMetadata: Bool = false   // `workspace.setMeta` labels
    public var sidebarShowPorts: Bool = true   // ports the tabs' processes listen on (dev servers)
    public var sidebarShowAgentDots: Bool = true   // one dot per Claude session
    public var sidebarShowShortcuts: Bool = true   // the ⌘1…⌘9 hints
    public var sidebarShowPin: Bool = true   // the pin on pinned workspaces
    /// Height of the widget card under the sidebar, unless `widgetHeightAuto`.
    public var widgetHeight: Double = 150
    /// The widget card takes the hosted widget's own height (150 when it has none).
    public var widgetHeightAuto: Bool = true
    /// Widget ids, top to bottom, for the stacked cards under the sidebar. Workspace widgets always sit above
    /// global ones; this orders them within each group. Widgets not listed follow, by folder name.
    public var widgetOrder: [String] = []
    /// Where the widget library's catalog comes from.
    public var widgetCatalogURL: String = Settings.defaultWidgetCatalogURL
    public static let defaultWidgetCatalogURL = "https://raw.githubusercontent.com/mcurses/meum-widgets/main/catalog.json"
    /// Widgets signed (Developer ID) by these teams load without a pinned hash. Default: Max's team.
    public var widgetTeamIDs: [String] = ["XHXWK3RG86"]
    /// Load any widget, verified or not (for people building widgets).
    public var widgetDeveloperMode: Bool = false
    public var background: Background = .glass
    /// The desktop picture, blurred and pinned to the screen, under the cards' material: the material then shows a
    /// calm, still picture instead of whatever is behind meum. Ignored by `solid`.
    public var wallpaper: Bool = true
    /// The Liquid Glass variant.
    public var liquidStyle: LiquidStyle = .regular
    /// The focused card's frame: how much of the workspace colour it keeps (1 full colour, 0 grey) and how strong
    /// it is (its opacity).
    public var focusFrameSaturation: Double = 1
    public var focusFrameOpacity: Double = 0.8
    /// Gaussian blur of the wallpaper glass, in points.
    public var glassBlur: Double = 4
    /// Opacity of the dark tint over the wallpaper glass, 0…1.
    public var glassTint: Double = 0.35
    /// `#rrggbb` for the solid background.
    public var solidColor: String = "#16181d"
    /// Terminal font family; nil uses Ghostty's default.
    public var fontFamily: String?
    public var fontSize: Double = 13
    /// An extra Ghostty config file loaded after meum's own (and after `<state dir>/ghostty.conf`).
    public var ghosttyConfigPath: String?
    /// Clicks in the gaps between cards stay in meum instead of reaching the app behind.
    public var gapsCatchClicks: Bool = false
    /// On launch, reattach the tabs' zmx sessions that are still running. Off: those sessions are ended and
    /// every tab starts a fresh shell.
    public var reattachSessions: Bool = true
    /// After a reboot (session gone), resume the tab's Claude Code session from its snapshot.
    public var resumeClaude: Bool = true
    /// Look for a new meum release at launch and once a day (release builds only).
    public var checkUpdates: Bool = true
    /// Keyboard shortcut overrides: action id (`Shortcuts.actions`) -> "cmd+shift+r", or "" for none.
    public var shortcuts: [String: String] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? nil ?? def }
        cardGap = v(.cardGap, d.cardGap)
        cornerRadius = v(.cornerRadius, d.cornerRadius)
        sidebarWidth = v(.sidebarWidth, d.sidebarWidth)
        sidebarCollapsed = v(.sidebarCollapsed, d.sidebarCollapsed)
        sidebarShowBranch = v(.sidebarShowBranch, d.sidebarShowBranch)
        sidebarShowDirectory = v(.sidebarShowDirectory, d.sidebarShowDirectory)
        sidebarShowStatus = v(.sidebarShowStatus, d.sidebarShowStatus)
        sidebarShowMetadata = v(.sidebarShowMetadata, d.sidebarShowMetadata)
        sidebarShowPorts = v(.sidebarShowPorts, d.sidebarShowPorts)
        sidebarShowAgentDots = v(.sidebarShowAgentDots, d.sidebarShowAgentDots)
        sidebarShowShortcuts = v(.sidebarShowShortcuts, d.sidebarShowShortcuts)
        sidebarShowPin = v(.sidebarShowPin, d.sidebarShowPin)
        widgetHeight = v(.widgetHeight, d.widgetHeight)
        widgetHeightAuto = v(.widgetHeightAuto, d.widgetHeightAuto)
        widgetOrder = v(.widgetOrder, d.widgetOrder)
        widgetCatalogURL = v(.widgetCatalogURL, d.widgetCatalogURL)
        widgetTeamIDs = v(.widgetTeamIDs, d.widgetTeamIDs)
        widgetDeveloperMode = v(.widgetDeveloperMode, d.widgetDeveloperMode)
        background = v(.background, d.background)
        // settings from before the switch existed: the pinned wallpaper was part of "glass" only
        wallpaper = (try? c.decodeIfPresent(Bool.self, forKey: .wallpaper)) ?? nil ?? (background == .glass)
        liquidStyle = v(.liquidStyle, d.liquidStyle)
        focusFrameSaturation = v(.focusFrameSaturation, d.focusFrameSaturation)
        focusFrameOpacity = v(.focusFrameOpacity, d.focusFrameOpacity)
        glassBlur = v(.glassBlur, d.glassBlur)
        glassTint = v(.glassTint, d.glassTint)
        solidColor = v(.solidColor, d.solidColor)
        fontFamily = (try? c.decodeIfPresent(String.self, forKey: .fontFamily)) ?? nil
        fontSize = v(.fontSize, d.fontSize)
        ghosttyConfigPath = (try? c.decodeIfPresent(String.self, forKey: .ghosttyConfigPath)) ?? nil
        gapsCatchClicks = v(.gapsCatchClicks, d.gapsCatchClicks)
        reattachSessions = v(.reattachSessions, d.reattachSessions)
        resumeClaude = v(.resumeClaude, d.resumeClaude)
        shortcuts = v(.shortcuts, d.shortcuts)
        checkUpdates = v(.checkUpdates, d.checkUpdates)
    }
}

extension StatePaths {
    public var settings: URL { directory.appendingPathComponent("settings.json") }
}

/// Reads and writes `settings.json` atomically (mode 0600).
public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }
    public init(paths: StatePaths) { self.url = paths.settings }

    /// Defaults when there is no file; throws on a file that is not JSON.
    public func load() throws -> Settings {
        guard FileManager.default.fileExists(atPath: url.path) else { return Settings() }
        return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
    }

    public func save(_ s: Settings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(s).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
