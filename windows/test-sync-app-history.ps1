(Get-Process -Id $PID).PriorityClass = 'Idle'   # first statement: a long test must not freeze the desktop (children inherit it)
<#
  test-sync-app-history.ps1 -- scenario test for sync-app-history.ps1's pass 1.4: the isArchived / isStarred
  flags follow you across seats. (The sidebar pin LIST and groups are not synced -- see the script header.)
  Covers: first-run union (a planted disagreement, and again after the state folder is deleted); a record
  not seen last run spreads only when it is on; a record whose write fails, or that can't be read, keeps its
  session's last baseline (the rest is saved), so its stale value does not spread next run; a deleted record
  does not stop the save; with the app running (-AssumeAppRunning) nothing is changed or saved and a record
  it creates is neutral; a state file without the record->session map stops the whole save on an unreadable
  record; a record truncated to 0 bytes counts as unreadable; archived-sessions.idx follows archive and
  un-archive; idle run changes nothing; pin / unpin and archive / un-archive on one seat reach
  every seat; opposite changes in one run -> "on" wins; a corrupt state file -> warning, nothing changed, file
  left as is; a missing ~\.claude-app-seats directory -> run succeeds and writes the state file; records the
  script creates (cloned from another seat, or fabricated from the transcript) carry the flags and are in the
  saved baseline.
  Copies the LIVE app session index into a fresh sandbox under C:\Dev\Temp and runs the sync there with
  %APPDATA% / %USERPROFILE% redirected (so the script's app-running guard counts the sandbox as not live).
  The real files are only read. The sandbox is deleted on success and kept (path printed) on failure. Exit 1 on
  any failure. Each sync run takes ~1-2 min on a full index.
    pwsh -File test-sync-app-history.ps1 [<path to sync-app-history.ps1>]
#>
$Script = if ($args[0]) { [string]$args[0] } else { Join-Path $PSScriptRoot 'sync-app-history.ps1' }
$sb = "C:\Dev\Temp\sync-app-history-test\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$proj = "$sb\home\.claude\projects\C--Dev-hameishiv"
New-Item -ItemType Directory "$sb\app\Claude", $proj, "$sb\home\.claude-app-seats" -Force | Out-Null
Copy-Item "$env:APPDATA\Claude\claude-code-sessions" "$sb\app\Claude\" -Recurse -Force
# One synthetic, recent, substantive transcript so the script has a session to create records for (pass 2).
# The real index's transcripts are NOT copied, so with -NoPrune nothing else is created or pruned.
$X = [guid]::NewGuid().ToString()
$asst = 1..7 | ForEach-Object { '{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"ok ' + $_ + '"}]}}' }
Set-Content "$proj\$X.jsonl" (@('{"type":"user","message":{"role":"user","content":"please help me with the flag sync test"}}') + $asst)
"sandbox: $sb"
$ccs = "$sb\app\Claude\claude-code-sessions"; $statePath = "$sb\home\.claude-app-seats\.flag-state.json"
$fail = 0; $script:out = @(); $script:rc = 0
function run([string]$extra = '') {
  $script:out = @(pwsh -NoProfile -Command "`$env:APPDATA='$sb\app'; `$env:USERPROFILE='$sb\home'; & '$Script' -NoPrune $extra *>&1" 2>&1 | ForEach-Object { "$_" })
  $script:rc = $LASTEXITCODE
  $script:out | Where-Object { $_ -match '^set |^WOULD |isArchived|isStarred|not synced|rror|xception|WARNING|added \d' } | ForEach-Object { "    $_" }
}
function check($name, $ok) { if ($ok) { "PASS $name" } else { "FAIL $name"; $script:fail++ } }
function key($f) { $f.Substring($ccs.Length).TrimStart('\') }
function recs { Get-ChildItem $ccs -Recurse -Filter local_*.json | ForEach-Object { try { $j = Get-Content $_.FullName -Raw | ConvertFrom-Json } catch { return }; [pscustomobject]@{ f = $_.FullName; id = $j.sessionId; cli = [string]$j.cliSessionId; arch = [bool]$j.isArchived; star = [bool]$j.isStarred; title = [string]$j.title } } | Where-Object cli }
function setRec($f, $k, $v) { $j = Get-Content $f -Raw | ConvertFrom-Json; $j | Add-Member -NotePropertyName $k -NotePropertyValue $v -Force; Set-Content $f ($j | ConvertTo-Json -Compress -Depth 100) -NoNewline }
function recHash { (Get-ChildItem $ccs -Recurse -Filter local_*.json | Sort-Object FullName | ForEach-Object { "$($_.FullName):$((Get-FileHash $_.FullName -Algorithm MD5).Hash)" }) -join '|' }
function state { Get-Content $statePath -Raw | ConvertFrom-Json -AsHashtable }
function mixed($R, $p) { @($R | Group-Object cli | Where-Object { ($_.Group.$p -contains $true) -and ($_.Group.$p -contains $false) }).Count }
function ofSession($cli) { @(recs | Where-Object { $_.cli -eq $cli }) }
# is this record's sessionId in its folder's archived-sessions.idx?
function inIdx($r) { $p = Join-Path (Split-Path $r.f) 'archived-sessions.idx'; (Test-Path $p) -and (@((Get-Content $p -Raw | ConvertFrom-Json).archived) -contains $r.id) }

# The live index already agrees across seats, so plant a disagreement for the first run to resolve.
$U = recs | Where-Object { $_.cli -ne $X } | Group-Object cli | Where-Object { $_.Count -ge 2 -and -not ($_.Group.star -contains $true) -and -not ($_.Group.arch -contains $true) } | Select-Object -First 1
if (-not $U) { "FAIL no unflagged multi-seat session in the index to test with"; exit 1 }
setRec $U.Group[0].f 'isArchived' $true
"--- run 1 (baseline: first run, no state file)"; run; $R = recs
check "first run: archived on one seat -> archived on all $($U.Count)" (@(ofSession $U.Name | Where-Object { -not $_.arch }).Count -eq 0)
check 'run 1 exits 0' ($rc -eq 0)
check 'state file written' (Test-Path $statePath)
check 'every record of a session with any archived record is archived' ((mixed $R 'arch') -eq 0)
check 'every record of a session with any starred record is starred' ((mixed $R 'star') -eq 0)
check "synthetic session got records ($(@($R | Where-Object cli -eq $X).Count))" (@($R | Where-Object cli -eq $X).Count -ge 2)

"--- run 2 (idle)"; $h = recHash; run
check 'idle run changes no record file' ((recHash) -eq $h)
check "idle run prints no 'set ' line, no error" (-not ($out -match '^set |rror|xception') -and $rc -eq 0)

# a real multi-seat session, nothing flagged, for the pin / archive tests
$G = recs | Where-Object { $_.cli -ne $X } | Group-Object cli | Where-Object { $_.Count -ge 2 -and -not ($_.Group.star -contains $true) -and -not ($_.Group.arch -contains $true) } | Sort-Object Count -Descending | Select-Object -First 1
if (-not $G) { "FAIL no unflagged multi-seat session in the index to test with"; exit 1 }
$g0 = $G.Group[0]; $g1 = $G.Group[1]
"--- pin on one seat ($($G.Count) seats)"
setRec $g0.f 'isStarred' $true; run
check 'starred on every seat' (@(ofSession $G.Name | Where-Object { -not $_.star }).Count -eq 0)
"--- unpin on a different seat"
setRec $g1.f 'isStarred' $false; run
check 'unstarred on every seat' (@(ofSession $G.Name | Where-Object star).Count -eq 0)

"--- archive on one seat"
setRec $g0.f 'isArchived' $true; run
check 'archived on every seat' (@(ofSession $G.Name | Where-Object { -not $_.arch }).Count -eq 0)
check "archived: listed in every folder's archived-sessions.idx" (@(ofSession $G.Name | Where-Object { -not (inIdx $_) }).Count -eq 0)
"--- un-archive on a different seat"
setRec $g1.f 'isArchived' $false; run
check 'un-archived on every seat' (@(ofSession $G.Name | Where-Object arch).Count -eq 0)
check "un-archived: removed from every folder's archived-sessions.idx" (@(ofSession $G.Name | Where-Object { inIdx $_ }).Count -eq 0)

"--- opposite changes on two seats in the same run -> on wins"
# After a run every record of a session agrees, so opposite changes can only come from a state file where two
# seats were recorded differently: seat 0 was 'on' (now off), seat 1 was 'off' (now on).
$st = state
foreach ($fl in 'isArchived', 'isStarred') { $st[$fl][(key $g0.f)] = $true; $st[$fl][(key $g1.f)] = $false; setRec $g0.f $fl $false; setRec $g1.f $fl $true }
Set-Content $statePath ($st | ConvertTo-Json -Compress -Depth 5); run
$S = ofSession $G.Name
check 'on wins: archived on every seat' (@($S | Where-Object { -not $_.arch }).Count -eq 0)
check 'on wins: starred on every seat' (@($S | Where-Object { -not $_.star }).Count -eq 0)
foreach ($r in $S) { setRec $r.f 'isArchived' $false; setRec $r.f 'isStarred' $false }; run   # reset, and let the state follow
check 'reset: nothing flagged on that session' (@(ofSession $G.Name | Where-Object { $_.arch -or $_.star }).Count -eq 0)

"--- a record not seen last run that is ON spreads (archived on a newly used seat)"
$st = state; $st['isArchived'].Remove((key $g1.f)); Set-Content $statePath ($st | ConvertTo-Json -Compress -Depth 5)
setRec $g1.f 'isArchived' $true; run
check 'unseen archived record -> archived on every seat' (@(ofSession $G.Name | Where-Object { -not $_.arch }).Count -eq 0)
"--- a record not seen last run that is OFF does not un-archive the others (a new app record starts off)"
$st = state; $st['isArchived'].Remove((key $g0.f)); Set-Content $statePath ($st | ConvertTo-Json -Compress -Depth 5)
setRec $g0.f 'isArchived' $false; run
check 'unseen off record -> still archived on every seat' (@(ofSession $G.Name | Where-Object { -not $_.arch }).Count -eq 0)
foreach ($r in (ofSession $G.Name)) { setRec $r.f 'isArchived' $false }; run
check 'reset again: nothing archived on that session' (@(ofSession $G.Name | Where-Object arch).Count -eq 0)

"--- a record whose write fails: its session keeps its last baseline, so its stale ON value does not spread next run"
foreach ($r in (ofSession $G.Name)) { setRec $r.f 'isArchived' $true }; run          # archived everywhere, all known
setRec $g0.f 'isArchived' $false                                                       # un-archive on seat 0
# a second session changed in the same run must still be saved (only the failed session holds back)
$H = recs | Where-Object { $_.cli -ne $X -and $_.cli -ne $G.Name } | Group-Object cli | Where-Object { $_.Count -ge 2 -and -not ($_.Group.star -contains $true) } | Select-Object -First 1
if ($H) { setRec $H.Group[0].f 'isStarred' $true }
Set-ItemProperty -LiteralPath $g1.f -Name IsReadOnly -Value $true; run                 # seat 1's record can't be written
check 'failed write warns' ($out -match 'could not set isArchived')
check 'failed write: the other seats are un-archived' (@(ofSession $G.Name | Where-Object { $_.f -ne $g1.f -and $_.arch }).Count -eq 0)
$st = state; check 'failed write: the session keeps its last baseline' ($st['isArchived'][(key $g0.f)] -eq $true -and $st['isArchived'][(key $g1.f)] -eq $true)
if ($H) {
  check 'failed write: another session changed in the same run is saved' (@(ofSession $H.Name | Where-Object { $st['isStarred'][(key $_.f)] -ne $true }).Count -eq 0)
  foreach ($r in (ofSession $H.Name)) { setRec $r.f 'isStarred' $false }               # put it back (all known -> off)
} else { "(no second unpinned multi-seat session; skipped the other-session check)" }
Set-ItemProperty -LiteralPath $g1.f -Name IsReadOnly -Value $false; run
check 'retried: un-archived on every seat, not re-archived' (@(ofSession $G.Name | Where-Object arch).Count -eq 0)
$st = state; check 'retried: the session baseline moves on' ($st['isArchived'][(key $g0.f)] -eq $false -and $st['isArchived'][(key $g1.f)] -eq $false)

"--- a record that can't be read for a run: its session keeps its last baseline (the rest is saved), so its stale ON value does not spread"
foreach ($r in (ofSession $G.Name)) { setRec $r.f 'isArchived' $true }; run          # archived everywhere, all known
$keep1 = Get-Content -LiteralPath $g1.f -Raw
if ($H) { setRec $H.Group[0].f 'isStarred' $true }                                     # another session changed in the same run
setRec $g0.f 'isArchived' $false; Set-Content -LiteralPath $g1.f 'not json' -NoNewline; run   # un-archive on seat 0; seat 1 unreadable
check 'unreadable record warns' ($out -match 'could not read')
$st = state
check 'unreadable record: its session keeps its last baseline' ($st['isArchived'][(key $g0.f)] -eq $true -and $st['isArchived'][(key $g1.f)] -eq $true)
check 'unreadable record: the rest of the state is saved (not the whole-save stop)' (($out -notmatch 'is not saved this run') -and $st['cli'] -and $st['cli'][(key $g1.f)] -eq $G.Name)
if ($H) {
  check 'unreadable record: another session changed in the same run is saved' (@(ofSession $H.Name | Where-Object { $st['isStarred'][(key $_.f)] -ne $true }).Count -eq 0)
  foreach ($r in (ofSession $H.Name)) { setRec $r.f 'isStarred' $false }
}
Set-Content -LiteralPath $g1.f $keep1 -NoNewline; run                                # seat 1 readable again, still archived
check 'readable again: un-archived on every seat, not re-archived' (@(ofSession $G.Name | Where-Object arch).Count -eq 0)

"--- a record truncated to 0 bytes counts as unreadable too"
foreach ($r in (ofSession $G.Name)) { setRec $r.f 'isArchived' $true }; run
$keep1 = Get-Content -LiteralPath $g1.f -Raw
setRec $g0.f 'isArchived' $false; Set-Content -LiteralPath $g1.f '' -NoNewline; run
check 'empty record warns' ($out -match 'could not read')
$st = state; check 'empty record: its session keeps its last baseline' ($st['isArchived'][(key $g1.f)] -eq $true)
Set-Content -LiteralPath $g1.f $keep1 -NoNewline; run
check 'empty record, restored: un-archived on every seat, not re-archived' (@(ofSession $G.Name | Where-Object arch).Count -eq 0)

"--- the desktop app is running: no record is changed and the state is not saved"
setRec $g0.f 'isArchived' $true
$h = recHash; $stBefore = Get-Content $statePath -Raw; run '-AssumeAppRunning'
check 'app running: says flags are not synced' ($out -match 'not synced: the desktop app is running')
check 'app running: no record changed' ((recHash) -eq $h)
check 'app running: state file not saved' ((Get-Content $statePath -Raw) -eq $stBefore)
setRec $g0.f 'isArchived' $false

"--- a record created while the app is running is neutral (off), so it can't count as a change next run"
$xs = @(ofSession $X); foreach ($r in $xs) { setRec $r.f 'isArchived' $true; setRec $r.f 'isStarred' $true }
$before = @($xs.f); Remove-Item -LiteralPath $xs[0].f; run '-AssumeAppRunning'
$new = @(ofSession $X | Where-Object { $before -notcontains $_.f -or $_.f -eq $xs[0].f })
check "app running: a record was recreated for the synthetic session ($($new.Count))" ($new.Count -ge 1)
check 'app running: the recreated record is neither archived nor pinned' (@($new | Where-Object { $_.arch -or $_.star }).Count -eq 0)
run; foreach ($r in (ofSession $X)) { setRec $r.f 'isArchived' $false; setRec $r.f 'isStarred' $false }; run
check 'reset: synthetic session unflagged' (@(ofSession $X | Where-Object { $_.arch -or $_.star }).Count -eq 0)

"--- a state file from before the record->session map: an unreadable record stops the whole save"
$st = state; $st.Remove('cli'); Set-Content $statePath ($st | ConvertTo-Json -Compress -Depth 5)
$stBefore = Get-Content $statePath -Raw; $keep1 = Get-Content -LiteralPath $g1.f -Raw
Set-Content -LiteralPath $g1.f 'not json' -NoNewline; run
check 'old state file: says the state is not saved' ($out -match 'is not saved this run')
check 'old state file: state file unchanged' ((Get-Content $statePath -Raw) -eq $stBefore)
Set-Content -LiteralPath $g1.f $keep1 -NoNewline; run
check 'old state file: the next good run adds the map' ([bool](state)['cli'])

"--- a record deleted between runs does not stop the save"
$gd = @(ofSession $G.Name | Where-Object { $_.f -ne $g0.f -and $_.f -ne $g1.f })[0]
if (-not $gd) { $gd = $g1 }
$keepD = Get-Content -LiteralPath $gd.f -Raw; $kd = key $gd.f
Remove-Item -LiteralPath $gd.f; run
check 'deleted record: no read warning' ($out -notmatch 'could not read')
check 'deleted record: dropped from the saved state' (-not (state)['isArchived'].ContainsKey($kd))
Set-Content -LiteralPath $gd.f $keepD -NoNewline; run

"--- corrupt state file: warn, change nothing, leave the file as is"
$good = Get-Content $statePath -Raw
setRec $g0.f 'isArchived' $true          # a real change that a healthy run would spread to every seat
Set-Content $statePath 'not json' -NoNewline
$h = recHash; run
check 'warns about the state file' (($out -match 'WARNING.*unreadable|unreadable.*not synced') -and ($out -match [regex]::Escape('.flag-state.json')))
check 'no record changed' ((recHash) -eq $h)
check 'state file left as is' ((Get-Content $statePath -Raw) -eq 'not json')
check 'corrupt state does not fail the run' ($rc -eq 0)
Set-Content $statePath $good -NoNewline; setRec $g0.f 'isArchived' $false

"--- missing ~\.claude-app-seats directory (a first run again: pinned on one seat -> pinned on all)"
setRec $g0.f 'isStarred' $true
Remove-Item -LiteralPath "$sb\home\.claude-app-seats" -Recurse -Force
run
check 'first run again: starred on every seat' (@(ofSession $G.Name | Where-Object { -not $_.star }).Count -eq 0)
check 'run succeeds' ($rc -eq 0 -and -not ($out -match 'rror|xception'))
check 'state file exists again' (Test-Path $statePath)

"--- a record the script clones from another seat carries the flags"
$RX = ofSession $X
if ($RX.Count -ge 2) {
  $a = $RX[0]; $b = $RX[1]
  Remove-Item -LiteralPath $b.f
  setRec $a.f 'isArchived' $true; setRec $a.f 'isStarred' $true
  run
  $S = ofSession $X
  $new = @($S | Where-Object { $_.f -ne $a.f -and (Split-Path $_.f) -eq (Split-Path $b.f) })
  check 'the deleted record was re-created' ($new.Count -eq 1 -and $S.Count -eq $RX.Count)
  check 'every record of the session archived + starred' (@($S | Where-Object { -not ($_.arch -and $_.star) }).Count -eq 0)
  $st = state
  check 'new record is in the saved baseline with its flags' ($new.Count -eq 1 -and $st['isArchived'][(key $new[0].f)] -eq $true -and $st['isStarred'][(key $new[0].f)] -eq $true)
} else { "SKIP clone scenario: fewer than 2 records of the synthetic session" }

"--- a record the script fabricates from the transcript carries the flags"
$RX = ofSession $X
if ($RX.Count -ge 1) {
  $a = $RX[0]
  foreach ($r in ($RX | Select-Object -Skip 1)) { Remove-Item -LiteralPath $r.f }
  setRec $a.f 'title' 'Session 2026-01-01 00:00'    # no well-titled source left -> pass 2 cannot clone, it fabricates
  run
  $S = ofSession $X
  $made = @($S | Where-Object { $_.f -ne $a.f })
  check "records were fabricated ($($made.Count))" ($made.Count -ge 1)
  check 'fabricated records are archived + starred' (@($made | Where-Object { -not ($_.arch -and $_.star) }).Count -eq 0)
  $st = state
  check 'fabricated records are in the saved baseline' (@($made | Where-Object { $st['isArchived'][(key $_.f)] -ne $true -or $st['isStarred'][(key $_.f)] -ne $true }).Count -eq 0)
}

"$fail failure(s)"
if ($fail -eq 0) { Remove-Item -LiteralPath $sb -Recurse -Force } else { "sandbox kept: $sb" }
exit [int]($fail -gt 0)
