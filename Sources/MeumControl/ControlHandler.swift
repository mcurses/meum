import Foundation

/// What the app implements. The server decodes the wire, answers `system.ping` and `events.subscribe`
/// itself, and hands every other method here. Throw `ControlError` for coded errors (`not_found`,
/// `invalid_params`, ...); any other thrown error becomes `{"code":"internal"}`.
///
/// Method names and params are the contract in docs/design/architecture.md; `MeumMethod` lists them.
public protocol ControlHandler: Sendable {
    func handle(method: String, params: JSON) async throws -> JSON
}

/// Closure-backed handler, handy for tests and small tools.
public struct ClosureHandler: ControlHandler {
    private let body: @Sendable (String, JSON) async throws -> JSON
    public init(_ body: @escaping @Sendable (String, JSON) async throws -> JSON) { self.body = body }
    public func handle(method: String, params: JSON) async throws -> JSON { try await body(method, params) }
}

/// Method names of the v1 API, so the CLI, the app and widgets never retype strings.
public enum MeumMethod {
    public static let ping = "system.ping"
    public static let tree = "tree"
    public static let workspaceList = "workspace.list"
    public static let workspaceNew = "workspace.new"
    public static let workspaceSelect = "workspace.select"
    public static let workspaceRename = "workspace.rename"
    public static let workspaceClose = "workspace.close"
    public static let workspaceReorder = "workspace.reorder"
    public static let workspaceSetColor = "workspace.setColor"
    /// `{id, icon}`: an emoji or up to two characters, `sf:<symbol>`, or null / "none" to clear.
    public static let workspaceSetIcon = "workspace.setIcon"
    /// `{id, key, value | null}` sets or removes one label; `{id, metadata: {key: value | null}}` several.
    public static let workspaceSetMeta = "workspace.setMeta"
    /// `{collapsed?}`: collapses or expands the sidebar (without `collapsed`: toggles). -> `{collapsed}`.
    public static let sidebarSetCollapsed = "sidebar.setCollapsed"
    /// `{}` -> `{groups: [{id, name, collapsed, workspaces: [id…]}]}` in sidebar order.
    public static let groupList = "group.list"
    /// `{name, workspaces: [ws…]}` -> the group. The workspaces leave other groups; the group sits where the first is.
    public static let groupNew = "group.new"
    /// `{group, name}`. `group` is an id or a unique name everywhere.
    public static let groupRename = "group.rename"
    /// `{group, collapsed?}` (without `collapsed`: toggles) -> `{collapsed}`.
    public static let groupSetCollapsed = "group.setCollapsed"
    /// `{group}`: dissolves the group; its workspaces stay where they are.
    public static let groupUngroup = "group.ungroup"
    /// `{id | ids: [ws…], group | null}`: into a group (at its end), or out of theirs.
    public static let workspaceSetGroup = "workspace.setGroup"
    public static let workspacePin = "workspace.pin"
    public static let workspaceMarkRead = "workspace.markRead"
    public static let workspaceMarkUnread = "workspace.markUnread"
    public static let tabNew = "tab.new"
    public static let tabSelect = "tab.select"
    public static let tabClose = "tab.close"
    public static let tabSendText = "tab.sendText"
    /// `{}` -> `{workspace, tab}`: the selected workspace and its focused tab (a terminal or a widget tab).
    public static let tabFocused = "tab.focused"
    /// `{tab, text}` -> `{tab}`: text pasted into a tab's terminal as a paste (bracketed when its program
    /// enabled mode 2004), wherever that tab is; no focus change, no clipboard. Errors: not_found (no such tab),
    /// unavailable (a widget tab, or a terminal not attached yet: its workspace was not shown since meum started).
    public static let tabPaste = "tab.paste"
    public static let tabMove = "tab.move"
    public static let splitResize = "split.resize"
    public static let settingsGet = "settings.get"
    public static let settingsSet = "settings.set"
    public static let statusSet = "status.set"
    public static let statusClear = "status.clear"
    public static let notify = "notify"
    public static let widgetList = "widget.list"
    public static let widgetReload = "widget.reload"
    public static let widgetEnable = "widget.enable"
    /// `{tab | widget, message}` -> the widget's reply (any JSON). Waits for the widget (async).
    public static let widgetSend = "widget.send"
    /// `{tab | widget, path?}` -> `{png: base64}` or, with `path`, `{path}`. Asks the widget, else draws its view.
    public static let widgetScreenshot = "widget.screenshot"
    /// `{}` -> `{url, widgets: [catalog entry + installed, installedVersion, update, runs]}`. Fetches the catalog (async).
    public static let widgetCatalog = "widget.catalog"
    /// `{id}` -> like `widget.list`. Downloads, checks the sha256, installs and pins (async).
    public static let widgetInstall = "widget.install"
    /// `{id}` -> like `widget.list`. Installs the catalog's newer version (async).
    public static let widgetUpdate = "widget.update"
    /// `{id, data?}` -> like `widget.list`. Removes the widget (with `data: true` also its data folder).
    public static let widgetRemove = "widget.remove"
    /// `{id}` -> like `widget.list`. Trusts the widget's current library (pins its hash) and reloads.
    public static let widgetAllow = "widget.allow"
    /// Methods that wait for the network: answered off the request queue.
    public static let widgetAsync: Set<String> = [widgetCatalog, widgetInstall, widgetUpdate]
    /// `{}` -> `{current, available, latest?, url?, page?, canUpdate, reason?}`. Asks GitHub (async).
    public static let updateCheck = "app.update.check"
    /// `{relaunch?}` -> as check, after installing; then meum restarts (unless relaunch is false). Async.
    public static let updateInstall = "app.update.install"
    public static let agentHook = "agent.hook"
    public static let eventsSubscribe = "events.subscribe"

    /// Everything the server itself answers (the handler never sees these).
    public static let serverOwned: Set<String> = [ping, eventsSubscribe]

    /// Everything the app's handler must implement.
    public static let handlerOwned: [String] = [
        tree, workspaceList, workspaceNew, workspaceSelect, workspaceRename, workspaceClose, workspaceReorder,
        workspaceSetColor, workspaceSetIcon, workspaceSetMeta, workspacePin, workspaceSetGroup,
        groupList, groupNew, groupRename, groupSetCollapsed, groupUngroup, workspaceMarkRead, workspaceMarkUnread, sidebarSetCollapsed,
        tabNew, tabSelect, tabClose, tabSendText, tabFocused, tabPaste, tabMove, splitResize, settingsGet, settingsSet, statusSet, statusClear, notify, agentHook,
        widgetList, widgetReload, widgetEnable, widgetSend, widgetScreenshot,
        widgetCatalog, widgetInstall, widgetUpdate, widgetRemove, widgetAllow, updateCheck, updateInstall,
    ]
}
