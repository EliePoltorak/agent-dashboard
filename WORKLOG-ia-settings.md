# WORKLOG - ia-settings (Part B: Settings panel, seats for every provider)

Branch `ia-settings` (from `integrated-app` @ ac89511). Plan: C:\Dev\hameishiv-wiki\wiki\handoffs\agent-dashboard-integration-20261122.md ("Plan -> B").
Implementer: Claude Code - Sonnet 5.5. Parallel branch `ia-data` owns usage-history.py / template changes; this branch keeps those two files to tiny hooks.

## Approach (written before any code)

Files (all new except the three hooks):
- `windows/dashboard_settings.py` - server side. `Settings` class holding every path and every outside effect as a constructor argument
  (command runner, process lister, credential API, clock), so the tests drive it with fakes and temp dirs. Routes:
  `GET /settings.js`, `GET /api/settings/seats`, `GET /api/settings/automation`, `GET /api/settings/job?id=`, `POST /api/settings/action`.
  POST needs `X-Quota-App: 1` (same as the existing POSTs); the Host check already ran in the handler.
- `windows/settings.js` - the drawer UI (CSS inside the file, page tokens only). Adds a gear button into the page's `.top` row from a MutationObserver
  (the page re-renders `#app` wholesale, so a button written into the template would be wiped; the observer survives the `ia-data` template rewrite).
- `windows/test-dashboard-settings.py` - unittest, fake runner / temp dirs / fake credential API.
- Hooks (tiny): `usage-history.py` - import + two delegations (`do_GET`, `do_POST`) before the 404; template - one `<script src="/settings.js">` tag.
  Deviation from the brief, on purpose: no static gear button in the template (see above); the template diff is one line.

Rules the module follows:
- Every action calls an EXISTING entry point as an argv list (never a shell string, no page text in a command): `claude-cli-account.ps1 --switch/--import`,
  `claude-app-rotator.ps1 --capture/--switch --relaunch`, `codex-app-rotator.ps1 --switch`, `sync-app-history.ps1`, `claude-app-seat-keepalive.ps1 -Status`,
  `schtasks /Change|/End|/Run|/Query`. File moves (remove/restore) and `email.txt` / `rotator.local.json` writes are plain file operations (the rotators have no command for them).
- Labels `^[A-Za-z0-9_-]{1,32}$`; the label only ever lands in a path or an argv element.
- Remove = MOVE to `<store>\.removed\<label>-<UTC timestamp>`, never delete; restore moves it back (refused if the label is taken). The seat in use is not removable.
- Long actions are jobs (thread, id, state, last 40 lines of output with tokens/emails scrubbed); one mutating action at a time (own lock; also takes
  `store.refreshing` when the store has one, so it cannot interleave with a Refresh/switch). A job is never killed, as /api/switch.
- Token and credential values are never returned, logged or put in an error. The pasted Claude token goes to a private temp dir file for `--import`, removed in a `finally`.
- Seat listing reads files/blob only; emails come from the same places the page uses.

Generic credential-seat store (B3): `~/.agent-dashboard-seats/<provider>/<label>/` holds `meta.json` (email, captured), `files/<n>` copies and `cred/<n>.bin`
blobs. A provider is a small table (files, Credential Manager targets, processes that must be closed, how to read the account email). Capture refuses a
login already captured under another label; switch refuses while the provider's app runs, backs the live login up to `.swap-backups/<ts>/`, re-captures the
leaving login into the seat it matches (by email), then writes the new one and reads it back. "Most headroom" uses the dashboard blob's windows (used = max over windows;
a capped seat is excluded); for these providers the dashboard reads only the ACTIVE login, so the last reading of each seat is remembered in `readings.json`
whenever the panel is opened (shortcut: a seat that was never active while the panel was open has no number and is never picked automatically).

## B1 inventory

