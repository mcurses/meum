# Project brief: a lean, native workspace manager for terminal agent sessions (now named meum)

This brief describes a personal project so it can be discussed with someone who knows nothing about it, with the
goal of finding a good name. It covers what the project is, why it exists, how it is built, what it deliberately
leaves out, and what a name has to fit.

## The one-line idea

A native macOS app that keeps your many terminal sessions, mostly AI coding agents such as Claude Code, organised
in workspaces. It does that one job well, and nothing else.

Its tagline could be "cmux without the bloat".

## Who it is for

The author runs many Claude Code sessions at once, across several projects and several Claude accounts. Each
project gets a workspace, and each workspace has a few terminals tiled side by side, with tabs. He wants to see at
a glance which workspace has sessions running and which has an agent waiting for him, without managing dozens of
loose terminal windows by hand.

The project is personal first. It may become open source later, so the name should work in public too.

## Why it exists

The author uses **cmux**, a native macOS terminal app built on Ghostty's terminal engine. It is good at exactly
what he needs:
- workspaces in a vertical sidebar
- a tiling layout with tabs inside each workspace
- dots showing running and unread agent sessions
- lower load for background workspaces
- automatic resume of all agent sessions after a restart

But cmux is turning into everything at once:
- an embedded, scriptable web browser
- computer-use automation
- cloud VMs as a paid tier, with a permanent "Upgrade" button
- agent-to-agent messaging and its own orchestrator agent
- code-review and diff views
- an iOS simulator, mobile companion features and telemetry

The app is 3.5× the size of Ghostty itself. It quietly wraps the `claude` command to inject its own hooks and
tools. Its codebase changes by about 300 commits a week. It is becoming a monolith with a business model attached.

The author wants to go back to the Unix philosophy: **do one thing, do it well**. Messaging between agents is
handled by a separate tool he already has. The terminal engine is Ghostty, keeping sessions alive is a small
session daemon, and agent status comes from plain hooks. This app only arranges and keeps the sessions.

## What it does (the whole feature list)

1. Workspaces in a fixed-width sidebar, one per project, reorderable, with names and colours.
2. Inside each workspace, terminals tiled like in a tiling window manager, with tabs.
3. Small dots per workspace: how many agent sessions run there, and whether one finished a turn (unread) or is
   waiting for input (a permission prompt).
4. Sessions survive the app: closing or crashing the app does not kill the shells or agents running in it. On
   relaunch everything reattaches with its scrollback. After a reboot, agent sessions resume by their session id.
5. Hidden workspaces cost almost nothing: their terminal views are dropped while the processes keep running.
6. A good look: see "Design concepts".
7. A small command-line tool and local socket so scripts can list, create, select and annotate workspaces.
8. A home for **Tamago**, the author's sidebar companion: a small animated ASCII pet (an egg by default, or one
   of 18 other species) that lives at the bottom of the sidebar. It watches all agent sessions and now and then
   makes a short, characterful remark about the work. It has moods, a diary and a long-term memory.

## What it deliberately does not do

- No browser, no cloud, no accounts, no upgrade prompts, no telemetry.
- No agent-to-agent messaging, orchestration or AI features of its own.
- No code review, diffs or project management.
- Not a terminal emulator of its own: it hosts Ghostty's engine.
- Not a git worktree manager.

## Design concepts

- **Floating cards.** The whole workspace is one invisible, screen-sized window. Inside it float rounded,
  shadowed "cards": a fixed-width sidebar card and several terminal cards, tiled with even gaps, as if a tiling
  window manager were arranging separate windows. Clicks in the gaps go through to whatever is behind. Re-tiling
  animates all cards together, smoothly.
- **Wallpaper glass.** Card backgrounds show the desktop wallpaper, blurred and darkened and aligned to the
  screen, the way X11 terminals faked transparency. It looks like frosted glass, but other windows never show
  through, so text stays readable. A wallpaper per workspace is a possible extension.
- **Calm and quiet.** Status is shown by small dots and subtle tints, not badges, banners or pop-ups.
- **A companion, not a dashboard.** Tamago gives the tool personality: a small creature keeping you company while
  your agents work.
- **Unix-style parts that can be swapped:**
  - Ghostty's engine draws the terminals.
  - A tiny session daemon (zmx) keeps them alive.
  - Agent hooks report status over a local socket.
  - The app is the thin layer that arranges it all.

## How it is built

| Part | Choice |
|---|---|
| Platform | macOS only, native Swift / AppKit / SwiftUI |
| Terminal engine | libghostty (from the Ghostty terminal) |
| Session persistence | zmx, a small MIT-licensed session daemon. Every tab is a zmx session, so processes outlive the app |
| Agent status | plain Claude Code hooks in each account's settings post events (session started, prompt sent, turn finished, needs input) to the app's local socket. No wrapper around the `claude` command |
| Layout | one transparent container window, cards as views, Core Animation for re-tiling |
| Sidebar | SwiftUI. Tamago's existing SwiftUI sidebar plugs in through a small host interface |
| CLI | a short command name, used often from the shell |

Spikes done so far all succeeded:
- a Ghostty terminal inside zmx survives the app being killed
- hooks work across all of the author's Claude accounts without a wrapper
- the floating card layout is native and robust

## Related tools and their names (the landscape the name lives in)

| Name | What it is |
|---|---|
| tmux, screen | classic terminal multiplexers |
| Zellij | a modern terminal multiplexer in Rust |
| cmux | the app this replaces: a native agent terminal on Ghostty, growing into a platform |
| Ghostty | the terminal engine it builds on |
| zmx | the session daemon it uses |
| Supacode | a native worktree-centric agent command centre on Ghostty |
| Warp, Wave, WezTerm, Kitty, iTerm2 | terminal emulators |
| Conductor, Superset, Claude Squad, Agent Deck | agent-orchestration apps and TUIs |
| AeroSpace, yabai | tiling window managers for macOS |
| Tamago | the companion pet that will live in the sidebar (Japanese for "egg") |

## Name requirements and wishes

- **Short CLI command**, ideally 3–6 letters and easy to type. It must not clash with common commands
  (`nest` is taken by the NestJS CLI, for example).
- **Free in public:** no well-known app, company or popular GitHub repo with the same name in the
  developer-tools space. A Homebrew formula and a domain should be available.
- **"mux" is out for public use.** Coder released an agent app called "mux" and later renamed its repository to
  "xum". The video-API company Mux uses the same name, which may be why. "mux" is also generic (tmux, cmux, dmux,
  rmux), so it is hard to search for.
- **Should suggest at least one of these:**
  - lean, light, minimal, calm, "one thing done well"
  - a place where things are kept, sorted or resting: workspaces, sessions, a home for a small creature
  - glass, floating or cards
- **Nice but optional:** a link to Tamago (egg, nest, roost, hatch, coop, shell …) or to terminals and Ghostty,
  without being a pun that ages badly.
- **Avoid:** names that sound like an AI or cloud platform, "agent"/"AI" in the name, and anything that implies
  orchestration. The tool deliberately doesn't orchestrate.

## Questions to explore

- Should the name lean on "lean multiplexer" (in the cmux/tmux family) or break away from the "-mux" pile
  entirely?
- Is a companion-flavoured name (around the egg, the nest, a home) better than a technical one?
- Could the app name and the CLI command differ, for example a friendly app name with a three-letter command?
