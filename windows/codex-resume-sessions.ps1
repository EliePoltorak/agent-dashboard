<#
codex-resume-sessions.ps1 — after a Codex seat rotation, nudge Codex to resume on the
new account. The Codex mirror of claude-resume-sessions.ps1; shares the same input engine.

  * Codex CLI interactive TUI sessions:
      - in a VS Code integrated terminal (ConPTY): pinned to the CODEX_HOME/auth.json they
        launched with, so they must RESTART to pick up the newly-rotated account. Each is
        killed, then a fresh terminal is opened (focus VS Code + Ctrl+Shift+`), relaunched
        with `codex resume --last -C <cwd>`, and given the resume prompt (real keystrokes —
        ConPTY can't take WriteConsoleInput).
      - own-window (e.g. a merge-pr codex review console): merge-pr already points these at a
        spendable account, so they just get the prompt in place via WriteConsoleInput.

  * Codex desktop App (GUI): focus its window and type the prompt into the composer. With
    -RestartApp it is closed and relaunched first (to pick up a rotated auth.json), then
    prompted. GUI automation is best-effort: the composer must be the focused control after
    launch (it is, on a normal Codex start). Watch the first run.

USAGE
  codex-resume-sessions.ps1              # CLI sessions + prompt the Codex app
  codex-resume-sessions.ps1 -DryRun
  codex-resume-sessions.ps1 -CliOnly / -AppOnly
  codex-resume-sessions.ps1 -RestartApp # close+reopen the Codex app before prompting it
  codex-resume-sessions.ps1 -Prompt 'resume'
#>
[CmdletBinding()]
param(
  [string]$Prompt = 'resume',
  [switch]$DryRun,
  [switch]$CliOnly,
  [switch]$AppOnly,
  [switch]$RestartApp,
  [int]$CodexStartupMs = 9000,
  [string]$CodexCli = "$env:USERPROFILE\AppData\Local\Programs\OpenAI\Codex\bin\codex.exe",
  [string]$CodexAumid = 'OpenAI.Codex_2p2nqsd0c76g0!App'
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
. (Join-Path $here 'SessionInput.ps1')

# reuse the PEB cwd reader from the Claude script's type if already loaded; else define it
if (-not ('ProcCwd' -as [type])) {
  Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class ProcCwd {
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, ref PBI pbi, int len, out int ret);
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(int a, bool i, int pid);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr h, IntPtr b, byte[] buf, int size, out int read);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] struct PBI { public IntPtr R1, Peb, R3, R4, Pid, R6; }
  static IntPtr RP(IntPtr h, IntPtr a){ var b=new byte[8]; int r; if(!ReadProcessMemory(h,a,b,8,out r)||r!=8) return IntPtr.Zero; return (IntPtr)BitConverter.ToInt64(b,0);}
  public static string Get(int pid){
    IntPtr h=OpenProcess(0x0400|0x0010,false,pid); if(h==IntPtr.Zero) return null;
    try{ var pbi=new PBI(); int ret; if(NtQueryInformationProcess(h,0,ref pbi,Marshal.SizeOf(pbi),out ret)!=0) return null;
      IntPtr pp=RP(h,(IntPtr)((long)pbi.Peb+0x20)); if(pp==IntPtr.Zero) return null;
      var lb=new byte[2]; int rr; if(!ReadProcessMemory(h,(IntPtr)((long)pp+0x38),lb,2,out rr)) return null;
      ushort len=BitConverter.ToUInt16(lb,0); if(len==0||len>1040) return null;
      IntPtr buf=RP(h,(IntPtr)((long)pp+0x38+0x8)); if(buf==IntPtr.Zero) return null;
      var s=new byte[len]; if(!ReadProcessMemory(h,buf,s,len,out rr)||rr!=len) return null;
      return Encoding.Unicode.GetString(s).TrimEnd('\\');
    } finally { CloseHandle(h); }
  }
}
'@
}

$procs = Get-CimInstance Win32_Process
$byId  = @{}; foreach ($p in $procs) { $byId[[int]$p.ProcessId] = $p }
function Ancestors([int]$pid_) {
  $out=@(); $cur=$pid_; $d=0
  while ($cur -and $d -lt 20) { $p=$byId[[int]$cur]; if(-not $p){break}; $out+=$p; $cur=[int]$p.ParentProcessId; $d++ }
  $out
}
function Is-InVSCode([int]$pid_) { foreach ($a in (Ancestors $pid_)) { if ($a.Name -eq 'Code.exe') { return $true } } return $false }
function VSCodeWindowHwnd([int]$pid_) {
  foreach ($a in (Ancestors $pid_)) {
    if ($a.Name -eq 'Code.exe') { $wp=Get-Process -Id $a.ProcessId -EA SilentlyContinue; if ($wp -and $wp.MainWindowHandle -ne 0) { return $wp.MainWindowHandle } }
  }
  $c = Get-Process Code -EA SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Sort-Object WorkingSet64 -Descending | Select-Object -First 1
  if ($c) { return $c.MainWindowHandle } else { return [IntPtr]::Zero }
}
$selfAncestorPids = (Ancestors ([int]$PID) | ForEach-Object { [int]$_.ProcessId })

# interactive Codex CLI TUI = the standalone codex.exe (…\Programs\OpenAI\Codex\bin), NOT the
# packaged desktop app / its bundled backend (…\WindowsApps\OpenAI.Codex…, incl. the Electron
# `Codex.exe` shell which -eq matches case-insensitively), NOT app-server/exec/review/mcp backends.
$targets = $procs | Where-Object {
  $_.Name -eq 'codex.exe' -and $_.CommandLine -and
  $_.CommandLine -notlike '*\WindowsApps\OpenAI.Codex*' -and
  $_.CommandLine -notlike '*app-server*' -and
  $_.CommandLine -notlike '*exec-server*' -and
  $_.CommandLine -notlike '*remote-control*' -and
  $_.CommandLine -notlike '* exec *' -and
  $_.CommandLine -notlike '* review*' -and
  $_.CommandLine -notlike '*mcp*' -and
  $_.CommandLine -notlike '*--type=*'
}

$vscode=@(); $own=@()
foreach ($t in $targets) {
  if ($selfAncestorPids -contains [int]$t.ProcessId) { continue }
  $rec = [pscustomobject]@{ Pid=[int]$t.ProcessId; Cmd=$t.CommandLine; Cwd=[ProcCwd]::Get([int]$t.ProcessId); InVSCode=(Is-InVSCode ([int]$t.ProcessId)) }
  if ($rec.InVSCode) { $vscode+=$rec } else { $own+=$rec }
}

$appProc = Get-Process Codex -EA SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
Write-Host ("Codex: {0} CLI TUI session(s) ({1} VS Code, {2} own-window); desktop app {3}." -f `
  ($vscode.Count+$own.Count), $vscode.Count, $own.Count, ($(if ($appProc) { "running (hwnd $($appProc.MainWindowHandle))" } else { 'not running' }))) -ForegroundColor Cyan
