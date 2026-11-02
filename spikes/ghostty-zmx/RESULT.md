# Spike: libghostty surface + `zmx attach`, survives an app kill

Date: 2026-11-02. Machine: macOS 26.6, Xcode 27.2 (Swift 6.4), Apple Silicon.
Question (from `docs/research/2026-11-02-cmux-fork-or-replace.md`, section 3D): can a minimal native macOS app
host a GhosttyKit terminal surface whose command is `zmx attach <name>`, so that after the app is killed and
relaunched the terminal comes back with screen and scrollback intact?

## Verdict: works, with caveats

A 330-line AppKit app embedding GhosttyKit (Ghostty v1.4.0) with `zmx attach spike-1` as the surface command
reattached cleanly after a `kill -9` of the app. The screen, all 300 scrollback lines, the marker line and a
full-screen vim all came back, and a counter loop inside the session kept counting while no app was attached.
The caveats are about packaging and polish, not feasibility (see Risks).

## What was verified (observed, not assumed)

| Check | Result | Evidence |
|---|---|---|
| zmx builds; `run`, `list`, `history`, `kill`, `attach` behave as documented | yes | commands below; `zmx history spike-1` printed the marker and all 300 lines before any GUI attached |
| GhosttyKit xcframework builds from the v1.4.0 tag | yes, after installing Xcode's Metal Toolchain | `ghostty-build-1-failed-no-metal-toolchain.log`, then a clean build |
| App renders the zmx session on first attach | yes | `shot-1-first-attach.png` |
| App killed with SIGKILL by its captured pid: session survives | yes: `zmx list` showed `clients=0`; the zmx daemon (pid 61324), its shell and the counter script were still running | counter file went 30 → 40 during 10 s with no app |
| Relaunch reattaches with screen intact | yes; counter read 52 on reattach (it had been 30 at kill time) | `shot-2-after-kill-relaunch.png` |
| Scrollback intact after reattach | yes: Ghostty's `read_text` over the whole screen returned 305 lines incl. `=== SPIKE-MARKER-7f3a ===` and lines 001–300; `scroll_to_top` shows them on screen | `out/run2.screen.txt`, `shot-3-reattach-scroll-to-top.png` |
| Keyboard input, real OS key events (System Events keystrokes, incl. Ctrl-C, Return, Esc) | yes: Ctrl-C stopped the loop, `echo REAL-KEYS-OK $((6*7)) \| tr a-z A-Z` printed `REAL-KEYS-OK 42` | `shot-4-keyboard.png` |
| Keyboard input via synthesized NSEvents through the view's `keyDown` | yes (`synth-keys-ok`) | `shot-4-keyboard.png` |
| Full-screen TUI (vim, alternate screen, colors, cursor position) survives kill + relaunch | yes; only vim's last command-line message (`/counter`) was not redrawn | `shot-6-vim-before-kill.png` vs `shot-7-vim-after-relaunch.png` |
| Window resize propagates through zmx to the inner program | yes: the session started at 24 rows, vim filled the 119x36 grid | `shot-6` |
| Drop the surface while the app keeps running, then recreate it (the "hidden workspace drops its surface" pattern) | yes: on drop zmx shows `clients=0` and the session keeps running; a new surface reattaches with full content | `out/app.log`, `out/restored.*.txt` |
| Fresh session created by the app itself (`zmx attach spike-2` on a name that does not exist yet) | yes: TERM=xterm-ghostty, truecolor, 256 colors, bold/red/✓/emoji render | `shot-8-fresh-session-term.png` |
| Graceful app quit leaves the session alive | yes | `zmx list` after `quit` |

Not verified: IME / dead keys / non-US layouts (the spike uses a simplified `keyDown`), mouse selection and
copy/paste, more than one surface per window, behaviour across a reboot (zmx sessions die with the machine; that is the
`claude --resume` path in the design), long-running memory with many sessions, a signed `.app` bundle.

## Timings

| Step | Time |
|---|---|
| `brew install zig` (0.17.0) | 1 min 43 s |
| zmx `zig build -Doptimize=ReleaseSafe` (cold, includes fetching its Ghostty dependency) | 1 min 51 s |
| GhosttyKit build, first attempt | 1 min 35 s, failed at the Metal shader step |
| `xcodebuild -downloadComponent MetalToolchain` (839 MB) | 1 min 36 s |
| GhosttyKit build, second attempt (warm cache) | 84 s |
| Spike app build (`swiftc`, links the 143 MB static lib) | 2.3 s |
| `ghostty_init` + config + `ghostty_app_new` | 1–2.5 ms |
| `ghostty_surface_new` + size (synchronous part) | 1.5–2.9 ms |
| From `surface_new` to restored text present in the viewport (zmx attach handshake + replay) | 108–114 ms (3 runs) |
| `ghostty_surface_free` (stops renderer + IO threads, the zmx client exits) | 13–15 ms |
| Full recreate (free + new) | 16–19 ms synchronous, plus ~110 ms until content |
| App RSS with one surface | ~100 MB |
| Whole spike, wall clock | about 14 min of build/run time, measured with `date` |

