<#
test-sidebar-sync-journey.ps1 -- the OWNER-run pre-merge journey for the sidebar pins sync (agent-dashboard issue #10, PR 1).

  RUN BY THE OWNER, in a plain PowerShell window, not from inside a Claude session. IT CLOSES AND REOPENS THE CLAUDE APP (through
  claude-app-rotator.ps1 --switch <seat> --relaunch) and asks you to click in the app. Nothing here is run by the build agent.

  pwsh -NoProfile -File windows\test-sidebar-sync-journey.ps1 [-From C] [-To D]

It prompts at each step; you click in the app and answer what you SEE. After every relaunch it waits (at most 5 min) for the sync's own
check (.sidebar-sync-work\<gen>\verify.txt for the right seat and gen), then reads the three pin stores for the chosen session and
prints them next to your answer. The result block at the end is what goes into the PR comment. The PR stays a draft until it passes.

Steps:
  1  picks a session that has a copy on both seats and is unpinned on both, and names it
  2  on -From you pin it; switch to -To; you confirm it is pinned there; the three stores agree
  3  on -To you unpin it; switch back to -From; you confirm it is unpinned there
  4  a session pinned on -From with no copy on -To: switch to -To; the report counts it (reach limit)
  5  you restore the original state (unpin what you pinned; re-pin nothing else); the script prints PASS/FAIL
#>
param([string]$From = 'C', [string]$To = 'D')

$ErrorActionPreference = 'Stop'
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
  # --relaunch closes the app (never force-kills it), switches, and reopens it. Returns the stamp the switch started at.
  $t0 = Get-Date
  Say "Switching to seat $seat (the app will close and reopen)..." 'Yellow'
  & pwsh -NoProfile -File $rot --switch $seat --relaunch
  Say "rotator exit code: $LASTEXITCODE" 'DarkGray'
  $t0
}
function Wait-Verify([string]$seat, [datetime]$since) {
  # the sync's own check for this switch: a gen dir created after $since whose verify.txt names the seat. Bounded at 5 min.
  $end = (Get-Date).AddMinutes(5)
  while ((Get-Date) -lt $end) {
    $g = Get-ChildItem -LiteralPath $work -Directory -ErrorAction SilentlyContinue | Where-Object { $_.CreationTime -ge $since.AddSeconds(-2) } | Sort-Object Name -Descending
    foreach ($d in $g) {
      $v = Join-Path $d.FullName 'verify.txt'
      if ((Test-Path $v) -and ((Get-Content $v -Raw) -match "seat $seat")) { return $d.FullName }
    }
    Start-Sleep -Seconds 5
  }
  return $null
}

Say "Journey: pins must follow you from seat $From to seat $To and back. Seats come from $seats." 'White'
Say 'Make sure nothing in the app is mid-task: it will be closed and reopened several times.' 'Yellow'
if (-not (Ask 'Start?')) { return }

# ---- step 0: both seats must be reachable; the app must be on -From
$info = (Invoke-Sync @('--journey', 'pick', '--leaving', $From, '--target', $To)) | ConvertFrom-Json
if (-not $info.pick) { Say 'No session has a copy on both seats and is unpinned on both; unpin one in the app and run again.' 'Red'; return }
$cli = $info.pick.cli
Say "Step 1. The test session is: ""$($info.pick.title)""   (it must be visible on both seats; the id is $cli)" 'White'

# ---- step 2: pin on From, switch to To
Say "Step 2a. In the app, on seat $From, PIN the session named above (right-click it in the sidebar > Pin). Then CLOSE NOTHING." 'White'
if (-not (Ask 'Is it pinned now?')) { return }
$t = Switch-To $To
$gdir = Wait-Verify $To $t
Record 'step 2: the check ran for the switch to the target' ($null -ne $gdir) $(if ($gdir) { $gdir } else { 'no verify.txt within 5 min' })
$s = Get-Stores $cli
Record 'step 2: the three pin stores all hold the pin on the target (Local Storage, IndexedDB, config)' ($s.'Local Storage' -and $s.IndexedDB -and $s.config) ($s | ConvertTo-Json -Compress)
Say "Step 2b. Look at the sidebar on seat ${To}: ""$($info.pick.title)"" should be in the PINNED section." 'White'
Record 'step 2: you SEE it pinned on the target' (Ask 'Is it pinned on this seat?')

# ---- step 3: unpin on To, switch back
Say "Step 3a. Now UNPIN it on seat $To." 'White'
if (-not (Ask 'Is it unpinned now?')) { return }
$t = Switch-To $From
$gdir = Wait-Verify $From $t
Record 'step 3: the check ran for the switch back' ($null -ne $gdir)
$s = Get-Stores $cli
Record 'step 3: the three pin stores all show it unpinned' (-not $s.'Local Storage' -and -not $s.IndexedDB -and -not $s.config) ($s | ConvertTo-Json -Compress)
Record 'step 3: you SEE it unpinned (not in the pinned section) on the origin seat' (Ask "Is ""$($info.pick.title)"" unpinned on seat $From now?")

# ---- step 4: a pin with no copy on the target is counted, not added
if ($info.nocopy) {
  Say "Step 4. ""$($info.nocopy.title)"" is pinned on $From but has no copy on $To. Switching to $To must REPORT it (reach limit), not fail." 'White'
  $t = Switch-To $To
  $gdir = Wait-Verify $To $t
  $rep = if ($gdir) { Get-Content (Join-Path $gdir 'report.txt') -Raw } else { '' }
  Record 'step 4: the report counts the session the target has no copy of' ($rep -match 'no copy on') ($rep -split "`n" | Where-Object { $_ -match 'no copy' } | Select-Object -First 1)
  $null = Switch-To $From
} else { Say 'Step 4: no session is pinned on the origin seat without a copy on the target; skipped.' 'DarkGray'; $results.Add('SKIP  step 4 (nothing to test with)') }

# ---- step 5: restore
Say "Step 5. Restore the original state: the test session should be UNPINNED on both seats (it was when we started)." 'White'
Record 'step 5: you restored the original state' (Ask 'Done?')
Say ''
Say '==== paste this block into the PR comment ====' 'White'
$results | ForEach-Object { Write-Host $_ }
Say $(if ($allOk) { 'JOURNEY PASSED' } else { 'JOURNEY FAILED' }) $(if ($allOk) { 'Green' } else { 'Red' })
