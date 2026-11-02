# meum

A lean, native macOS workspace manager for terminal agent sessions:
- workspaces in a sidebar;
- floating, tiled terminal cards with tabs, on libghostty;
- sessions that survive the app (zmx);
- Claude Code agent status from plain hooks;
- native widgets.

## Install

```sh
brew install --cask mcurses/meum/meum
```

This needs Apple Silicon and macOS 14 or later. The app is signed and notarized. Releases are on this repo's
[Releases](https://github.com/mcurses/meum/releases) page.

The cask also puts the `meum` CLI on your PATH. `meum help` lists what it can do: workspaces, tabs, status entries,
notifications, settings and widgets, all over meum's local control socket.

## What it does

- **Workspaces and cards:** each workspace has its own layout of cards, split horizontally or vertically. Every card
  holds tabs. Drag tabs between cards or onto a card's edge to split it. All shortcuts are configurable in Settings.
- **Sessions that survive:** every tab runs in a zmx session. Quit meum and reopen it, and your shells and agents are
  still there. After a reboot, Claude Code tabs resume their conversation.
- **Agent status:** `meum hooks install` adds small hooks to your Claude Code settings. The sidebar and tabs then show
  which agents are running, waiting for input or finished.
- **Widgets:** native plugins (MeumKit) live in cards under the sidebar or as tabs next to your terminals. Settings ▸
  Widgets installs them from a [catalog](https://github.com/mcurses/meum-widgets), for example the browser.
- **For agents:** `meum mcp` is an MCP server. With it, a Claude Code session in a meum tab can open widgets (such as
  a browser showing the page it just built), take screenshots of them, and set status entries. Install it with
  `claude mcp add --scope user meum -- meum mcp`.

## Build from source

You need Xcode's command line tools, Swift 6 and Zig.

```sh
scripts/setup.sh          # fetches and builds libghostty and zmx into vendor/ (zmx with the patches in scripts/patches/zmx)
scripts/build-app.sh      # builds build/meum.app
swift test                # tests for the model, control API and CLI
```

`scripts/run-test-app.sh` starts an isolated instance (its own state, widgets and zmx sessions), and `scripts/meumt`
drives it. The design notes are in `docs/design/`.

## Credits

meum embeds [Ghostty](https://github.com/ghostty-org/ghostty)'s terminal and uses
[zmx](https://github.com/neurosnap/zmx) for persistent sessions. Its libghostty bridge is adapted from
[agterm](https://github.com/umputun/agterm) and [macterm](https://github.com/thdxg/macterm). See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
