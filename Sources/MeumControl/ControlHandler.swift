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
    /// `{}` -> `{api, pid, seq, version, methods}`: the API version, meum's pid, the last event seq, the app version (null in a development build) and every method this meum serves. Answered by the server itself.
    public static let ping = "system.ping"
    /// `{}` -> the whole model: workspaces with their groups, cards, tabs, labels, status entries and agent states.
    public static let tree = "tree"
    /// `{}` -> `[{id, name, …}]`: every workspace in sidebar order. Workspaces are named by id or by a unique name everywhere.
    public static let workspaceList = "workspace.list"
    /// `{name?, cwd?, color?}` -> `{id}`: a new workspace with one terminal tab.
    public static let workspaceNew = "workspace.new"
    /// `{id}`: shows the workspace.
    public static let workspaceSelect = "workspace.select"
    /// `{id, name}`.
    public static let workspaceRename = "workspace.rename"
    /// `{id}`: closes the workspace and ends its terminals.
    public static let workspaceClose = "workspace.close"
    /// `{id, index}`: moves the workspace to `index` in the sidebar.
    public static let workspaceReorder = "workspace.reorder"
    /// `{id, color}`: `#rrggbb`, or null to clear.
    public static let workspaceSetColor = "workspace.setColor"
    /// `{id, icon}`: an emoji or up to two characters, `sf:<symbol>`, or null / "none" to clear.
    public static let workspaceSetIcon = "workspace.setIcon"
    /// `{id, labels: [string]}`: chips on the workspace's sidebar row (at most 4, 24 characters each; empty clears).
    public static let workspaceSetLabels = "workspace.setLabels"
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
    /// `{id, pinned?}` (default true): a pinned workspace stays at the top of the sidebar.
    public static let workspacePin = "workspace.pin"
    /// `{id}`: marks every Claude session in the workspace read (blue dots go grey).
    public static let workspaceMarkRead = "workspace.markRead"
    /// `{id}`: marks the workspace's finished Claude sessions unread again.
    public static let workspaceMarkUnread = "workspace.markUnread"
    /// `{workspace?, card?, cwd?, command?, split?: "right"|"down", widget?, config?}` -> `{id, workspace, card}`: a terminal tab, in `card` (default the focused card) or in a new card split off it.
    public static let tabNew = "tab.new"
    /// `{tab}`: shows the tab (and its workspace).
    public static let tabSelect = "tab.select"
    /// `{tab}`: closes the tab and ends its terminal.
    public static let tabClose = "tab.close"
    /// `{tab, text}`: typed into the tab's terminal as keystrokes; a newline submits.
    public static let tabSendText = "tab.sendText"
    /// `{}` -> `{workspace, tab, widget, name}`: the selected workspace and its focused tab (a terminal or a widget
    /// tab); `name` is the Claude Code session's own name, null without one.
    public static let tabFocused = "tab.focused"
    /// `{tab, labels: [string]}` -> `{tab, labels}`: short labels an agent attaches to its session (at most 4, each at
    /// most 24 characters), shown as chips on its tab and workspace row; an empty list clears them. They belong to the
    /// tab's Claude session and are dropped when it ends; a tab without one answers `unavailable`.
    public static let tabSetLabels = "tab.setLabels"
    /// `{tab, text, submit?}` -> `{tab, submitted}`: text pasted into a tab's terminal as a paste (bracketed when its
    /// program enabled mode 2004), wherever that tab is; no focus change, no clipboard. `submit: true` presses Return
    /// after the text on the same path, so it can't overtake it (meum before 0.5 ignores it and omits `submitted`).
    /// Errors: not_found (no such tab), unavailable (a widget tab, or a terminal not attached yet: its workspace was
    /// not shown since meum started).
    public static let tabPaste = "tab.paste"
    /// `{tab, card?, index?, split?: "left"|"right"|"up"|"down"}`: without `split`, into `card` (default its own) at `index`; with `split`, into a new card on that side of `card`. An emptied card is removed; the target may be in another workspace.
    public static let tabMove = "tab.move"
    /// `{split, ratio}` -> `{split, ratio}`: the split's first share, 0.1…0.9 (clamped).
    public static let splitResize = "split.resize"
    /// `{key?}` -> `{settings, path}` or `{key, value}`. Keys and ranges: SettingsJSON.swift.
    public static let settingsGet = "settings.get"
    /// `{key, value}` -> `{key, value}` (the stored value); publishes `settings.changed`. The widget trust keys are read-only here (`forbidden`).
    public static let settingsSet = "settings.set"
    /// `{workspace, key, value, color?, url?}`: a status entry on the workspace's sidebar row; a click on one with a `url` opens it and publishes `status.clicked`.
    public static let statusSet = "status.set"
    /// `{workspace, key}`: removes that status entry.
    public static let statusClear = "status.clear"
    /// `{tab?, title, body?}`: a macOS notification, on behalf of `tab` when given.
    public static let notify = "notify"
    /// `{}` -> `{directory, apiVersion, widgets: […]}`: the installed native widgets, their state and trust.
    public static let widgetList = "widget.list"
    /// `{}` -> like `widget.list`, after reloading every native widget.
    public static let widgetReload = "widget.reload"
    /// `{id, enabled?}` (default true) -> like `widget.list`.
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
    /// `{id}` -> always `forbidden`: trusting a widget is done in Settings ▸ Widgets only (meum opens it there).
    public static let widgetAllow = "widget.allow"
    /// Methods that wait for the network: answered off the request queue.
    public static let widgetAsync: Set<String> = [widgetCatalog, widgetInstall, widgetUpdate]
    /// `{}` -> `{current, available, latest?, url?, page?, canUpdate, reason?}`. Asks GitHub (async).
    public static let updateCheck = "app.update.check"
    /// `{relaunch?}` -> as check, after installing; then meum restarts (unless relaunch is false). Async.
    public static let updateInstall = "app.update.install"
    /// `{tab, configDir?, payload}`: one Claude Code hook event, as `meum-hook` sends it; drives the agent dots.
    public static let agentHook = "agent.hook"
    /// `{after?, types?}`: turns the connection into a stream of `{seq, type, data}` lines (types: docs/api.md). `after` resumes from a seq while the ring buffer still holds it; `types` filters by pattern (`tab.*`).
    public static let eventsSubscribe = "events.subscribe"

    /// Everything the server itself answers (the handler never sees these).
    public static let serverOwned: Set<String> = [ping, eventsSubscribe]

    /// Everything the app's handler must implement.
    public static let handlerOwned: [String] = [
        tree, workspaceList, workspaceNew, workspaceSelect, workspaceRename, workspaceClose, workspaceReorder,
        workspaceSetColor, workspaceSetIcon, workspaceSetLabels, workspaceSetMeta, workspacePin, workspaceSetGroup,
        groupList, groupNew, groupRename, groupSetCollapsed, groupUngroup, workspaceMarkRead, workspaceMarkUnread, sidebarSetCollapsed,
        tabNew, tabSelect, tabClose, tabSendText, tabFocused, tabSetLabels, tabPaste, tabMove, splitResize, settingsGet, settingsSet, statusSet, statusClear, notify, agentHook,
        widgetList, widgetReload, widgetEnable, widgetSend, widgetScreenshot,
        widgetCatalog, widgetInstall, widgetUpdate, widgetRemove, widgetAllow, updateCheck, updateInstall,
    ]
}

