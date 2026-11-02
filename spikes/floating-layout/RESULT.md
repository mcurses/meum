# Floating layout spike: a floating sidebar and tiled floating terminals

2026-11-02, MacBook Pro 16" (one display, 1728×1117 pt, macOS 26 / Darwin 25.6), Swift 6.4.2.

## Verdict: native and robust, with one product caveat

Use **approach A**: one invisible container window holding a rounded, shadowed sidebar card and tiled
terminal cards. Everything it relies on is public, long-standing AppKit and Core Animation behaviour, and
none of it fights the window server:

- **Clicks in the gaps go to whatever is behind, natively.** This is the window server's own alpha hit
  test on a non-opaque window; no event tap and no `ignoresMouseEvents` toggling is needed (verified below).
- **The layout is atomic.** All cards move in one Core Animation transaction inside one window, so cards
  can never drift apart, tear against each other or lag behind the wallpaper glass.
- **The app is a single window to macOS.** Mission Control, Spaces, Cmd-Tab, Stage Manager and
  window-to-front all treat the workspace as one unit, which is what Max wants.

Approach B (one borderless window per card) also works. Grouped as child windows of the sidebar, it
behaves almost the same as A, but it has more moving parts and nothing to gain for this design.

**The caveat is a product one, not a fragility.** The workspace is a screen-sized layer, not a window
you drag around. A click in a gap activates the app behind, and that app's window then covers the whole
workspace until you click a card again or Cmd-Tab back. That is how any floating-window desktop behaves.
If it annoys, the gaps can be made to catch clicks (see the gotchas list; not tested).

An external tiling window manager (the AeroSpace / yabai route) is the hacky one. See the last section.

## What was built

`Sources/main.swift` is one binary with two window structures behind a shared layout engine and a
shared animation driver, so the comparison is about window structure only.

- **Layout:** a fixed 240 pt sidebar, 12 pt gaps, and N terminal cards, either master + stack or
  columns. `n` adds a card, `w` removes the focused one, `Tab` moves focus, `l` toggles the layout,
  `m` cycles the material, `q` quits.
- **Animation:** a display-link tween (0.22 s ease-out; `--duration` to slow it down). It sets every
  card frame per tick, in one transaction for A and via `setFrame` per window for B.
- **Materials:**
  - `glass`: the wallpaper-glass look, a minimal port of `~/code/wallpaper-glass`. The wallpaper is
    anchored to screen coordinates, blurred 4, tint 0.35, and opaque, so nothing behind shows through.
  - `vibrancy`: `NSVisualEffectView`, `.hudWindow`, blending behind the window.
  - `liquid`: macOS 26 `NSGlassEffectView`.
  - `solid`: a 94% opaque dark fill.
- **Mode A:** a borderless `NSWindow` with `isOpaque = false`, a clear background and no window
  shadow, covering `visibleFrame`. Each card is a host view carrying an `NSShadow`, with a rounded,
  clipping content view inside it.
- **Mode B:** one borderless, clear `NSWindow` per card with `hasShadow = true`; the window server
  draws the shadow from the rounded alpha shape. `--group child` makes the terminal cards child windows
  of the sidebar window; `--group none` leaves them independent.
- **`probe.swift`:** synthesises clicks and keys with `CGEvent`, reads the frontmost app, the
  CGWindowList z-order and window bounds, and sends commands to the spike through a distributed
  notification.