foreach ($r in ($vscode+$own)) {
  $k = if ($r.InVSCode) { 'vscode' } else { 'own' }
  Write-Host ("  [{0}] pid {1}  cwd {2}" -f $k, $r.Pid, ($(if ($r.Cwd){$r.Cwd}else{'?'}))) -ForegroundColor DarkGray
}

if ($DryRun) { Write-Host "`n-DryRun: nothing changed." -ForegroundColor Yellow; return }

# ---- Codex CLI sessions ----
if (-not $AppOnly) {
  foreach ($r in $vscode) {
    Write-Host "`nVS Code Codex session pid $($r.Pid): exit + resume" -ForegroundColor Green
    $hwnd = VSCodeWindowHwnd $r.Pid
    if ($hwnd -eq [IntPtr]::Zero) { Write-Host "  no VS Code window; skipping" -ForegroundColor Red; continue }
    Stop-Process -Id $r.Pid -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 500
    if (-not [SessionInput]::Focus($hwnd)) { Write-Host "  couldn't focus VS Code; skipping" -ForegroundColor Red; continue }
    Start-Sleep -Milliseconds 400
    [SessionInput]::CtrlShift(0xC0)
    Start-Sleep -Milliseconds 2500
    $launch = if ($r.Cwd) { "codex resume --last -C '$($r.Cwd.Replace("'","''"))'" } else { "codex resume --last" }
    [SessionInput]::TypeText($launch); [SessionInput]::Enter()
    Write-Host "  launched: $launch" -ForegroundColor DarkGray
    Start-Sleep -Milliseconds $CodexStartupMs
    [SessionInput]::TypeText($Prompt); [SessionInput]::Enter()
    Write-Host "  typed prompt: '$Prompt'" -ForegroundColor DarkGray
  }
  $injector = Join-Path $here 'Inject-ConsoleInput.ps1'
  foreach ($r in $own) {
    Write-Host "`nOwn-window Codex session pid $($r.Pid): prompt '$Prompt'" -ForegroundColor Green
    $out = & pwsh -NoProfile -File $injector -TargetPid $r.Pid -Text $Prompt 2>&1
    Write-Host "  $out" -ForegroundColor DarkGray
  }
}

# ---- Codex desktop App ----
if (-not $CliOnly) {
  if ($RestartApp) {
    Write-Host "`nCodex app: restart + prompt" -ForegroundColor Green
    Get-Process Codex -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep 2
    Start-Process "shell:AppsFolder\$CodexAumid"    # relaunch the packaged app (picks up rotated auth.json)
    Start-Sleep -Milliseconds $CodexStartupMs
    $appProc = Get-Process Codex -EA SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  }
  if ($appProc) {
    Write-Host "`nCodex app: focus + prompt '$Prompt'" -ForegroundColor Green
    if ([SessionInput]::Focus($appProc.MainWindowHandle)) {
      Start-Sleep -Milliseconds 500
      [SessionInput]::TypeText($Prompt); [SessionInput]::Enter()
      Write-Host "  typed prompt into the focused composer." -ForegroundColor DarkGray
      Write-Host "  (verify it landed in the message box; if not, click the composer and re-run -AppOnly.)" -ForegroundColor DarkYellow
    } else { Write-Host "  couldn't focus the Codex app window." -ForegroundColor Red }
  } elseif (-not $CliOnly) {
    Write-Host "`nCodex app: not running (nothing to prompt; use -RestartApp to launch it)." -ForegroundColor DarkGray
  }
}

Write-Host "`nDone." -ForegroundColor Cyan
