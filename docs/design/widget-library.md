# Plan: a widget library that friends install from

Status (2026-11-02): steps 1 to 3 are built and tested in an isolated instance against a local catalog. Helpers (step 4,
meum side) are built by the second meum session. The public catalog repo `mcurses/meum-widgets` exists; Browser 1.0
is its first widget.
See "As built" at the end.
library, clicks Install, and the browser or Tamago is installed."

## Where we stand

What already works (see `sidebar-widgets-extensibility.md`, "As built"):

- Widgets load at runtime. A widget is a folder `<name>.meumwidget/` in `~/.local/share/meum/widgets/`, holding
  `manifest.json` and a dylib that links MeumKit. A fresh meum has an empty folder, so it starts without widgets.
- `meum widget reload` loads a newly copied widget without restarting. Settings ▸ Widgets enables, disables and
  orders widgets.
- MeumKit is built with library evolution, so a widget built against an older MeumKit keeps loading.
- Three scopes: `global` and `workspace` (cards under the sidebar) and `tile` (widget tabs only, e.g. the browser).

What's missing: a catalog, an install path, trust, widgets with a background program, and universal builds.

## 1. Catalog

- One JSON file, `catalog.json`, in a public GitHub repo (e.g. `mcurses/meum-widgets`). meum reads it from a
  fixed URL, which the settings can override.
- Per widget:
  - id, display name, one-line description, author, icon URL;
  - scope, and whether it has a collapsed sidebar look (see "Collapsed sidebar" below);
  - newest version, minimum meum version (`minMeum`: release-widget.sh writes `widgets/MINIMUM_MEUM`, the
    release whose MeumKit last grew; meum 0.5 and later don't offer a widget to an older meum, older ones ignore the
    field), minimum MeumKit API (`meum.v1`);
  - archs, download URL (zip) and sha256;
  - the signing Team ID it must carry.
- Each widget is released as a zip of its `.meumwidget/` folder, for example as a GitHub release asset of the widget's
  own repo, or of the `widgets/` folder in this repo for first-party widgets (browser).

## 2. Install, update and uninstall in meum

- **Settings ▸ Widgets gets a "Library" part:**
  - it lists the catalog next to what is installed;
  - per widget it shows Install, Update or Remove;
  - it shows the version and what the widget uses (`uses` from the manifest).
- **Install:** download the zip to a temporary folder, check the sha256, unpack it into
  `<widgets>/<id>.meumwidget.incoming`, swap it into place, record the dylib's hash (see 3), then `widget reload`.
  A failed step leaves the old install untouched.
- **Update:** the same path. meum checks the catalog at launch and once a day, and shows a dot in Settings when an
  update exists. No silent auto-update in the first version.
- **A data folder per widget:** MeumKit gets `host.dataDirectory`, `~/.local/state/meum/widgets/<id>/`, created
  on first use. Per-tile state goes there under the tab id from `placement`. That makes "remove with data"
  well-defined.
- **Remove:**
  - first close the widget's tabs and cards (the existing `willUnload`) and stop its helper (see 4);
  - then delete the folder.
  - The data folder stays unless the user ticks "also delete data".
- **API and CLI, same calls as the UI:**
  - `widget.catalog`, `widget.install`, `widget.update`, `widget.remove`;
  - `meum widget install <id>`, and the same for update and remove.
  - Install, update and remove return the same JSON as `widget.list`, as reload and enable already do, so the
    CLI prints one view.
  An agent can then install a widget for the user.

## 3. Trust and signing

A widget is native code that runs inside meum with the user's full rights. Installing one is installing an app.

