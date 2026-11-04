// MeumKit: the public interface for native widgets (layer 2, docs/design/sidebar-widgets-extensibility.md).
//
// A widget is a dynamic library that links this module and exports one C symbol:
//
//     @_cdecl("meum_widget_main")
//     public func meumWidgetMain() -> UnsafeMutableRawPointer {
//         MeumWidgetRegistration(manifest: .init(id: "com.example.clock", displayName: "Clock")) { host in
//             ClockWidget(host: host)
//         }.export()
//     }
//
// meum ships MeumKit as `Contents/Frameworks/libMeumKit.dylib`; the widget's `@rpath/libMeumKit.dylib`
// resolves to that copy, so both sides share one set of types. Install a widget by putting a folder
// `<name>.meumwidget/` with `manifest.json` and the library into `~/.local/share/meum/widgets/`
// (or `$MEUM_WIDGETS_DIR`), then `meum widget reload` or restart meum.
//
// Several widgets stack under the sidebar, each in its own card. `manifest.json` may say `"scope": "workspace"`
// for a widget that shows the selected workspace's content: those cards sit above the global ones (the default
// scope, e.g. Tamago, which looks the same on every workspace). The `widgetOrder` setting orders cards within a scope.
//
// The interface is AppKit-level (an NSView) so a widget may use SwiftUI (`NSHostingView`) or plain AppKit.
// The sidebar can collapse to a narrow rail. A sidebar widget that wants to stay visible there says so with
// `supportsCollapsedSidebar` and draws its own collapsed look on `sidebarCollapsedDidChange`; others are hidden
// in the rail.
//
// Everything here is `meum.v1`; additions are allowed, changes are not. scripts/interface-diff enforces it at each
// release against the last public one, and wants widgets/MINIMUM_MEUM set to the release that adds anything.

import AppKit

public enum MeumKit {
    /// The widget API version this build of meum speaks.
    public static let apiVersion = "meum.v1"
    /// The symbol meum looks up in a widget library.
    public static let entrySymbol = "meum_widget_main"
}

/// Who the widget is. Mirrors `manifest.json` in the widget folder; the library's copy wins.
public struct MeumWidgetManifest: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var version: String
    public var apiVersion: String
    /// What the widget does with meum, for documentation and the settings window ("select", "notify").
    public var uses: [String]

    public init(id: String, displayName: String, version: String = "0", apiVersion: String = MeumKit.apiVersion,
                uses: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.apiVersion = apiVersion
        self.uses = uses
    }
}

/// The card the widget is drawn on, so it can pick contrasting colours.
public struct MeumWidgetAppearance: Sendable, Equatable {
    public enum Material: String, Sendable { case glass, vibrancy, solid }
    public enum Scheme: String, Sendable { case dark, light }

    public var scheme: Scheme
    public var material: Material
    /// Approximate brightness of the card's background, 0 (black) to 1 (white).
    public var backgroundLuminance: Double
    public var accentColor: NSColor
    public var cornerRadius: CGFloat
    /// Space the widget should keep free at the bottom (0 in meum: no fade).
    public var bottomInset: CGFloat
    /// The card's width; the height is the widget's to ask for.
    public var width: CGFloat

    public init(scheme: Scheme = .dark, material: Material = .glass, backgroundLuminance: Double = 0.12,
                accentColor: NSColor = .controlAccentColor, cornerRadius: CGFloat = 12, bottomInset: CGFloat = 0,
                width: CGFloat = 240) {
        self.scheme = scheme
        self.material = material
        self.backgroundLuminance = backgroundLuminance
        self.accentColor = accentColor
        self.cornerRadius = cornerRadius
        self.bottomInset = bottomInset
        self.width = width
    }
}

/// Whether anyone can see the widget. A widget should pause animations when `isVisible` is false.
public struct MeumWidgetVisibility: Sendable, Equatable {
    /// The card is shown (not hidden by a setting, not removed).
    public var isShown: Bool
    /// The window is on screen and not fully covered (`NSWindow.occlusionState`), and the screen is awake.
    public var isOnScreen: Bool
    public var isVisible: Bool { isShown && isOnScreen }

