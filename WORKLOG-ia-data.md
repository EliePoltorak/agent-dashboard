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
