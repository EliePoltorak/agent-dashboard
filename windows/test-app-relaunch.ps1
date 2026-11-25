<#
test-app-relaunch.ps1 — mocked tests for claude-app-rotator.ps1 --switch <label> --relaunch.

Nothing real is closed, switched or launched: the profile folders are a temp dir, the process list is
injected (Get-AppProcs is shadowed), Stop-Process and Start-Process are shadowed to record calls, and
the arg-parse cases run in a child pwsh that exits before any action.

  pwsh -NoProfile -File windows/test-app-relaunch.ps1
#>
$ErrorActionPreference = 'Stop'
(Get-Process -Id $PID).PriorityClass = 'Idle'      # first: every child below (the arg-parse pwsh) inherits Idle
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { Write-Host "  PASS  $name" -ForegroundColor Green }
  else { $script:fail++; Write-Host "  FAIL  $name  $detail" -ForegroundColor Red }
}

$script_ = Join-Path $PSScriptRoot 'claude-app-rotator.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ("app-relaunch-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$keep = @{ USERPROFILE = $env:USERPROFILE; APPDATA = $env:APPDATA; LOCALAPPDATA = $env:LOCALAPPDATA }
$env:USERPROFILE = $root
$env:APPDATA = Join-Path $root 'AppData'
$env:LOCALAPPDATA = Join-Path $root 'Local'
New-Item -ItemType Directory -Path $env:APPDATA, $env:LOCALAPPDATA -Force | Out-Null
try {
  # --- arg parse, in a child process (exits before touching anything) ---
  $out = & pwsh -NoProfile -File $script_ --status --relaunch 2>&1 | Out-String
  Check '--relaunch without --switch exits 2' ($LASTEXITCODE -eq 2 -and $out -match 'with --switch') "rc=$LASTEXITCODE out=$out"
  $out = & pwsh -NoProfile -File $script_ --relaunch 2>&1 | Out-String
  Check '--relaunch alone exits 2' ($LASTEXITCODE -eq 2) "rc=$LASTEXITCODE"

  . $script_          # functions only (the dot-source guard returns before any mode runs)
  Check 'dot-source parsed no --relaunch' (-not $Relaunch)

  # --- injected processes ---
  $script:closed = @(); $script:killed = @(); $script:started = @()
  function New-FakeProc([int]$id, [bool]$win) {
    $o = [pscustomobject]@{ Id = $id; MainWindowHandle = $(if ($win) { [IntPtr]1 } else { [IntPtr]::Zero }) }
    $o | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value { $script:closed += $this.Id; $true }
    $o
  }
  function Stop-Process { $script:killed += 1 }
  function Start-Process { param($FilePath, $ArgumentList) $script:started += , @($FilePath, @($ArgumentList)) }
  $script:CloseWaitSec = 1

  # an app that ignores the close request: abort, never force-kill
  $script:procs = @((New-FakeProc 101 $true), (New-FakeProc 102 $false))
  function Get-AppProcs { $script:procs }
  $t0 = Get-Date
  $r = Close-AppGracefully
  Check 'stuck app: Close-AppGracefully returns $false' ($r -eq $false)
  Check 'stuck app: CloseMainWindow only on the windowed PID' (($script:closed -join ',') -eq '101') "closed=$($script:closed -join ',')"
  Check 'stuck app: nothing force-killed' ($script:killed.Count -eq 0)
  Check 'stuck app: waited about CloseWaitSec' (((Get-Date) - $t0).TotalSeconds -ge 0.9)

  # the whole --relaunch path with a stuck app, in a child pwsh: ABORTED, exit 1, nothing switched, nothing launched
  $seat = Join-Path $root '.claude-app-seats\B'
  New-Item -ItemType Directory -Path $seat -Force | Out-Null
  '{"lastKnownAccountUuid":"u-b"}' | Set-Content (Join-Path $seat 'config.json')
  $child = @"
. '$script_'
`$script:CloseWaitSec = 1
function Get-AppProcs { `$o = [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]1 }; `$o | Add-Member ScriptMethod CloseMainWindow { `$true }; `$o }
function Stop-Process { Write-Host 'KILLED' }
function Start-Process { Write-Host 'LAUNCHED' }
function Invoke-Switch { Write-Host 'SWITCHED' }
Invoke-SwitchRelaunch B
"@
  $out = & pwsh -NoProfile -Command $child 2>&1 | Out-String
  Check 'stuck app: --relaunch aborts with exit 1' ($LASTEXITCODE -eq 1 -and $out -match 'ABORTED') "rc=$LASTEXITCODE out=$out"
  Check 'stuck app: no switch, no kill, no launch' ($out -cnotmatch 'SWITCHED|KILLED|LAUNCHED') $out
  Check 'stuck app: the abort says to quit it from the tray and retry' ($out -match 'system tray' -and $out -match 'tray icon') $out

  # an app that closes: returns $true
  $script:closed = @()
  $script:procs = @((New-FakeProc 201 $true))
  function Get-AppProcs { $p = $script:procs; $script:procs = @(); $p }     # gone after the first look
  Check 'closing app: returns $true' ((Close-AppGracefully) -eq $true)
  Check 'not running: returns $true, nothing closed' ((Close-AppGracefully) -eq $true -and $script:closed.Count -eq 1)

  # success and failure relaunch, in a child pwsh with Invoke-Switch replaced
  foreach ($case in @(@{ name = 'switch ok'; body = "`$script:SwitchDone = `$true"; want = 'Relaunched the Claude app on seat B'; rc = 0 },
                      @{ name = 'switch refused'; body = 'exit 1'; want = 'Switch failed; relaunched the Claude app on its old login'; rc = 1 })) {
    $child = @"
. '$script_'
`$script:n = 0; `$script:StartWaitSec = 2
function Get-AppProcs { `$script:n++; if (`$script:n -eq 1 -or `$script:launched) { `$o = [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]1 }; `$o | Add-Member ScriptMethod CloseMainWindow { `$true }; `$o } }
function Start-Process { param(`$FilePath) `$script:launched = `$true; Write-Host "LAUNCHED `$FilePath" }
function Find-AppLauncher { @{ file = 'fake-claude.exe'; args = @() } }
function Invoke-Switch { $($case.body) }
Invoke-SwitchRelaunch B
"@
    $out = & pwsh -NoProfile -Command $child 2>&1 | Out-String
    Check "$($case.name): exit $($case.rc), relaunched" ($LASTEXITCODE -eq $case.rc -and $out -match 'LAUNCHED fake-claude.exe' -and $out -match [regex]::Escape($case.want)) "rc=$LASTEXITCODE out=$out"
  }

  # switch ok but the app cannot be reopened (no launcher found): exit 3 and a line that says the switch stood, not a plain success
  $child = @"
. '$script_'
`$script:n = 0; `$script:StartWaitSec = 2
function Get-AppProcs { `$script:n++; if (`$script:n -eq 1 -or `$script:launched) { `$o = [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]1 }; `$o | Add-Member ScriptMethod CloseMainWindow { `$true }; `$o } }
function Start-Process { param(`$FilePath) `$script:launched = `$true; Write-Host "LAUNCHED `$FilePath" }
function Find-AppLauncher { `$null }
function Invoke-Switch { `$script:SwitchDone = `$true }
Invoke-SwitchRelaunch B
"@
  $out = & pwsh -NoProfile -Command $child 2>&1 | Out-String
  Check 'switch ok, relaunch failed: exit 3, says the switch stood' ($LASTEXITCODE -eq 3 -and $out -match 'Switched to seat B, but the Claude app could not be reopened' -and $out -notmatch 'LAUNCHED') "rc=$LASTEXITCODE out=$out"

  # switch refused AND the app cannot be reopened: the refusal's exit code, and a last line that still says the switch failed
  $child = @"
. '$script_'
`$script:n = 0; `$script:StartWaitSec = 2
function Get-AppProcs { `$script:n++; if (`$script:n -eq 1 -or `$script:launched) { `$o = [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]1 }; `$o | Add-Member ScriptMethod CloseMainWindow { `$true }; `$o } }
function Find-AppLauncher { `$null }
function Invoke-Switch { Write-Host 'REFUSED: seat B'; exit 1 }
Invoke-SwitchRelaunch B
"@
  $out = & pwsh -NoProfile -Command $child 2>&1 | Out-String
  $last = @($out -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^\s' })[-1]
  Check 'switch refused, reopen failed: exit 1, last line says the switch failed' ($LASTEXITCODE -eq 1 -and $last -match '^Switch failed') "rc=$LASTEXITCODE last=$last"

  # launcher: Squirrel stub first, then Update.exe --processStart, else none
  $sq = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
  New-Item -ItemType Directory -Path $sq -Force | Out-Null
  function Get-AppxPackage { $null }
  Check 'no install: no launcher' ($null -eq (Find-AppLauncher))
  'x' | Set-Content (Join-Path $sq 'Update.exe')
  $l = Find-AppLauncher
  Check 'Update.exe --processStart claude.exe' ($l.file -eq (Join-Path $sq 'Update.exe') -and ($l.args -join ' ') -eq '--processStart claude.exe')
  'x' | Set-Content (Join-Path $sq 'claude.exe')
  $l = Find-AppLauncher
  Check 'Squirrel stub preferred' ($l.file -eq (Join-Path $sq 'claude.exe') -and $l.args.Count -eq 0)
  $script:started = @()
  Check 'Start-ClaudeApp launches the stub' ((Start-ClaudeApp) -and $script:started.Count -eq 1 -and $script:started[0][0] -eq (Join-Path $sq 'claude.exe'))

  # the app must not be started at this shell's Idle class: Normal while Start-Process runs, the old class restored after (even when it throws)
  function Start-Process { param($FilePath, $ArgumentList) $script:classAtStart = "$((Get-Process -Id $PID).PriorityClass)" }
  Check 'test shell is Idle' ("$((Get-Process -Id $PID).PriorityClass)" -eq 'Idle')
  $script:classAtStart = $null
  Check 'Start-ClaudeApp from an Idle shell: Start-Process runs at Normal' ((Start-ClaudeApp) -and $script:classAtStart -eq 'Normal') "class=$($script:classAtStart)"
  Check 'Start-ClaudeApp restores Idle afterwards' ("$((Get-Process -Id $PID).PriorityClass)" -eq 'Idle')
  function Start-Process { param($FilePath, $ArgumentList) throw 'no such launcher' }
  Check 'a failed launch returns $false and still restores Idle' ((-not (Start-ClaudeApp 6>$null)) -and "$((Get-Process -Id $PID).PriorityClass)" -eq 'Idle')
  # (a real launched child is not started here: it would run at Normal, and every test process stays at Idle. The mocked Start-Process above
  # already proves Start-Process runs while this shell is at Normal, which is the class a child inherits.)

  # ======================= sidebar pins sync (agent-dashboard #10): the rotator's part =======================
  # Each scenario is a child pwsh with its own temp profile root (USERPROFILE/APPDATA), the rotator's functions dot-sourced, history sync and the
  # box publish replaced, and a STUB in place of python that writes the files sidebar-sync.py would (the engine itself is tested by
  # test-sidebar-sync.py). The real Move/robocopy/Start-Process run, on temp dirs.
  $stub = Join-Path $root 'stage-stub.ps1'
  @'
param([Parameter(ValueFromRemainingArguments=$true)]$a)
function Arg($n) { $a[[array]::IndexOf($a, $n) + 1] }
$gen = Arg '--gen'; $seats = Arg '--seats'; $app = Arg '--app'; $target = Arg '--target'; $leaving = Arg '--leaving'
$g = Join-Path $seats ".sidebar-sync-work\$gen"
Add-Content $env:STUB_LOG ("STAGE leaving=$leaving target=$target gen=$gen baseline=" + (Get-Content (Join-Path $seats "$target\sidebar-baseline.json") -Raw -ErrorAction SilentlyContinue))
if ($env:STUB_MODE -eq 'sleep') { $PID | Set-Content $env:STUB_PIDFILE; Start-Sleep -Seconds 120; exit 0 }
if ($env:STUB_MODE -eq 'exit1') { exit 1 }
New-Item -ItemType Directory -Path $g -Force | Out-Null
if ($env:STUB_MODE -eq 'staged') {
  foreach ($rel in 'Local Storage\leveldb', 'IndexedDB\https_claude.ai_0.indexeddb.leveldb') {
    New-Item -ItemType Directory -Path (Join-Path $g $rel) -Force | Out-Null
    'STAGED' | Set-Content (Join-Path $g "$rel\marker.txt")
  }
  '{"valid":true,"gen":"' + $gen + '","pins":["staged"],"manifest":{"ls":1,"idb":1}}' | Set-Content (Join-Path $g 'baseline.json')
}
'{"valid":true,"gen":"' + $gen + '","pins":["stash"],"manifest":{"ls":1,"idb":1}}' | Set-Content (Join-Path $g 'baseline-stash.json')
'{"version":1,"gen":"' + $gen + '","pins":{"cliX":true}}' | Set-Content (Join-Path $g 'state.json')
$lines = foreach ($d in Get-ChildItem $seats -Directory | Where-Object { $_.Name -notmatch '^\.' }) {
  $cp = Join-Path $d.FullName 'sidebar-departure.json'
  if (Test-Path $cp) { "$($d.Name)`t$((Get-FileHash $cp -Algorithm SHA256).Hash)" }
}
if ($lines) { $lines | Set-Content (Join-Path $g 'consumed.txt') }
if ($env:STUB_CONFIG -and $env:STUB_CONFIG -ne 'refused') {
  $live = Join-Path $app 'claude_desktop_config.json'
  $sha = if ($env:STUB_CONFIG -eq 'badhash') { 'DEADBEEF' } else { (Get-FileHash $live -Algorithm SHA256).Hash }
  $pair = if ($env:STUB_MODE -eq 'staged') { 'staged' } else { 'stash' }
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"new":true}'))
  ('{"sha256":"' + $sha + '","pair":"' + $pair + '","b64":"' + $b64 + '"}') | Set-Content (Join-Path $g 'config.json')
}
$n = if ($env:STUB_MODE -eq 'staged') { 1 } else { 0 }
$rg = if ($env:STUB_RESULT -eq 'wronggen') { 'some-other-gen' } else { $gen }
$rp = if ($env:STUB_MODE -eq 'staged') { 'staged' } else { 'stash' }
$co = if ($env:STUB_CONFIG -eq 'refused') { 'refused: config not changed (boom)' } elseif ($env:STUB_CONFIG) { 'prepared' } else { 'match' }
('{"status":"' + $(if ($n) { 'synced' } else { 'nothing' }) + '","n":' + $n + ',"reason":"","target":"' + $target + '","gen":"' + $rg + '","pair":"' + $rp + '","config":"' + $co + '","config_pair":"' + $rp + '"}') | Set-Content (Join-Path $g 'result.json')
'report' | Set-Content (Join-Path $g 'report.txt')
'done'
'@ | Set-Content $stub

  $sleeper = Join-Path $root 'sleeper.ps1'
  '$PID | Set-Content $env:SLEEPER_PIDFILE; Start-Sleep -Seconds 45' | Set-Content $sleeper

  function New-Scenario([string]$name, [bool]$legacyTarget = $false) {
    $sc = Join-Path $root $name
    $st = Join-Path $sc '.claude-app-seats'; $app = Join-Path $sc 'AppData\Claude'
    function Put($p, $t) { New-Item -ItemType Directory -Path (Split-Path $p) -Force | Out-Null; Set-Content -LiteralPath $p -Value $t }
    $ls = 'Local Storage\leveldb'; $idb = 'IndexedDB\https_claude.ai_0.indexeddb.leveldb'
    foreach ($m in @(@('C', 'uc', 'C-stash'), @('D', 'ud', 'D-stash'))) {
      $d = Join-Path $st $m[0]
      if (-not ($legacyTarget -and $m[0] -eq 'D')) { Put (Join-Path $d 'owner-uuid.txt') $m[1] }
      if (-not ($legacyTarget -and $m[0] -eq 'D')) { Put (Join-Path $d 'config.json') ('{"lastKnownAccountUuid":"' + $m[1] + '"}') }
      else { Put (Join-Path $d 'config.json') '{"lastKnownAccountUuid":"ud"}' }
      Put (Join-Path $d "$ls\marker.txt") $m[2]; Put (Join-Path $d "$idb\marker.txt") $m[2]
      Put (Join-Path $d 'Session Storage\marker.txt') $m[2]; Put (Join-Path $d 'Network\marker.txt') $m[2]
    }
    Put (Join-Path $app 'config.json') '{"lastKnownAccountUuid":"uc"}'
    Put (Join-Path $app "$ls\marker.txt") 'live-C'; Put (Join-Path $app "$idb\marker.txt") 'live-C'
    Put (Join-Path $app 'Session Storage\marker.txt') 'live-C'; Put (Join-Path $app 'Network\marker.txt') 'live-C'
    Put (Join-Path $app 'claude_desktop_config.json') '{"old":true}'
    Set-Content (Join-Path $st '.active') 'C'
    $sc
  }
  $gen = '20261125-120000'
  function Invoke-Scenario([string]$sc, [string]$body, [hashtable]$vars = @{}) {
    $pre = @"
`$env:USERPROFILE = '$sc'; `$env:APPDATA = '$sc\AppData'; `$env:LOCALAPPDATA = '$sc\Local'
. '$script_'
`$stamp = '$gen'
`$script:StartWaitSec = 2
if (-not `$env:REAL_GEN) { function New-SwitchGen { `$g = '$gen'; `$null = New-Item -ItemType Directory -Path (Join-Path `$SidebarWork `$g) -Force; `$g } }
function Invoke-AppHistorySync {}
function Invoke-AppSeatPublish {}
if (-not `$env:REAL_VERIFY) { function Start-SidebarVerify { param(`$l, `$g) Write-Host "VERIFY `$l `$g" } }
function Find-AppLauncher { @{ file = 'fake-claude.exe'; args = @() } }
function Start-Process {
  param(`$FilePath, `$ArgumentList, [switch]`$PassThru, `$WindowStyle, `$RedirectStandardOutput, `$RedirectStandardError)
  if (`$FilePath -eq 'fake-claude.exe') { `$script:launched = `$true; Write-Host 'LAUNCHED' } else { Microsoft.PowerShell.Management\Start-Process @PSBoundParameters }
}
function Get-AppProcs { if (`$script:launched) { [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]::Zero } } }
function Get-SidebarSyncCommand { @{ file = 'pwsh'; args = @('-NoProfile', '-File', '$stub') } }
"@
    $saved = @{}
    foreach ($k in $vars.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
    try { $o = & pwsh -NoProfile -Command ($pre + "`n" + $body) 2>&1 | Out-String; @{ rc = $LASTEXITCODE; out = $o } }
    finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
  }
  function Rdf($p) { if (Test-Path -LiteralPath $p) { (Get-Content -LiteralPath $p -Raw).Trim() } else { '<missing>' } }
  $ls = 'Local Storage\leveldb\marker.txt'; $idb = 'IndexedDB\https_claude.ai_0.indexeddb.leveldb\marker.txt'

  # 1) staged pair in: the staged databases are the copy-in source; baseline copied only after the install; state published; checkpoint consumed
  $sc = New-Scenario 's1'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_CONFIG = '1' }
  $st = Join-Path $sc '.claude-app-seats'; $app = Join-Path $sc 'AppData\Claude'
  Check 'staged: the staged pair is the copy-in source for both sidebar dirs' ((Rdf "$app\$ls") -eq 'STAGED' -and (Rdf "$app\$idb") -eq 'STAGED') "rc=$($r.rc) out=$($r.out)"
  Check 'staged: the other login dirs come from the stash' ((Rdf "$app\Network\marker.txt") -eq 'D-stash' -and (Rdf "$app\Session Storage\marker.txt") -eq 'D-stash')
  Check 'staged: the departure checkpoint of the leaving seat was written after the re-capture (the stage read it; the publish then consumed it)' ((Rdf "$st\.sidebar-sync-work\$gen\consumed.txt") -match '^C\s' -and (Rdf "$st\C\Local Storage\leveldb\marker.txt") -eq 'live-C') (Rdf "$st\.sidebar-sync-work\$gen\consumed.txt")
  $log = Rdf $env:STUB_LOG
  Check 'staged: the stage ran for the right seats, with the target baseline INVALID while it ran' ($log -match 'leaving=C target=D' -and $log -match '"valid":false') $log
  Check 'staged: the target baseline is the staged one, valid, carrying the gen' ((Rdf "$st\D\sidebar-baseline.json") -match '"pins":\["staged"\]' -and (Rdf "$st\D\sidebar-baseline.json") -match $gen)
  Check 'staged: sidebar-installed.json records the live creation times' ((Rdf "$st\D\sidebar-installed.json") -match '"created":\{"ls":\d+,"idb":\d+\}' -or (Rdf "$st\D\sidebar-installed.json") -match '"idb":\d+')
  Check 'staged: state published, consumed checkpoint deleted (hash matched)' ((Rdf "$st\.sidebar-sync-state.json") -match 'cliX' -and -not (Test-Path "$st\C\sidebar-departure.json")) (Get-ChildItem $st -Force | Out-String)
  Check 'staged: config committed by the rotator, preimage saved' ((Rdf "$app\claude_desktop_config.json") -eq '{"new":true}' -and (Rdf "$st\.sidebar-sync-backups\$gen\claude_desktop_config.json") -eq '{"old":true}') (Rdf "$app\claude_desktop_config.json")
  Check 'staged: verify was scheduled for the new gen after a valid baseline' ($r.out -match "VERIFY D $gen")
  Check 'staged: .active moved, the previous login is backed up' ((Rdf "$st\.active") -eq 'D' -and (Rdf "$st\.swap-backups\$gen\Local Storage\leveldb\marker.txt") -eq 'live-C')
  Check 'staged: the last unindented line carries the sidebar result' ((@($r.out -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^\s' })[-1]) -match '^Now reopen the Claude desktop app\. Sidebar: synced 1 pins\.$') $r.out

  # 2) the checkpoint is written after a good re-capture only (a live database dir missing -> none)
  $sc = New-Scenario 's2'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  Remove-Item -LiteralPath (Join-Path $sc 'AppData\Claude\IndexedDB') -Recurse -Force
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG }
  Check 'no checkpoint when a live sidebar database is missing' (-not (Test-Path "$sc\.claude-app-seats\C\sidebar-departure.json")) $r.out
  $sc = New-Scenario 's2b'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  '{"valid":true,"gen":"g0","pins":["old"],"manifest":{"ls":1,"idb":1}}' | Set-Content "$sc\.claude-app-seats\C\sidebar-baseline.json"
  '{"created":{"ls":5,"idb":6}}' | Set-Content "$sc\.claude-app-seats\C\sidebar-installed.json"
  $r = Invoke-Scenario $sc "Write-DepartureCheckpoint 'C' (Get-LiveCreation)" @{}
  $cj = Get-Content "$sc\.claude-app-seats\C\sidebar-departure.json" -Raw | ConvertFrom-Json
  Check 'checkpoint = baseline + installed + created' ($cj.baseline.gen -eq 'g0' -and $cj.installed.created.ls -eq 5 -and $cj.created.ls -gt 0 -and $cj.created.idb -gt 0) $r.out
  '{"valid":false}' | Set-Content "$sc\.claude-app-seats\C\sidebar-baseline.json"
  $r = Invoke-Scenario $sc "Write-DepartureCheckpoint 'C' (Get-LiveCreation)" @{}
  Check 'an unconsumed checkpoint KEEPS its old baseline when refreshed (S72)' ((Get-Content "$sc\.claude-app-seats\C\sidebar-departure.json" -Raw | ConvertFrom-Json).baseline.gen -eq 'g0') $r.out

  # 3) stash pair when python produced no staged copy; baseline-stash used; config pair mismatch is not committed
  $sc = New-Scenario 's3'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG; STUB_CONFIG = '1' }
  $st = Join-Path $sc '.claude-app-seats'; $app = Join-Path $sc 'AppData\Claude'
  Check 'stash pair: the seat''s own databases go in, its stash baseline is recorded, a stash-pair config repair is committed' ((Rdf "$app\$ls") -eq 'D-stash' -and (Rdf "$st\D\sidebar-baseline.json") -match '"pins":\["stash"\]' -and (Rdf "$app\claude_desktop_config.json") -eq '{"new":true}') $r.out
  $sc = New-Scenario 's3b'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_CONFIG = 'badhash' }
  Check 'config refused after a staged install: the baseline goes invalid again and the note says partial, not synced' ((Rdf "$sc\.claude-app-seats\D\sidebar-baseline.json") -match '"valid":false' -and $r.out -match 'Sidebar: partial \(config not changed: it differs' -and $r.out -notmatch 'synced' -and $r.out -notmatch 'VERIFY') $r.out
  Check 'config refused when the live file is not the one that was read: left alone, reported' ((Rdf "$sc\AppData\Claude\claude_desktop_config.json") -eq '{"old":true}' -and (Rdf "$sc\.claude-app-seats\.sidebar-sync-work\$gen\report.txt") -match 'config not changed: it differs') (Rdf "$sc\.claude-app-seats\.sidebar-sync-work\$gen\report.txt")

  # 4) one staged copy failing: the stash PAIR and its baseline go in, a `pair: staged` config is NOT committed (S74); both failing: stop, no relaunch
  $sc = New-Scenario 's4'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $body = '$orig = ${function:Copy-Dir}; function Copy-Dir($s, $d) { & $orig $s $d; if ($s -like ''*sidebar-sync-work*IndexedDB*'') { $script:RobocopyRc = 8 } }' + "`nInvoke-Switch 'D'"
  $r = Invoke-Scenario $sc $body @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_CONFIG = '1' }
  $st = Join-Path $sc '.claude-app-seats'; $app = Join-Path $sc 'AppData\Claude'
  Check 'staged IndexedDB copy fails: BOTH sidebar dirs come from the stash, the baseline stays INVALID (the stage''s config outcome was for the staged pair)' ((Rdf "$app\$ls") -eq 'D-stash' -and (Rdf "$app\$idb") -eq 'D-stash' -and (Rdf "$st\D\sidebar-baseline.json") -match '"valid":false') $r.out
  Check 'staged copy failed: the staged-pair config is not committed (S74), the note says skipped' ((Rdf "$app\claude_desktop_config.json") -eq '{"old":true}' -and $r.out -match 'Sidebar: skipped \(the staged copy could not be installed') $r.out
  $sc = New-Scenario 's4b'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $body = '$orig = ${function:Copy-Dir}; function Copy-Dir($s, $d) { & $orig $s $d; if ($d -like ''*IndexedDB*'') { $script:RobocopyRc = 8 } }' + "`nInvoke-SwitchRelaunch 'D'"
  $r = Invoke-Scenario $sc ("function Get-AppProcs { if (`$script:launched -or `$script:n++ -lt 1) { [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]::Zero } } }`n" + $body) @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG }
  Check 'both sidebar copies fail: exit nonzero naming the backup, no relaunch' ($r.rc -eq 1 -and $r.out -match 'FAILED: could not copy the sidebar databases' -and $r.out -match 'swap-backups' -and $r.out -notmatch 'LAUNCHED' -and $r.out -match 'NOT reopened') "rc=$($r.rc) $($r.out)"

  # 5) stage over its time: that PID is stopped, nothing published, the checkpoint stays; the next switch consumes it (S73)
  $sc = New-Scenario 's5'; $env:STUB_LOG = Join-Path $sc 'stub.log'; $pidf = Join-Path $sc 'stub.pid'
  $t0 = Get-Date
  $r = Invoke-Scenario $sc "`$script:StageTimeoutSec = 25; Invoke-Switch 'D'" @{ STUB_MODE = 'sleep'; STUB_LOG = $env:STUB_LOG; STUB_PIDFILE = $pidf }
  $st = Join-Path $sc '.claude-app-seats'
  $spid = if (Test-Path $pidf) { [int](Rdf $pidf) } else { 0 }
  Check 'timed-out stage: the stub started (its PID is on record)' ($spid -gt 0)
  Start-Sleep -Milliseconds 500
  Check 'timed-out stage: that PID was stopped' (-not (Get-Process -Id $spid -ErrorAction SilentlyContinue)) "pid=$spid"
  if (Get-Process -Id $spid -ErrorAction SilentlyContinue) { Stop-Process -Id $spid }       # only the PID the stub wrote, and only if the check above failed
  Check 'timed-out stage: nothing published, the checkpoint is intact, the stash pair is installed with an INVALID baseline' (-not (Test-Path "$st\.sidebar-sync-state.json") -and (Test-Path "$st\C\sidebar-departure.json") -and (Rdf "$sc\AppData\Claude\$ls") -eq 'D-stash' -and (Rdf "$st\D\sidebar-baseline.json") -match '"valid":false') (Get-ChildItem $st -Force | Out-String)
  Check 'timed-out stage: the note says skipped with the reason and a report path' ($r.out -match 'Sidebar: skipped \(the stage did not finish in 25 s\) - see .*report\.txt') $r.out
  Check 'timed-out stage: no verify (the baseline is invalid)' ($r.out -notmatch 'VERIFY')
  $r = Invoke-Scenario $sc "Invoke-Switch 'C'" @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG }
  Check 'the next switch consumes the surviving checkpoints and publishes (S73)' ((Test-Path "$st\.sidebar-sync-state.json") -and -not (Test-Path "$st\C\sidebar-departure.json") -and (Test-Path "$st\D\sidebar-departure.json") -eq $false) (Get-ChildItem $st -Recurse -Filter 'sidebar-*' -Force | Out-String)

  # 6) a stage that fails (exit 1): the switch goes on with the stash pair, nothing published
  $sc = New-Scenario 's6'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'exit1'; STUB_LOG = $env:STUB_LOG }
  Check 'stage exit 1: switch completes on the stash pair, nothing published, note says the stage failed' ((Rdf "$sc\AppData\Claude\$ls") -eq 'D-stash' -and -not (Test-Path "$sc\.claude-app-seats\.sidebar-sync-state.json") -and $r.out -match 'Sidebar: skipped \(the stage failed \(exit 1\)\)') $r.out

  # 7) move-aside failure: what was moved goes back, nothing cleared, the old login is intact and the relaunch reopens it only once verified (S75)
  $sc = New-Scenario 's7'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $lockf = "$sc\AppData\Claude\Session Storage\marker.txt"
  $body = "`$fs = [IO.File]::Open('$lockf', 'Open', 'Read', 'None')`n" + "function Get-AppProcs { if (`$script:launched -or `$script:n++ -lt 1) { [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]::Zero } } }`ntry { Invoke-SwitchRelaunch 'D' } finally { `$fs.Dispose() }"
  $r = Invoke-Scenario $sc $body @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG }
  $app = "$sc\AppData\Claude"; $st = "$sc\.claude-app-seats"
  Check 'move-aside fails on the second dir: the first is moved back, live login intact, nothing cleared' ($r.rc -eq 1 -and $r.out -match 'REFUSED: could not move the current login' -and (Rdf "$app\$ls") -eq 'live-C' -and (Rdf "$app\Session Storage\marker.txt") -eq 'live-C' -and (Rdf "$st\.active") -eq 'C') "rc=$($r.rc) $($r.out)"
  Check 'move-aside refusal: the app is reopened on the old login only because it was verified intact' ($r.out -match 'LAUNCHED' -and $r.out -match 'Switch failed; relaunched the Claude app on its old login') $r.out

  # 8) same-seat switch stages nothing and swaps nothing (it used to reload the older stash over the live profile)
  $sc = New-Scenario 's8'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'C'" @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG }
  Check 'same-seat switch: live profile untouched, nothing staged, .active written, says so' ((Rdf "$sc\AppData\Claude\$ls") -eq 'live-C' -and -not (Test-Path $env:STUB_LOG) -and (Rdf "$sc\.claude-app-seats\.active") -eq 'C' -and $r.out -match 'nothing to swap' -and $r.out -match 'Sidebar: nothing to sync\.') $r.out

  # 9) the relaunch checks the live identity in both branches, its wait is bounded, the lock is released, exit 3 is kept (S68, S69, S75, S76)
  $sc = New-Scenario 's9'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $pre9 = "function Get-AppProcs { if (`$script:launched -or `$script:n++ -lt 1) { [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]::Zero } } }`nfunction Invoke-Switch { `$script:SwitchDone = `$true }`n"
  $r = Invoke-Scenario $sc ($pre9 + "Invoke-SwitchRelaunch 'D'") @{}
  Check 'switched, but the live login is not the target''s: not reopened, exit 3 (S68)' ($r.rc -eq 3 -and $r.out -notmatch 'LAUNCHED' -and $r.out -match 'could not be reopened') "rc=$($r.rc) $($r.out)"
  Check 'the seat lock is released afterwards' (-not (Test-Path "$sc\.claude-app-seats\.seat-write.lock"))
  '{"lastKnownAccountUuid":"ud"}' | Set-Content "$sc\AppData\Claude\config.json"
  $r = Invoke-Scenario $sc ($pre9 + "Invoke-SwitchRelaunch 'D'") @{}
  Check 'switched and the live login is the target''s: reopened on it' ($r.rc -eq 0 -and $r.out -match 'LAUNCHED' -and $r.out -match 'Relaunched the Claude app on seat D') "rc=$($r.rc) $($r.out)"
  $t0 = Get-Date
  $r = Invoke-Scenario $sc ($pre9 + "function Get-AppProcs { if (`$script:n++ -lt 1) { [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]::Zero } } }`nInvoke-SwitchRelaunch 'D'") @{}
  Check 'the app never appears: the wait is bounded (2 s here, 30 s in use) and exit 3 is kept' ($r.rc -eq 3 -and $r.out -match 'could not be reopened' -and $r.out -match 'LAUNCHED') "rc=$($r.rc) $($r.out)"
  $pre9r = "function Get-AppProcs { if (`$script:launched -or `$script:n++ -lt 1) { [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]::Zero } } }`nfunction Invoke-Switch { Write-Host 'REFUSED: x'; exit 1 }`n"
  $r = Invoke-Scenario $sc ($pre9r + "`$script:ProfileIntact = `$false`nInvoke-SwitchRelaunch 'D'") @{}
  Check 'refused with the old profile NOT verified intact: not reopened' ($r.rc -eq 1 -and $r.out -notmatch 'LAUNCHED' -and (@($r.out -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^\s' })[-1]) -match '^Switch failed') "rc=$($r.rc) $($r.out)"
  $r = Invoke-Scenario $sc ($pre9r + "Invoke-SwitchRelaunch 'D'") @{}
  Check 'refused and the old login is still the live one: reopened' ($r.rc -eq 1 -and $r.out -match 'LAUNCHED') "rc=$($r.rc) $($r.out)"
  # legacy capture (no owner-uuid.txt) and an empty seat chosen to reach the sign-in prompt still reopen (S76)
  $sc = New-Scenario 's9b' $true
  $r = Invoke-Scenario $sc ($pre9 + "Invoke-SwitchRelaunch 'D'") @{}
  Check 'legacy seat (no owner-uuid.txt): still reopened' ($r.rc -eq 0 -and $r.out -match 'LAUNCHED') "rc=$($r.rc) $($r.out)"
  New-Item -ItemType Directory -Path "$sc\.claude-app-seats\E" -Force | Out-Null
  $r = Invoke-Scenario $sc ($pre9 + "Invoke-SwitchRelaunch 'E'") @{}
  Check 'empty seat chosen to reach the sign-in prompt: still reopened' ($r.rc -eq 0 -and $r.out -match 'LAUNCHED') "rc=$($r.rc) $($r.out)"

  # 10) the verify spawn: both streams redirected to files, started detached through cmd.exe, and it does NOT keep the caller's stdout pipe open
  $sc = New-Scenario 's10'; $pidf = Join-Path $sc 'sleeper.pid'; New-Item -ItemType Directory -Path "$sc\.claude-app-seats\.sidebar-sync-work\$gen" -Force | Out-Null
  $body = "function Start-Process { param(`$FilePath, `$ArgumentList, `$WindowStyle) Write-Host `"SPAWN `$FilePath :: `$ArgumentList :: `$WindowStyle`" }`nfunction Get-SidebarSyncCommand { @{ file = 'C:\py\python.exe'; args = @('-I', 'C:\r\sidebar-sync.py') } }`nStart-SidebarVerify 'D' '$gen'"
  $pre = (Invoke-Scenario $sc $body @{ REAL_VERIFY = '1' }).out
  $r = Invoke-Scenario $sc ($body -replace 'function Start-Process.*?\n', '') @{}
  Check 'verify spawn: cmd.exe, hidden, --verify with gen and target, stdout AND stderr redirected to files in the gen dir' ($pre -match 'SPAWN cmd.exe' -and $pre -match 'Hidden' -and $pre -match '--verify" "--gen" "20261125-120000" "--target" "D"' -and $pre -match '> "[^"]*verify\.out"' -and $pre -match '2> "[^"]*verify\.err"') $pre
  $t0 = Get-Date
  $body2 = "function Get-SidebarSyncCommand { @{ file = 'pwsh'; args = @('-NoProfile', '-File', '$sleeper') } }`nStart-SidebarVerify 'D' '$gen'"
  $r = Invoke-Scenario $sc $body2 @{ SLEEPER_PIDFILE = $pidf; REAL_VERIFY = '1' }
  $alive = $false
  for ($i = 0; $i -lt 60 -and -not (Test-Path $pidf); $i++) { Start-Sleep -Milliseconds 500 }
  if (Test-Path $pidf) { $spid = [int](Rdf $pidf); $alive = [bool](Get-Process -Id $spid -ErrorAction SilentlyContinue); if ($alive) { Stop-Process -Id $spid } }
  Check 'verify spawn: the caller''s output pipe closed while the spawned child was still running (it holds no inherited pipe)' ($alive -and $r.out -notmatch 'not started') "alive=$alive out=$($r.out)"

  # 11) review round 1: unique generation, result identity, ONE lock for --relaunch, checks under the lock, partial installs
  $sc = New-Scenario 'r1a'
  $body = "`$script:rs = 0; function Get-Random { param(`$Maximum) `$script:rs++; if (`$script:rs -le 2) { 5 } else { 6 } }`n`$g1 = New-SwitchGen; `$g2 = New-SwitchGen; Write-Host `"GENS `$g1 `$g2`"; Write-Host ('EXIST ' + (Test-Path (Join-Path `$SidebarWork `$g1)) + ' ' + (Test-Path (Join-Path `$SidebarWork `$g2)))"
  $r = Invoke-Scenario $sc $body @{ REAL_GEN = '1' }
  $m = [regex]::Match($r.out, 'GENS (\S+) (\S+)')
  Check 'two switches in the same second get different generations, both directories created (a collision is retried)' ($m.Success -and $m.Groups[1].Value -ne $m.Groups[2].Value -and $m.Groups[1].Value -match '^\d{8}-\d{6}-[0-9a-f]{8}$' -and $r.out -match 'EXIST True True') $r.out
  $sc = New-Scenario 'r1b'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_RESULT = 'wronggen' }
  Check 'a stage result naming another generation: the staged pair is NOT installed, nothing published or consumed, skipped' ((Rdf "$sc\AppData\Claude\$ls") -eq 'D-stash' -and -not (Test-Path "$sc\.claude-app-seats\.sidebar-sync-state.json") -and $r.out -match 'Sidebar: skipped \(the stage result does not belong to this switch\)') $r.out
  $sc = New-Scenario 'r1c'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; REAL_GEN = '1' }
  $gl = @(Get-ChildItem "$sc\.claude-app-seats\.sidebar-sync-work" -Directory)
  Check 'the real allocator names the work dir, the swap backup and the verify call with the same generation' ($gl.Count -eq 1 -and $gl[0].Name -match '^20\d{6}-\d{6}-[0-9a-f]{8}$' -and (Test-Path "$sc\.claude-app-seats\.swap-backups\$($gl[0].Name)") -and $r.out -match "VERIFY D $($gl[0].Name)" -and $r.out -match "sidebar gen: $($gl[0].Name)") $r.out

  # ONE seat lock from before the app is closed to after it is up again; Invoke-Switch neither takes it again nor releases it early
  $sc = New-Scenario 'r1d'
  '{"lastKnownAccountUuid":"ud"}' | Set-Content "$sc\AppData\Claude\config.json"      # the stubbed switch leaves the target's login live
  $lk = '$SeatRoot\.seat-write.lock'
  $body = "function Get-AppProcs { if (`$script:launched -or `$script:n++ -lt 1) { Write-Host ('LOCK_IN_PROCS=' + (Test-Path `"$lk`")); [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]::Zero } } }`n" +
          "function Invoke-Switch { Write-Host ('LOCK_IN_SWITCH=' + (Test-Path `"$lk`")); `$script:SwitchDone = `$true }`n" +
          "function Start-ClaudeApp { Write-Host ('LOCK_AT_LAUNCH=' + (Test-Path `"$lk`")); `$script:launched = `$true; `$true }`n" +
          "Invoke-SwitchRelaunch 'D'; Write-Host ('LOCK_AFTER=' + (Test-Path `"$lk`"))"
  $r = Invoke-Scenario $sc $body @{}
  Check 'relaunch: the lock is held while the app is looked at and closed, in the switch, at the launch and the wait, and gone afterwards' ($r.out -match 'LOCK_IN_PROCS=True' -and $r.out -match 'LOCK_IN_SWITCH=True' -and $r.out -match 'LOCK_AT_LAUNCH=True' -and $r.out -match 'LOCK_AFTER=False' -and $r.out -notmatch '=False[^`n]*LOCK_IN_SWITCH') $r.out
  $sc = New-Scenario 'r1e'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $body = "`$script:ac = 0; function Assert-Closed { `$script:ac++; if (`$script:ac -ge 2) { Write-Host 'BLOCKED-UNDER-LOCK'; exit 1 } }`nInvoke-Switch 'D'"
  $r = Invoke-Scenario $sc $body @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG }
  Check 'the app is running by the time the lock is held: nothing is re-captured, staged, published or swapped' ($r.rc -eq 1 -and $r.out -match 'BLOCKED-UNDER-LOCK' -and (Rdf "$sc\.claude-app-seats\C\Local Storage\leveldb\marker.txt") -eq 'C-stash' -and -not (Test-Path $env:STUB_LOG) -and -not (Test-Path "$sc\.claude-app-seats\C\sidebar-departure.json") -and -not (Test-Path "$sc\.claude-app-seats\.swap-backups") -and -not (Test-Path "$sc\.claude-app-seats\.seat-write.lock")) "rc=$($r.rc) $($r.out)"
  $sc = New-Scenario 'r1f'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $body = "`$script:tc = 0; `$orig = ${function:Get-TargetSnapshot}; function Get-TargetSnapshot(`$l, `$s) { `$script:tc++; if (`$script:tc -ge 2) { Write-Host 'REFUSED-UNDER-LOCK'; exit 1 }; & `$orig `$l `$s }`nInvoke-Switch 'D'"
  $r = Invoke-Scenario $sc $body @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG }
  Check 'the target snapshot check is repeated under the lock, before anything is re-captured or staged' ($r.rc -eq 1 -and $r.out -match 'REFUSED-UNDER-LOCK' -and -not (Test-Path $env:STUB_LOG) -and (Rdf "$sc\.claude-app-seats\C\Local Storage\leveldb\marker.txt") -eq 'C-stash') "rc=$($r.rc) $($r.out)"
  $sc = New-Scenario 'r1g'
  $r = Invoke-Scenario $sc "function Assert-Closed { Write-Host 'app is running'; exit 1 }`nInvoke-SwitchRelaunch 'D'" @{}
  Check 'relaunch: a lock that cannot be taken is reported before the app is touched' ($r.rc -eq 1 -and $r.out -match 'app is running' -and -not (Test-Path "$sc\.claude-app-seats\.seat-write.lock")) $r.out

  # partial installs: no config commit without a saved baseline; a failed commit makes the baseline invalid again
  $sc = New-Scenario 'r1h'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $body = "`$orig = `${function:Write-JsonAtomic}; function Write-JsonAtomic(`$path, `$obj) { if (`$path -like '*sidebar-baseline.json' -and `$obj.ContainsKey('pins')) { throw 'disk full' }; & `$orig `$path `$obj }`nInvoke-Switch 'D'"
  $r = Invoke-Scenario $sc $body @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_CONFIG = '1' }
  Check 'the baseline could not be saved: the shared config is NOT replaced, the baseline stays invalid, the note says partial' ((Rdf "$sc\AppData\Claude\claude_desktop_config.json") -eq '{"old":true}' -and (Rdf "$sc\.claude-app-seats\D\sidebar-baseline.json") -match '"valid":false' -and $r.out -match 'Sidebar: partial \(config not changed: the baseline was not saved\)' -and $r.out -notmatch 'VERIFY') $r.out
  $sc = New-Scenario 'r1i'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG; STUB_CONFIG = 'badhash' }
  Check 'a stash-pair install that needed the config and could not get it: partial, baseline invalid again' ((Rdf "$sc\.claude-app-seats\D\sidebar-baseline.json") -match '"valid":false' -and $r.out -match 'Sidebar: partial' -and $r.out -notmatch 'VERIFY') $r.out
  $sc = New-Scenario 'r1j'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_CONFIG = '1' }
  Check 'config committed after the baseline was saved: synced, baseline valid, verify scheduled' ((Rdf "$sc\AppData\Claude\claude_desktop_config.json") -eq '{"new":true}' -and (Rdf "$sc\.claude-app-seats\D\sidebar-baseline.json") -match '"valid":true' -and $r.out -match 'Sidebar: synced 1 pins' -and $r.out -match 'VERIFY D') $r.out

  # 12) review round 2: explicit config outcome and baseline order, capture under the lock, history/heartbeat around the relaunch lock
  $sc = New-Scenario 'r2a'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_CONFIG = 'refused' }
  Check 'a config the stage REFUSED to read (explicit outcome, not an omitted file): not replaced, baseline stays invalid, partial, no verify' ((Rdf "$sc\AppData\Claude\claude_desktop_config.json") -eq '{"old":true}' -and (Rdf "$sc\.claude-app-seats\D\sidebar-baseline.json") -match '"valid":false' -and $r.out -match 'Sidebar: partial \(config not changed \(refused: config not changed \(boom\)\)\)' -and $r.out -notmatch 'VERIFY') $r.out
  $sc = New-Scenario 'r2b'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $body = "function Commit-SidebarConfig { `$b = Get-Content (Join-Path `$SeatRoot 'D\sidebar-baseline.json') -Raw; Write-Host ('BASELINE_AT_COMMIT ' + `$b); exit 5 }`nInvoke-Switch 'D'"
  $r = Invoke-Scenario $sc $body @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_CONFIG = '1' }
  Check 'interrupted between the candidate baseline and the config commit: the candidate is on disk but INVALID (carries the pins, valid:false), and stays so' ($r.rc -eq 5 -and $r.out -match 'BASELINE_AT_COMMIT .*"valid":false' -and $r.out -match 'BASELINE_AT_COMMIT .*staged' -and (Rdf "$sc\.claude-app-seats\D\sidebar-baseline.json") -match '"valid":false' -and (Rdf "$sc\AppData\Claude\claude_desktop_config.json") -eq '{"old":true}') "rc=$($r.rc) $($r.out)"
  $sc = New-Scenario 'r2c'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_CONFIG = '1' }
  Check 'match/committed: the baseline is rewritten valid:true only at the end, after the config was replaced' ((Rdf "$sc\.claude-app-seats\D\sidebar-baseline.json") -match '"valid":true' -and (Rdf "$sc\AppData\Claude\claude_desktop_config.json") -eq '{"new":true}') $r.out

  # capture: every check inside the seat lock
  $sc = New-Scenario 'r2d'
  '{"lastKnownAccountUuid":"unew"}' | Set-Content "$sc\AppData\Claude\config.json"          # the live login matches no seat: the pre-lock checks of the old code passed
  $body = "`$real = `${function:Enter-SeatLock}; function Enter-SeatLock { '{""lastKnownAccountUuid"":""ud""}' | Set-Content (Join-Path `$AppDir 'config.json'); & `$real }`nInvoke-Capture 'X'"
  $r = Invoke-Scenario $sc $body @{}
  Check 'a capture queued behind a lock while the live login changes to ANOTHER seat is refused, nothing copied' ($r.rc -eq 1 -and $r.out -match "already captured as seat 'D'" -and -not (Test-Path "$sc\.claude-app-seats\X") -and -not (Test-Path "$sc\.claude-app-seats\.seat-write.lock")) "rc=$($r.rc) $($r.out)"
  $sc = New-Scenario 'r2e'
  '{"lastKnownAccountUuid":"unew"}' | Set-Content "$sc\AppData\Claude\config.json"
  $body = "`$real = `${function:Enter-SeatLock}; function Enter-SeatLock { `$script:up = `$true; & `$real }`nfunction Get-AppProcs { if (`$script:up) { [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]::Zero } } }`nInvoke-Capture 'X'"
  $r = Invoke-Scenario $sc $body @{}
  Check 'a capture queued behind a lock while the app is started is refused by the app-closed check made inside the lock' ($r.rc -eq 1 -and $r.out -match 'BLOCKED' -and -not (Test-Path "$sc\.claude-app-seats\X") -and -not (Test-Path "$sc\.claude-app-seats\.seat-write.lock")) "rc=$($r.rc) $($r.out)"
  $sc = New-Scenario 'r2f'
  '{"lastKnownAccountUuid":"unew"}' | Set-Content "$sc\AppData\Claude\config.json"
  $r = Invoke-Scenario $sc "Invoke-Capture 'X'" @{}
  Check 'an ordinary capture still works and releases the lock' ($r.rc -eq 0 -and $r.out -match "Captured current login as profile 'X'" -and (Rdf "$sc\.claude-app-seats\X\owner-uuid.txt") -eq 'unew' -and -not (Test-Path "$sc\.claude-app-seats\.seat-write.lock")) "rc=$($r.rc) $($r.out)"

  # history sync is quiet while the relaunch lock is held; the heartbeat runs after the app is up and the lock is released; a plain switch keeps today's order
  $sc = New-Scenario 'r2g'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $lk2 = '$SeatRoot\.seat-write.lock'
  $hs = "function Invoke-AppHistorySync([switch]`$Quiet) { Write-Host ('HIST quiet=' + [bool]`$Quiet + ' lock=' + (Test-Path `"$lk2`")) }`nfunction Invoke-AppSeatPublish { Write-Host ('PUBLISH lock=' + (Test-Path `"$lk2`")) }`n"
  $body = $hs + "function Get-AppProcs { if (`$script:launched -or `$script:n++ -lt 1) { [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]::Zero } } }`nInvoke-SwitchRelaunch 'D'"
  $r = Invoke-Scenario $sc $body @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG }
  Check 'relaunch: the history sync runs -Quiet inside the lock; the heartbeat runs AFTER the app is up, with the lock released' ($r.out -match 'HIST quiet=True lock=True' -and $r.out -match 'PUBLISH lock=False' -and $r.out.IndexOf('PUBLISH') -gt $r.out.IndexOf('Relaunched the Claude app') -and $r.out -notmatch 'PUBLISH lock=True') $r.out
  $sc = New-Scenario 'r2h'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc ($hs + "Invoke-Switch 'D'") @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG }
  Check 'a plain --switch keeps today''s order: history sync (not quiet) then the heartbeat, before the last line' ($r.out -match 'HIST quiet=False lock=False' -and $r.out.IndexOf('HIST') -lt $r.out.IndexOf('PUBLISH') -and $r.out.IndexOf('PUBLISH') -lt $r.out.IndexOf('Now reopen')) $r.out
} catch { $fail++; Write-Host "  FAIL  the test itself stopped: $_" -ForegroundColor Red } finally {
  foreach ($k in $keep.Keys) { Set-Item "env:$k" $keep[$k] }
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'test-app-relaunch: all passed' -ForegroundColor Green
