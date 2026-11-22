# WORKLOG ia-data (Part A of the Agent Dashboard rebuild)

Plan source: the orchestrator's integration plan of 2026-11-22 (agent-dashboard-integration-20261122.md in the owner's wiki; sections Findings and Plan A).
Branch ia-data from origin/muse-provider @ ac89511. Files: windows/usage-history.py, usage-dashboard.template.html,
usage-sim.js, README-claude-rotator.md. Parallel branch ia-settings owns dashboard_settings.py / settings.js (not touched here).

## Approach (written before any code)
- A1 Gemini: new `read_gemini_api(now)` (Credential Manager `gemini:antigravity` via ctypes CredReadW; loadCodeAssist ->
  project; retrieveUserQuotaSummary on daily-cloudcode-pa; UA antigravity/hub/<ver> windows/amd64). In-memory refresh using
  client pairs regexed out of the installed language_server.exe at runtime. A pure `gemini_quota_seat(summary)` parser is the
  tested unit. Existing LS probe stays as fallback only when no credential exists.
- A2 Kimi: mirror Muse (`kimi_seat`, `fetch_kimi`, PROVIDERS["kimi"], read_live in sample, --c-kimi token). Token files read
  from ~/.kimi-code (KIMI_CODE_HOME); GET {base}/usages. Fixture tests only.
- A3 Concurrent refresh: per-provider threads, per-provider locks, POST /api/refresh {"provider": pid}. Measure before/after.
- A4 Self-update: POST /api/update -> rotator-sync --pull (reuse), then restart; autoUpdate setting; build id; page reload.
- A6 UI changes in template; A5 tests (selftest + usage-sim node + new asserts).

## Open questions / unknowns
- Exact refresh/lock structure in sample()/handler: to read next.
- Kimi token file subdir/wire names: confirm from kimi.exe strings (best effort).

## Progress log
- [A1 done] Gemini via Cloud Code quota API. Live check on this machine (owner's account): 5 windows, (Gemini Models weekly/5h, Claude and GPT models weekly/5h,
  Gemini 4 Argon weekly), 0.7 s with a valid token; forced-stale token path (real refresh token, in-memory refresh, client pairs scanned from language_server.exe in
  ~4.5 s once, 9 id/secret combos tried) works: 6.8 s first time, 0.55 s after. Credential never written back; no secrets in repo.
  Notes: Antigravity 2.34.0 exe version read via ctypes (GetFileVersionInfo); the "running LS --override_ide_version" source from the plan is not used (needs the
  1.3 s CIM probe; the exe version gives the same answer) -> ponytail-skipped.
  NB: files are CRLF; Edit-tool/py edits flip them, so I run C:\Dev\Temp\crlf-fix.py on the three CRLF files before each commit.
  Existing sample() tests stub `read_gemini`; I added a `read_gemini_api=NOAPI_` stub next to them so they never touch the real login (test-only change).
- [A3 BEFORE numbers, serial refresh at ac89511+A1, this machine, POST /api/refresh from a spare-port server (8797, temp state dir)]
  4 runs: 13.1 s, 8.8 s, 23.1 s, 11.4 s (median ~12.3 s). Component times alone: claude probe 7.8 s, codex usage cmd 3.1 s, grok 0.7 s, muse 1.0 s, gemini 1.0 s
  (sum ~13.6 s; concurrent ceiling = the slowest, claude, ~7.8 s).
