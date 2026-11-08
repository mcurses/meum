# First launch: meum wires its own seams

Design note, 2026-11-07. Not built. It answers two questions. What should meum's first launch look like, so that a
new person has the status dots and the Claude Code tools without reading a manual? And how can a tool installed later
connect to meum without writing meum's files?

The rule stays as it is: no other program writes meum's state or folders. meum does its own wiring, and it says what it
wrote.

## What exists today

- **Settings ▸ Claude hooks** has an Install button. It runs `meum hooks install --yes` for every Claude config folder
  meum finds, copies the bundled `meum-hook`, and backs up every `settings.json` it changes.
- **Help ▸ Copy the Claude Code Setup Command** copies `claude mcp add --scope user meum -- <cli> mcp`. The person
  pastes and runs it.
- **Reminders when hooks are missing.** An orange line under the dots toggle and a ring on a Claude tab without hooks
  both say where to fix it.
- **Talking to meum.** Other programs reach meum only through the control socket, which only the same user can open,
  or through `meum://focus?claude=ID`, which only selects a tab.

Everything a newcomer needs is there, but it takes two places and a copy-paste.

## The first-launch sheet

meum shows a sheet on the main window the first time it starts, when the setting `setupOffered` is absent. The sheet
asks once:

```
Set up meum for Claude Code

[x] Status dots on Claude tabs
    Adds meum's hooks to ~/.claude/settings.json (a backup is kept)
    and puts meum-hook in ~/.local/bin.
[x] meum's tools inside Claude Code
    Runs: claude mcp add --scope user meum -- …/meum mcp

    Found Claude config folders: ~/.claude, ~/.claude-work

                                    [Not Now]  [Set Up]
```

- **Only what applies.** A row appears only when it has something to do. With no `claude` command on the login
  shell's PATH, the second row is replaced by one line saying the setup command is under Help, for later.
- **The result replaces the buttons.** After Set Up, the sheet shows one line per file written or command run, each
  with its outcome, and "Help ▸ Uninstall… undoes all of this". Running sessions pick the change up when they restart,
  and the sheet says so.
- **It asks once.** Not Now and Set Up both set `setupOffered`. The sheet never comes back by itself. Help ▸ Set Up
  for Claude Code… opens it again at any time, and the existing reminders cover a folder added later (a new profile).
- **MCP is added per folder.** The MCP entry is added once for each Claude config folder, with `CLAUDE_CONFIG_DIR`
  set, so every profile gets it. An entry that is already there counts as done, not as an error.
- **The same code as the CLI.** The sheet calls the code paths of `meum hooks install` and the setup command. There
  is no second installer.

What stays a person's yes: anything that writes Claude Code's configuration. meum never edits it unasked, even
though it could.

## When another tool arrives

Tools that come later need a moment to say "I am here and have something for meum". meum must not watch other
tools' folders, and they must not write into meum's. So the arriving tool announces itself over the socket, and
meum decides.

### Offering a widget

New method `widget.offer {path}`, and the matching command `meum widget offer PATH`:

- **meum checks the bundle where it is.** It reads the manifest and verifies the signature, as it does for every
  widget. A bundle that fails either check is refused, and the reply says why.
- **An offer is a question.** A valid bundle becomes a card under the sidebar, like Tips: "A program offers the
  widget <Name> (signed by <Team>). [Install] [No]". The card names the signing team, never a name the offering
  program claims for itself. The offer never installs anything by itself.
- **Install copies it.** Install copies the bundle into meum's widgets folder, pins it as an install from the library
  would, and reloads. When the signing team is not yet trusted, Settings ▸ Widgets opens at the existing allow
  step, the one place where trust is granted.
- **Offers live in memory.** They last until meum quits. A tool whose offer was not answered offers again the next
  time it starts. There is no new data store.
- **Updates are offers too.** An offer for a widget that is already installed at the same version answers
  `installed` and asks nothing. A newer version becomes an update offer with the same buttons.
- **The answer doesn't wait.** The reply is `{state: offered | installed | refused, reason?}` right away. The tool
  learns the outcome later from `widget.list` or the `widget.*` events, and never blocks on a person.

This replaces "copy the folder into meum's widget folder, then call `widget.reload`". `widget.reload` stays as it is,
for widget developers.

### Targeting a tab

A tool that routes work to a Claude session needs nothing new:

- `tab.select {claude: ID}` and `meum://focus?claude=ID` show a session's tab;
- `tab.sendText` and `tab.paste` type into a tab;
- `tree` and `workspace.list` say which tab runs which session.

Selecting is harmless. Typing is not: it can run anything in the person's shell. Today the socket's rule (only
programs of the same user) is the whole gate. Whether typing into a tab where Claude Code runs should need more,
such as a one-time yes per tool, is an open question below.

### The general shape

Every seam another tool wants follows the same pattern. The tool announces over the socket. meum checks what it can
check, asks the person once where something is written or trusted, does the writing itself, and reports the outcome
by events. No tool gets a back door into meum's folders. meum learns about tools only when they speak.

## What needs a yes, and what doesn't

| Action | Who decides |
|---|---|
| writing Claude Code's hooks or MCP entry | the person, in the first-launch sheet or Settings |
| installing an offered widget | the person (Install) |
| trusting a new signing team | the person, in Settings ▸ Widgets only |
| opening a link of a new kind from the sidebar | the person, once per kind (already built) |
| reloading widgets, selecting a tab, setting status entries | no yes: any program of this user |
| typing into a tab | no yes today; see open question 2 |

## What this does not add

It adds no background process, no launch job, no data store and no polling. It adds one setting (`setupOffered`),
one socket method (`widget.offer`), one sheet, one Help item and in-memory offers.

## Open questions

1. **Offers outside the sidebar.** Should an offer also post a macOS notification when meum is in the background? The
   proposal is no: the sidebar line is enough, and notifications stay for Claude sessions.
2. **A gate on typing.** Should `tab.sendText` and `tab.paste` into a tab running Claude Code ask once per program?
   meum can't name the program reliably over a Unix socket (it only knows the peer's process id), so such a gate would
   be advice, not protection. The proposal is no gate, and the tool that types should say so to its person.
3. **The CLI on PATH.** Should the first-launch sheet also offer to link `meum` into `~/.local/bin`? Today `meum`
   is on PATH only inside meum's own tabs. The proposal is yes, as a third row, but only when `~/.local/bin` is
   already on PATH.