- **A widget loads if one of these holds:**
  - **Pinned hash.** It was installed from a trusted catalog (Max's, over https), and its dylib still matches the
    sha256 recorded at install. This works with widgets signed by Max's local certificate (no Team ID), so friends
    can use widgets before there is a paid account.
  - **Team ID.** Its signature is valid and carries a Team ID on the allow list: Max's team, more can be added in
    Settings.
  - **Developer mode.** It's a local build, and a "developer mode" switch is on. That is what local builds use
    today; `scripts/build-widget.sh` signs with the local certificate.
- **Where the check runs:** WidgetManager doesn't dlopen the installed file. It copies the dylib to a fresh path
  first (`$TMPDIR/meum-widgets/<pid>-<n>-<lib>.dylib`), so a rebuild reloads. The check runs on that copy, in a
  private 0700 folder, right before dlopen, so the file can't change between the check and the load.
- **MeumKit:** a widget that bundles its own libMeumKit is rejected. `@rpath/libMeumKit.dylib` must resolve to
  meum's copy in `Contents/Frameworks`, or the types don't match.
- **meum for friends needs a Developer ID and notarization** (the paid Apple Developer account), for Gatekeeper.
  - Notarization requires the hardened runtime.
  - The hardened runtime's library validation only loads libraries signed by meum's own team, so meum needs the
    entitlement `com.apple.security.cs.disable-library-validation`. The checks above replace it.
- Downloads made by meum carry no quarantine flag. The checks above are what protects the user, not Gatekeeper.
- **Who can change trust.** Developer mode, the trusted teams and the library address are set only in
  Settings ▸ Widgets, and so is Allow for a single widget. Over the control socket (and so the CLI and the MCP
  server) these settings are read-only and `widget.allow` answers `forbidden`, because every program in every tab
  reaches the socket: a Claude Code session that read a hostile page, a script it runs, a package's install script.
- **What that does not stop:** a program that writes meum's files directly (`settings.json`, the pins file, the
  widgets folder). It already runs as the user, with the user's rights; no check inside meum can tell it from the
  user. The trust checks guard against a tampered catalog or download and against requests over the socket, not
  against code already running as you.

## 4. Widgets with a background program (Tamago)

Tamago is a widget plus a Node daemon, installed today by its own `install.sh`, written for cmux.

- **New manifest field:** `"helper": {"command": "bin/tamago-daemon", "args": [...]}`. The command is a path inside
  the widget folder; an absolute path or one with `..` is refused, at install and when meum scans the folder.
- **It runs from a private copy:** meum copies the helper into `~/.local/state/meum/helpers/bin/` (0700), checks the
  copy (pin or team signature) and starts the copy, also on every restart. Replacing the file in the widget folder
  takes effect only after the next check (a reload), never in between.
- **One helper per installed widget**, not per instance (a widget can have a sidebar card plus several tiles).
- **Starting:**
  - meum starts the helper at launch if the widget is enabled, not when the first instance loads. Tamago's
    daemon follows agents even while nothing shows it.
  - `widget reload` doesn't restart it unless the helper's file changed.
  - It restarts the helper with backoff when it dies.
- **Stopping:** on disable or remove, meum stops only the process group it started.
- **Environment and log:** the helper gets `MEUM_SOCKET`, `MEUM_WIDGET_DATA` (the data folder from 2) and
  `MEUM_WIDGET_DIR` (its widget folder, for files next to it). It logs to
  `~/.local/state/meum/helpers/<id>.log`.
- This replaces Tamago's shell-hook start and its cmux socket workaround.
- **Node:** either the helper bundles a Node runtime (about 40 MB) or Tamago's daemon gets ported to Swift. That is
  the Tamago session's choice; the helper field works either way.
- **Owners:** meum provides the helper supervision. The Tamago session ships a `.meumwidget` zip that contains its
  helper.

## 5. Builds for friends' Macs

- **Universal builds (arm64 + x86_64)** of meum, libMeumKit and every widget. Without that, Intel Macs can't run
  them.
  - meum's own dependencies must be universal too: GhosttyKit from `vendor/` and the bundled zmx. Both are built
    for arm64 only today.
  - Check `vendor/` before promising Intel at all.
  - The catalog's `archs` lets meum hide widgets that can't run.
