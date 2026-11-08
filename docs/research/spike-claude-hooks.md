# Spike: plain Claude Code hooks -> meum unix socket (2026-11-02)

> The spike's code was removed from the tree on 2026-11-05; this result is what remains. The paths below are where it lived.

Verdict: **works, go.** Plain hooks reach the socket for every config dir tested, survive resume/continue,
carry everything needed, and the hook is safe when the app is down. Tested with the real binary
`/opt/homebrew/bin/claude` (CMUX_* vars stripped, cmux wrapper bypassed), `-p --model haiku`, hooks passed with
`--settings spike/settings.spike.json`. No user config was edited.

Files: `meum-hook` (POSIX sh), `listener.py` (test socket -> JSON lines), `settings.spike.json`, `run-one.sh`,
`pty-run.py` (interactive check), `run/events*.jsonl` (raw captures).

## Q1. Payload and environment: YES
Every hook gets JSON on stdin with `session_id`, `transcript_path`, `cwd`, `hook_event_name` (+ event extras).
The hook process inherits the terminal's env: `MEUM_TAB` and `CLAUDE_CONFIG_DIR` both arrived (tab field populated
in all runs, also in the pty run). Captured (default dir, `-p`):

```
SessionStart      {"session_id":"910c9ccf-…","transcript_path":"/Users/dev/.claude/projects/-Users-dev-code-app-spikes-claude-hooks/910c9ccf-….jsonl","cwd":"…","hook_event_name":"SessionStart","source":"startup"}
UserPromptSubmit  {…,"prompt_id":"8616dd59-…","permission_mode":"auto","hook_event_name":"UserPromptSubmit","prompt":"say ok"}
Stop              {…,"prompt_id":"…","permission_mode":"auto","effort":{"level":"medium"},"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"ok","background_tasks":[],"session_crons":[]}
SessionEnd        {…,"prompt_id":"…","hook_event_name":"SessionEnd","reason":"other"}
Notification      {…,"hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}
PermissionRequest {…,"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"touch …","description":"…"},"permission_suggestions":[…]}
PreToolUse        {…,"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{…},"tool_use_id":"toolu_…"}
```
SessionStart `source` values seen: `startup`, `resume`, `fork`; docs add `clear`, `compact`. SessionStart also
carries `model` and `scratchpad_dir` in newer builds (seen in pty run). Envelope sent by meum-hook:
`{"tab":"<MEUM_TAB>","config_dir":"<CLAUDE_CONFIG_DIR>","payload":<stdin json>}`.

Gotcha: **`config_dir` is empty when CLAUDE_CONFIG_DIR is unset** (default `~/.claude`). The app should treat
"" as `~/.claude`, or derive the dir from `transcript_path` (`<dir>/projects/…`), which is always correct.

## Q2. Every config dir, and resume: YES
| dir | result |
|---|---|
| ~/.claude (var unset) | all 4 events |
| six other ~/.claude-* profiles | all 4 events (SessionStart, UserPromptSubmit, Stop, SessionEnd), transcript_path under the right dir |
| ~/.claude with CLAUDE_CONFIG_DIR=$HOME/.claude set explicitly | "Not logged in" (credential lookup differs when the var is set); only SessionStart/Prompt/End fired, no Stop. Auth quirk, not a hook problem. Real use sets it only for non-default dirs |
| one profile that was not logged in | skipped (same partial events) |

Resume (session 2697b9e4 created in -work): `--resume <id>` -> SessionStart `source:"resume"`, **same session_id**;
`--continue` -> `source:"resume"`, same session_id; `--resume <id> --fork-session` -> `source:"fork"`, **new**
session_id (2183717b…). So: key the tab's resume id on the latest session_id seen for that tab (overwrite on every
SessionStart), which handles /clear, compact and fork too. Reboot-resume = `CLAUDE_CONFIG_DIR=<config_dir> claude
--resume <session_id>` in `cwd`. Caveat: hooks are tied to the hooks present in settings at start, so every config
dir needs the entry (install plan below); the cmux-style per-launch injection is what failed before.