Consequence for meum: dropping hidden workspaces' surfaces is cheap. Switching to a workspace costs about 0.1 s per
surface before its text appears, so a workspace with several splits should create all its surfaces in parallel (they
are independent) and may want a placeholder or a cached snapshot for that 0.1 s.

## Exact commands

All paths are under `/Users/dev/code/meum/spikes/ghostty-zmx`. `vendor/` and `build/` are gitignored.

```sh
brew install zig                                   # 0.17.0; both zmx and Ghostty v1.4.0 require minimum_zig_version 0.17.0

# zmx (MIT, Eric Bower; github.com/neurosnap/zmx, commit d6dc347, version 0.8.1)
git clone --depth 50 https://github.com/neurosnap/zmx.git vendor/zmx
(cd vendor/zmx && zig build -Doptimize=ReleaseSafe)  # -> vendor/zmx/zig-out/bin/zmx

# GhosttyKit (Ghostty v1.4.0 = 83fb95624b0439ee660c2679b43b38c8b63769cd)
git clone --depth 1 --branch v1.4.0 https://github.com/ghostty-org/ghostty.git vendor/ghostty
xcodebuild -downloadComponent MetalToolchain       # once per machine; Xcode 27 does not ship `metal` by default
(cd vendor/ghostty && zig build -Demit-macos-app=false -Demit-xcframework=true \
    -Dxcframework-target=native -Doptimize=ReleaseFast)
# -> vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64/{libghostty-internal.a, Headers/ghostty.h, Headers/module.modulemap}

./build-app.sh                                     # swiftc app/main.swift + the static lib -> build/GhosttyZmxSpike
swiftc -O winid.swift -o build/winid               # CGWindowList helper: build/winid <pid> -> window ids
```

