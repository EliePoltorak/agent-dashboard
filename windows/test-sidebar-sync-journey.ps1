<#
test-sidebar-sync-journey.ps1 -- the OWNER-run pre-merge journey for the sidebar pins sync (agent-dashboard issue #10, PR 1).

  RUN BY THE OWNER, in a plain PowerShell window, not from inside a Claude session. IT CLOSES AND REOPENS THE CLAUDE APP (through
  claude-app-rotator.ps1 --switch <seat> --relaunch) and asks you to click in the app. Nothing here is run by the build agent.

  pwsh -NoProfile -File windows\test-sidebar-sync-journey.ps1 [-From C] [-To D]

It prompts at each step; you click in the app and answer what you SEE. After every relaunch it waits (at most 5 min) for the sync's own
check (.sidebar-sync-work\<gen>\verify.txt for the right seat and gen), then reads the three pin stores for the chosen session and
prints them next to your answer. The result block at the end is what goes into the PR comment. The PR stays a draft until it passes.

Steps:
  0  initialization: one switch to -To and back to -From, so the origin seat HAS a sidebar baseline (a seat's first departure has none, and its edit would
     not be read); the journey checks that baseline before it asks you to pin anything
  1  picks a session that has a copy on both seats and is unpinned on both, and names it
  2  on -From you pin it; switch to -To; you confirm it is pinned there; the three stores agree
  3  on -To you unpin it; switch back to -From; you confirm it is unpinned there
  4  a session pinned on -From with no copy on -To: switch to -To; the report counts it (reach limit)
  5  you restore the original state (unpin what you pinned; re-pin nothing else); the script prints PASS/FAIL
#>
param([string]$From = 'C', [string]$To = 'D')

$ErrorActionPreference = 'Stop'
(Get-Process -Id $PID).PriorityClass = 'Idle'      # first: every child below inherits Idle (owner rule 10e)
$here = $PSScriptRoot
$rot = Join-Path $here 'claude-app-rotator.ps1'
$sync = Join-Path $here 'sidebar-sync.py'
$seats = Join-Path $env:USERPROFILE '.claude-app-seats'
$work = Join-Path $seats '.sidebar-sync-work'
$results = New-Object System.Collections.Generic.List[string]
$allOk = $true

function Say([string]$m, [string]$c = 'Cyan') { Write-Host $m -ForegroundColor $c }
function Ask([string]$q) { (Read-Host "$q [y/n]") -match '^(y|yes)$' }
function Record([string]$name, [bool]$ok, [string]$detail = '') {
  $script:allOk = $script:allOk -and $ok
  $line = "{0}  {1}{2}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, $(if ($detail) { "  ($detail)" } else { '' })
  $script:results.Add($line); Say $line $(if ($ok) { 'Green' } else { 'Red' })
}
function Invoke-Sync([string[]]$a) { (& py -3 -I $sync @a --seats $seats | Out-String).Trim() }
function Get-Stores([string]$cli) { (Invoke-Sync @('--journey', 'stores', '--target', $To, '--cli', $cli)) | ConvertFrom-Json }
function Switch-To([string]$seat) {
  # --relaunch closes the app (never force-kills it), switches, and reopens it. A nonzero exit stops the journey. -> the generation of THIS switch,
  # read from the rotator's own "sidebar gen:" line.
  Say "Switching to seat $seat (the app will close and reopen)..." 'Yellow'
  $out = & pwsh -NoProfile -File $rot --switch $seat --relaunch 2>&1 | ForEach-Object { $_.ToString() }
  $rc = $LASTEXITCODE
  $out | ForEach-Object { Write-Host $_ }
  if ($rc -ne 0) { Record "switch to $seat succeeded" $false "the rotator exited $rc; the journey stops here" ; throw "rotator exit $rc" }
  $m = $out | ForEach-Object { [regex]::Match($_, 'sidebar gen:\s*(\S+)') } | Where-Object { $_.Success } | Select-Object -First 1
  if (-not $m) { Record "switch to $seat reported its sidebar generation" $false 'no "sidebar gen:" line in the rotator output'; throw 'no generation' }
  $m.Groups[1].Value
}
function Wait-Verify([string]$seat, [string]$gen) {
  # THIS switch's own check: <work>\<gen>\verify.txt naming the seat and the gen, with a result of differences=0 (not superseded, not "could not
  # check"). Bounded at 5 min. -> @{ dir; ok; text }.
  $d = Join-Path $work $gen; $v = Join-Path $d 'verify.txt'
  $end = (Get-Date).AddMinutes(5)
  while ((Get-Date) -lt $end) {
    if (Test-Path $v) {
      $t = Get-Content $v -Raw
      $ok = ($t -match "seat $seat\b") -and ($t -match "gen $([regex]::Escape($gen))\b") -and ($t -match 'differences=0\b')
      return @{ dir = $d; ok = $ok; text = ($t -replace "\s+", ' ') }
    }
    Start-Sleep -Seconds 5
  }
  return @{ dir = $d; ok = $false; text = 'no verify.txt within 5 min' }
}
function Test-Stores($s, [string]$seat, [bool]$wantPinned) {
  # explicit booleans from ALL THREE stores, on the expected account/seat; an unreadable store ($null) is a failure, never "unpinned"
  if (-not $s -or $s.seat -ne $seat) { return $false }
  foreach ($k in 'Local Storage', 'IndexedDB', 'config') { if ($s.$k -isnot [bool] -or $s.$k -ne $wantPinned) { return $false } }
  $true
}

try {
Say "Journey: pins must follow you from seat $From to seat $To and back. Seats come from $seats." 'White'
Say 'Make sure nothing in the app is mid-task: it will be closed and reopened several times.' 'Yellow'
if (-not (Ask 'Start?')) { return }

# ---- step 0: initialization. The sync reads a seat's edits at its departure against the baseline written when the seat was entered. On a fresh setup
# the origin seat has none yet, so the first pin made on it would be skipped and step 2 would fail even though the sync works as designed.
Say "Step 0. Initialization: switching to seat $To and back to seat $From once, so seat $From gets its sidebar baseline. Do not touch the app." 'White'
$null = Switch-To $To
$g0 = Switch-To $From
$null = Wait-Verify $From $g0
$bj = try { Get-Content (Join-Path (Join-Path $seats $From) 'sidebar-baseline.json') -Raw | ConvertFrom-Json } catch { $null }
$hasBase = [bool]($bj -and $bj.created -and ($bj.PSObject.Properties.Name -contains 'pins'))
Record "step 0: seat $From has a sidebar baseline after the initialization switch" $hasBase $(if ($bj) { "gen $($bj.gen)" } else { 'no readable sidebar-baseline.json' })
if (-not $hasBase) { Say "Seat $From has no baseline: its first departure would not be read, so the journey stops. See the switch output above for the sidebar line." 'Red'; return }

# ---- step 1: both seats must be reachable; the app must be on -From
$info = (Invoke-Sync @('--journey', 'pick', '--leaving', $From, '--target', $To)) | ConvertFrom-Json
if (-not $info.pick) { Say 'No session has a copy on both seats and is unpinned on both; unpin one in the app and run again.' 'Red'; return }
$cli = $info.pick.cli
Say "Step 1. The test session is: ""$($info.pick.title)""   (it must be visible on both seats; the id is $cli)" 'White'

# ---- step 2: pin on From, switch to To
Say "Step 2a. In the app, on seat $From, PIN the session named above (right-click it in the sidebar > Pin). Then CLOSE NOTHING." 'White'
if (-not (Ask 'Is it pinned now?')) { return }
$gen = Switch-To $To
$v = Wait-Verify $To $gen
Record "step 2: the sync's own check for THIS switch (gen $gen) found no differences" $v.ok $v.text
$s = Get-Stores $cli
Record 'step 2: all three pin stores hold the pin on the target seat (Local Storage, IndexedDB, config)' (Test-Stores $s $To $true) ($s | ConvertTo-Json -Compress)
Say "Step 2b. Look at the sidebar on seat ${To}: ""$($info.pick.title)"" should be in the PINNED section." 'White'
Record 'step 2: you SEE it pinned on the target' (Ask 'Is it pinned on this seat?')

# ---- step 3: unpin on To, switch back
Say "Step 3a. Now UNPIN it on seat $To." 'White'
if (-not (Ask 'Is it unpinned now?')) { return }
$gen = Switch-To $From
$v = Wait-Verify $From $gen
Record "step 3: the sync's own check for THIS switch (gen $gen) found no differences" $v.ok $v.text
$s = Get-Stores $cli
Record 'step 3: all three pin stores explicitly show it unpinned on the origin seat' (Test-Stores $s $From $false) ($s | ConvertTo-Json -Compress)
Record 'step 3: you SEE it unpinned (not in the pinned section) on the origin seat' (Ask "Is ""$($info.pick.title)"" unpinned on seat $From now?")

# ---- step 4: a pin with no copy on the target is counted, not added
if ($info.nocopy) {
  Say "Step 4. ""$($info.nocopy.title)"" is pinned on $From but has no copy on $To. Switching to $To must REPORT it (reach limit), not fail." 'White'
  $gen = Switch-To $To
  $v = Wait-Verify $To $gen
  $rf = Join-Path $v.dir 'report.txt'
  $rep = if (Test-Path $rf) { Get-Content $rf -Raw } else { '' }
  # the report names each counted session as "no copy: <title> (<cli id>)": the SELECTED one must be in it, and the count must be at least 1
  $counted = ($rep -match "no copy on $To[^\n]*: ([1-9]\d*)") -and ($rep -match [regex]::Escape("($($info.nocopy.cli))"))
  Record 'step 4: the report counts THE session the target has no copy of (not just any count)' $counted ($rep -split "`n" | Where-Object { $_ -match 'no copy' } | Select-Object -First 3 | Out-String)
  $null = Switch-To $From
} else { Say 'Step 4: no session is pinned on the origin seat without a copy on the target; skipped.' 'DarkGray'; $results.Add('SKIP  step 4 (nothing to test with)') }

# ---- step 5: restore
Say "Step 5. Restore the original state: the test session should be UNPINNED on both seats (it was when we started)." 'White'
Record 'step 5: you restored the original state' (Ask 'Done?')
} catch { Say "Journey stopped: $_" 'Red'; $allOk = $false }
Say ''
Say '==== paste this block into the PR comment ====' 'White'
$results | ForEach-Object { Write-Host $_ }
Say $(if ($allOk) { 'JOURNEY PASSED' } else { 'JOURNEY FAILED' }) $(if ($allOk) { 'Green' } else { 'Red' })
