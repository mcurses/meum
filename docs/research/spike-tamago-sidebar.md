# Tamago's sidebar inside the meum floating layout

> The spike's code was removed from the tree on 2026-11-05; this result is what remains. The paths below are where it lived.

2026-11-02, MacBook Pro 16", macOS 26, Swift 6.4.2. Tamago HEAD `0c53cad` (the copied files had no
uncommitted changes; see `vendor/PROVENANCE.txt`).

## Verdict: Tamago's Swift side runs in meum with zero edits

- **All five sidebar sources compile unchanged.** That covers the entry point, the model, the view, the
  pet and the daemon client. They are copied byte for byte, and `build.sh` checks that with `cmp`
  against the Tamago repo. They build against a 70-line stand-in for cmux's `CmuxExtensionKit`. The
  real SDK has about 1,400 lines plus ExtensionKit and XPC.
- **It renders and animates on the wallpaper-glass sidebar card.** It shows your real 29 workspaces
  from the running cmux, colour stripes, session dots, the unread badge, the port chip, Tama's bubble,
  and the egg's feet stepping every second. Two screenshots 1.1 s apart differ only in the sprite area.
- **The daemon side is where the real port work is.** The node daemon calls the cmux CLI in eleven
  ways and reads cmux's settings and environment variables (list below). The sidebar view itself
  needs nothing from cmux beyond a workspace list and a "select" callback.

## Shim size: what Tamago really uses from CmuxExtensionKit

`Shim/CmuxExtensionKit.swift` is 99 lines, of which 70 are code. It contains:

| Type | Members Tamago uses |
|---|---|
| `CmuxSidebarSnapshot` | `selectedWorkspaceID`, `workspaces` (the shim also carries `sequence`) |
| `CmuxSidebarWorkspace` | `id`, `title`, `isPinned`, `gitBranch`, `unreadCount` |
| `CmuxSidebarHost` | `selectWorkspace(_:) async throws`, and nothing else |
| `CmuxSidebarContext` | `snapshot`, `host` |
| `CmuxSidebarExtension` | `manifest`, `body`, `update(context:)`, `init()` |
| `CmuxExtensionManifest` + 2 scope enums | only for the manifest literal in `TamagoSidebarExtension.swift` |

**How `@main` works without ExtensionKit.** Tamago's `@main final class TamagoSidebarExtension` needs a
`static func main()`. The shim provides it in a protocol extension. It builds the extension object and
passes it to whatever class is registered under the Objective-C name `MeumSidebarHostApp` (protocol
`CmuxShimHostApp`). The meum host implements that class. So the real Tamago entry point boots the meum
window, and nothing in Tamago knows the difference.

**Tamago edits needed: none.** I made no edits, so there is no diff to report.

## What was built (`Host/MeumHost.swift`, 628 lines)

- **The floating layout.** This is the floating-layout spike's approach A, trimmed to mode A: one
  clear window covering the screen, a 240 pt rounded sidebar card and two terminal placeholder cards.
  It keeps all four materials: glass, vibrancy, liquid and solid. The sidebar card's placeholder text
  is replaced by `NSHostingView(rootView: ext.body)` with a dark colour scheme.
- **Workspaces come from your real cmux, read-only.** The host runs
  `cmux rpc extension.sidebar.snapshot '{}'` every 2 s and maps its snake_case JSON to the shim's
  types. The socket accepted the call: the spike was started from a cmux terminal, so cmux's
  "cmuxOnly" check passed. The ids are the real ones, so the daemon's per-workspace details (colour,
  session dots, ports) match up. If cmux refuses, the host falls back to `fixtures/snapshot.json`.
- **Selection stays local.** `selectWorkspace` logs `{"ev":"selectWorkspace","forwardedToCmux":false}`,
  moves the highlight and retitles terminal card 1.
  - A synthesised click on "garden" logged that event, and cmux's own selection stayed on "meum"
    (checked with a fresh snapshot right after).
  - A second click on "factorio" was logged 10 s later. I didn't make that click; it was probably
    yours.