- **`test.sh`:** one scripted run of about 10 s. It opens a "backdrop" window from a second process
  behind the spike, then screenshots, clicks in two gaps and on a card, presses Tab and Cmd-`, adds a
  card while sampling window bounds, and cleans up: it kills only its own two pids and hands focus back.
- **`analyze_sample.py`:** checks whether separately moved windows stayed in step.

### Run

```sh
cd ~/code/meum/spikes/floating-layout
./build.sh
build/FloatingLayout.app/Contents/MacOS/FloatingLayout --mode A --material glass           # approach A
build/FloatingLayout.app/Contents/MacOS/FloatingLayout --mode B --group child --material liquid
./test.sh A-glass 100,100,1500,900 -- --mode A --material glass                           # scripted test
```

Each instance quits by itself after 90 s (`--autoquit`).

## Results

### Verified by test

| Question | A: one container | B: window per card (child group) | B: independent windows |
|---|---|---|---|
| Click in a gap reaches the window behind | **yes**: the backdrop process logged `mouseDown` at both gap points and became frontmost | yes (no window there at all) | yes |
| Click on a card stays in the app | yes (`mouseDown` card 2) | yes, and that card's window becomes key | yes |
| After a gap click | the other app's window is raised above the whole workspace | same, the whole group goes behind | same |
| Clicking a card when another app is on top | the whole workspace comes forward | the whole group comes forward (child windows follow the parent) | **only that card comes forward; the other app stays wedged between cards** (`shots/B-interleave-none.png`) |
| Focus between cards | internal focus in one key window (Tab worked) | a real key-window change per card (Tab worked, `windowDidBecomeKey`) | same as child |
| Cmd-` | nothing (one window) | nothing: borderless card windows are not cycled, and there is no Window menu | nothing |
| Window count in CGWindowList | 1 (1728×1084) | N+1 | N+1 |
| Mission Control | one window thumbnail showing the whole layout (`shots/A-mission-control.png`) | one group with the layout intact (`shots/B-mission-control.png`) | **cards scattered as unrelated windows** (`shots/B-none-mission-control.png`) |
| Rounded corners and shadows | yes. The shadow darkens the gap from (210,96,74) to (133,61,47) across its full 12 pt | yes, the window-server shadow, lighter and fixed in style | yes |
| Gaps show the real desktop or window behind | yes (`shots/A-glass-2.png`) | yes (`shots/B-glass.png`) | yes |
| Wallpaper glass stays aligned across cards, also mid-animation | yes (`shots/A-midanim.png`: dune lines continue across overlapping cards) | yes (`shots/B-midanim.png`) | n/a |
| Relayout animation | 2 s run: 121 frames, longest frame gap 16.7 ms, mean app-side cost 1.7 ms per tick | 2 s run: 121 frames, longest gap 20.4 ms, mean 0.27 ms app-side (the work moves to the window server) | n/a |
| Separate windows stay in step while animating | atomic by construction | sampled CGWindowList during an add: the stacked cards' gap stayed within 1–2 pt of the intended 11–12 pt in all 13 states seen. Close, but not guaranteed | n/a |
| Vibrancy and Liquid Glass inside a single transparent window | both render correctly per card, clipped to the rounded corners (`shots/A-vibrancy.png`, `shots/A-liquid-zoom.png`) | `shots/B-liquid-zoom.png` | n/a |
| `ignoresMouseEvents` fallback (120 Hz mouse poll) | works too (4 toggles, gap clicks passed, card clicks kept), but **not needed** | n/a | n/a |

Event posting and screen capture were both permitted in this shell (`AXIsProcessTrusted` true), so all
click results above come from real synthesised clicks, not from reasoning.

### Reasoned, not tested

- **Spaces:** one container window moves between Spaces as a unit. Child windows move with their
  parent. Independent windows each pick their own Space.
- **Stage Manager** (off on this Mac, so not toggled): A is one window, so one stage tile. B with child
  windows should stay one group. Independent windows would become separate stage entries.
- **Cmd-Tab:** app-level in all variants. With independent windows it brings all cards forward, but a
  later click on another app's window can again interleave.
- **Native full screen:** not a fit for a borderless container. A already fills `visibleFrame`. For a
  "no menu bar" mode, use `NSApplication.presentationOptions` (auto-hide the menu bar and Dock) and
  re-layout to `screen.frame`, or opt into a full-screen Space through `collectionBehavior` (untested
  for borderless windows).
- **Multiple displays:** a window effectively lives on one display, so A needs one container per
  display, each with its own sidebar or none. B could place cards on any display, but child windows on
  a different display from their parent are an edge case AppKit handles poorly. With "Displays have
  separate Spaces" on, a container cannot span displays at all.
- **Screen changes:** A must re-fit the container on `NSApplication.didChangeScreenParametersNotification`
  (Dock show/hide, resolution change, display plug). This is trivial but required.
