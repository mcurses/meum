# meum architecture (v1 contract)

Working name **meum**. Max is choosing a final name, so the name appears in exactly one place per layer and
renaming is a search and replace:
- `Product.name` in MeumCore
- the bundle id `io.github.mcurses.meum`
- the CLI target name
- the env prefix `MEUM_`

Read first: `docs/design/sidebar-widgets-extensibility.md` (principles, layers) and the spike results in
`docs/research/2026-11-02-cmux-fork-or-replace.md` and `docs/research/spike-*.md`.

## Parts and owners

| Part | Where | Owner lane | Depends on |
|---|---|---|---|
| Model, layout tree, persistence (host-free) | `Sources/MeumCore` | app lane | Foundation only |
| Control channel: wire protocol, socket server/client, event bus, agent tracker, resume builder, hook installer (host-free) | `Sources/MeumControl` | control lane | MeumCore (only `Product`, ids) |
| `meum` CLI | `Sources/meum` | control lane | MeumControl |
| `meum-hook` (POSIX sh) | `Resources/bin/meum-hook` | control lane | `nc` |
| (`meum-hook` also prints two factual lines on SessionStart, once meum took the event: the session runs in a meum tab, and what it can label. Claude Code adds them to the session's context.) | | | |
| The app: AppKit/SwiftUI, libghostty bridge, container window, cards, tabs, sidebar, widget slot, zmx sessions | `App/` | app lane | MeumCore, GhosttyKit, zmx |
| Build scripts | `scripts/setup.sh` (vendor Ghostty + zmx), `scripts/build-app.sh` (assemble `build/meum.app`) | app lane | |
| Integration (ControlHandler in the app, dots from the tracker, reboot resume, Tamago widget) | `App/` | integration step, after both lanes land | everything |

`Package.swift` already declares all targets. A lane adds files only in its own directories. If a lane must
change `Package.swift`, it keeps the change minimal and says so in its report.

## Paths and environment

- **State dir:** `~/.local/state/meum/`, mode 0700. Inside it:
  - `meum.sock`: unix socket, mode 0600
  - `layout.json`: persisted model
  - `meum.log`
- **Env set in every tab's shell:**
  - `MEUM_SOCKET`
  - `MEUM_WORKSPACE`: workspace UUID
  - `MEUM_TAB`: tab UUID
  - `MEUM_CLI`: the `meum` command of the app that runs the tab (the Claude Code plugin's MCP server uses it)
  - `PATH` with the bundle's `bin/` (`meum`, `meum-hook`) in front
  - `TERM=xterm-ghostty`, `COLORTERM=truecolor`
  - `GHOSTTY_RESOURCES_DIR` from the bundle
- **Env removed from every tab** (`ProcessEnvironment.scrub`, before libghostty starts): every inherited
  `CLAUDE*` variable (a meum started from inside Claude Code must not make a `claude` in a tab think it is nested
  or bind it to another profile), `CMUX_*`, `GHOSTTY_*` (re-set from the bundle), `MEUM_*`, `TERMINFO`,
  `ZMX_SESSION`, `TERM_PROGRAM*`, `TMUX*`, `ITERM_SESSION_ID`, `TERM_SESSION_ID`.
- **zmx session name per tab:** `meum-<first 12 hex chars of tab UUID>`. The bundled zmx is used.

## Model (MeumCore)

```
AppState      { workspaces: [Workspace], selectedWorkspaceID: UUID? }
Workspace     { id, name, color: String? (hex), pinned: Bool, cwd: String?, root: LayoutNode?, focusedCardID: UUID? }
LayoutNode    = .split(Split) | .card(Card)
Split         { id, axis: .horizontal | .vertical, ratio: Double (0.1…0.9), first: LayoutNode, second: LayoutNode }
Card          { id, tabs: [Tab], selectedTabID: UUID }          // a tiled "window" with a tab strip
Tab           { id, title: String?, cwd: String?, command: String?, agent: AgentSnapshot? }
AgentSnapshot { sessionID: String, configDir: String?, transcriptPath: String?, cwd: String? }   // for reboot resume
```

- Value types, `Codable`, `Equatable`, `Sendable`.
- The layout is a binary split tree (BSP) of cards. Splitting a card replaces it with a split holding the old card
  and a new one.
- Closing the last tab of a card removes the card and collapses its parent split.
- Pure functions, unit-tested:
  - geometry: `frames(in: CGRect, gap:) -> [UUID: CGRect]`
  - mutations: split, close, move focus by direction, resize a split, reorder workspaces
- Persistence: JSON at `layout.json`, atomic write, saved on every structural mutation. The model carries a
  `version` field.

## Control channel (MeumControl)

- **Transport:** unix socket `MEUM_SOCKET`, newline-delimited JSON, one request per line.
  - Request: `{"id": 1, "method": "workspace.list", "params": {…}}`
  - Response: `{"id": 1, "result": …}` or `{"id": 1, "error": {"code": "not_found", "message": "…"}}`
  - The API version is `meum.v1`, returned by `system.ping`.
- **Methods and events v1:** [docs/api.md](../api.md), generated from the doc comments in
  `Sources/MeumControl/ControlHandler.swift` (`MeumMethod`, `MeumEvent`); a test fails when a method or event has
  no comment, or the file is stale. `system.ping` lists the methods a running meum serves.
- **Server:** MeumControl owns the socket and dispatch. The app supplies a
  `ControlHandler` (`func handle(method:params:) async throws -> JSON`). The server knows nothing about AppKit.
- **AgentTracker:** a pure state machine.
  - Input: hook events keyed by tab.
  - Per tab: `{sessionID, configDir, transcriptPath, cwd, phase: running | idle | needsInput, unread: Bool, updatedAt}`.
  - Transitions:
    - `SessionStart` → idle; record the session id, overwriting the old one (fork gives a new id).
    - `UserPromptSubmit` → running.
    - `Stop` → idle, unread = true unless that tab is focused.
    - `Notification(permission_prompt | elicitation_dialog)` → needsInput, unread. `idle_prompt` is ignored: Claude Code
      sends it 60 s after every finished turn, which `Stop` already covers.
    - `SessionEnd` → remove.
  - Dedupe identical events.
  - Workspace summary: live session count, any unread, any needsInput, and how many sessions need input or are unread
    (the sidebar draws one dot per session).
  - `markRead(tab | workspace)`.
- **Resume builder:** `AgentSnapshot` → the shell command to resume:
  `cd <cwd> && CLAUDE_CONFIG_DIR=<dir> claude --resume <id>`. The `CLAUDE_CONFIG_DIR=` part is left out when the
  dir is `~/.claude`, because setting it explicitly broke login in the spike.
- **Hook installer:** `meum hooks status | install | uninstall [--config-dir DIR …]`.
  - Default target: every `~/.claude*` directory that has a `settings.json` or credentials.
  - It writes one `meum-hook` entry for SessionStart, UserPromptSubmit, Stop, Notification and SessionEnd.
  - It merges and never clobbers other hooks, it is idempotent, and it backs up `settings.json.bak-<timestamp>`
    before writing.
  - `install` without `--yes` only prints the planned diff.
  - **Never run it against Max's real dirs during development**: tests use temp dirs.

## App (App/)

- **Window: approach A from the floating spike.** One borderless, non-opaque, screen-sized container window per
  display it is on (v1: main screen's `visibleFrame`, following screen changes). It holds:
  - a fixed-width **sidebar card** (built-in sidebar);
  - under it, attached, a **widget slot card** (empty in v1 core; Tamago comes in integration);
  - the **terminal cards** of the selected workspace, tiled from the BSP with even gaps.

  All cards are rounded and shadowed (use `NSShadow`, not `layer.shadow*`), with a wallpaper-glass background
  (port from `~/code/wallpaper-glass`, defaults blur 4, tint 0.35). Clicks in gaps pass through (setting
  `gapsCatchClicks`, default false).
- **Card:** a slim tab strip (title, agent dot per tab, close, +) over one libghostty surface (the selected tab).
  Relayout animates the cards in one Core Animation transaction. Terminal surfaces get their final size once, at
  the end.
- **Terminals:**
  - The libghostty bridge is adapted from agterm (github.com/umputun/agterm, MIT; its bridge is itself adapted
    from macterm, MIT): GhosttyApp, callbacks, resources, the surface view with full `NSTextInputClient` input.
    Keep their attribution comments and add ours.
  - Every tab's surface runs `<bundled zmx> attach <zmx-name>`, with the shell as the session command.
- **Sessions survive the app:**
  - On launch, restore `layout.json` and reattach every visible tab.
  - Tabs of hidden workspaces have no surface. Their surface is created when the workspace is shown and freed
    when it is hidden (cheap: about 2 ms create, about 15 ms free, measured in the spike). zmx keeps the
    processes.
  - If a tab's zmx session is gone (after a reboot) and the tab has an `AgentSnapshot`, start the resume command
    in the new session. Otherwise start a plain shell in the tab's cwd.
- **Default keys:**
  - ⌘N new workspace; ⌘1…9 select workspace; ⌘⇧[ / ⌘⇧] previous/next workspace
  - ⌘T new tab in the focused card; ⌘D split right; ⌘⇧D split down
  - ⌘W close tab; ⌘⌥←↑→↓ focus card; ⌃⌘←↑→↓ resize split; ⌘[ / ⌘] previous/next tab in card
- **Sidebar v1** (built-in, its data access kept behind a small protocol so it can later become a real extension):
  - workspace rows: colour stripe, name, agent dots (live count, unread, needs input), selected highlight;
  - click to select; drag to reorder; right-click to rename, colour, pin or close; a "+" to add.

## Verification (every lane)

- Host-free logic gets unit tests (`swift test`).
- The app gets a scripted check, driven through the CLI or a debug flag:
  - launch the app;
  - create workspaces and tabs;
  - type into a tab;
  - kill the app by its captured pid and relaunch;
  - verify the screen came back, by screenshot and by reading the surface text.
- Look at the screenshots.
- Never kill processes you didn't start. Never touch cmux, Ghostty.app, Max's `~/.claude*`, or the Tamago repo.

## Integration notes (as built)

- **Tree encoding** (`ModelJSON` in MeumControl): flat nodes, `{"type":"card","id","selectedTabID","tabs"}` and
  `{"type":"split","id","axis","ratio","first","second"}`. Workspaces in `tree` and `workspace.list` also carry
  `selected`, `focusedTabID`, `branch` (from `.git/HEAD` of the focused tab's cwd), `cwds` and `status`.
- **Model events** come from one place: every store mutation is diffed (`ModelJSON.diff`) into
  `workspace.*` / `tab.*` events, so UI, keys and API cause the same events. Extra types: `status.changed`,
  `notification`, and `workspace.changed {fields:["branch"]}`.
- **Unread**: the tracker's focused tab is the UI's focused tab while the app is active, none while it is not.
- **Snapshot** (`Tab.agent`) is written from every hook that carries a new session id and cleared on
  `SessionEnd` with an explicit reason (`prompt_input_exit`, `logout`, `clear`). `SessionEnd` with reason `other`
  keeps it: Claude Code reports `other` both for a finished `claude -p` and for a session killed by a signal
  (reboot), and the second case is what resume is for.
- **Startup commands** (resume, `tab.new --command`) run as `$SHELL -ilc '<cmd>; exec $SHELL -l'`, so rc-file
  PATH entries and shell functions (e.g. a `claude` wrapper) apply.
- `tab.sendText` writes raw input through `zmx send`; a tab whose workspace was never shown has no session yet.
- **Moving tabs** (`tab.move`, dragging a tab): reconcile detaches the surfaces of tabs that left their card into a
  pool and re-adds them to the new card, so the libghostty surface and its zmx client stay the same (no reattach,
  scrollback kept). A tab moved into a hidden workspace loses its surface; the zmx session lives on and is
  reattached when that workspace is shown. Events: `tab.moved {id, workspace, card, index, fromWorkspace,
  fromCard}` (plus `tab.changed {fields:["card"]}` and `workspace.changed {fields:["layout"]}`).
- **Drag and drop:** a tab dragged from a strip drops into another strip at the caret, onto a card body (into that
  card), or onto the outer 28% of a card body (split that card on that edge, highlighted half). Dropping outside
  any card cancels.
- **Split gaps:** one `DividerView` per split over its gap strip (at least 8 pt to grab). It paints a 1% fill, so
  the window server sends it the mouse while the rest of the gaps stay click-through. During a drag the layout uses
  live ratios (no store mutation); surfaces are resized at most every 100 ms and once at the end (layout plus
  `ghostty_surface_set_size` measured under 1 ms per step; the throttle spares the program in the pty a SIGWINCH
  per frame). Mouse-up commits one `split.resize`-equivalent mutation, so one `split.resized {id, workspace, axis,
  ratio, previous}` event. Double-click resets to 0.5. Cards stay at least 140 pt.
- **Settings:** `<state dir>/settings.json` (`Settings` in MeumCore, tolerant of missing and unknown keys). The
  settings window (⌘,) writes through the same `AppSettings.set(key, value)` as `settings.set`; every change is
  applied live and published as `settings.changed {key, value}`. Ghostty config load order: meum defaults,
  `<state dir>/ghostty.conf`, the extra config file, then the font settings (`ghostty.settings.conf`); applied to
  running surfaces with `ghostty_app_update_config`. `reattachSessions` off ends the restored tabs' sessions at
  launch, so they start fresh shells.