- **Tama's state comes from the live daemon, read-only.** Tamago's own `DaemonClient` finds the daemon
  this way:
  - the URL is the `TamagoDaemonURL` key in Info.plist, defaulting to `http://127.0.0.1:47321`;
  - the token is re-read on every request from `<real home>/.local/state/tamago/token` (found through
    `getpwuid`, so it also works in the sandbox);
  - the token is sent as the `X-Tamago-Token` header.

  It ran unchanged against the live daemon.
- **Actions are blocked in the adapter, not in Tamago.** A `URLProtocol` registered for
  `URLSession.shared` (the session `DaemonClient` uses) catches every request that isn't a GET. It
  logs the body and answers `200 {"ok":true}`.
  - How the block was proven without touching your Tama: `--selftest` sends a POST shaped like
    `DaemonClient`'s to a dead port (47399). It came back as `actionBlocked` with 200, not
    connection-refused.
  - The daemon log showed no "sidebar action" line during either run.
  - `--daemon fixture` also serves `GET /state` from `fixtures/state.json`. That wasn't needed, because
    the daemon was reachable.
  - Side effect worth knowing: a `GET /state` sets the daemon's `stateReadAt`, which keeps its
    once-a-minute sweeps running (`sidebar-state`, `netstat`, `ps`). The cmux sidebar already does
    the same.

### Run

```sh
cd ~/code/meum/spikes/tamago-sidebar
./build.sh                                   # re-copies Tamago's sources (read-only), checks them, builds
build/TamagoInMeum.app/Contents/MacOS/TamagoInMeum --autoquit 30 --selftest > logs/run.log
#   --material glass|vibrancy|liquid|solid  --feed cmux|fixture  --daemon live|fixture
#   remote: distributed notification "meum.tamago.cmd", object add|remove|next|layout|material:<m>|quit
```

## How it looks on the glass (screenshots in `shots/`)

- `run1-sidebar-a.png` / `-b.png`: the full sidebar on glass, 1.1 s apart. Only the sprite region
  differs (pixel box x 215–319, y 1873–2015), so the egg animates.
- `run2-sidebar-selected-glass.png`: after the local click on garden.
- `materials-top.png`: glass, vibrancy and liquid side by side. **Caveat:** `screencapture -l`
  captures only the window, so behind-window vibrancy shows as flat grey and Liquid Glass as near
  black. Only the glass column (which the app draws itself) is a faithful picture.
- `run1-a.png`, `run2-*.png`: the whole container window. The gaps are transparent, so none of your
  other windows were captured.

What needs attention on the glass:

1. **The bottom 40 pt are empty.** `PetFooter` adds `.padding(.bottom, 40)` to clear cmux's fade at
   the bottom of its sidebar. meum has no fade, so Tama sits too high and the card wastes its bottom.
   meum should either draw a fade or have the host pass in a bottom inset, which would be the one
   Tamago change worth making.
2. **The full-width `Divider()`** above the pet runs into the card's rounded edge. It's fine on glass,
   but an inset divider would look cleaner. This is cosmetic.
3. **Colours hold up on the dark glass (tint 0.35):**
   - the selection fill `#3D7BFF40` reads clearly;
   - the faint session dots (`secondary` at 45%) are barely visible but legible;
   - the speech bubble's `#8A8A8A` outline is fine.

   On a light wallpaper or vibrancy the dots and the bubble outline would lose contrast, because
   Tamago assumes a dark `#1E1E1E`-like background.
4. **There's no title-bar inset**, which is correct here: cmux reserves the top of its sidebar for
   traffic lights. I gave the hosted view an 8 pt top margin, and the rows' own `padding(6)` looks
   right in the card.
5. **Keyboard:** the host's layout shortcuts (n/w/l/m/q) are skipped while a text field has focus, so
   Tamago's inline rename still types.

## Porting plan

### Swift side: no edits needed; three optional ones

- `import CmuxExtensionKit` keeps working as long as meum ships a module with that name and the shim's
  shape. That is the zero-edit path.
- The clean path is a rename: `import TamagoHostKit` (or similar) in four files, plus a different
  `@main` story.
- Optional: drop the 40 pt scrim padding, and make the "Waiting for cmux…" and
  "Workspace details: cmux Settings → Sidebar" strings host-neutral.

### Node daemon: what it needs from its host (cmux today, so meum must offer it)

