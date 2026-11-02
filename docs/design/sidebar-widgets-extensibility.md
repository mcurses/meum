# Design: sidebar, widgets and extensibility

Status: agreed direction (Max, 2026-11-02). Layer 0 (socket API, CLI) and layer 2 (native widgets, MeumKit) are
built; the built-in sidebar does not use the public API yet. See "As built" at the end.

## Principles

1. **meum promises a small set of things and does them very well:** workspaces, tiled terminals with tabs,
   sessions that survive the app, agent status, and a good look. Everything else is out of scope (see the
   research note).
2. **Extensible by default.** Anyone who wants more hooks it in. Nobody should have to fork meum or rewrite it
   because something can't be done. That is the opposite of cmux, which is only half extensible: there you
   replace the whole sidebar or nothing, and the extension API lacks basic actions.
3. **meum uses its own extension API.** The built-in sidebar is an extension that ships with meum and uses the
   same public interface a third party would. If the built-in sidebar can be written with the API, so can any
   replacement.
4. **One responsibility per part.** meum owns the workspaces and the sidebar. A widget such as Tamago owns only
   itself.

## Sidebar and Tamago

The current Tamago sidebar is both a workspace list and the pet. That was a cmux limitation: cmux lets an
extension replace the whole sidebar, nothing smaller. In meum the two are split.

**meum's built-in sidebar owns:**
- the workspace rows: names, colour stripes, session dots, unread, branch, ports, PRs, status and progress;
- drag to reorder, and the right-click actions (rename, pin, colour, move, mark read, close);
- the session dots, fed directly from the agent hook events. This replaces Tamago's 10-second `ps` polling and
  stays correct when a pane moves.

**Tamago becomes a widget and owns only the character:**
- the pet's view: animation, speech bubble, +1, the feed/pet/poke menu, species and name;
- its background program: mood, memory, diary, remarks.

**What moves out of Tamago:**
- the workspace rows, roughly lines 1–325 of `SidebarView.swift` plus `FlowRow`;
- `daemon/details.mjs`;
- the `ps` session counting;
- the workspace actions over HTTP.

What remains is `PetFooter` + `Pet.swift`, plus the daemon without the workspace parts.

**Placement:** widgets live in **slots**. The first slot is a floating card attached under the sidebar: same
width, same look, moving with it. The sidebar card and the widget card are separate cards. Tamago's current
functionality stays the same; only who is responsible for what changes.

## What any extension gets

Everything goes through one versioned API. The same API is reachable in three ways (see "Layers").

**Read:**
- windows, workspaces (id, title, colour, pinned, cwd, branch, ports, status entries), panes, tabs;
- the selected workspace and the focused tab;
- agent sessions per tab (config dir, session id, transcript path, state: running / turn finished / needs input).

**Events:** a single ordered stream of every change above, plus the raw agent hook events. Each event carries a
sequence number, so a consumer can resume where it left off.

**Act:**
- create, select, rename, reorder, recolour, pin and close workspaces;
- split, move and close panes and tabs;
- start a command in a new tab;
- send text to a tab;
- set status entries, progress and a log line on a workspace;
- mark read or unread;
- post a notification.

**Permissions:** an extension declares which of these it uses. A personal tool doesn't need a sandbox, but the
declaration documents the extension and lets meum show what it can do. Unlike cmux, changing the declaration
doesn't re-trigger an approval dance.

## Layers: how extensions plug in, from cheapest to most expensive

| Layer | What it is | Who it's for | Cost to us |
|---|---|---|---|
| 0. Socket API + CLI | JSON-RPC and the event stream on a unix socket. `meum` CLI is a thin client. | scripts, daemons, other tools, Tamago's background program | low: we need it anyway for the CLI and hooks |
| 1. Terminal widgets | any program runs in a slot card (under the sidebar, or as the whole sidebar), with `MEUM_SOCKET` in its environment. TUI in any language | quick custom widgets, an alternative sidebar as a TUI | very low: a slot is just a terminal card, and we host Ghostty anyway |
| 2. Native Swift widgets | a SwiftUI view in a slot, built against a small `MeumKit` package (protocol + data types). Compiled in at first, loadable bundles later | widgets that must look native: Tamago, the built-in sidebar | medium: keeping the API stable is the real cost |
| 3. Sandboxed out-of-process UI | ExtensionKit, as cmux does | untrusted third-party code distributed to many users | high, and it brings the friction Tamago hit in cmux. **Skip until there's a real need.** |