/// Event types on an `events.subscribe` stream (`{seq, type, data}`). docs/api.md is generated from these comments.
public enum MeumEvent {
    /// `{workspace, index}`: a new workspace (the full workspace object, as in `tree`).
    public static let workspaceAdded = "workspace.added"
    /// `{id, fields…}`: something about a workspace changed (name, colour, order, ports, branch, remotes, …).
    public static let workspaceChanged = "workspace.changed"
    /// `{id}`.
    public static let workspaceRemoved = "workspace.removed"
    /// `{id}`: the shown workspace changed.
    public static let workspaceSelected = "workspace.selected"
    /// `{tab, workspace, card, …}`: a new tab.
    public static let tabAdded = "tab.added"
    /// `{id, …}`: a tab's title, directory or session name changed.
    public static let tabChanged = "tab.changed"
    /// `{id, workspace}`.
    public static let tabRemoved = "tab.removed"
    /// `{id, …}`: a card's selected tab changed.
    public static let tabSelected = "tab.selected"
    /// `{id, …}`: a tab went to another card or position.
    public static let tabMoved = "tab.moved"
    /// `{tab, labels}`: the labels a session set on its tab.
    public static let tabLabels = "tab.labels"
    /// `{split, ratio}`.
    public static let splitResized = "split.resized"
    /// `{key, value}`: one setting changed (from Settings or `settings.set`).
    public static let settingsChanged = "settings.changed"
    /// `{workspace, key, value, color, url}`: a status entry was set or (value null) cleared.
    public static let statusChanged = "status.changed"
    /// `{workspace, key, value, url}`: the user clicked a status entry that has a url.
    public static let statusClicked = "status.clicked"
    /// `{title, body, tab}`: meum posted a notification (`notify`).
    public static let notification = "notification"
    /// `{tab, agent}`: a tab's Claude state (`agent` null when the session ended).
    public static let agentChanged = "agent.changed"
    /// `{tab, configDir, payload}`: a raw hook event, as received.
    public static let agentHook = "agent.hook"
    /// `{id, version}`: a native widget loaded.
    public static let widgetLoaded = "widget.loaded"
    /// `{widget, tab, data}`: a widget published an event of its own.
    public static let widgetEvent = "widget.event"
}
