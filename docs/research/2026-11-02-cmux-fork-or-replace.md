# cmux: what it is becoming, and whether to fork, switch or build

2026-11-02. Facts come from the cmux 0.65.2 install on this Mac, the cmux settings schema, the GitHub API and
a web sweep. Anything marked *unverified* rests on one secondary source.

## Bottom line

- **Don't fork cmux.** The main repo is about 8 GB and took 316 commits in the last seven days. It ships its own
  forks of Ghostty and of the split library, and its cloud code runs through the sidebar, the right sidebar and
  the agent layer. A fork that strips all that becomes a full-time rebase job, or else a frozen copy that stops
  getting fixes.
- **No existing app covers your list without the extras.** Supacode is closest in shape, but it is built around
  git worktrees, uses a source-available license, and has no way to host Tamago.
- **Build your own, small**: a native Swift window that hosts Ghostty terminals (libghostty), with
  [zmx](https://zmx.sh) keeping the sessions alive, and plain Claude Code hooks for the dots. None of the hard
  parts needs inventing: Supacode shows the libghostty + zmx pattern works, Tamago's sidebar is already SwiftUI,
  and your wallpaper-glass prototype covers the visual part.
- **Until then, trim cmux** with the switches in section 4. That takes a few minutes and keeps Tamago running.

## 1. What cmux is trying to be

cmux started as "Ghostty with a vertical workspace sidebar and agent notifications". Here is what 0.65.2 does
on this Mac:

| Area | Evidence on this machine |
|---|---|
| Terminal multiplexer | workspaces, splits, tabs, plus a full tmux-compatible command set (`swap-pane`, `copy-mode`, `bind-key` …) |
| Agent IDE | `diff` viewer, `review`/`comments`, Markdown viewer, `todo`, `vault` (search, checkpoint, fork Claude sessions), `recover` |
| Agent orchestration | `agent message` (agent-to-agent mail), `claude-teams`/`codex-teams`, "Chief" (cmux's own orchestrator agent, run on Claude Code or Codex, with a skip-permissions option) |
| Browser | a full embedded browser with automation (`browser click/fill/eval/cookies/devtools…`), opened by default for terminal links, ports and PR links |
| Computer use | `cmux-cua` helper. It runs as **24 processes** on this Mac right now: every Claude session started in cmux gets it attached as a tool server |
| Remote & cloud | Cloud VMs (`cmux vm …`: snapshot, fork, ports, desktop), SSH/mosh/tmux mirroring, `session move` between machines, Iroh peer-to-peer networking, devices, iOS simulator, mobile companion |
| Misc | `sudo` with Touch ID, screen `record`/`shot`, an automation engine, `coderouter`, AI-account upload |
| Telemetry | PostHog and Sentry are bundled. `sendAnonymousTelemetry` defaults to true, and analytics keys show your upgrade came "from the sidebar badge" |

Size: the app is 233 MB against Ghostty's 67 MB, and the main process is using 367 MB here.

**How it hooks into Claude Code.** cmux puts a `claude` wrapper on the PATH of its terminals. The wrapper adds
`--settings` (the hooks behind the dots, resume and status) and `--mcp-config` (computer use) to every Claude
session started there. That is invisible from `~/.claude/settings.json`.

**The business.** Manaflow is a YC company. The app is free for good, and the money comes from Cloud VMs at
$50–200 a month per seat (cmux.com/pricing; "Cloud is available to everyone" since 0.65.0). So the upgrade
button is the sales funnel. It will not go away, and every release has a reason to wire cloud in more deeply.

**Your sense is right.** In October's releases, your features (hibernation, 30 fps for unfocused panes,
scrollback checkpoints, Claude auto-resume) came alongside an equal or larger amount of cloud, SSH, mobile,
browser and agent-tooling work. cmux is turning into an agent workbench with a cloud business attached. A
terminal manager is now one part of it.

## 2. What you actually use, and what each piece really is

| You use | Mechanism underneath | Hard to rebuild? |
|---|---|---|
| Workspaces in a vertical sidebar | SwiftUI list | easy |
| Tiling with tabs inside a workspace | a split tree whose leaves hold tabs (cmux uses its "bonsplit" library) | medium, mostly UI detail |
| Dots: Claude sessions per workspace, unread | Claude Code hooks (SessionStart, UserPromptSubmit, Stop, Notification) injected by the wrapper and fed into cmux's notification store | easy, and cleaner without a wrapper |
| Lower load for background workspaces / hibernation | lower redraw rate for hidden surfaces, plus suspending agents | free with a session daemon (see 5) |
| Auto-resume after restart | stored session id per pane → `claude --resume <id>` in the same directory | easy to do, fiddly to get right |
| Hosting Tamago | CmuxExtensionKit sidebar + the cmux CLI (`rpc extension.sidebar.snapshot`, `sidebar-state`, `events`) | a small adapter |
| *Wanted:* nicer visuals, wallpaper | your `~/code/wallpaper-glass` prototype (screen-anchored, blurred wallpaper behind an opaque window) | already prototyped |

Everything you use sits on four ideas: a window with a sidebar, a split tree, a session daemon, and a hook
pipe. Everything you don't use is the other 90% of cmux.

## 3. The options

### A. Stay on cmux, trimmed

- Effort: minutes.
- Upside: Tamago keeps working, and you get their fixes.
- Downside: the upgrade badge, the wrapper, the churn (316 commits a week means regressions as well as fixes),
  and features creeping back with defaults set to on.

### B. Fork cmux

- GPL-3.0 allows it. Parts of the repo (`web/`, the relay) are under the Business Source License, but you
  wouldn't need those.
- What you'd carry: an 8 GB repo, forked Ghostty and bonsplit submodules, and Cloud/Chief/browser code woven
  into the same SwiftUI views you'd keep. Tracking upstream means rebasing a strip-down patch onto about 300
  commits a week. Freezing it means losing Ghostty and Claude-resume fixes.
- Existing forks: one telemetry-free fork (kernelalex/zerocmux) keeps everything else, and nobody has removed
  cloud or the browser.
- **Verdict: worst cost-to-value of the four.**

### C. Switch to something that exists

| Candidate | Fit | Why not |
|---|---|---|
| **Supacode** (Swift, libghostty, zmx sessions; v0.11.6, 2026-10-25; ~2.4k ★) | sidebar, tabs and splits, per-pane busy/waiting/idle badge, sessions survive app restarts through zmx, installs agent hooks, local only | built around git worktrees; Functional Source License (source-available, turns Apache-2.0 after 2 years); macOS 26+; no extension API, so no Tamago; no wallpaper |
| **Ghostty** 1.4 alone | the terminal you already like; AppleScript control since 1.3 | no sidebar, restores layout only with fresh shells, no agent state |
| **tmux + resurrect/continuum + tmux-claude-continuity**, inside Ghostty | the most Unix option; resume through a Stop hook (*the plugin's README is unclear on which hook it needs*) | no native sidebar, visuals limited to the status line, terminal inside a terminal |
| **Agent Deck** (Go TUI on tmux, MIT) | session list with Running/Waiting/Idle | TUI, no reboot restore, no visuals |
| **iTerm2 3.7** | Claude "session status" dots, tab groups, session archive, per-profile backgrounds | heavy, plus its own AI chat and phone app; no vertical sidebar |
| Zellij, WezTerm, Kitty | sessions and layouts | no sidebar, no agent awareness |
| Warp, Wave, Superset, Conductor | – | Electron and/or accounts and cloud, the same problem as cmux |
| AeroSpace | tiles Ghostty windows | a window manager, no sessions or dots |

Nothing here hosts Tamago, and nothing has wallpaper glass. Supacode is worth an afternoon's test drive, mainly
as a reference for how to build your own.

### D. Build your own ("meum"): recommended

The Unix split: **zmx keeps sessions alive, Claude Code hooks report agent state, and a thin native app draws
the window.** Each piece is replaceable.

```
┌──────────── meum.app (Swift/AppKit + SwiftUI) ───────────┐
│ sidebar: workspaces + dots + Tamago view                 │
│ per workspace: split tree → tabs → libghostty surface    │
│ behind it all: wallpaper glass (per workspace optional)  │
└───────────────┬──────────────────────────┬───────────────┘
                │ each tab = `zmx attach`  │ unix socket: JSON events
        ┌───────▼───────┐          ┌───────▼─────────────────┐
        │ zmx daemon    │          │ ~/.claude hooks          │
        │ (shells keep  │          │ SessionStart/Stop/       │
        │  running)     │          │ Notification → meum-hook │
        └───────────────┘          └──────────────────────────┘
        state: ~/.local/state/meum/layout.json (workspaces, splits, tab→zmx name, tab→claude session id)
```

- **Sessions.** Each tab runs `zmx attach meum-<workspace>-<tab>`. If the app quits or crashes, the shells and
  Claude sessions keep running in zmx, and reattaching restores screen and scrollback (zmx uses libghostty-vt).
  Restore after a crash or restart is therefore built in. `claude --resume <id>` is only needed after a reboot.
- **Background workspaces.** A hidden workspace can drop its libghostty surfaces entirely, because zmx holds the
  processes. That is cheaper than cmux's 30 fps throttle and needs no "hibernation" feature.
- **Dots and resume ids.** Add one hook command to `~/.claude/settings.json` for every account dir. Each tab gets
  `MEUM_TAB=<id>` in its environment, and the hook posts
  `{tab, event, session_id, cwd, transcript_path}` to the app's socket. That is enough for "N sessions, unread
  yes/no" per workspace, and it records the resume id. No wrapper, no hidden flags.
- **Tamago.** `SidebarView`/`SidebarModel` are SwiftUI already. Replace `CmuxExtensionKit` with a small in-app
  protocol, or load it as a plugin bundle. Point the daemon's few cmux CLI calls at `meum` equivalents (snapshot,
  events, set-status). Its own state, memory and `claude -p` remarks don't change.
- **Visuals.** Bring in wallpaper-glass as the window background, optionally a wallpaper per workspace, with
  your own sidebar styling.
- **CLI.** Keep it small: `meum new|select|list|notify|events`. Socket-based, so Tamago and scripts can drive it.
- **Explicitly out of scope:** browser, cloud, agent messaging (other tools do that), diff/review, telemetry and
  auto-update pings.

**Risks**

- The libghostty embedding API is still unstable. Ghostty 1.3 shipped a Zig module and a C API marked
  work-in-progress, so pin one Ghostty commit and upgrade on purpose. cmux and Supacode both embed it
  successfully, so it is proven, just not frozen.
- zmx is young (Zig; check its license and maturity during the spike). tmux in control mode is the fallback for
  the same role.
- Drag-and-drop splits and tab polish are where the hours actually go.

**Size of the job** (calibrated against your log, where my gut tends to run 10× high):

- **Minimum viable**: a window with workspaces, splits with tabs, zmx persistence, hook dots and reboot resume.
  About 1–2 focused sessions.
- **Polish-complete**: the Tamago port, wallpaper glass, drag and drop, settings, a signed build. A few more
  sessions.

**First step, if you want one:** a short spike with three questions. Does a GhosttyKit surface attached to
`zmx attach` reattach cleanly after the app is killed? Do hook events reach a socket with the right tab id? Do
the hooks fire across your multiple `~/.claude*` account dirs? If all three pass, the rest is UI.

## 4. Trimming cmux in the meantime (option A, or the bridge to D)

These are keys in `~/.config/cmux/cmux.json`, taken from the official schema. Back up the file first, as cmux
asks.

- `computerUse.enabled: false`: stops the 24 helper processes being attached to every Claude session.
- `cloud.enabled: false`, plus `sidebar.showCloudDeviceIcons: false`.
- `sendAnonymousTelemetry: false`.
- `agentMessages.enabled: false`, and set the Chief/"Home row" `enabled` key in the same block to false.
- The `browser` settings: stop terminal, port and PR links opening in cmux's browser
  (`openTerminalLinksInCmuxBrowser`, `openPortLinksInCmuxBrowser`, `openPullRequestLinksInCmuxBrowser`).
- **Keep** `autoResumeAgentSessions`/`agentAutoResume`, `agentHibernation` and `claudeCodeIntegration` (which
  feeds the dots). The extension-sidebar settings Tamago needs also stay on.
- I found no key for the upgrade badge.

## Why the dots work only "so semi" (answer from the Tamago session)

- **cmux only hears about sessions started through its wrapper.** On 2026-10-22 it got 8 of 36 finished turns.
  Sessions started with another `CLAUDE_CONFIG_DIR` alias (`~/.claude-work` and the like) or resumed
  sessions bypass the wrapper. cmux's unread badge comes from those notifications only, so those workspaces
  never turn unread. Tamago therefore detects turn ends itself, from the transcripts.
- **Tamago's session dots don't come from cmux at all.** Every 10 seconds it reads `ps` and assigns each
  `claude` process to a workspace through the `CMUX_WORKSPACE_ID` in its environment. That breaks when a pane
  moves to another workspace (the environment is fixed when the shell starts) and lags by up to 10 seconds.
- **Other friction:**
  - After a cmux restart, the socket refuses the old Tamago daemon.
  - After an update, the sidebar can show "Extension Blocked" until you click.
  - The extension API has no rename, pin, reorder or colour actions, so those take side routes.
  - The upgrade pill can't be hidden (manaflow-ai/cmux#29596).
  - In windowed Minimal Mode the pane tab bar is missing (#29735).
- **What this means for meum:** one hook entry in *every* account folder's `settings.json` (no wrapper) fixes
  the root cause. A tab id set by the app, not a workspace id frozen at shell start, fixes the moved-pane
  case. To keep working, Tamago needs four things from meum: a workspace list with selection and change
  events, a per-terminal environment variable, a place for its SwiftUI view, and the workspace actions.

## Open points

- Not checked: zmx's license and stability; whether Supacode resumes Claude conversations or only reattaches
  shells; how cmux's YC batch and funding are dated (sources disagree).

## Sources

- github.com/manaflow-ai/cmux (GitHub API: size 8,035,367 KB, 316 commits 2026-10-26…11-02), cmux.com/pricing,
  cmux.com/docs/changelog
- cmux settings schema: raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json
- github.com/supabitapp/supacode (FSL-1.1-ALv2, v0.11.6), zmx.sh
- ghostty.org/docs/install/release-notes (1.3.0, 1.4.0), github.com/ghostty-org/ghostty/discussions/3358
- github.com/MadAppGang/tmux-claude-continuity, github.com/asheshgoplani/agent-deck, github.com/kernelalex/zerocmux
- alternativeto.net news on iTerm2 3.7 (2026-09)

## Spike results (2026-11-02)

All three risky parts of option D work. Details are in `spikes/*/RESULT.md`.

- **Ghostty + zmx** (`spikes/ghostty-zmx`): **works, with caveats.**
  - What was tested: a Ghostty v1.4.0 terminal running `zmx attach` inside a one-file Swift app. The app was
    killed with `kill -9` and relaunched.
  - The session kept running while the app was gone. Screen, 300 lines of scrollback and a vim session came
    back intact.
  - Freeing a terminal takes about 15 ms and recreating it about 2 ms, so hidden workspaces can drop their
    terminals.
  - zmx is MIT-licensed. Both zmx and Ghostty need zig 0.17.
  - Caveats: meum must ship Ghostty's resource files (terminfo, shell integration) inside the app. The spike's
    keyboard handling is simplified (no input methods or dead keys).
- **Claude hooks without a wrapper** (`spikes/claude-hooks`): **works.**
  - All seven logged-in account folders delivered events to a unix socket, each carrying the tab id.
  - `--resume` keeps the session id.
  - A permission prompt arrives as a Notification event.
  - The hook is a no-op in about 4 ms when meum isn't running.
- **Floating layout** (`spikes/floating-layout`): **native and robust.**
  - The layout: one invisible screen-sized window with a rounded sidebar card and tiled terminal cards.
  - Clicks in the gaps reach the windows behind.
  - Cards move in a single animation at 60 fps, and Mission Control treats the workspace as one unit.
  - An external tiling window manager would be the hacky route.