The layers can be mixed. Tamago, for example, would be a layer 2 view with a layer 0 background program.

## What extensibility by default costs

Not much, as long as it's there from day one. cmux pays dearly because its extensibility was added afterwards to
an app that wasn't designed for it.

The real costs:
- **API discipline.** Every feature is first an API call or event, then UI. Built-in features use the same calls.
  This slows the first features a little and speeds up everything after.
- **Stability.** Once others build on the API we can't change it freely. Keep it small, version it from the start
  (`meum.v1`), and mark new parts experimental until they've settled.
- **Documentation.** One reference page for the API and the event stream. It can mostly be generated from the
  type definitions.

What we deliberately don't pay for: layer 3 (sandboxing, remote views, an approval UI, keeping an SDK in sync
per release).

## Open questions

- Which slots exist besides "under the sidebar": in the sidebar's header, a status line, a right-side panel?
- Should layer 2 widgets load from bundles at runtime from the start, or only once a second native widget exists?
- Since Tamago's background program is its own process anyway, should it talk to meum only over layer 0, keeping
  its view a pure renderer of daemon state?

## Widget protocol: what Tamago needs (from the Tamago session, 2026-11-02)

The Tamago session agrees with the split. Requirements for `MeumKit`'s widget protocol:

1. **Height:** the widget reports its preferred height and the card follows it, animated. Tama is about 90 pt,
   and up to about 200 pt with a five-line bubble. The width is the host's.
2. **Input:** clicks (the +1, the egg), a right-click menu (Feed/Pet/Poke/Listen plus settings submenus), and an
   inline text field for renaming. While that field is focused the host must not take the keystrokes.
3. **Appearance:** the host provides the colour scheme, the card's material and background so contrast can
   adapt, a bottom inset, and optionally its accent colour. Tamago currently assumes a dark background.
4. **Visibility:** hidden or visible, and on screen or occluded. Tamago pauses its 1 s animation and tells its
   daemon whether a bubble was actually seen, which the +1 timing relies on.
5. **Host calls:** `select(workspaceID)` (for a "re: <workspace>" jump; the daemon would add an `aboutId`) and
   optionally `notify`.
6. **Lifecycle:** one character across all meum windows. The view stays a pure renderer of the daemon's state,
   which makes that free.
7. **No sandbox.**