### Rotator functions (repo `windows/`), and what the panel does with each
| Function | Entry point | Becomes |
|---|---|---|
| Claude CLI list/status | claude-cli-account.ps1 --list/--status | seat table reads the seat folders directly (no probe); Refresh stays on the page |
| Claude CLI switch / switch best | --switch <L> / --switch best --no-usage | action (job) |
| Claude CLI add (setup-token) | `claude setup-token` + --import <L> <file> [--replace] | action: open console, paste field, job |
| Claude CLI capture (interactive paste) | --capture | NOT used: it prompts on stdin; --import covers it |
| Claude CLI clear (--clear) | unset env var | left out (terminal-only, reverts shell state) |
| Claude app capture | claude-app-rotator.ps1 --capture <L> | action (refused with a message while the app runs) |
| Claude app switch | --switch <L> --relaunch | action (job, confirm) |
| Claude app rotate (--rotate) | | left out: "Switch to best" and explicit switch cover it |
| Display email | email.txt (no rotator command) | action: file write |
| Seat weight | rotator.local.json seatWeights | action: file write |
| Remove / restore seat | (none; today a manual move) | action: move to .removed / back |
| App history sync | ~/.grok/bin/sync-app-history.ps1 (repo copy as fallback) | action (job) + task toggle |
| App-seat keepalive | claude-app-seat-keepalive.ps1 -Status, task | status (job) + task toggle |
| App-seat heartbeat | app-seat-publish.ps1, task | left as is (publishes to the Merge Driver box; not a user function) |
| Auto-rotate | task `Claude usage auto-rotate` (check-rotate-hidden.vbs) | task toggle |
| Rotate proxy | claude-rotate-proxy.py, task `Claude rotate proxy`, GET :18484/__proxy/health | status + restart + task toggle |
| Auto-resume | claude-resume-sessions.ps1 via Ping-ActiveSessions | toggle: marker `.auto-resume-off`; ONE small change in claude-cli-account.ps1 (Ping-ActiveSessions returns when the marker exists) because the rotator had no switch |
| StopFailure hook, access fallback, Fable ladder | stopfailure-rotate.py etc. | internal, no UI |
| Resume now (claude-resume) | claude-resume-sessions.ps1 | left out (steals focus / kills sessions; terminal-only by design) |
| rotator-sync | rotator-sync.py | belongs to Part A (self-update) |

### Live in C:\Dev\Rotators but NOT in the repo (found by comparing the two folders)
- `codex-cli-account.ps1` - Codex seat rotator (dashboard `codexUsageScript` runs it). BRING IN (header emails replaced by placeholders).
- `codex-app-rotator.ps1` - Codex app/CLI switch (the dashboard's Codex switch buttons need it next to usage-history.py). BRING IN.
- `codex-keepalive.ps1` + `codex-keepalive-hidden.vbs` - task `Codex seat keepalive` (every 4 min). BRING IN; the vbs hard-codes `C:\Dev\Rotators`, changed to the
  script's own folder like the other vbs files; keepalive gets a Test-Path guard for the merge-pr script it calls (that script is outside the repo).
- `codex-resume-sessions.ps1` - Codex mirror of claude-resume, not used by the dashboard. BRING IN (no secrets, no personal paths).
- `rotator-functions.local.ps1` - git-ignored by design (`*.local.*`); stays local. It defines codex-rotator/codex-account/codex-usage/codex-resume; not added to the repo's rotator-functions.ps1 (skipped).
- `rotator.local.json` - local config, stays.
- `*.bak*` files and logs - ignored.
- Outside the folder: `~/.grok/bin/sync-app-history.ps1` (the running copy; the repo file is its source), `~/.claude/skills/merge-pr/scripts/codex_failover_review.py` and
  `codex_redeem_reset.py` (owner's skill, called by codex-keepalive / codexRedeemScript) - not brought in; they are the owner's merge-pr skill, not rotator files.

Scheduled tasks seen (Get-ScheduledTask, 2026-11-22): Claude usage dashboard (Running, not toggleable from the page), Claude usage auto-rotate (Ready), Claude app-history sync (Disabled),
Claude app-seat keepalive (Ready), Claude app-seat heartbeat (Ready), Claude rotate proxy (Running), Codex seat keepalive (Ready). Panel toggles all but the first and the heartbeat.

## B3 login-store discovery (this machine, read-only look, no values read)
| Provider | Where the login is | Swappable? |
|---|---|---|
| Gemini / Antigravity app | Credential Manager generic `gemini:antigravity` (UTF-8 JSON blob, has `id_token_email`); app = `Antigravity.exe` | yes - app must be closed |
| Gemini CLI | `~/.gemini/oauth_creds.json` + `~/.gemini/google_accounts.json` (plain files) | yes (same seat as above; node CLI has no resident process to test) |
| Grok | `~/.grok/auth.json` (one JSON, key `https://auth.x.ai::<id>` with `email`), `auth.json.lock` beside it; CLI = `grok.exe` | yes - CLI must be closed |
| Kimi | `~/.kimi-code` holds only `bin` and `region` here (not signed in). Token folder name NOT verifiable (kimi.exe strings show a `credentials` dir option, `credentialsDir`) | built against a guess (`credentials`/`auth`/`tokens` under the Kimi home), capture refuses until a login folder exists; UNTESTED on a real login |
| Muse (Meta) | not on disk: `~/.config/muse` holds only settings/trust json, no Credential Manager entry mentions muse/meta; `META_API_KEY` env var overrides login | NO - skipped, login store not locatable |

## Progress
- [x] Research + inventory (this file)
