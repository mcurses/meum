# meum control API (meum.v1)

Generated from the doc comments in `Sources/MeumControl/ControlHandler.swift` by `Tests/MeumControlTests/APIDocTests.swift`;
edit those, then run `MEUM_WRITE_API_DOC=1 swift test --filter APIDocTests`.

Newline-delimited JSON over the Unix socket in `$MEUM_SOCKET` (default `~/.local/state/meum/meum.sock`, mode 0600):
a request `{"id": 1, "method": "workspace.list", "params": {…}}` gets `{"id": 1, "result": …}` or
`{"id": 1, "error": {"code", "message"}}`. Error codes: `parse_error`, `invalid_request`, `method_not_found`,
`invalid_params`, `not_found`, `conflict`, `unavailable`, `forbidden`, `internal`. `system.ping` lists the methods
a running meum serves; a client should ask before it relies on a newer one. Changes are additions only: a new
method, a new optional parameter with a default, a new field in an answer.

The app's bundle identifier `io.github.mcurses.meum` is part of `meum.v1`: tools find meum by it (to tell
whether it is the app in front, say), and it stays the same across any rename of the app.

## Methods

### system

- `system.ping`: `{}` -> `{api, pid, seq, version, methods}`: the API version, meum's pid, the last event seq, the app version (null in a development build) and every method this meum serves. Answered by the server itself.

### model

- `tree`: `{}` -> the whole model: workspaces with their groups, cards, tabs, labels, status entries and agent states.
- `notify`: `{tab?, title, body?}`: a macOS notification, on behalf of `tab` when given.

### workspace

- `workspace.list`: `{}` -> `[{id, name, selected, focusedTabID, focusedCardID, tabCount, cwd, cwds, branch, remotes, color, icon, pinned, group, labels, metadata, status, ports, agents}]`: every workspace in sidebar order; `selected` is the one shown, `focusedTabID` its focused tab (null without one), `labels` the workspace's own chips. Workspaces are named by id or by a unique name everywhere.
- `workspace.new`: `{name?, cwd?, color?}` -> `{id}`: a new workspace with one terminal tab.
- `workspace.select`: `{id}`: shows the workspace.
- `workspace.rename`: `{id, name}`.
- `workspace.close`: `{id}`: closes the workspace and ends its terminals.
- `workspace.reorder`: `{id, index}`: moves the workspace to `index` in the sidebar.
- `workspace.setColor`: `{id, color}`: `#rrggbb`, or null to clear.
- `workspace.setIcon`: `{id, icon}`: an emoji or up to two characters, `sf:<symbol>`, or null / "none" to clear.
- `workspace.setLabels`: `{id, labels: [string]}`: chips on the workspace's sidebar row (at most 4, 24 characters each; empty clears).
- `workspace.setMeta`: `{id, key, value | null}` sets or removes one label; `{id, metadata: {key: value | null}}` several.
- `workspace.setGroup`: `{id | ids: [ws…], group | null}`: into a group (at its end), or out of theirs.
- `workspace.pin`: `{id, pinned?}` (default true): a pinned workspace stays at the top of the sidebar.
- `workspace.markRead`: `{id}`: marks every Claude session in the workspace read (blue dots go grey).
- `workspace.markUnread`: `{id}`: marks the workspace's finished Claude sessions unread again.

### sidebar

- `sidebar.setCollapsed`: `{collapsed?}`: collapses or expands the sidebar (without `collapsed`: toggles). -> `{collapsed}`.

### group

- `group.list`: `{}` -> `{groups: [{id, name, collapsed, workspaces: [id…]}]}` in sidebar order.
- `group.new`: `{name, workspaces: [ws…]}` -> the group. The workspaces leave other groups; the group sits where the first is.
- `group.rename`: `{group, name}`. `group` is an id or a unique name everywhere.
- `group.setCollapsed`: `{group, collapsed?}` (without `collapsed`: toggles) -> `{collapsed}`.
- `group.ungroup`: `{group}`: dissolves the group; its workspaces stay where they are.

### tab

- `tab.new`: `{workspace?, card?, cwd?, command?, split?: "right"|"down", widget?, config?}` -> `{id, workspace, card}`: a terminal tab, in `card` (default the focused card) or in a new card split off it.
- `tab.select`: `{tab}`: shows the tab (and its workspace).
- `tab.close`: `{tab}`: closes the tab and ends its terminal.
- `tab.sendText`: `{tab, text}`: typed into the tab's terminal as keystrokes; a newline submits.
- `tab.focused`: `{}` -> `{workspace, tab, widget, name, labels}`: the selected workspace's id and its focused tab (a terminal or a widget tab; `widget` is the widget id, null for a terminal); `name` is the Claude Code session's own name, null without one; `labels` the labels that session set on its tab (`tab.setLabels`, empty without).
- `tab.setLabels`: `{tab, labels: [string]}` -> `{tab, labels}`: short labels an agent attaches to its session (at most 4, each at most 24 characters), shown as chips on its tab and workspace row; an empty list clears them. They belong to the tab's Claude session and are dropped when it ends; a tab without one answers `unavailable`.
- `tab.paste`: `{tab, text, submit?}` -> `{tab, submitted}`: text pasted into a tab's terminal as a paste (bracketed when its program enabled mode 2004), wherever that tab is; no focus change, no clipboard. `submit: true` presses Return after the text on the same path, so it can't overtake it (meum before 0.5 ignores it and omits `submitted`). Errors: not_found (no such tab), unavailable (a widget tab, or a terminal not attached yet: its workspace was not shown since meum started).
- `tab.move`: `{tab, card?, index?, split?: "left"|"right"|"up"|"down"}`: without `split`, into `card` (default its own) at `index`; with `split`, into a new card on that side of `card`. An emptied card is removed; the target may be in another workspace.