- [A2 done] Kimi provider (pid "kimi", labels 5-hour / Weekly / Monthly / Monthly (coding), colour token --c-kimi added in A6). Token store confirmed from kimi.exe's
  embedded JS: <KIMI_CODE_HOME|~/.kimi-code>/credentials/*.json with access_token/refresh_token/expires_at (epoch s); base from the `region` file (global -> api.kimi.ai,
  else api.kimi.com) or KIMI_CODE_BASE_URL. Hidden when kimi is not installed; installed + no login -> "Kimi isn't signed in — open Kimi and log in" (verified live here:
  installed, signed out). An expired access token is NOT refreshed (Kimi rotates the refresh token; we must not rewrite the CLI's credential) -> note + ponytail-skipped.
  boosterWallet not shown -> ponytail-skipped. Fixture-tested only (no account).
- [A3 done] Concurrent per-provider refresh. sample()'s live providers (grok, muse, kimi, gemini) are now `_live_*` functions run one thread each (run_live);
  Store.refresh(pids) runs claude probe / codex usage command / each live read in its own thread under per-provider locks (Store.plock), then one take();
  `refreshing` stays as the exclusive-actions lock (switch, resets) and those refuse while any provider lock is held (and refresh refuses while `refreshing` is held).
  Gemini now has its own 240 s read cache (cache["gemini_read"]) so a Refresh just before a sample is not asked twice. POST /api/refresh {"provider": id} (400 for an
  unknown id / bad JSON, 409 when that provider is busy). The Codex command that outlives 120 s still hands its lock to a waiter (now the Codex lock only).
  Existing test adapted: the "/api/refresh with a Codex command still running" check now asserts the Codex lock (not `refreshing`) is the one kept.
  AFTER numbers (same machine, same method, POST /api/refresh, spare port): 3.6 s, 3.5 s, 3.9 s, 6.9 s (median ~3.7 s) vs BEFORE 13.1 / 8.8 / 23.1 / 11.4 s (median ~12.3 s).
  Single-provider: grok 1.5 s, gemini 2.0 s.
- [A4 server done + restart PROVEN here] POST /api/update -> rotator-sync --pull (reused unchanged, subprocess, its journal/backups intact) -> when usage-history.py was
  replaced: restart. Mechanism chosen: the running server starts its replacement FIRST (same interpreter, same args + --wait-port 40, DETACH_FLAGS = CHILD_FLAGS|DETACHED|
  NEW_PROCESS_GROUP), waits up to 6 s to see it stay alive (a release that does not even load keeps the old server up), then closes its socket and os._exit(0)s. Not "exit
  with a code the scheduled task restarts": the task's RestartCount is 3 / 1 min, too slow and limited. Experiment first: a detached child of a scheduled task survives the task
  ending (task state Ready, child kept running). Then end-to-end under a THROWAWAY scheduled task (ia-data-e2e-dashboard, port 8798, own state dir, own bare remote + clone,
  all in C:\Dev\Temp\ia-e2e; the live install and its task were never touched; the temp task is unregistered, every pid stopped by pid):
    manual: drift detected (1 file) -> POST /api/update -> 200 {"Updated 1 file.", restart:true} -> listener pid 52796 -> 23852, build id 6f957cd524 -> 3263620737, drift gone,
            update.done.sha recorded, new process runs at Idle priority, task state Ready.
    auto  : server started with a stale usage-history.py and autoUpdate absent (= on): first sampler loop's drift check found it, auto_update pulled it ("update (automatic):
            Updated 1 file."), server restarted itself (pid 29624 -> 58772), build id back to 3263620737.
  Windows quirk seen: ThreadingHTTPServer's SO_REUSEADDR lets the new server bind while the old one still listens (a few seconds of two listeners; both answer correctly);
  --wait-port is still the fallback for a platform that refuses. Known limit (shortcut comment): the replacement is not a child of the task, so Task Scheduler's own Stop
  does not stop it. DETACH_FLAGS added next to CHILD_FLAGS; the existing "every child starts with CHILD_FLAGS" test now allows DETACH_FLAGS (which includes CHILD_FLAGS).
- [A6 + A5 UI/tests done] Template: one Refresh button (the Reload data icon and the meta refresh are gone; the file page reloads itself from script, the app polls /api/data
  every 60 s QUIETLY: no spinner/message, no redraw when the data is unchanged, reload when `build` changes); a small refresh icon after each provider tab (spins while that
  provider refreshes, others stay usable); Gemini's "<group> · Weekly/5-hour" windows share one column per group with a bar each; Kimi tab (--c-kimi token, both themes);
  update banner states: Updating... / Updated to <sha> (10 min, dismissible) / Update available + Update now / last update failed. Checked in headless Chrome screenshots
  (light + dark, desktop; Gemini groups, Kimi signed-out note). Existing tests changed because the behaviour they pinned was replaced on purpose: the "update notice" test in
  usage-sim.test.js (the notice no longer tells the user to run rotator-sync in a terminal) and the selftest line asserting the template's meta refresh.
  PRE-EXISTING failure (not mine): `node usage-sim.test.js` stops at its "public install" file scan because windows/sync-app-history.ps1 names the owner's folder (C:\Dev\hameishiv
  in a comment and as the -Cwd default) - it fails identically at the base commit and hides every later test in that file. I verified the rest with a temp copy of the test that
  skips that one file (_sim_check.test.js, untracked, not committed).
  INCIDENT (mine, repaired): I ran my worktree server beside a copied rotator.local.json (repoClone = the live install's clone), the new auto-update pulled GitHub's older files
  OVER my worktree (windows/ was its live folder; rotator-sync only refuses its own clone). rotator rotator-sync's own backups held my exact pre-pull files; restored byte for byte,
  the copied json removed. Root-cause fix: in_checkout() - the dashboard never updates (button or automatic) a copy that sits in a git checkout (.git in its folder or the one
  above); selftest covers it. The live install (C:\Dev\Rotators, no .git above it) is unaffected; nothing in it was touched at any point.
