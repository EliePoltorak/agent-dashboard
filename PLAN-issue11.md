# Plan: issue #11 — ranking/selection honour a cached cap when the live probe is headerless

## Known
- Rank-Accounts (windows/claude-cli-account.ps1 ~692) ranks on the in-memory probe only: `$capped` (s5/w7/status) and `$fCapped` (oi7).
- Select-RotationTarget main loop (~1186) re-probes Fable per candidate and skips only on live `oi7_stat -eq 'rejected'`.
- A headerless ok non-2xx probe (Overloaded 500) has no *_stat, so the seat ranks usable with score 0 and sorts first.
- Get-UsageCached's `$keepCap` (~460) leaves a cap still in force on disk when the probe is headerless; otherwise the file is the live reading.
  So after any probe, Test-CapCached(label) == live capped OR (live headerless AND cached cap still in force). Expired caps read false.

## Approach (a): consult Test-CapCached, no new helpers
- Rank-Accounts: `$capped` also true when `Test-CapCached $l 'default'`; `$fCapped` also true when `$WithFable -and (Test-FableCapCached $l)`.
  Only when the Fable reading was taken this pass: with WithFable=$false a no-reset Fable cap would never be re-probed and would wedge the seat.
- Select-RotationTarget loop: after the fresh Fable probe, also `continue` when `Test-FableCapCached $c.label`.
- Rejected (b) "headerless = unknown": excludes every seat during an API-wide overload even with no cap, and changes the `unknown`/fallback semantics.

## Test (test-cli-access-fallback.ps1, existing probe mocks default-500 / fable-500)
- s5 and w7: cached rejected with future reset, probe default-500 -> Rank row A not usable; Select-RotationTarget not A.
- oi7: cached Fable rejected future reset, probe fable-500, A lowest session -> not usable, not selected.
- each window with reset in the past -> A usable and selected.
- Prove red on origin/main, then revert-proof after the fix.