### split

- `split.resize`: `{split, ratio}` -> `{split, ratio}`: the split's first share, 0.1…0.9 (clamped).

### settings

- `settings.get`: `{key?}` -> `{settings, path}` or `{key, value}`. Keys and ranges: SettingsJSON.swift.
- `settings.set`: `{key, value}` -> `{key, value}` (the stored value); publishes `settings.changed`. The widget trust keys are read-only here (`forbidden`).

### status

- `status.set`: `{workspace, key, value, color?, url?}`: a status entry on the workspace's sidebar row; a click on one with a `url` opens it and publishes `status.clicked`.
- `status.clear`: `{workspace, key}`: removes that status entry.

### widget

- `widget.list`: `{}` -> `{directory, apiVersion, widgets: […]}`: the installed native widgets, their state and trust.
- `widget.reload`: `{}` -> like `widget.list`, after reloading every native widget.
- `widget.enable`: `{id, enabled?}` (default true) -> like `widget.list`.
- `widget.send`: `{tab | widget, message}` -> the widget's reply (any JSON). Waits for the widget (async).
- `widget.screenshot`: `{tab | widget, path?}` -> `{png: base64}` or, with `path`, `{path}`. Asks the widget, else draws its view.
- `widget.catalog`: `{}` -> `{url, widgets: [catalog entry + installed, installedVersion, update, runs]}`. Fetches the catalog (async).
- `widget.install`: `{id}` -> like `widget.list`. Downloads, checks the sha256, installs and pins (async).
- `widget.update`: `{id}` -> like `widget.list`. Installs the catalog's newer version (async).
- `widget.remove`: `{id, data?}` -> like `widget.list`. Removes the widget (with `data: true` also its data folder).
- `widget.allow`: `{id}` -> always `forbidden`: trusting a widget is done in Settings ▸ Widgets only (meum opens it there).

### app

- `app.update.check`: `{}` -> `{current, available, latest?, url?, page?, canUpdate, reason?}`. Asks GitHub (async).
- `app.update.install`: `{relaunch?}` -> as check, after installing; then meum restarts (unless relaunch is false). Async.

### agent

- `agent.hook`: `{tab, configDir?, payload}`: one Claude Code hook event, as `meum-hook` sends it; drives the agent dots.

### events

- `events.subscribe`: `{after?, types?}`: turns the connection into a stream of `{seq, type, data}` lines (types: docs/api.md). `after` resumes from a seq while the ring buffer still holds it; `types` filters by pattern (`tab.*`).

## Events

`events.subscribe` streams `{"seq": n, "type": "…", "data": {…}}` lines.

- `workspace.added`: `{workspace, index}`: a new workspace (the full workspace object, as in `tree`).
- `workspace.changed`: `{id, fields…}`: something about a workspace changed (name, colour, order, ports, branch, remotes, …).
- `workspace.removed`: `{id}`.
- `workspace.selected`: `{id}`: the shown workspace changed.
- `tab.added`: `{tab, workspace, card, …}`: a new tab.
- `tab.changed`: `{id, …}`: a tab's title, directory or session name changed.
- `tab.removed`: `{id, workspace}`.
- `tab.selected`: `{id, …}`: a card's selected tab changed.
- `tab.moved`: `{id, …}`: a tab went to another card or position.
- `tab.labels`: `{tab, labels}`: the labels a session set on its tab.
- `split.resized`: `{split, ratio}`.
- `settings.changed`: `{key, value}`: one setting changed (from Settings or `settings.set`).
- `status.changed`: `{workspace, key, value, color, url}`: a status entry was set or (value null) cleared.
- `status.clicked`: `{workspace, key, value, url}`: the user clicked a status entry that has a url.
- `notification`: `{title, body, tab}`: meum posted a notification (`notify`).
- `agent.changed`: `{tab, agent}`: a tab's Claude state (`agent` null when the session ended).
- `agent.hook`: `{tab, configDir, payload}`: a raw hook event, as received.
- `widget.loaded`: `{id, version}`: a native widget loaded.
- `widget.event`: `{widget, tab, data}`: a widget published an event of its own.
