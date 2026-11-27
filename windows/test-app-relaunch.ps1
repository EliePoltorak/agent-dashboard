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
  function Send-AppEndSession([int[]]$Ids) { $script:closed += $Ids; $true }
  function Start-Process { param($FilePath, $ArgumentList) $script:started += , @($FilePath, @($ArgumentList)) }
  $script:CloseWaitSec = 1

  # an app that ignores the close request: abort, never force-kill
  $script:procs = @((New-FakeProc 101 $true), (New-FakeProc 102 $false))
  function Get-AppProcs { $script:procs }
  $t0 = Get-Date
  $r = Close-AppGracefully
  Check 'stuck app: Close-AppGracefully returns $false' ($r -eq $false)
  Check 'stuck app: asked every app PID to quit, hidden ones too' (($script:closed -join ',') -eq '101,102') "closed=$($script:closed -join ',')"
  Check 'stuck app: nothing force-killed' ($script:killed.Count -eq 0)
  Check 'stuck app: waited about CloseWaitSec' (((Get-Date) - $t0).TotalSeconds -ge 0.9)

  # an app that refuses the quit: abort at once, not after the full wait
  function Send-AppEndSession([int[]]$Ids) { $false }
  $script:CloseWaitSec = 30; $t0 = Get-Date
  Check 'refusing app: Close-AppGracefully returns $false without waiting' ((Close-AppGracefully) -eq $false -and ((Get-Date) - $t0).TotalSeconds -lt 10)
  function Send-AppEndSession([int[]]$Ids) { $script:closed += $Ids; $true }
  $script:CloseWaitSec = 1

  # the real window messages, against a hidden test window that answers the quit query with 1 or 0
  $qf = Join-Path $root 'qform.ps1'
  @'
param([int]$Answer, [string]$Log)
Add-Type -AssemblyName System.Windows.Forms
$refs = [System.Windows.Forms.Form], [System.Windows.Forms.Message], [System.ComponentModel.Component], [System.Drawing.Size], [object], [System.IO.File], [System.ComponentModel.IComponent] | ForEach-Object { $_.Assembly.Location } | Select-Object -Unique
Add-Type -ReferencedAssemblies $refs @"
using System.Windows.Forms;
public class QForm : Form {
  public int Answer; public string Log;
  protected override void WndProc(ref Message m) {
    if (m.Msg == 0x11) { m.Result = (System.IntPtr)Answer; return; }
    if (m.Msg == 0x16) { System.IO.File.WriteAllText(Log, m.WParam.ToString()); Application.ExitThread(); return; }
    base.WndProc(ref m);
  }
}
"@
$f = [QForm]::new(); $f.Answer = $Answer; $f.Log = $Log; $null = $f.Handle
Set-Content "$Log.ready" 1
[System.Windows.Forms.Application]::Run()
'@ | Set-Content $qf
  $child = @"