    public init(isShown: Bool = true, isOnScreen: Bool = true) {
        self.isShown = isShown
        self.isOnScreen = isOnScreen
    }
}

/// The workspace selected in meum, as a widget sees it.
public struct MeumWorkspaceInfo: Sendable, Equatable {
    public var id: UUID
    public var name: String
    /// The workspace's directory (its project), if it has one.
    public var cwd: String?
    /// `#rrggbb`, if the workspace has a colour.
    public var color: String?
    /// The origin URL (credentials stripped) of the repository the workspace's directory is in; else of the first
    /// tab directory that is in one. Read from the repository's config, refreshed every few seconds.
    public var remote: String?
    /// Every distinct origin among the workspace's directory and its tabs' directories, `remote` first.
    public var remotes: [String] = []
    /// The workspace's key/value labels (`meum workspace meta set`), e.g. "board.project".
    public var metadata: [String: String] = [:]

    public init(id: UUID, name: String, cwd: String? = nil, color: String? = nil) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.color = color
    }

    public init(id: UUID, name: String, cwd: String?, color: String?, remotes: [String], metadata: [String: String]) {
        self.init(id: id, name: name, cwd: cwd, color: color)
        self.remote = remotes.first
        self.remotes = remotes
        self.metadata = metadata
    }
}

/// Where a widget instance is shown.
public enum MeumWidgetPlacement: Sendable, Equatable {
    /// A card in the stack under the sidebar.
    case sidebar
    /// A tab in a workspace's tiling area, next to the terminals. `tab` is stable across launches, so a widget
    /// can keep per-tab state under it.
    case tile(tab: UUID)
}

/// What meum offers a widget. Every call is on the main actor.
@MainActor
public protocol MeumWidgetHost: AnyObject {
    var appearance: MeumWidgetAppearance { get }
    var visibility: MeumWidgetVisibility { get }
    /// The control socket (layer 0) for anything beyond this interface: the workspace tree, events, actions.
    var socketPath: String { get }
    /// The widget's own folder for state, caches and settings (`~/.local/state/meum/widgets/<id>/`), created by
    /// meum. Shared by all instances of the widget and by its helper (`MEUM_WIDGET_DATA`); per-tile state can go
    /// under the tab id from `placement`. Removing the widget "with data" deletes it.
    var dataDirectory: URL { get }

    /// Where this instance is shown. A widget may be both under the sidebar and in tiles: one instance each.
    var placement: MeumWidgetPlacement { get }
    /// The workspace selected right now (nil only while meum starts). Changes arrive via `workspaceDidChange`.
    /// For a tile it is always the tile's own workspace (tiles exist only while their workspace is shown).
    var selectedWorkspace: MeumWorkspaceInfo? { get }

    /// Asks for a card height in points. The card animates to it (clamped to 40…800) when the widget height
    /// setting is "auto"; otherwise it is ignored. Tiles ignore it (the layout sizes them). 0 hides the card (e.g. a workspace widget with nothing to
    /// show for this workspace); any other height shows it again.
    func setPreferredHeight(_ height: CGFloat)
    /// A tile's settings, saved with its tab (JSON text, e.g. `{"url": "…"}`); nil in the sidebar or when
    /// there are none. Set when the tab is made (`meum tab new --widget ID --config JSON`) or by the widget.
    var configuration: String? { get }
    /// Saves a tile's settings with its tab (they come back after a restart). Ignored in the sidebar.
    func setConfiguration(_ json: String?)
    /// Publishes `widget.event {widget, tab, data}` on meum's socket; `json` (JSON text) becomes `data`.
    func publish(_ json: String)