- **Release script for meum: built 2026-11-02, `scripts/release.sh <version>`.**
  - It signs every executable with the Developer ID, the hardened runtime and a timestamp.
  - `scripts/entitlements.plist` turns off library validation, so widgets load.
  - It notarizes and staples the app, builds a DMG with an Applications link, then signs, notarizes and staples
    the DMG.
  - Notarization uses the keychain profile `meum` (App Store Connect API key).
  - Verified: 0.2.0 was accepted by Apple. A copy marked as downloaded passes Gatekeeper ("Notarized
    Developer ID"). Under the hardened runtime the shell, zmx and both test widgets (Hello, Tamago) run.
  - It builds arm64 only, so Intel waits for universal GhosttyKit and zmx.
- **A release script for widgets:** build universal, sign, zip, and print the sha256 for the catalog.

## Collapsed sidebar (built 2026-11-02)

The sidebar collapses to a 60 pt rail (⌃⌘S). Workspaces show icons their agent can set, and a sidebar widget draws
its own collapsed look. A sidebar widget declares that itself (`supportsCollapsedSidebar` in MeumKit), not through
the catalog, because local and older widgets have no catalog entry. One without it is hidden in the rail. See
`sidebar-widgets-extensibility.md`, "As built: the collapsed sidebar".

## Order and size

| Step | What | Size |
|---|---|---|
| 1 | Catalog format, `catalog.json` repo, widget release script (zip + sha256) | small |
| 2 | Library section in Settings, install, update and remove, API and CLI | the main piece; the minimum version is a few hours |
| 3 | Pinned-hash, Team ID and developer-mode checks on the loaded copy; the library-validation entitlement | small; hashes work without the paid account |
| 4 | Helper supervision in meum; Tamago ships a `.meumwidget` with its helper | medium; the Tamago session owns the Tamago side |
| 5 | Universal builds and meum's release script (Developer ID, notarization, DMG) | small to medium; needs the paid account |

Steps 1 to 3 can start now: catalog installs are trusted by their pinned hash, with no paid account needed. Step 5
waits for the Apple account, for meum itself. Step 4 waits for the Tamago session.

## Open questions for Max

- Catalog location: a separate `meum-widgets` repo, or `catalog.json` in this repo?
- Do widgets from other people come into the catalog, or only yours at first? This decides whether the Team ID
  allow list needs a UI from the start.
- Intel Macs: are any of your friends on Intel? If not, universal builds can wait.
- Tamago's daemon: bundle Node, or port it to Swift?

## As built (2026-11-02)

- **Model** (`Sources/MeumCore/WidgetLibrary.swift`):
  - `WidgetCatalog`, the catalog format;
  - `WidgetPins` in `<state dir>/widget-pins.json` (mode 600), holding the library's and the helper's sha256 per widget;
  - `WidgetTrust.decide`, which returns pinned, team, developer or unverified.
- **Settings:**
  - `widgetCatalogURL`: https, or file:// for tests;
  - `widgetTeamIDs`: default `XHXWK3RG86`;
  - `widgetDeveloperMode`.
- **Installer** (`App/Sources/MeumApp/Widgets/WidgetInstaller.swift`):
  - Downloads the zip, checks its sha256 against the catalog, and unpacks it.
  - Requires exactly one `.meumwidget` folder whose manifest id matches, with no bundled libMeumKit, and a helper
    inside the folder.
  - Stops the old helper and swaps the folder in, keeping the `disabled` switch. It pins the hashes and reloads.
  - Remove stops the helper, deletes the folder and the pin, and with `--data` also the data folder.
- **Trust at load:**
  - WidgetManager checks the private copy (in a 0700 folder) right before dlopen. An unverified widget doesn't load;
    its card says why and how to allow it.
  - Helpers start only if their executable is trusted in the same way.
  - The first meum that pins anything trusts the widgets already installed (source "existing"), so an upgrade
    breaks nothing.
- **API and CLI:**
  - `widget.catalog`, `widget.install`, `widget.update`, `widget.remove {data?}`, `widget.allow`;
  - `meum widget catalog|install|update|remove [--data]|allow`;
  - `widget list` shows the trust of each widget.
- **Settings ▸ Widgets:**
  - the Widget Library with Install, Update and Remove;
  - Allow on unverified widgets;
  - the developer mode switch.
- **Scripts:**
  - `scripts/release-widget.sh` builds a widget (or takes a ready folder with `--folder`), sets the version, signs
    every executable with the Developer ID, zips it and records the sha256.
  - Without `--publish` it writes a local `build/widget-release/catalog.json` with file:// URLs. With `--publish` it
    creates the GitHub release and updates `catalog.json` in the `~/code/meum-widgets` clone.
  - `scripts/build-widget.sh` signs local builds with the Developer ID, so they count as verified by team.
- **Verified in an isolated instance** (local catalog):
  - the existing widget was pinned on first start;
  - the catalog lists the browser, install works, and the browser tab shows a page;
  - a swapped library is refused, then loads after Allow;
  - an ad-hoc widget from elsewhere is refused, and loads in developer mode;
  - an update from 1.0 to 1.1 works;
  - a download with a wrong sha256 is refused and nothing is installed;
  - remove with data works;
  - Settings shows the Library, Allow and the switch;
  - 138 unit tests pass.
- **Over the internet:** Browser 1.0 was published with `release-widget.sh --publish`. A fresh isolated instance
  with the default catalog URL listed it, installed it from GitHub over https (sha256 checked), and showed a page in
  a browser tab.
- **Not verified:** clicks on the Settings buttons (they call the same code as the API).
