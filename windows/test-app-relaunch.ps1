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
`$script:n = 0
function Get-AppProcs { `$script:n++; if (`$script:n -eq 1) { `$o = [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]1 }; `$o | Add-Member ScriptMethod CloseMainWindow { `$true }; `$o } }
function Send-AppEndSession { `$true }
function Start-Process { param(`$FilePath) Write-Host "LAUNCHED `$FilePath" }
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
`$script:n = 0
function Get-AppProcs { `$script:n++; if (`$script:n -eq 1) { `$o = [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]1 }; `$o | Add-Member ScriptMethod CloseMainWindow { `$true }; `$o } }
function Send-AppEndSession { `$true }
function Start-Process { param(`$FilePath) Write-Host "LAUNCHED `$FilePath" }
function Find-AppLauncher { `$null }
function Invoke-Switch { `$script:SwitchDone = `$true }
Invoke-SwitchRelaunch B
"@
  $out = & pwsh -NoProfile -Command $child 2>&1 | Out-String
  Check 'switch ok, relaunch failed: exit 3, says the switch stood' ($LASTEXITCODE -eq 3 -and $out -match 'Switched to seat B, but the Claude app could not be reopened' -and $out -notmatch 'LAUNCHED') "rc=$LASTEXITCODE out=$out"

  # switch refused AND the app cannot be reopened: the refusal's exit code, and a last line that still says the switch failed
  $child = @"
. '$script_'
`$script:n = 0
function Get-AppProcs { `$script:n++; if (`$script:n -eq 1) { `$o = [pscustomobject]@{ Id = 7; MainWindowHandle = [IntPtr]1 }; `$o | Add-Member ScriptMethod CloseMainWindow { `$true }; `$o } }
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
} finally {
  foreach ($k in $keep.Keys) { Set-Item "env:$k" $keep[$k] }
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'test-app-relaunch: all passed' -ForegroundColor Green