`-Dxcframework-target=native` builds arm64 macOS only (Ghostty's default is universal incl. iOS). The flags are those
Ghostty's `macos/AGENTS.md` prescribes for building the library its own Xcode project consumes. No Xcode project
was needed: `build-app.sh` is one `swiftc` call with `-I Headers` (the modulemap exposes `import GhosttyKit`), the `.a`,
`-lc++` and the frameworks AppKit, Metal, QuartzCore, CoreText, CoreGraphics, IOSurface, Carbon, CoreVideo,
UniformTypeIdentifiers and GameController. It linked on the first try.

Run sequence used for the evidence:

```sh
. ./env.sh       # ZMX_DIR=vendor/zmxdir (isolated socket dir), ZMX=..., SPIKE_OUT=out
SHELL=/bin/bash TERM=xterm-256color $ZMX run spike-1 -d $SPIKE_DIR/session-setup.sh $SPIKE_OUT
                 # marker line, 300 numbered lines, then a counter that rewrites one line every second
                 # and writes out/counter.txt
PID=$(./launch.sh)                                # SPIKE_CMD="$ZMX attach spike-1"; prints the app pid
build/winid $PID                                  # window id
echo "dump run1" > out/cmd                        # app's control file: dump | action <name> | type <text> | enter
                                                  # | recreate | drop | restore | quit
screencapture -x -o -l <winid> shot-1-first-attach.png
kill -9 $PID; $ZMX list; cat out/counter.txt      # session alive, counter advancing
PID=$(./launch.sh); ...                           # relaunch, screenshot, dump, scroll_to_top
$ZMX kill spike-1 spike-2                         # cleanup (done)
```

Real keystrokes came from `osascript` / System Events after raising the app by its pid.

## libghostty C API used

- App and config: `ghostty_init`, `ghostty_config_new`, `ghostty_config_load_file` (optional, env `SPIKE_CONFIG`;
  no default config files are loaded, so Max's `~/.config/ghostty` is not read), `ghostty_config_finalize`,
  `ghostty_config_diagnostics_count`, `ghostty_config_get_diagnostic`, `ghostty_app_new`, `ghostty_app_tick`,
  `ghostty_app_set_focus`.
- Runtime callbacks in `ghostty_runtime_config_s`: `wakeup_cb` (dispatch `ghostty_app_tick` to main), `action_cb`
  (returns false for nearly everything; logs set_title / child_exited), clipboard read/confirm/write stubs,
  `close_surface_cb`.
- Surface: `ghostty_surface_config_new`, `ghostty_surface_new` (platform MACOS, `nsview` = our NSView, `command`,
  `scale_factor`, `font_size`, context WINDOW), `ghostty_surface_free`, `ghostty_surface_set_content_scale`,
  `ghostty_surface_set_size`, `ghostty_surface_size`, `ghostty_surface_set_focus`, `ghostty_surface_key`,
  `ghostty_surface_mouse_scroll` (wired, not exercised), `ghostty_surface_read_text` + `ghostty_surface_free_text`
  (SCREEN = incl. scrollback, VIEWPORT = visible), `ghostty_surface_binding_action` (`scroll_to_top`,
  `scroll_to_bottom`).

About 20 functions. Ghostty attaches its own Metal layer to the NSView you pass, so the host does no drawing.

## Risks and rough edges found

1. **Metal Toolchain.** Building GhosttyKit on Xcode 27 needs `xcodebuild -downloadComponent MetalToolchain`
   (839 MB, into `/System/Library/AssetsV2`). Without it the build fails at the shader step with a clear message.
   It is a one-time step per machine, but it belongs in the meum build docs and CI.
2. **Bundle Ghostty's resources.** A bare binary does not find Ghostty's resources dir, so Ghostty did not set
   `TERMINFO`. The spike app inherited `TERMINFO=/Applications/cmux.app/Contents/Resources/terminfo` from the cmux
   terminal this session runs in, which is why `xterm-ghostty` resolved. A meum `.app` launched from Finder must ship
   `share/terminfo` (and shell-integration) in `Contents/Resources` the way Ghostty.app does, or fall back to
   `TERM=xterm-256color`. When launched from cmux it should also scrub inherited `CMUX_*`/`TERMINFO` variables.
3. **Who creates the session sets its TERM and size.** A session created by `zmx run` without a tty started at 24
   rows with the caller's TERM. meum should create sessions with `zmx attach` from the surface itself (verified with
   spike-2) so they get `TERM=xterm-ghostty` and the real size.
4. **A dropped surface leaves its last frame on the view.** After `ghostty_surface_free` the layer keeps showing the
   stale image (`shot-5-dropped-surface.png`). When hiding a workspace, remove or hide the view as well.
5. **Keyboard handling is simplified.** The spike's `keyDown` (~40 lines) handles text, control and function keys,
   but not IME, dead keys or the `NSTextInputClient` protocol. For production, copy Ghostty's own
   `SurfaceView_AppKit.swift` input code (several hundred lines; MIT) rather than reinventing it.
6. **Two libghostty versions.** zmx 0.8.1 pins Ghostty `1.3.2-dev` (22f100c) for its VT state, while the app uses
   v1.4.0. Restore works because zmx replays plain VT sequences. Edge cases such as kitty graphics or newer OSC
   features may differ; pin both on purpose.
7. **API instability.** `ghostty.h` is still marked unstable. The calls above are the same ones Ghostty's macOS app
   uses, so a pinned tag plus a small wrapper layer contains the churn.
8. **zmx quirks seen.** `zmx run <name> '<a single quoted string>'` passes the string as one word (command not
   found); pass words separately or run a script. `run` appends `; echo ZMX_TASK_COMPLETED:<id>:$?`, which stays
   visible in scrollback. The first `zmx run` sessions started bash although `SHELL=/bin/zsh` was set, while
   `attach` started zsh; the cause was not investigated. zmx puts its sockets in `$TMPDIR/zmx-<uid>` unless
   `ZMX_DIR` is set (the spike used `vendor/zmxdir`). meum needs to decide whether to share the user's zmx namespace.
9. **vim message line.** After reattach vim's bottom command-line message was blank; the rest of the alternate
   screen was exact. This is cosmetic.

## zmx license and maturity

MIT (Copyright (c) 2025 Eric Bower), `vendor/zmx/LICENSE`. Version 0.8.1, last commit 2026-11-01, Zig 0.17. It
has `list` with labels and pids, `history` (plain, `--vt`, `--html`), `run -d`, `send`, `wait`, `tail` and
`kill`. That covers what meum needs for programmatic session management.

## Files

- `app/main.swift`: the host app (one window, one surface, control-file hooks for dump, recreate, drop/restore,
  binding actions and synthetic keys; logs timings to `out/app.log`).
- `build-app.sh`, `launch.sh`, `env.sh`, `session-setup.sh`, `winid.swift`: build and run helpers.
- `shot-1` … `shot-8` PNGs: screenshots referenced above.
- `out/`: `app.log` with timings, text dumps (`run1/run2/keys*/restored/s2 .viewport.txt/.screen.txt`), pids.
- `zmx-build.log`, `ghostty-build-1-failed-no-metal-toolchain.log`, `ghostty-build-2-ok.log` (empty = success).
- `vendor/` (gitignored): zmx and Ghostty checkouts, the built xcframework, and the zmx socket dir.

Side effects outside the spike dir: Homebrew `zig` 0.17.0 installed; Xcode Metal Toolchain component downloaded;
the Zig global cache `~/.cache/zig` grew to about 221 MB. The test app was closed and both test zmx sessions were killed.