| Today (cmux) | Used for | meum equivalent |
|---|---|---|
| `cmux rpc extension.sidebar.snapshot '{}'` | workspace list; per workspace `id, title, selected, pinned, unread_count, custom_color, description, current_directory/root_path, git_branches, pull_request_urls, listening_ports, latest_notification_text, latest_submitted_message, remote_*` | `meum snapshot --json` with the same field names, or a mapping in the daemon |
| `cmux events --reconnect --name agent.hook.Stop/SessionStart/UserPromptSubmit` | session → transcript mapping, activity | meum's hook socket already receives these (the Claude-hooks spike); expose it as `meum events` |
| `cmux events --category sidebar` | when to re-read details | `meum events` (workspace changes) |
| `cmux sidebar-state --workspace ID` | status pills, progress, log lines | meum's own status per workspace (from hooks), or drop it |
| `cmux clear-progress --workspace ID` | cleaning up an old label | drop it |
| `cmux workspace-action --action pin/unpin/mark-read/mark-unread/move-top/move-up/move-down/close-others/clear-color/set-color/rename` | the row context menu | meum CLI or socket commands of the same names |
| `cmux close-workspace`, `cmux reorder-workspace --index` | menu, drag reorder | the same |
| `cmux browser open URL` | port and PR links "in cmux's browser" | not offered: always `open URL` |
| `defaults export com.cmuxterm.app` + `~/.config/cmux/cmux.json` "sidebar" | which detail rows to show | meum settings file, or Tamago's own settings |
| `CMUX_WORKSPACE_ID` in each `claude` process's environment (via `ps -E`) | session dots | `MEUM_TAB` / `MEUM_WORKSPACE` from meum, or better, counts pushed from meum's hook data |
| cmux-only socket admission and `ensure-running.sh` started from a cmux shell | daemon lifecycle | a meum socket with a token, and a launchd agent; the "denied" dance goes away |

The cleanest split is for the daemon to talk to a **host interface**: a module `host-cmux.mjs` (the
calls above) and `host-meum.mjs`, chosen by an environment variable. About 15 call sites go through the
existing `cmux(...)` helper and two `spawn(CMUX, ["events", …])` calls, so the seam already exists.

### Proposed package split

```
TamagoCore (SwiftPM library, no cmux import)
  SidebarModel, SidebarView, Pet, DaemonClient, species.json
  public protocol TamagoHost: AnyObject  (MainActor)
      var snapshot: TamagoSnapshot { get }            // selectedID + [Workspace(id,title,isPinned,gitBranch,unreadCount)]
      var snapshots: AsyncStream<TamagoSnapshot> { get }
      func select(_ id: UUID) async throws
      func perform(_ action: TamagoWorkspaceAction) async throws   // pin, rename, reorder, color, close, open-url …
      var bottomInset: CGFloat { get }                // 40 for cmux's fade, 0 for meum
  public func TamagoSidebar(host:) -> some View

TamagoCmux (the .appex):     CmuxSidebarExtension → adapts CmuxSidebarContext to TamagoHost; actions go
                             through the daemon as today (the extension is sandboxed)
TamagoMeum  (linked into meum): meum's workspace store → TamagoHost directly; select and workspace
                             actions are in-process calls, no daemon round-trip; the daemon keeps only
                             Tama (mood, memory, remarks, Claude calls)
```

In meum the view isn't sandboxed, so workspace actions don't need to go through the daemon. Only Tama's
own actions (feed, pet, poke, species, name, like, settings, update) keep using `POST /action`.

## Files

- `Shim/CmuxExtensionKit.swift`: the stand-in for cmux's SDK.
- `Host/MeumHost.swift`: the floating layout plus the adapters: the cmux feed, the action blocker, the
  local selection and the host the shim looks up by name.
- `build.sh`: builds everything.
- `vendor/tamago/`: Tamago's files, copied verbatim and checksummed in `vendor/PROVENANCE.txt`.
- `fixtures/`: a trimmed snapshot (ids and titles only) and a minimal state.
- `logs/run1.log`, `logs/run2.log`: the two runs.
- `shots/`: the screenshots.

Both runs ended cleanly, one by autoquit and one by the quit command; no process was left behind. Focus
went back to the app that was frontmost before the run.