    /// The sidebar is collapsed to the narrow rail (`appearance.width` is then the rail's width). Changes arrive
    /// via `sidebarCollapsedDidChange`. Always false for a tile.
    var isSidebarCollapsed: Bool { get }

    /// Selects a workspace by id, as a click in the sidebar would.
    func selectWorkspace(_ id: UUID)
    /// Posts a macOS notification through meum, optionally tied to a workspace (a click selects it).
    func notify(title: String, body: String, workspace: UUID?)
}

public extension MeumWidgetHost {
    var isSidebarCollapsed: Bool { false }
}

/// What a widget implements.
@MainActor
public protocol MeumWidget: AnyObject {
    /// The view meum puts into the card. It is sized to the card; the widget's background should be clear.
    var view: NSView { get }
    /// Called when the card's look changes (settings, wallpaper, dark/light).
    func appearanceDidChange(_ appearance: MeumWidgetAppearance)
    /// Called when the widget becomes visible or invisible.
    func visibilityDidChange(_ visibility: MeumWidgetVisibility)
    /// Called once before meum drops the widget (reload, quit). Stop timers and tasks here.
    func willUnload()
    /// Called when another workspace is selected, or the selected one is renamed, recoloured or moves
    /// directory. Every widget gets it; a workspace widget (`"scope": "workspace"`) shows that workspace's content.
    func workspaceDidChange(_ workspace: MeumWorkspaceInfo?)
    /// A message from outside (`meum widget send`, the socket, the `meum mcp` server), as JSON text. Call
    /// `reply` exactly once with JSON text; meum waits up to 30 s. By convention `{"action": "screenshot"}` asks
    /// for `{"png": "<base64>"}` (meum draws the view itself when a widget doesn't answer that one).
    func receive(_ message: String, reply: @escaping @MainActor (String) -> Void)
    /// Whether this widget has a look for the collapsed sidebar (the narrow rail, about 60 pt wide). A sidebar
    /// widget that says false (the default, and every widget built before this existed) is hidden while the
    /// sidebar is collapsed. Tile-only widgets (a browser) never see the rail and can leave it false.
    var supportsCollapsedSidebar: Bool { get }
    /// Called when the sidebar collapses or expands, before the card moves, if `supportsCollapsedSidebar`.
    /// Switch the view to its collapsed look and ask for the height it needs (`setPreferredHeight`); the
    /// card's width is `appearance.width` (an `appearanceDidChange` with the new width follows).
    func sidebarCollapsedDidChange(_ collapsed: Bool)
}

public extension MeumWidget {
    func appearanceDidChange(_ appearance: MeumWidgetAppearance) {}
    func visibilityDidChange(_ visibility: MeumWidgetVisibility) {}
    func willUnload() {}
    func workspaceDidChange(_ workspace: MeumWorkspaceInfo?) {}
    func receive(_ message: String, reply: @escaping @MainActor (String) -> Void) {
        reply(#"{"error": "this widget takes no messages"}"#)
    }
    var supportsCollapsedSidebar: Bool { false }
    func sidebarCollapsedDidChange(_ collapsed: Bool) {}
}

/// What `meum_widget_main` returns: the manifest and a factory.
public final class MeumWidgetRegistration {
    public let manifest: MeumWidgetManifest
    public let make: @MainActor (MeumWidgetHost) -> MeumWidget

    public init(manifest: MeumWidgetManifest, make: @escaping @MainActor (MeumWidgetHost) -> MeumWidget) {
        self.manifest = manifest
        self.make = make
    }

    /// A retained pointer for `meum_widget_main` to return. meum takes ownership.
    public func export() -> UnsafeMutableRawPointer { Unmanaged.passRetained(self).toOpaque() }

    /// meum's side: takes ownership of the pointer `meum_widget_main` returned.
    public static func adopt(_ pointer: UnsafeMutableRawPointer) -> MeumWidgetRegistration {
        Unmanaged<MeumWidgetRegistration>.fromOpaque(pointer).takeRetainedValue()
    }
}