. '$script_'
[void](Send-AppEndSession @())
foreach (`$a in 1, 0) {
  `$log = Join-Path '$root' "qform`$a.txt"
  `$c = Start-Process pwsh -ArgumentList '-NoProfile', '-File', '$qf', `$a, `$log -PassThru -WindowStyle Hidden
  `$t = Get-Date; while (-not (Test-Path "`$log.ready") -and ((Get-Date) - `$t).TotalSeconds -lt 120) { Start-Sleep 1 }
  `$sent = [RotatorEndSession]::Send(@(`$c.Id))
  `$t = Get-Date; while (-not `$c.HasExited -and ((Get-Date) - `$t).TotalSeconds -lt 30) { Start-Sleep 1 }
  `$wp = if (Test-Path `$log) { (Get-Content `$log -Raw).Trim() } else { 'none' }
  "R `$a `$sent `$wp"
  if (-not `$c.HasExited) { Stop-Process -Id `$c.Id }
}
"R nowin `$([RotatorEndSession]::Send(@(3)))"
"@
  $out = & pwsh -NoProfile -Command $child 2>&1 | Out-String
  Check 'real messages, window answers 1: Send returns True, WM_ENDSESSION carries 1' ($out -match 'R 1 True 1') $out
  Check 'real messages, window answers 0: Send returns False, WM_ENDSESSION carries 0' ($out -match 'R 0 False 0') $out
  Check 'real messages: no window at all is a refusal' ($out -match 'R nowin False') $out

  # the whole --relaunch path with a stuck app, in a child pwsh: ABORTED, exit 1, nothing switched, nothing launched
  $seat = Join-Path $root '.claude-app-seats\B'
  New-Item -ItemType Directory -Path $seat -Force | Out-Null
  '{"lastKnownAccountUuid":"u-b"}' | Set-Content (Join-Path $seat 'config.json')
  $child = @"
. '$script_'
`$script:CloseWaitSec = 1
function Get-AppProcs { `$o = [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]1 }; `$o | Add-Member ScriptMethod CloseMainWindow { `$true }; `$o }
function Send-AppEndSession { `$true }
function Stop-Process { Write-Host 'KILLED' }
function Start-Process { Write-Host 'LAUNCHED' }
function Invoke-Switch { Write-Host 'SWITCHED' }
Invoke-SwitchRelaunch B
"@
  $out = & pwsh -NoProfile -Command $child 2>&1 | Out-String
  Check 'stuck app: --relaunch aborts with exit 1' ($LASTEXITCODE -eq 1 -and $out -match 'ABORTED') "rc=$LASTEXITCODE out=$out"
  Check 'stuck app: no switch, no kill, no launch' ($out -cnotmatch 'SWITCHED|KILLED|LAUNCHED') $out
  Check 'stuck app: the abort says to quit it from the tray and retry' ($out -match 'system tray' -and $out -match 'tray icon') $out
  Check 'stuck app: the reason is on the abort line itself (the dashboard shows only the last line)' ($out -match 'ABORTED: the Claude app did not quit: PIDs 7 still running') $out

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
function Send-AppEndSession { `$true }
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
function Send-AppEndSession { `$true }
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
function Send-AppEndSession { `$true }
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
if ($env:STUB_PRIO_FILE) { (Get-Process -Id $PID).PriorityClass.ToString() | Set-Content $env:STUB_PRIO_FILE }
if ($env:STUB_MODE -eq 'sleep') { $PID | Set-Content $env:STUB_PIDFILE; Start-Sleep -Seconds 120; exit 0 }
if ($env:STUB_MODE -eq 'exit1') { exit 1 }
New-Item -ItemType Directory -Path $g -Force | Out-Null
function Cfg($file, $pair, $bad) {
  $live = Join-Path $app 'claude_desktop_config.json'
  $sha = if ($bad) { 'DEADBEEF' } else { (Get-FileHash $live -Algorithm SHA256).Hash }
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"new":true}'))
  ('{"sha256":"' + $sha + '","pair":"' + $pair + '","b64":"' + $b64 + '"}') | Set-Content (Join-Path $g $file)
}
$staged = $env:STUB_MODE -eq 'staged'
$cfgenv = $env:STUB_CONFIG
# the stash pair's baseline, config outcome and stash-result.json come FIRST, before anything that can skip or run long
'{"gen":"' + $gen + '","pins":["stash"],"manifest":{"ls":1,"idb":1}}' | Set-Content (Join-Path $g 'baseline-stash.json')
$sco = 'match'
if ($staged -and $env:STUB_STASHCFG) { $sco = 'prepared'; Cfg 'config-stash.json' 'stash' ($env:STUB_STASHCFG -eq 'badhash') }
if (-not $staged -and $cfgenv) { if ($cfgenv -eq 'refused') { $sco = 'refused: config not changed (boom)' } else { $sco = 'prepared'; Cfg 'config-stash.json' 'stash' ($cfgenv -eq 'badhash') } }
('{"target":"' + $target + '","gen":"' + $gen + '","config":"' + $sco + '","config_pair":"stash"}') | Set-Content (Join-Path $g 'stash-result.json')
if ($env:STUB_MODE -eq 'sleep2') { $PID | Set-Content $env:STUB_PIDFILE; Start-Sleep -Seconds 120; exit 0 }
if ($env:STUB_MODE -eq 'skipstage') {
  ('{"status":"skipped","n":0,"reason":"the sidebar state file is unreadable (test)","target":"' + $target + '","gen":"' + $gen + '","pair":"stash","config":"' + $sco + '","config_pair":"stash"}') | Set-Content (Join-Path $g 'result.json')
  'report' | Set-Content (Join-Path $g 'report.txt')
  exit 0
}
if ($staged) {
  foreach ($rel in 'Local Storage\leveldb', 'IndexedDB\https_claude.ai_0.indexeddb.leveldb') {
    New-Item -ItemType Directory -Path (Join-Path $g $rel) -Force | Out-Null
    'STAGED' | Set-Content (Join-Path $g "$rel\marker.txt")
  }
  if ($env:STUB_LEFTOVER) { 'x' | Set-Content (Join-Path $g 'Local Storage\leftover.txt') }
  '{"gen":"' + $gen + '","pins":["staged"],"manifest":{"ls":1,"idb":1}}' | Set-Content (Join-Path $g 'baseline.json')
}
$co = $sco
if ($staged) {
  $co = 'match'
  if ($cfgenv -eq 'refused') { $co = 'refused: config not changed (boom)' } elseif ($cfgenv) { $co = 'prepared'; Cfg 'config.json' 'staged' ($cfgenv -eq 'badhash') }
}
$n = if ($staged) { 1 } else { 0 }
$rg = if ($env:STUB_RESULT -eq 'wronggen') { 'some-other-gen' } else { $gen }
$rp = if ($staged) { 'staged' } else { 'stash' }
$cf = if ($env:STUB_NOCONFIG) { '' } else { ',"config":"' + $co + '","config_pair":"' + $rp + '"' }
$ns = if ($env:STUB_NOTSYNCED) { ',"not_synced":["' + $env:STUB_NOTSYNCED + '"]' } else { '' }
('{"status":"' + $(if ($n) { 'synced' } else { 'nothing' }) + '","n":' + $n + ',"reason":"","target":"' + $target + '","gen":"' + $rg + '","pair":"' + $rp + '"' + $cf + $ns + '}') | Set-Content (Join-Path $g 'result.json')
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
function Send-AppEndSession { `$true }
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

  # 1) staged pair in: the staged databases are the copy-in source; the baseline is written once, after the install; the marker of the leaving seat stays
  $sc = New-Scenario 's1'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_CONFIG = '1' }
  $st = Join-Path $sc '.claude-app-seats'; $app = Join-Path $sc 'AppData\Claude'
  Check 'staged: the staged pair is the copy-in source for both sidebar dirs' ((Rdf "$app\$ls") -eq 'STAGED' -and (Rdf "$app\$idb") -eq 'STAGED') "rc=$($r.rc) out=$($r.out)"
  Check 'staged: the other login dirs come from the stash' ((Rdf "$app\Network\marker.txt") -eq 'D-stash' -and (Rdf "$app\Session Storage\marker.txt") -eq 'D-stash')
  $mk = Get-Content "$st\C\sidebar-departure.json" -Raw | ConvertFrom-Json
  Check 'staged: the leaving seat has ONE departure marker {dep, at, baseline, created} written after the re-capture, dep = this switch''s generation' ($mk.dep -eq $gen -and $mk.at -gt 0 -and $mk.created.ls -gt 0 -and $mk.created.idb -gt 0 -and $mk.PSObject.Properties.Name -contains 'baseline' -and (Rdf "$st\C\Local Storage\leveldb\marker.txt") -eq 'live-C') (Rdf "$st\C\sidebar-departure.json")
  $log = Rdf $env:STUB_LOG
  Check 'staged: the stage ran for the right seats, and the target baseline was NOT invalidated beforehand' ($log -match 'leaving=C target=D' -and $log -notmatch '"valid"') $log
  Check 'staged: the target baseline is the staged one, carrying the gen, with no valid flag' ((Rdf "$st\D\sidebar-baseline.json") -match '"pins":\["staged"\]' -and (Rdf "$st\D\sidebar-baseline.json") -match $gen -and (Rdf "$st\D\sidebar-baseline.json") -notmatch '"valid"')
  Check 'staged: the baseline carries the creation time of the install (F1d), in it and nowhere else' ((Rdf "$st\D\sidebar-baseline.json") -match '"created":\{[^}]*"(ls|idb)":\d+' -and -not (Test-Path "$st\D\sidebar-installed.json")) (Rdf "$st\D\sidebar-baseline.json")
  Check 'staged: the rotator publishes and deletes nothing: the marker stays (the stage''s state records that it was merged), no state file of its own' ((Test-Path "$st\C\sidebar-departure.json") -and -not (Test-Path "$st\.sidebar-sync-state.json") -and -not (Test-Path "$st\.sidebar-sync-work\$gen\consumed.txt")) (Get-ChildItem $st -Force | Out-String)
  Check 'staged: config committed by the rotator, preimage saved' ((Rdf "$app\claude_desktop_config.json") -eq '{"new":true}' -and (Rdf "$st\.sidebar-sync-backups\$gen\claude_desktop_config.json") -eq '{"old":true}') (Rdf "$app\claude_desktop_config.json")
  Check 'staged: verify was scheduled for the new gen after a valid baseline' ($r.out -match "VERIFY D $gen")
  Check 'staged: .active moved, the previous login is backed up' ((Rdf "$st\.active") -eq 'D' -and (Rdf "$st\.swap-backups\$gen\Local Storage\leveldb\marker.txt") -eq 'live-C')
  Check 'staged: the last unindented line carries the sidebar result' ((@($r.out -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^\s' })[-1]) -match '^Now reopen the Claude desktop app\. Sidebar: synced 1 pins\.$') $r.out

  # 2) the checkpoint is written after a good re-capture only (a live database dir missing -> none)
  $sc = New-Scenario 's2'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  Remove-Item -LiteralPath (Join-Path $sc 'AppData\Claude\IndexedDB') -Recurse -Force
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG }
  $mk2 = Get-Content "$sc\.claude-app-seats\C\sidebar-departure.json" -Raw | ConvertFrom-Json
  Check 'no FULL marker when a live sidebar database is missing: only the dismissed form {dep} is left (the stage dismisses and reports it)' ($mk2.dep -and $mk2.PSObject.Properties.Name -notcontains 'baseline') $r.out
  $sc = New-Scenario 's2b'
  $r = Invoke-Scenario $sc "Write-DepartureMarker 'C' @{ dep = 'g1' }; Write-DepartureMarker 'C' @{ dep = 'g2'; at = 5; baseline = `$null; created = @{ ls = 1; idb = 2 } }" @{}
  $mj = Get-Content "$sc\.claude-app-seats\C\sidebar-departure.json" -Raw | ConvertFrom-Json
  Check 'a departure marker is REPLACED, never appended: one object, the latest dep, no entries list' ($mj.dep -eq 'g2' -and $mj.at -eq 5 -and $mj.PSObject.Properties.Name -notcontains 'entries' -and $mj.created.ls -eq 1) (Get-Content "$sc\.claude-app-seats\C\sidebar-departure.json" -Raw)

  # 3) stash pair when python produced no staged copy; baseline-stash used; config pair mismatch is not committed
  $sc = New-Scenario 's3'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG; STUB_CONFIG = '1' }
  $st = Join-Path $sc '.claude-app-seats'; $app = Join-Path $sc 'AppData\Claude'
  Check 'stash pair: the seat''s own databases go in, its stash baseline is recorded, a stash-pair config repair is committed' ((Rdf "$app\$ls") -eq 'D-stash' -and (Rdf "$st\D\sidebar-baseline.json") -match '"pins":\["stash"\]' -and (Rdf "$app\claude_desktop_config.json") -eq '{"new":true}') $r.out
  $sc = New-Scenario 's3b'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_CONFIG = 'badhash' }
  Check 'config refused after a staged install: NO baseline is written (a stale one cannot match the new databases) and the note says partial, not synced' (-not (Test-Path "$sc\.claude-app-seats\D\sidebar-baseline.json") -and $r.out -match 'Sidebar: partial \(config not changed: it differs' -and $r.out -notmatch 'synced' -and $r.out -notmatch 'VERIFY') $r.out
  Check 'config refused when the live file is not the one that was read: left alone, reported' ((Rdf "$sc\AppData\Claude\claude_desktop_config.json") -eq '{"old":true}' -and (Rdf "$sc\.claude-app-seats\.sidebar-sync-work\$gen\report.txt") -match 'config not changed: it differs') (Rdf "$sc\.claude-app-seats\.sidebar-sync-work\$gen\report.txt")

  # 4) one staged copy failing: the stash PAIR and its baseline go in, a `pair: staged` config is NOT committed (S74); both failing: stop, no relaunch
  $sc = New-Scenario 's4'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $body = '$orig = ${function:Mirror-Dir}; function Mirror-Dir($s, $d) { & $orig $s $d; if ($s -like ''*sidebar-sync-work*IndexedDB*'') { $script:RobocopyRc = 8 } }' + "`nInvoke-Switch 'D'"
  $r = Invoke-Scenario $sc $body @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_CONFIG = '1' }
  $st = Join-Path $sc '.claude-app-seats'; $app = Join-Path $sc 'AppData\Claude'
  Check 'staged IndexedDB copy fails: BOTH sidebar dirs come from the stash, and the stash pair gets ITS OWN baseline and config outcome (the staged config is not committed)' ((Rdf "$app\$ls") -eq 'D-stash' -and (Rdf "$app\$idb") -eq 'D-stash' -and (Rdf "$st\D\sidebar-baseline.json") -match '"created":' -and (Rdf "$st\D\sidebar-baseline.json") -match '"pins":\["stash"\]') $r.out
  Check 'staged copy failed: the staged-pair config is not committed (S74), the note says skipped' ((Rdf "$app\claude_desktop_config.json") -eq '{"old":true}' -and $r.out -match 'Sidebar: skipped \(the staged copy could not be installed') $r.out
  $sc = New-Scenario 's4b'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $body = '$orig = ${function:Mirror-Dir}; function Mirror-Dir($s, $d) { & $orig $s $d; if ($d -like ''*IndexedDB.new'') { $script:RobocopyRc = 8 } }' + "`nInvoke-SwitchRelaunch 'D'"
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
  Check 'timed-out stage: the marker is intact, the stash pair is installed and NO baseline is written (the stage left no files)' (-not (Test-Path "$st\.sidebar-sync-state.json") -and (Test-Path "$st\C\sidebar-departure.json") -and (Rdf "$sc\AppData\Claude\$ls") -eq 'D-stash' -and -not (Test-Path "$st\D\sidebar-baseline.json")) (Get-ChildItem $st -Force | Out-String)
  Check 'timed-out stage: the note says skipped with the reason, with NO path in it; the report path is on an indented line before it' ($r.out -match 'Sidebar: skipped \(the stage did not finish in 25 s\)' -and $r.out -notmatch 'in 25 s\) - see' -and $r.out -match '(?m)^  sidebar report: .*report\.txt') $r.out
  Check 'timed-out stage: no verify (no baseline)' ($r.out -notmatch 'VERIFY')

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
  $body = "(Get-Process -Id `$PID).PriorityClass = 'Normal'`nfunction Start-Process { param(`$FilePath, `$ArgumentList, `$WindowStyle) Write-Host `"SPAWN `$FilePath :: `$ArgumentList :: `$WindowStyle :: CLASS=`$((Get-Process -Id `$PID).PriorityClass)`" }`nfunction Get-SidebarSyncCommand { @{ file = 'C:\py\python.exe'; args = @('-I', 'C:\r\sidebar-sync.py') } }`nStart-SidebarVerify 'D' '$gen'"
  $pre = (Invoke-Scenario $sc $body @{ REAL_VERIFY = '1' }).out
  $r = Invoke-Scenario $sc ($body -replace 'function Start-Process.*?\n', '') @{}
  Check 'verify spawn: cmd.exe, hidden, --verify with gen and target, stdout AND stderr redirected to files in the gen dir' ($pre -match 'SPAWN cmd.exe' -and $pre -match 'CLASS=Idle' -and $pre -match 'Hidden' -and $pre -match '--verify" "--gen" "20261125-120000" "--target" "D"' -and $pre -match '> "[^"]*verify\.out"' -and $pre -match '2> "[^"]*verify\.err"') $pre
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
  Check 'a stage result naming another generation: the staged pair is NOT installed, skipped' ((Rdf "$sc\AppData\Claude\$ls") -eq 'D-stash' -and -not (Test-Path "$sc\.claude-app-seats\.sidebar-sync-state.json") -and $r.out -match 'Sidebar: skipped \(the stage result does not belong to this switch\)') $r.out
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

  # partial installs: the config is settled first; the baseline is written ONCE, last, only after a match or a committed config
  $sc = New-Scenario 'r1h'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $body = "`$orig = `${function:Write-JsonAtomic}; function Write-JsonAtomic(`$path, `$obj) { if (`$path -like '*sidebar-baseline.json' -and `$obj.ContainsKey('pins')) { throw 'disk full' }; & `$orig `$path `$obj }`nInvoke-Switch 'D'"
  $r = Invoke-Scenario $sc $body @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_CONFIG = '1' }
  Check 'the baseline write fails AFTER the config was committed: no baseline, the note says partial (the config and the databases agree; the next departure has no baseline and is reported)' ((Rdf "$sc\AppData\Claude\claude_desktop_config.json") -eq '{"new":true}' -and -not (Test-Path "$sc\.claude-app-seats\D\sidebar-baseline.json") -and $r.out -match 'Sidebar: partial \(the baseline could not be saved\)' -and $r.out -notmatch 'VERIFY') $r.out
  $sc = New-Scenario 'r1i'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG; STUB_CONFIG = 'badhash' }
  Check 'a stash-pair install that needed the config and could not get it: partial, no baseline written' (-not (Test-Path "$sc\.claude-app-seats\D\sidebar-baseline.json") -and $r.out -match 'Sidebar: partial' -and $r.out -notmatch 'VERIFY') $r.out
  $sc = New-Scenario 'r1j'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_CONFIG = '1' }
  Check 'config committed, then the baseline written once: synced, verify scheduled' ((Rdf "$sc\AppData\Claude\claude_desktop_config.json") -eq '{"new":true}' -and (Rdf "$sc\.claude-app-seats\D\sidebar-baseline.json") -match '"created":' -and $r.out -match 'Sidebar: synced 1 pins' -and $r.out -match 'VERIFY D') $r.out

  # 12) review round 2: explicit config outcome and baseline order, capture under the lock, history/heartbeat around the relaunch lock
  $sc = New-Scenario 'r2a'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_CONFIG = 'refused' }
  Check 'a config the stage REFUSED to read (explicit outcome, not an omitted file): not replaced, no baseline, partial, no verify' ((Rdf "$sc\AppData\Claude\claude_desktop_config.json") -eq '{"old":true}' -and -not (Test-Path "$sc\.claude-app-seats\D\sidebar-baseline.json") -and $r.out -match 'Sidebar: partial \(config not changed \(refused: config not changed \(boom\)\)\)' -and $r.out -notmatch 'VERIFY') $r.out
  $sc = New-Scenario 'r2b'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  '{"gen":"old","pins":["old"],"manifest":{"ls":1,"idb":1},"created":{"ls":1,"idb":2}}' | Set-Content "$sc\.claude-app-seats\D\sidebar-baseline.json"
  $body = "function Commit-SidebarConfig { Write-Host 'COMMIT-REACHED'; exit 5 }`nInvoke-Switch 'D'"
  $r = Invoke-Scenario $sc $body @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_CONFIG = '1' }
  Check 'interrupted between the install and the baseline write (at the config commit): the OLD baseline is untouched (its created cannot match the new databases) and the config was not replaced' ($r.rc -eq 5 -and $r.out -match 'COMMIT-REACHED' -and (Rdf "$sc\.claude-app-seats\D\sidebar-baseline.json") -match '"gen":"old"' -and (Rdf "$sc\AppData\Claude\claude_desktop_config.json") -eq '{"old":true}') "rc=$($r.rc) $($r.out)"
  $sc = New-Scenario 'r2c'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_CONFIG = '1' }
  Check 'match/committed: the baseline is written once, at the end, after the config was replaced' ((Rdf "$sc\.claude-app-seats\D\sidebar-baseline.json") -match '"created":' -and (Rdf "$sc\AppData\Claude\claude_desktop_config.json") -eq '{"new":true}') $r.out

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
  $hs = "function Invoke-AppHistorySync([switch]`$Quiet) { Write-Host ('HIST quiet=' + [bool]`$Quiet + ' lock=' + (Test-Path `"$lk2`")) }`nfunction Invoke-AppSeatPublish { Write-Host ('PUBLISH lock=' + (Test-Path `"$lk2`")) }`nfunction Start-AppSeatHeartbeat { Write-Host ('PUBLISH lock=' + (Test-Path `"$lk2`")) }`n"
  $body = $hs + "function Get-AppProcs { if (`$script:launched -or `$script:n++ -lt 1) { [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]::Zero } } }`nInvoke-SwitchRelaunch 'D'"
  $r = Invoke-Scenario $sc $body @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG }
  Check 'relaunch: the history sync runs -Quiet inside the lock; the heartbeat runs AFTER the app is up, with the lock released' ($r.out -match 'HIST quiet=True lock=True' -and $r.out -match 'PUBLISH lock=False' -and $r.out.IndexOf('PUBLISH') -gt $r.out.IndexOf('Relaunched the Claude app') -and $r.out -notmatch 'PUBLISH lock=True') $r.out
  $sc = New-Scenario 'r2h'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc ($hs + "Invoke-Switch 'D'") @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG }
  Check 'a plain --switch keeps today''s order: history sync (not quiet) then the heartbeat, before the last line' ($r.out -match 'HIST quiet=False lock=False' -and $r.out.IndexOf('HIST') -lt $r.out.IndexOf('PUBLISH') -and $r.out.IndexOf('PUBLISH') -lt $r.out.IndexOf('Now reopen')) $r.out

  # 13) round 3: F1a stash baseline when the stage is skipped/killed, F1c not-synced on the line, F1d created in the baseline, C1 history lock, C2 heartbeat, C3 in-memory result
  $sc = New-Scenario 'r3a'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'skipstage'; STUB_LOG = $env:STUB_LOG }
  Check 'F1a: a SKIPPED stage still gives the stash pair its baseline (edits made on the entered seat are not forfeited); the note says skipped' ((Rdf "$sc\.claude-app-seats\D\sidebar-baseline.json") -match '"created":' -and (Rdf "$sc\.claude-app-seats\D\sidebar-baseline.json") -match '"created":' -and $r.out -match 'Sidebar: skipped \(the sidebar state file is unreadable \(test\)\)' -and $r.out -match 'VERIFY D' -and -not (Test-Path "$sc\.claude-app-seats\.sidebar-sync-state.json")) $r.out
  $sc = New-Scenario 'r3b'; $env:STUB_LOG = Join-Path $sc 'stub.log'; $pidf = Join-Path $sc 'stub.pid'
  $r = Invoke-Scenario $sc "`$script:StageTimeoutSec = 25; Invoke-Switch 'D'" @{ STUB_MODE = 'sleep2'; STUB_LOG = $env:STUB_LOG; STUB_PIDFILE = $pidf }
  $spid = if (Test-Path $pidf) { [int](Rdf $pidf) } else { 0 }
  if ($spid -gt 0 -and (Get-Process -Id $spid -ErrorAction SilentlyContinue)) { Stop-Process -Id $spid }       # only the PID the stub wrote
  Check 'F1a: a stage KILLED at its deadline after it wrote the stash files: the stash pair goes in WITH its baseline (from stash-result.json); the note says the stage did not finish' ((Rdf "$sc\.claude-app-seats\D\sidebar-baseline.json") -match '"created":' -and -not (Test-Path "$sc\.claude-app-seats\.sidebar-sync-state.json") -and (Test-Path "$sc\.claude-app-seats\C\sidebar-departure.json") -and $r.out -match 'Sidebar: skipped \(the stage did not finish in 25 s\)') $r.out
  $sc = New-Scenario 'r3c'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_NOTSYNCED = 'C' }
  Check 'F1c/item 7: a departure that was not synced is FIRST on the last line, with no path in it; the report path is on an indented line before it' (@($r.out -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^\s' })[-1] -match '^Sidebar: edits on C not synced; synced 1 pins\. Now reopen the Claude desktop app\.$' -and $r.out -match '(?m)^  sidebar report: .*report\.txt') $r.out

  # C3: the result is validated ONCE and kept in memory; an outcome the stage did not state is never read as a match
  $sc = New-Scenario 'r3d'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $body = "`$script:rr = 0; `$orig = `${function:Read-JsonFile}; function Read-JsonFile(`$p) { if (`$p -like '*result.json' -and `$p -notlike '*stash-result.json') { `$script:rr++ }; & `$orig `$p }`nInvoke-Switch 'D'; Write-Host ('RESULT_READS=' + `$script:rr)"
  $r = Invoke-Scenario $sc $body @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG }
  Check 'C3: result.json is read exactly once (no re-read after the install)' ($r.out -match 'RESULT_READS=1\b') $r.out
  $sc = New-Scenario 'r3e'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_NOCONFIG = '1' }
  Check 'C3: a result with NO config outcome is not a match: no baseline, partial, no verify' (-not (Test-Path "$sc\.claude-app-seats\D\sidebar-baseline.json") -and $r.out -match 'Sidebar: partial \(config not changed: the stage reported no config outcome\)' -and $r.out -notmatch 'VERIFY') $r.out
  $sc = New-Scenario 'r3f'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $body = "`$script:cnt = 0; `$orig = `${function:Read-JsonFile}; function Read-JsonFile(`$p) { if (`$p -like '*result.json' -and `$p -notlike '*stash-result.json') { `$script:cnt++; if (`$script:cnt -ge 2) { return `$null } }; & `$orig `$p }`nInvoke-Switch 'D'"
  $r = Invoke-Scenario $sc $body @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_CONFIG = 'refused' }
  Check 'C3: even if a later read of result.json would fail, the refused outcome validated before the install stays refused (no baseline)' (-not (Test-Path "$sc\.claude-app-seats\D\sidebar-baseline.json") -and $r.out -match 'Sidebar: partial') $r.out

  # C1: the history lock is held across the launch and the startup wait; a busy history sync defers the reopening
  $sc = New-Scenario 'r3g'
  '{"lastKnownAccountUuid":"ud"}' | Set-Content "$sc\AppData\Claude\config.json"
  $hl = "$sc\.claude-app-seats\.sync-history.lock"
  New-Item -ItemType Directory -Path "$sc\.claude-app-seats" -Force | Out-Null
  $held = [IO.File]::Open($hl, 'OpenOrCreate', 'ReadWrite', 'None')
  try {
    $body = "`$script:HistoryLockWaitSec = 3`nfunction Get-AppProcs { if (`$script:launched -or `$script:n++ -lt 1) { [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]::Zero } } }`nfunction Invoke-Switch { `$script:SwitchDone = `$true }`nInvoke-SwitchRelaunch 'D'"
    $r = Invoke-Scenario $sc $body @{}
  } finally { $held.Dispose() }
  Check 'C1: a history sync that still holds its lock after the deadline: the app is NOT launched, last line says reopening deferred, exit 3' ($r.rc -eq 3 -and $r.out -notmatch 'LAUNCHED' -and (@($r.out -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^\s' })[-1]) -match 'Switched to seat D; reopening deferred: history sync busy') "rc=$($r.rc) $($r.out)"
  $sc = New-Scenario 'r3h'
  '{"lastKnownAccountUuid":"ud"}' | Set-Content "$sc\AppData\Claude\config.json"
  $hl2 = '$SeatRoot\.sync-history.lock'
  $body = "function Get-AppProcs { if (`$script:launched -or `$script:n++ -lt 1) { [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]::Zero } } }`nfunction Invoke-Switch { `$script:SwitchDone = `$true }`n" +
          "function Test-HistLockHeld { try { `$x = [IO.File]::Open(`"$hl2`", 'OpenOrCreate', 'ReadWrite', 'None'); `$x.Dispose(); `$false } catch { `$true } }`n" +
          "function Start-ClaudeApp { Write-Host ('HISTLOCK_AT_LAUNCH=' + (Test-HistLockHeld)); `$script:launched = `$true; `$true }`n" +
          "Invoke-SwitchRelaunch 'D'; Write-Host ('HISTLOCK_AFTER=' + (Test-HistLockHeld))"
  $r = Invoke-Scenario $sc $body @{}
  Check 'C1: the history lock is held while the app is launched and released afterwards' ($r.out -match 'HISTLOCK_AT_LAUNCH=True' -and $r.out -match 'HISTLOCK_AFTER=False' -and $r.rc -eq 0) $r.out

  # C2: the heartbeat is started off the critical path (relaunch only); the last line stays the relaunch + sidebar result
  $sc = New-Scenario 'r3i'
  '{"lastKnownAccountUuid":"ud"}' | Set-Content "$sc\AppData\Claude\config.json"
  $base = "function Get-AppProcs { if (`$script:launched -or `$script:n++ -lt 1) { [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]::Zero } } }`nfunction Invoke-Switch { `$script:SwitchDone = `$true; `$script:SidebarNote = 'Sidebar: nothing to sync.' }`nfunction Invoke-AppSeatPublish { Write-Host 'SYNC-PUBLISH-RAN' }`n"
  $r = Invoke-Scenario $sc ($base + "function Get-ScheduledTask { param(`$TaskName) if (`$TaskName -eq 'Claude app-seat heartbeat') { [pscustomobject]@{ TaskName = `$TaskName } } }`nfunction Start-ScheduledTask { param(`$TaskName) Write-Host ('HB-TASK ' + `$TaskName) }`nInvoke-SwitchRelaunch 'D'") @{}
  Check 'C2: the existing heartbeat scheduled task is started; the publisher is NOT run synchronously; the last line is still the relaunch + sidebar result' ($r.out -match 'HB-TASK Claude app-seat heartbeat' -and $r.out -notmatch 'SYNC-PUBLISH-RAN' -and (@($r.out -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^\s' })[-1]) -match '^(Relaunched the Claude app on seat D\. Sidebar: nothing to sync\.|HB-TASK .*)$' -and $r.out.IndexOf('HB-TASK') -gt $r.out.IndexOf('Relaunched the Claude app')) $r.out
  $r = Invoke-Scenario $sc ($base + "function Get-ScheduledTask { `$null }`nfunction Start-Process { param(`$FilePath, `$ArgumentList, `$WindowStyle, [switch]`$PassThru, `$RedirectStandardOutput, `$RedirectStandardError) if (`$FilePath -eq 'fake-claude.exe') { `$script:launched = `$true; Write-Host 'LAUNCHED' } else { Write-Host ('DETACHED ' + `$FilePath + ' :: ' + `$ArgumentList) } }`nInvoke-SwitchRelaunch 'D'") @{}
  Check 'C2: with no scheduled task the publisher is started detached through cmd.exe with its output in a file, after the relaunch line' ($r.out -match 'DETACHED cmd.exe :: /d /c ".*app-seat-publish\.ps1.*> ".*\.app-seat-publish\.out" 2>&1"' -and $r.out -notmatch 'SYNC-PUBLISH-RAN') $r.out
  $sc = New-Scenario 'r3j'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc ("function Invoke-AppSeatPublish { Write-Host 'SYNC-PUBLISH-RAN' }`nfunction Start-AppSeatHeartbeat { Write-Host 'HEARTBEAT-STARTED' }`nInvoke-Switch 'D'") @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG }
  Check 'C2: a plain --switch keeps today''s order: the synchronous publish, no heartbeat start' ($r.out -match 'SYNC-PUBLISH-RAN' -and $r.out -notmatch 'HEARTBEAT-STARTED') $r.out

  # 14) review round 4 and the marker design: whole-or-nothing sidebar install, reopen path, Idle children, owner check, login file copies
  # a switch whose install fails leaves the marker in place (the rotator publishes and deletes nothing)
  $sc = New-Scenario 'r4b'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $body = "`$orig = `${function:Mirror-Dir}; function Mirror-Dir(`$s, `$d) { & `$orig `$s `$d; if (`$d -like '*.new') { `$script:RobocopyRc = 8 } }`nInvoke-Switch 'D'"
  $r = Invoke-Scenario $sc $body @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG }
  Check 'a switch whose install fails (both pairs): exit 1 and the departure marker is still there' ($r.rc -eq 1 -and $r.out -match 'FAILED: could not copy the sidebar databases' -and -not (Test-Path "$sc\.claude-app-seats\.sidebar-sync-state.json") -and (Test-Path "$sc\.claude-app-seats\C\sidebar-departure.json")) "rc=$($r.rc) $($r.out)"
  $sc = New-Scenario 'r4c'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  '{"dep":"earlier"}' | Set-Content "$sc\.claude-app-seats\C\sidebar-departure.json"      # a pending marker (the locked file also fails the re-capture, so no full one is written now)
  $lockf = "$sc\AppData\Claude\Session Storage\marker.txt"
  $body = "`$fs = [IO.File]::Open('$lockf', 'Open', 'Read', 'None')`ntry { Invoke-Switch 'D' } finally { `$fs.Dispose() }"
  $r = Invoke-Scenario $sc $body @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG }
  Check 'a REFUSED switch (move-aside failure) after the stage ran leaves the marker in place' ($r.rc -eq 1 -and -not (Test-Path "$sc\.claude-app-seats\.sidebar-sync-state.json") -and (Test-Path "$sc\.claude-app-seats\C\sidebar-departure.json")) "rc=$($r.rc) $($r.out)"

  # whole-or-nothing: a leftover staged file cannot survive a fallback to the stash
  $sc = New-Scenario 'r4d'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $body = "`$orig = `${function:Mirror-Dir}; function Mirror-Dir(`$s, `$d) { & `$orig `$s `$d; if (`$s -like '*sidebar-sync-work*IndexedDB*') { `$script:RobocopyRc = 8 } }`nInvoke-Switch 'D'"
  $r = Invoke-Scenario $sc $body @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_LEFTOVER = '1' }
  $app = "$sc\AppData\Claude"
  Check 'staged IndexedDB fails (staged Local Storage carries a leftover file): the stash pair goes in whole; the leftover is NOT in the live profile; no .new directory remains' ((Rdf "$app\$ls") -eq 'D-stash' -and -not (Test-Path "$app\Local Storage\leftover.txt") -and -not (Test-Path "$app\Local Storage.new") -and -not (Test-Path "$app\IndexedDB.new") -and (Rdf "$app\$idb") -eq 'D-stash') $r.out
  Check 'the stash pair''s own baseline is written only after that install was checked' ((Rdf "$sc\.claude-app-seats\D\sidebar-baseline.json") -match '"created":' -and (Rdf "$sc\.claude-app-seats\D\sidebar-baseline.json") -match '"pins":\["stash"\]') $r.out
  $sc = New-Scenario 'r4e'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $body = "`$orig = `${function:Mirror-Dir}; function Mirror-Dir(`$s, `$d) { & `$orig `$s `$d; if (`$s -like '*sidebar-sync-work*IndexedDB*') { `$script:RobocopyRc = 8 } }`n" +
          "`$origR = `${function:Remove-DirStrict}; function Remove-DirStrict(`$p) { if (`$p -like '*Local Storage.new') { return `$false }; & `$origR `$p }`nInvoke-Switch 'D'"
  $r = Invoke-Scenario $sc $body @{ STUB_MODE = 'staged'; STUB_LOG = $env:STUB_LOG; STUB_LEFTOVER = '1' }
  Check 'a staged copy that cannot be cleaned up stops the switch (FAILED, exit 1) rather than letting the stash be installed over it: no mixed database in place' ($r.rc -eq 1 -and $r.out -match 'FAILED: could not copy the sidebar databases' -and -not (Test-Path "$sc\AppData\Claude\Local Storage\leftover.txt")) "rc=$($r.rc) $($r.out)"

  # a refused switch reopens the old login through the same history-locked path
  $sc = New-Scenario 'r4f'
  $hl = "$sc\.claude-app-seats\.sync-history.lock"
  New-Item -ItemType Directory -Path "$sc\.claude-app-seats" -Force | Out-Null
  $held = [IO.File]::Open($hl, 'OpenOrCreate', 'ReadWrite', 'None')
  try {
    $body = "`$script:HistoryLockWaitSec = 3`nfunction Get-AppProcs { if (`$script:launched -or `$script:n++ -lt 1) { [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]::Zero } } }`nfunction Invoke-Switch { Write-Host 'REFUSED: x'; exit 1 }`nInvoke-SwitchRelaunch 'D'"
    $r = Invoke-Scenario $sc $body @{}
  } finally { $held.Dispose() }
  Check 'a REFUSED switch does not reopen the old login while a history sync holds its lock (same path as a successful relaunch)' ($r.rc -eq 1 -and $r.out -notmatch 'LAUNCHED' -and $r.out -match 'history sync is still running') "rc=$($r.rc) $($r.out)"
  $sc = New-Scenario 'r4g'
  $hl2 = '$SeatRoot\.sync-history.lock'
  $body = "function Get-AppProcs { if (`$script:launched -or `$script:n++ -lt 1) { [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]::Zero } } }`nfunction Invoke-Switch { Write-Host 'REFUSED: x'; exit 1 }`n" +
          "function Test-HistLockHeld { try { `$x = [IO.File]::Open(`"$hl2`", 'OpenOrCreate', 'ReadWrite', 'None'); `$x.Dispose(); `$false } catch { `$true } }`n" +
          "function Start-ClaudeApp { Write-Host ('HISTLOCK_AT_LAUNCH=' + (Test-HistLockHeld)); `$script:launched = `$true; `$true }`nInvoke-SwitchRelaunch 'D'"
  $r = Invoke-Scenario $sc $body @{}
  Check 'a refused switch reopens the old login WITH the history lock held, and says so' ($r.out -match 'HISTLOCK_AT_LAUNCH=True' -and $r.out -match 'Switch failed; relaunched the Claude app on its old login') $r.out

  # Idle: the stage child runs at Idle even when the rotator was started at Normal; this shell's class is restored afterwards
  $sc = New-Scenario 'r4h'; $env:STUB_LOG = Join-Path $sc 'stub.log'; $prio = Join-Path $sc 'stub.prio'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG; STUB_PRIO_FILE = $prio }
  Check 'the stage child of a whole switch (the scenario itself at Idle) runs at Idle' ((Rdf $prio) -eq 'Idle') "prio=$(Rdf $prio) $($r.out)"
  $sc = New-Scenario 'r4i'
  $body = "(Get-Process -Id `$PID).PriorityClass = 'Normal'`nfunction Start-Process { param(`$FilePath, `$ArgumentList) Write-Host ('STUB-CHILD-STARTED-AT=' + (Get-Process -Id `$PID).PriorityClass) }`nStart-IdleProcess @{ FilePath = 'x'; ArgumentList = 'y' }; Write-Host ('SHELL-AFTER=' + (Get-Process -Id `$PID).PriorityClass)"
  $r = Invoke-Scenario $sc $body @{}
  Check 'Start-IdleProcess directly: the child is launched while this shell is at Idle (a child starts at its parent''s class) and the shell''s own class (Normal here) is restored' ($r.out -match 'STUB-CHILD-STARTED-AT=Idle' -and $r.out -match 'SHELL-AFTER=Normal') $r.out

  # the stash pair's baseline: the lineage continues when the target's pending marker belongs to the baseline on disk; otherwise the stage's own baseline-stash.json
  $sc = New-Scenario 'r5a'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  '{"gen":"bX","pins":["old"],"manifest":{"ls":7,"idb":8},"created":{"ls":5,"idb":6}}' | Set-Content "$sc\.claude-app-seats\D\sidebar-baseline.json"
  '{"dep":"d0","at":1,"baseline":{"gen":"bX","pins":["old"],"manifest":{"ls":7,"idb":8},"created":{"ls":5,"idb":6}},"created":{"ls":5,"idb":6}}' | Set-Content "$sc\.claude-app-seats\D\sidebar-departure.json"
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG }
  $bl = Get-Content "$sc\.claude-app-seats\D\sidebar-baseline.json" -Raw | ConvertFrom-Json
  Check 'stash install with a matching pending marker: the lineage continues (gen, pins, manifest kept) and only created is refreshed' ($bl.gen -eq 'bX' -and $bl.pins -contains 'old' -and $bl.manifest.ls -eq 7 -and $bl.created.ls -gt 6) (Get-Content "$sc\.claude-app-seats\D\sidebar-baseline.json" -Raw)
  $sc = New-Scenario 'r5b'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  '{"gen":"bX","pins":["old"],"manifest":{"ls":7,"idb":8},"created":{"ls":5,"idb":6}}' | Set-Content "$sc\.claude-app-seats\D\sidebar-baseline.json"
  '{"dep":"d0","at":1,"baseline":{"gen":"bX","pins":["old"],"manifest":{"ls":7,"idb":8},"created":{"ls":5,"idb":6}},"created":{"ls":99,"idb":99}}' | Set-Content "$sc\.claude-app-seats\D\sidebar-departure.json"
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG }
  $bl = Get-Content "$sc\.claude-app-seats\D\sidebar-baseline.json" -Raw | ConvertFrom-Json
  Check 'stash install whose pending marker does NOT match its baseline (created differs): the stage''s own baseline-stash.json is used instead' ($bl.gen -ne 'bX' -and $bl.pins -contains 'stash' -and $bl.created.ls -gt 6) (Get-Content "$sc\.claude-app-seats\D\sidebar-baseline.json" -Raw)
  $sc = New-Scenario 'r5c'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG }
  $bl = Get-Content "$sc\.claude-app-seats\D\sidebar-baseline.json" -Raw | ConvertFrom-Json
  Check 'stash install with no marker at all: baseline-stash.json plus created' ($bl.pins -contains 'stash' -and $bl.created.ls -gt 0) (Get-Content "$sc\.claude-app-seats\D\sidebar-baseline.json" -Raw)

  # an owner's login must be live after the install; the login file copies must succeed
  $sc = New-Scenario 'r5d'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $body = "`$origI = `${function:Install-SidebarPair}; function Install-SidebarPair(`$f) { `$ok = & `$origI `$f; Set-Content (Join-Path `$AppDir 'config.json') '{`"lastKnownAccountUuid`":`"zz`"}'; `$ok }`nInvoke-Switch 'D'"
  $r = Invoke-Scenario $sc $body @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG }
  Check 'after the install the live login is not the owner''s account: FAILED, exit 1, nothing marked as switched (.active unchanged)' ($r.rc -eq 1 -and $r.out -match 'is not the account of seat .D.' -and (Rdf "$sc\.claude-app-seats\.active") -eq 'C' -and -not (Test-Path "$sc\.claude-app-seats\D\sidebar-baseline.json")) "rc=$($r.rc) $($r.out)"
  $sc = New-Scenario 'r5e'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $shadow = "function Copy-Item { [CmdletBinding()] param([Parameter(Position=0)]`$Path, [Parameter(Position=1)]`$Destination, [switch]`$Force) if (`"`$Destination`" -like '*swap-backups*config.json') { throw 'access denied' }; Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters }`n"
  $r = Invoke-Scenario $sc ($shadow + "Invoke-Switch 'D'") @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG }
  Check 'the backup copy of config.json fails: REFUSED before anything is moved (exit 1, live login untouched)' ($r.rc -eq 1 -and $r.out -match 'REFUSED: could not back up the current login' -and (Rdf "$sc\AppData\Claude\$ls") -eq 'live-C') "rc=$($r.rc) $($r.out)"
  $sc = New-Scenario 'r5f'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $shadow = "function Copy-Item { [CmdletBinding()] param([Parameter(Position=0)]`$Path, [Parameter(Position=1)]`$Destination, [switch]`$Force) if (`"`$Destination`" -like '*AppData*Claude*config.json' -and `"`$Path`" -like '*claude-app-seats*D*') { throw 'access denied' }; Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters }`n"
  $r = Invoke-Scenario $sc ($shadow + "Invoke-Switch 'D'") @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG }
  Check 'the apply copy of config.json fails: FAILED naming the backup, exit 1, .active unchanged' ($r.rc -eq 1 -and $r.out -match 'FAILED: could not copy the login file config.json' -and $r.out -match 'swap-backups' -and (Rdf "$sc\.claude-app-seats\.active") -eq 'C') "rc=$($r.rc) $($r.out)"
  $sc = New-Scenario 'r5g'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  $shadow = "function Copy-Item { [CmdletBinding()] param([Parameter(Position=0)]`$Path, [Parameter(Position=1)]`$Destination, [switch]`$Force) if (`"`$Destination`" -like '*claude-app-seats*C*config.json') { throw 'access denied' }; Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters }`n"
  $r = Invoke-Scenario $sc ($shadow + "Invoke-Switch 'D'") @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG }
  Check 'the re-capture copy of the leaving login''s config.json fails: REFUSED BEFORE the /MIR of the databases, nothing switched' ($r.rc -eq 1 -and $r.out -match 'REFUSED: could not save the current login' -and (Rdf "$sc\.claude-app-seats\C\$ls") -eq 'C-stash' -and (Rdf "$sc\.claude-app-seats\.active") -eq 'C') "rc=$($r.rc) $($r.out)"

  # the sidebar note on the last line is capped (the full reason is in report.txt)
  $sc = New-Scenario 'r5h'
  $r = Invoke-Scenario $sc "Set-SidebarNote ('Sidebar: partial (' + ('x' * 200) + ')') `$null ''; Write-Host ('NOTELEN=' + `$script:SidebarNote.Length); Write-Host ('WARN=' + `$script:SidebarWarn)" @{}
  Check 'a long sidebar note is cut to 80 characters (and still counts as a warning)' ($r.out -match 'NOTELEN=80' -and $r.out -match 'WARN=True') $r.out
  # r6 (1a): the dismissed marker cannot be written -> nothing of the seat is mirrored: its stash and its old marker stay, the line says not synced
  $sc = New-Scenario 'r6a'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  '{"dep":"old1","at":1,"baseline":{"gen":"b","pins":["p"],"created":{"ls":1,"idb":2}},"created":{"ls":3,"idb":4}}' | Set-Content "$sc\.claude-app-seats\C\sidebar-departure.json"
  $before = Rdf "$sc\.claude-app-seats\C\sidebar-departure.json"
  $r = Invoke-Scenario $sc "function Write-DepartureMarker(`$seat, `$m) { throw 'disk full' }`nInvoke-Switch 'D'" @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG }
  Check 'a departure marker that cannot be written: the seat is NOT mirrored (stash and old marker untouched), the switch still stands, the line says the edits are not synced' ($r.rc -eq 0 -and (Rdf "$sc\.claude-app-seats\C\$ls") -eq 'C-stash' -and (Rdf "$sc\.claude-app-seats\C\sidebar-departure.json") -eq $before -and $r.out -match 'Sidebar: edits on C not synced' -and (Rdf "$sc\AppData\Claude\$ls") -eq 'D-stash') "rc=$($r.rc) $($r.out)"

  # r6 (1b): replacing a FULL marker the state has not merged folds two visits into one delta: the line warns
  $sc = New-Scenario 'r6b'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  '{"dep":"old1","at":1,"baseline":{"gen":"b","pins":["p"],"created":{"ls":1,"idb":2}},"created":{"ls":3,"idb":4}}' | Set-Content "$sc\.claude-app-seats\C\sidebar-departure.json"
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG }
  Check 'an unmerged marker replaced at the next departure: "edits on C from two visits merged; check its pins" leads the line' ($r.rc -eq 0 -and $r.out -match 'Sidebar: edits on C from two visits merged; check its pins') "rc=$($r.rc) $($r.out)"
  $sc = New-Scenario 'r6c'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  '{"dep":"old1","at":1,"baseline":{"gen":"b","pins":["p"],"created":{"ls":1,"idb":2}},"created":{"ls":3,"idb":4}}' | Set-Content "$sc\.claude-app-seats\C\sidebar-departure.json"
  '{"version":2,"gen":"x","pins":[],"seats":{"C":{"dep":"old1"}}}' | Set-Content "$sc\.claude-app-seats\.sidebar-sync-state.json"
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG }
  Check 'a marker the state already merged is replaced without the two-visits warning' ($r.rc -eq 0 -and $r.out -notmatch 'two visits') "rc=$($r.rc) $($r.out)"

  # r6 (2): a stash-lineage switch (the baseline keeps an older gen) writes the install record and IS verified
  $sc = New-Scenario 'r6d'; $env:STUB_LOG = Join-Path $sc 'stub.log'
  '{"gen":"bX","pins":["old"],"manifest":{"ls":7,"idb":8},"created":{"ls":5,"idb":6}}' | Set-Content "$sc\.claude-app-seats\D\sidebar-baseline.json"
  '{"dep":"d0","at":1,"baseline":{"gen":"bX","pins":["old"],"manifest":{"ls":7,"idb":8},"created":{"ls":5,"idb":6}},"created":{"ls":5,"idb":6}}' | Set-Content "$sc\.claude-app-seats\D\sidebar-departure.json"
  $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'stash'; STUB_LOG = $env:STUB_LOG }
  $bl = Get-Content "$sc\.claude-app-seats\D\sidebar-baseline.json" -Raw | ConvertFrom-Json
  $ij = Get-Content "$sc\.claude-app-seats\.sidebar-sync-work\$gen\install.json" -Raw | ConvertFrom-Json
  Check 'stash-lineage switch: the baseline keeps gen bX, the install record carries THIS gen, the installed pair''s pins and the baseline''s created, and the verifier is started for it' ($bl.gen -eq 'bX' -and $ij.gen -eq $gen -and $ij.target -eq 'D' -and $ij.pair -eq 'stash' -and $ij.pins -contains 'stash' -and $ij.created.ls -eq $bl.created.ls -and $r.out -match "VERIFY D $gen") "rc=$($r.rc) $($r.out)"

  # r6 (3): a known-owner target without a readable config.json holding the owner's uuid is refused BEFORE anything moves
  foreach ($case in @('missing', 'noaccount', 'unreadable')) {
    $sc = New-Scenario "r6e$case"
    $cj = "$sc\.claude-app-seats\D\config.json"
    if ($case -eq 'missing') { Remove-Item -LiteralPath $cj } elseif ($case -eq 'noaccount') { '{"other":1}' | Set-Content $cj } else { 'not json {' | Set-Content $cj }
    $r = Invoke-Scenario $sc "Invoke-Switch 'D'" @{ STUB_MODE = 'stash' }
    Check "preflight ($case config.json of a known-owner target): REFUSED before the move, live login and backups untouched" ($r.rc -eq 1 -and $r.out -match 'REFUSED: seat .D. has no readable config.json' -and (Rdf "$sc\AppData\Claude\$ls") -eq 'live-C' -and -not (Test-Path "$sc\.claude-app-seats\.swap-backups\$gen") -and (Rdf "$sc\.claude-app-seats\C\$ls") -eq 'C-stash') "rc=$($r.rc) $($r.out)"
  }
} catch { $fail++; Write-Host "  FAIL  the test itself stopped: $_" -ForegroundColor Red } finally {
  foreach ($k in $keep.Keys) { Set-Item "env:$k" $keep[$k] }
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'test-app-relaunch: all passed' -ForegroundColor Green