The Tamago session's preference, which we adopt: Tamago's daemon talks to meum only over layer 0 (socket and
events), runs as a launchd agent (which ends cmux's "denied after restart" problem), and the view only renders
daemon state.

**Workspace data Tamago's remarks need from the API.** Not all of it is in v1 yet:
- `id`, `title`, the selected workspace and selection changes over time: in v1;
- the workspace cwd and all pane/tab cwds, to find transcripts: in v1 (tabs carry `cwd`);
- `agent.hook` events with `transcript_path`: in v1, which makes transcript lookup exact;
- unread, the latest notification text, the last submitted prompt and its time: unread is in v1; the prompt comes
  from `UserPromptSubmit` hook events, and notification text is still open;
- git branch, listening ports, description, colour: colour is in v1. **Branch, ports and description are open.**
  The built-in sidebar wants them too.

Dropped from Tamago when it runs in meum:
- the "Claude Session Dots" menu item, which becomes a meum sidebar setting;
- the 40 pt cmux fade padding, which becomes the host inset.

## As built: native widgets (2026-11-02)

- **MeumKit** (`Sources/MeumKit/MeumKit.swift`) is a dynamic library. meum ships it as
  `Contents/Frameworks/libMeumKit.dylib`, so meum and every widget share one copy of its types. It is built with
  library evolution, so a widget built against an older MeumKit keeps loading as long as nothing is removed.
- **A widget** is a dylib that links MeumKit and exports `meum_widget_main`, which returns a
  `MeumWidgetRegistration` (manifest plus factory). It lives in `~/.local/share/meum/widgets/<name>.meumwidget/`
  (or `--widgets-dir` / `MEUM_WIDGETS_DIR`) with a `manifest.json` `{"id", "displayName", "library"}`. A file
  `disabled` in the folder skips it.
- **Runtime loading, not compiled in.** This answers the open question above: Tamago lives in its own repo, so
  compiling it in would make meum's build depend on it. Runtime loading is also the "nobody has to fork" promise.
- **Stacked slots** (2026-11-02, second session): every enabled widget gets its own card under the sidebar, at
  sidebar width. The cards stack upward from the bottom edge, and the sidebar takes what is left above them. Each
  card takes the height its widget asks for ("auto", the default) or the fixed widget height.
  - `manifest.json` `"scope": "workspace"` makes a workspace widget. Those sit above the global ones (the default
    scope; Tamago is global, so it stays at the bottom).
  - The `widgetOrder` setting (widget ids, top to bottom) orders the cards within each group. Set it with
    `meum widget order <id>…`, or with the arrows in Settings ▸ Widgets.
  - `meum widget enable|disable <id>` and the switch in Settings ▸ Widgets add or remove the `disabled` file.
  - `setPreferredHeight(0)` hides a widget's own card, e.g. a project widget on a workspace without a project.
  - MeumKit additions, all backwards compatible: `MeumWorkspaceInfo` (id, name, cwd, colour);
    `MeumWidgetHost.selectedWorkspace`; `MeumWidget.workspaceDidChange(_:)`, with a default no-op. Every widget
    gets the change on selection, rename, recolour or a new directory. A Tamago build from before these
    additions loads and runs unchanged.
  - `Examples/WorkspaceWidget` is the smallest workspace widget. It shows the selected workspace and hides itself
    on workspaces in the home folder.
- **Host interface:**
  - `appearance`: scheme, material, background luminance, accent, radius, bottom inset, width;
  - `visibility`: shown, and on screen (window occlusion, screens asleep);
  - `socketPath` for layer 0;
  - `setPreferredHeight` (the card animates to it; the widget height setting defaults to "auto");
  - `selectWorkspace`;
  - `notify`.
- **Reload:** `meum widget reload` dlopens a fresh copy of the library, so a rebuilt widget shows without restarting
  meum. The old code stays mapped until meum quits, which is fine for development. `meum widget list` shows what
  was found, what is loaded, and any load error.
- **Tooling:** `scripts/build-widget.sh <package> <product> [id] [name]` builds and installs a widget.
  `Examples/HelloWidget` is the smallest example.
- **Verified in an isolated instance:**
  - the example loads and the card takes its 90 pt;
  - a button click grows the card to 180 pt, animated;
  - the counter counts;
  - typing goes to the widget's text field, not the terminal.

## As built: widget tabs in the tiling area (2026-11-02)

- **A widget tab is a tab.** `Tab.widget` holds a widget id. The card shows that widget's view instead of a
  terminal surface, so a widget tab moves, splits, closes and is saved with its workspace like any tab. It has
  no shell and no zmx session. Alone in a card it fills the card, because a one-tab card shows no strip.
- **Placing one:** Terminal ▸ Add Widget ▸ <name> (a new card to the right of the focused one), or
  `meum tab new --widget <id> [--card ID | --split right|down]`.
- **Instances:** each widget tab gets its own widget instance, made when its workspace is shown and dropped
  (`willUnload`) when it is hidden, closed, or the widgets reload. The same lifecycle as terminal surfaces. A
  move between cards keeps the instance. Tabs of one widget share its loaded library.
- **MeumKit:** `MeumWidgetHost.placement` is `.sidebar` or `.tile(tab:)`. The tab id is stable across launches,
  so a widget can keep per-tab state under it; meum itself saves only the tab, not the widget's state.
  `setPreferredHeight` does nothing in a tile: the layout sizes it.
- A widget tab whose widget is not installed shows a note in its card instead.

## As built: messages, tab settings, `meum mcp` and the browser widget (2026-11-02)

- **Widget tabs live as long as their tab.** A hidden workspace's widget tabs keep their instance: only the view
  leaves the window, and `visibility.isShown` says so. A browser keeps its page across workspace switches, and a
  widget in a hidden workspace can still be messaged and screenshotted.
- **Tab settings:** `Tab.widgetConfig` (JSON text the widget owns), set with `tab new --widget ID --config JSON`
  and by the widget (`host.setConfiguration`); `host.configuration` reads it.
- **Messages in:** `MeumWidget.receive(_:reply:)`, JSON text in and out. `widget.send {tab | widget, message}` waits
  up to 30 s for the reply (CLI `meum widget send`). `widget.screenshot {tab | widget, path?}` asks the widget
  (`{"action": "screenshot"}` -> `{"png": base64}`) and otherwise draws the view itself.
- **Events out:** `host.publish(json)` -> `widget.event {widget, tab, data}` on the socket.
- **Scope `tile`** in manifest.json: no sidebar card; the widget only appears as tabs.
- **Focus:** a click into a widget tab focuses its card, and the widget keeps the keyboard. A widget tab opened
  over the API (a Claude session, a script) never takes the keyboard: the workspace keeps its focused card.
- **`meum mcp`:** an MCP server on stdio for Claude Code sessions in meum tabs. They know their workspace and tab
  from MEUM_WORKSPACE / MEUM_TAB; outside meum it lists no tools. The tools are `meum_context`, `meum_open_widget`,
  `meum_widget_send`, `meum_widget_screenshot` (returns an image), `meum_close_tab`, `meum_set_status` and
  `meum_notify`. Whether to reuse a widget tab or open a new one is the session's call; `meum_context` lists the
  workspace's widget tabs with their settings. Install: the `meum` plugin in this repo (a local directory marketplace), once per
  profile: `CLAUDE_CONFIG_DIR=~/.claude-<profile> claude plugin marketplace add ~/code/meum` then
  `... claude plugin install meum@meum --scope user`. It starts `/Applications/meum.app/Contents/Resources/bin/meum mcp`
  (`MEUM_CLI` overrides that path) and holds no secret. After a change to `plugin/`, run
  `claude plugin marketplace update meum && claude plugin update meum@meum` in each profile.
- **The browser widget** (`widgets/browser`, tile scope) is not part of meum, but a separate widget built with
  `scripts/build-widget.sh widgets/browser BrowserWidget io.github.mcurses.meum.browser Browser tile`.
  - WKWebView with back, forward, reload and an address field (`:5173` means localhost).
  - The tab remembers its page.
  - Safari's Web Inspector is on.
  - Messages: `navigate`, `reload`, `back`, `forward`, `state` (url, title, loading, recent console errors) and
    `screenshot`.
  - Console errors are also published as `widget.event`.
- **Verified in the isolated instance:**
  - a session-style `meum mcp` run opened a localhost page next to the terminal;
  - `state` reported the page's console error;
  - the screenshot came back as an image, also with the workspace hidden;
  - the URL survived as the tab's settings;
  - the keyboard stayed on the terminal when the browser opened;
  - clicks moved focus between page and terminal.

## As built: the collapsed sidebar and workspace icons (2026-11-02)

- **Collapse:** View ▸ Toggle Sidebar, ⌃⌘S by default (customisable, action `toggleSidebar`). Also
  `meum sidebar [toggle|collapse|expand]` (API `sidebar.setCollapsed {collapsed?}`) or the setting
  `sidebarCollapsed`, which keeps the state across launches.
  - The sidebar and the widget cards animate to a 60 pt rail (`WorkspaceController.railWidth`).
  - Each workspace is a tile: its icon on its colour, the selection behind it, and its agent state as a dot (orange:
    needs input, blue: unread, grey: a live session). The name is the tooltip.
  - Click selects, dragging reorders, and the context menu has colour, pin and close.
  - Rename Workspace (⇧⌘R) expands the sidebar first, because a name doesn't fit in the rail.
- **Workspace icons:** `Workspace.icon` is an emoji or up to two characters ("🌿", "vi"), or an SF Symbol as
  `sf:<name>` ("sf:leaf.fill"). Without one, the tile shows the name's first letter.
  - Set it with `meum workspace icon <icon|none> [--workspace WS]`, or the API `workspace.setIcon {id, icon}`.
  - Inside a meum tab, `$MEUM_WORKSPACE` is the default, so the agent living in a workspace runs
    `meum workspace icon 🚀` and needs no id.
  - The API rejects anything longer than two characters and unknown symbol names.
  - The icon is in the workspace JSON, and `workspace.changed` lists the field `icon`.
- **Widgets in the rail:** `MeumWidget.supportsCollapsedSidebar` (default false) says the widget has a collapsed
  look. `MeumWidget.sidebarCollapsedDidChange(_:)` arrives before the cards move, and also when a widget starts while
  the sidebar is collapsed.
  - The widget switches its view and asks for its height with `setPreferredHeight`. `appearance.width` becomes the
    rail width, and an `appearanceDidChange` follows.
  - `MeumWidgetHost.isSidebarCollapsed` reads the state.
  - A sidebar widget without the look is hidden in the rail. That covers every build from before this, e.g.
    today's Tamago, which is told it is not shown. Tile widgets (the browser) never see the rail.
  - `widget list --json` reports `supportsCollapsedSidebar`.
  - `Examples/HelloWidget` is the example: its counter alone, in a 48 pt card.
- **Verified in an isolated instance:**
  - icons as emoji, SF Symbol, two letters and the fallback;
  - invalid icons rejected;
  - the hotkey toggles, and the state survives in settings.json;
  - the agent dots in the rail;
  - ⇧⌘R expands and opens the name field;
  - the Hello widget shows its collapsed look;
  - the old Tamago build is hidden in the rail and comes back on expand.

## As built: workspace remotes and metadata, for project tools (2026-11-02)

- **Remotes:** meum reads the origin URL of the repository that the workspace's directory and each of its tabs'
  directories belong to. It reads the repository's config file (no git process, worktrees included), strips
  credentials, and refreshes this every few seconds together with the branch. The result is `remotes` in the
  workspace JSON, plus `MeumWorkspaceInfo.remote` (the workspace's own repository first) and `.remotes`.
- **Metadata:** `Workspace.metadata` holds key/value labels saved with the workspace, with namespaced keys by
  convention ("board.project").
  - `meum workspace meta [list] | set <key> <value> | unset <key> [--workspace WS]`;
  - `workspace.setMeta {id, key, value|null}` or `{id, metadata: {...}}`;
  - in the workspace JSON and in `MeumWorkspaceInfo.metadata`;
  - a change is a `workspace.changed` field "metadata", and widgets get `workspaceDidChange`.
- `Examples/WorkspaceWidget` shows both.

## As built: widget helpers and data folders (2026-11-02)

- **Data folder:** MeumKit `host.dataDirectory` is `<state dir>/widgets/<id>/` (`~/.local/state/meum/widgets/<id>/`),
  created by meum. It's shared by all instances of a widget and its helper. `widget.list` shows it as
  `dataDirectory`.
- **Helpers** (`App/Sources/MeumApp/Widgets/WidgetHelpers.swift`): `manifest.json`
  `"helper": {"command": "bin/daemon", "args": [], "keepAlive": true}`, with the command relative to the widget folder.
  - One per installed, enabled widget. It starts with meum, not with the widget's first card or tab.
  - Environment: meum's own plus `MEUM_SOCKET`, `MEUM_WIDGET_ID` and `MEUM_WIDGET_DATA`; its working directory is the
    data folder.
  - Output goes to `<state dir>/helpers/<id>.log`.
  - It runs in its own process group. Stopping it signals only that group (SIGTERM, SIGKILL after 3 s), and so does
    its exit: nothing it started outlives it.
  - keepAlive restarts it after 1, 2, 4 … 60 s; a run of a minute resets that.
  - A widget reload restarts a helper only when its command, arguments or file changed. Disabling or removing the
    widget stops it, and so does quitting meum.
  - `WidgetManager.stopHelper(id:)` / `startHelper(id:)` are for install, update and remove. `widget.list` shows
    `helper {running, pid, restarts, lastExit, log}`.
- **Verified in the isolated instance** with a script helper that starts a child: it starts at launch with the
  environment above; after kill -9 its group is emptied and it comes back (restarts 1); an unchanged reload keeps the
  pid and a changed file restarts it; disable stops it and its child; enable starts it; quitting meum stops it.

## Decision: no browser in meum; project tools integrate from outside (2026-11-02)

- meum gets no web-view tab kind. A browser could only ever be someone else's widget on meum's public API, never
  part of meum.
- A dashboard tool starts with a health status entry under its own key prefix on the matching workspace, plus a
  jump to its own window. A board widget comes later. It needs stacked widget slots, or a widget that can take a tiled
  card, on meum's side; when is open.
- Related gaps on meum's side: status entries have no click action (e.g. a `myboard://` URL), and MeumKit doesn't push
  workspace-selection changes to widgets (they use the socket's event stream).

## Roadmap: where widgets live (2026-11-02)

1. **Done (2026-11-02): stacked slots under the sidebar.** More than one widget fits; the cards stack above each other at the
   sidebar's width, each with its own height. Tamago stays at the bottom.
2. **Done (2026-11-02): global vs workspace-dependent slot widgets.** A global widget (Tamago) is the same on every workspace.
   A workspace-dependent widget sits above it and shows the selected workspace's content (e.g. a project's
   health). It changes with the selection.
3. **Done (2026-11-02): widgets in a workspace's tiling area.** A widget as a card next to the terminals, only in workspaces
   where it was placed. It is part of the workspace's layout tree, saved and managed with it like a tab.