- **A real libghostty surface** (Metal-backed; Ghostty's own view uses an `IOSurfaceLayer`/`CAMetalLayer`)
  instead of the placeholder text:
  - **Corner clipping:** a parent layer with `cornerRadius` and `masksToBounds` clips a Metal layer
    fine. Core Animation composites it. The transparent window means no direct-to-display scanout,
    but that is already the case for any non-opaque window.
  - **Background:** set Ghostty's background opacity below 1 so the card glass shows through. The
    wallpaper-glass layer sits under the surface, as in the wallpaper-glass README.
  - **Do not resize the PTY on every animation frame.** Each size change reflows the grid and sends
    SIGWINCH, so TUIs like Claude Code would redraw dozens of times per relayout. Animate the frame,
    let the surface stretch or keep its old size until the end, then send one resize. This applies to
    A and B alike.
  - **Shadows:** in A they are layer shadows, cheap with a `shadowPath`, as here. In B they are free
    window-server shadows.
  - **Performance:** many Metal layers in one window is the normal Ghostty-split case. In B every
    terminal is its own window and backing store, which costs a little more window-server memory and
    gives no benefit.

## Recommendation: A, and why not B

- **One transaction, one window.** Layout, focus, the wallpaper glass and animation are all ordinary
  view code. B's per-window `setFrame` stays in step in practice, but it is not atomic: under load, or
  with a Metal surface that renders late, cards could briefly mismatch.
- **Same desktop behaviour without the grouping work.** B only matches A once the cards are child
  windows. Child windows have long-standing quirks: ordering edge cases, multi-display moves, and
  Mission Control and full-screen interactions that differ between releases.
- **Simpler keyboard model.** Focus is a first-responder change instead of key-window juggling, and
  there are no stray Cmd-` or "window menu" semantics to suppress.
- **B's only real advantage** is that other apps' windows could sit between cards, letting a browser
  be "one of the tiles". Max did not ask for that, and macOS cannot tile a foreign window into your
  layout without the Accessibility route below.

## The third route: an external tiling WM (AeroSpace / yabai style)

This means separate apps (for example plain Ghostty windows), arranged by a tool that moves them with
the Accessibility API (`AXUIElementSetAttributeValue` for position and size).

- **Moves are asynchronous and per window.** Each app applies them when it gets to it, so there are no
  atomic or smooth animated relayouts. AeroSpace does no animation. yabai's animations and window
  shadows or opacity need its scripting addition, which requires partly **disabling SIP**.
- **No control over the window's look.** The rounded floating card is whatever the app draws; Ghostty
  can drop its title bar, but corner radius and shadow are the system's.
- **The wallpaper glass would swim.** It is anchored to the screen, and an external mover produces
  exactly the lagging move notifications the wallpaper-glass README measured (about 10 Hz).
- **Spaces need tricks.** AeroSpace emulates workspaces by parking windows off-screen. yabai relies on
  private APIs. macOS updates break these tools regularly.
- **The sidebar would be another app**, with no shared focus model, dots or keyboard layer.

Verdict for this route: workable for plain tiling, but the most fragile of the three for the floating
look Max wants. Owning the windows (A) avoids every one of these problems.

## Known macOS gotchas (found or confirmed here)

1. **Borderless windows can't become key unless you override `canBecomeKey`/`canBecomeMain`.** Without
   that, no keyboard input reaches them.
2. **AppKit resets a layer-backed view's layer shadow from `NSView.shadow`.** Setting
   `layer.shadowOpacity` directly showed nothing. Use `NSShadow`, plus a `shadowPath` for performance.
3. **Click-through depends on the pixel alpha.** It works because the container's background is fully
   clear. A 1% fill anywhere (for example a backdrop layer) makes that area catch clicks; that is also
   the switch for "gaps catch clicks" if wanted (untested).
4. **The default display link ran at 60 Hz** (121 ticks in 2 s) on this 120 Hz ProMotion panel. For
   120 Hz animation, set `preferredFrameRateRange`.
5. **For window-server shadows, call `invalidateShadow()` after a borderless window's shape or size
   changes** (mode B).
6. **Translucent cards leak what's behind.** At 94% opacity, the text of the window behind was readable through
   a card (`shots/B-interleave-none.png`). For terminals, prefer the opaque wallpaper glass, or
   vibrancy and Liquid Glass, which blur.
7. **Dynamic (HEIC) and video wallpapers aren't covered by `desktopImageURL`.** This is carried over
   from the wallpaper-glass findings.
8. **A CLI process doesn't see `NSWorkspace.frontmostApplication` change without a run loop.** This
   only affects the probe, which spins its run loop.
9. **Cmd-` does nothing for borderless windows without a Window menu.** In A, you get to define your
   own focus keys freely.

## Files

- **Code:** `Sources/main.swift`, `probe.swift`, `build.sh`, `test.sh`, `analyze_sample.py`.
- **Logs:** `logs/*.log` (spike events as JSON lines), `logs/*-probe.txt`, `logs/*-sample.jsonl`.
- **Screenshots** (`shots/`):
  - `A-glass-1.png`, `A-glass-2.png` (after an animated add), `A-gap-zoom.png`
  - `A-vibrancy.png`, `A-liquid.png`, `A-liquid-zoom.png`, `A-vibrancy-zoom.png`
  - `B-child-1.png`, `B-child-2.png`, `B-glass.png`, `B-glass-zoom.png`, `B-liquid.png`, `B-liquid-zoom.png`
  - `B-interleave-none.png`
  - `A-midanim.png`, `B-midanim.png`
  - `A-mission-control.png`, `B-mission-control.png`, `B-none-mission-control.png`

  The full-screen shots and the Mission Control shots include other windows, so they are not in the repo.
