# WORKLOG ia-data (Part A of the Agent Dashboard rebuild)

Plan source: C:\Dev\hameishiv-wiki\wiki\handoffs\agent-dashboard-integration-20261122.md (Findings, Plan A).
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