## Q3. App not running: SAFE
meum-hook exits 0 silently if `MEUM_TAB` is unset (not a meum tab) or the socket path is missing; `nc -w 1` caps the
send, stderr/stdout discarded, so stdout never leaks into Claude context (SessionStart/UserPromptSubmit stdout
would be injected as context, so it must stay empty). Verified in a real run with a missing socket: claude output
was just `ok`, rc 0. Latency (50 runs each, macOS, sh + `/usr/bin/nc -U`):

| case | median | p95 |
|---|---|---|
| socket live (listener reads) | 13.6 ms | 37 ms |
| socket file missing | 4.1 ms | 9 ms |
| MEUM_TAB unset | 4.0 ms | 4.4 ms |
| stale socket file, nobody listening | 9.8 ms | 14 ms |

Fine for per-turn events; a compiled binary is not needed. If PreToolUse is ever hooked, consider `"async": true`
or a tiny swift binary, since that fires per tool call.

## Q4. Which event
- **Turn finished / unread**: `Stop` (fires once when Claude finishes responding; has `last_assistant_message`).
  Set busy on `UserPromptSubmit`, unread+idle on `Stop`, clear unread when the tab gets focus.
  Interrupted turns do not fire Stop (docs), so also treat next `UserPromptSubmit` as busy and `SessionEnd` as gone.
- **Needs input**: `Notification` with `notification_type:"permission_prompt"` (verified live in a pty: message
  "Claude needs your permission", arrived after `PreToolUse` and `PermissionRequest`). `idle_prompt` (waiting for
  input after idle) and `elicitation_dialog`/`auth_success` are documented but NOT verified here (idle fires only
  after ~60 s idle). `PermissionRequest` fires slightly earlier and is a possible alternative.
- Session lifecycle: `SessionStart` (register tab -> session_id/cwd/transcript), `SessionEnd` (`reason`).

Interactive check: python pty, `--permission-mode default`, cwd = an already-trusted dir, config dir -work; a
Bash call needing approval; session killed via the captured pid (SIGTERM). The tool was never approved
(pty-touch.txt not created).

## Proposed permanent install
One entry per config dir, in `<dir>/settings.json` for ~/.claude and every ~/.claude-* profile (the owner's call; I
changed none). Install `meum-hook` to a stable path, e.g.
`~/.local/bin/meum-hook` (cmux-style per-launch injection is exactly what to avoid):
```json
"hooks": {
  "SessionStart":     [{"hooks":[{"type":"command","command":"$HOME/.local/bin/meum-hook"}]}],
  "UserPromptSubmit": [{"hooks":[{"type":"command","command":"$HOME/.local/bin/meum-hook"}]}],
  "Stop":             [{"hooks":[{"type":"command","command":"$HOME/.local/bin/meum-hook"}]}],
  "Notification":     [{"hooks":[{"type":"command","command":"$HOME/.local/bin/meum-hook"}]}],
  "SessionEnd":       [{"hooks":[{"type":"command","command":"$HOME/.local/bin/meum-hook"}]}]
}
```
(Merge with existing `hooks` keys; hook arrays from several files are all run, so coexisting with other hooks is
fine. Use an absolute path if `$HOME` expansion is not wanted.) Also: socket at `~/.local/state/meum/meum.sock`
(override with MEUM_SOCK), each tab exports `MEUM_TAB`. A one-shot `meum install-hooks` could merge the entry into
all `~/.claude*/settings.json` idempotently.

## Open risks
1. If the user's settings.json is a symlink/shared between dirs, double fire; dedupe by (tab, session_id, event, prompt_id).
2. Sessions started before the hook entry exists, or outside a meum tab (no MEUM_TAB), are invisible: expected.
3. Plugins/`--bare`/`--settings` of others can disable or replace hooks; `disableAllHooks` kills them.
4. Events sent by plain `nc` are unauthenticated on a user-owned socket; keep it mode 0600 in a 0700 dir.
5. Payload built by string splice: valid as long as Claude's stdin is valid JSON (it is); `MEUM_TAB` must be a safe token.
6. Subagent Stop (`SubagentStop`) is a separate event, so Stop = main agent only; background tasks show up in
   `background_tasks` on Stop (could mean "done but still running things").
7. Auth: one profile was not logged in; ~/.claude with the var set explicitly also fails auth, so launch default-dir tabs with the var unset.
8. idle_prompt, `--resume` picker (no id given), /clear, compact were not exercised.
9. Session_id stability on resume holds in the installed version; re-record on every SessionStart anyway.
