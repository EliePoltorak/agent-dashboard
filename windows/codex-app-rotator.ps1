<#
codex-app-rotator.ps1 — switch the Codex DESKTOP APP between accounts, the Codex counterpart
of claude-app-rotator.ps1.

Unlike Claude (where the app has its OWN login store separate from the CLI), the Codex app's
backend is `codex app-server`, which authenticates through the SAME ~/.codex/auth.json as the
CLI. So there is nothing app-specific to swap — switching the account is just the CLI rotator's
job. What the APP additionally needs is a clean restart, because a running app caches the token
in memory and rewrites auth.json on refresh (which would clobber a switch made underneath it).

This script therefore: quits the app -> switches the shared login via codex-cli-account.ps1 ->
relaunches the app so its app-server reads the new account. --status/--list/--usage delegate to
the CLI rotator (same accounts).

USAGE  (run from a normal terminal)
  codex-app-rotator.ps1 --status
  codex-app-rotator.ps1 --list
  codex-app-rotator.ps1 --usage [--refresh]
  codex-app-rotator.ps1 --switch <label>     (aliases: --use/--to, or just <label>)
  codex-app-rotator.ps1 --rotate              (aliases: --toggle/--swap/--next)
  codex-app-rotator.ps1 --no-relaunch <...>   (switch but leave the app closed)
#>
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
$ErrorActionPreference = 'Continue'

$here  = Split-Path -Parent $PSCommandPath
$Cli   = Join-Path $here 'codex-cli-account.ps1'
$Aumid = 'OpenAI.Codex_2p2nqsd0c76g0!App'

function Get-CodexDesktopProcs {
  # Same detector as codex-cli-account.ps1. The window is ChatGPT.exe in the
  # OpenAI.Codex package; the login is held by its local-bin app-server child.
  # Quit the whole tree or a surviving child keeps the cached token and rewrites auth.json.
  $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
  $ids = New-Object 'System.Collections.Generic.HashSet[int]'
  foreach ($p in $all) {
    $path = [string]$p.ExecutablePath
    $cmd = [string]$p.CommandLine
    $desktop = ($p.Name -eq 'ChatGPT.exe' -and $path -like '*\WindowsApps\OpenAI.Codex*\ChatGPT.exe') -or
               ($p.Name -eq 'Codex.exe' -and $path -like '*\WindowsApps\OpenAI.Codex*') -or
               ($p.Name -eq 'codex.exe' -and $cmd -match 'codex-app-tools|code_mode_host') -or
               ($p.Name -eq 'codex.exe' -and $cmd -match 'exec-server' -and $cmd -match 'codex-cloud-environments')
    if ($desktop) { [void]$ids.Add([int]$p.ProcessId) }
  }
  $changed = $true
  while ($changed) {
    $changed = $false
    foreach ($p in $all) {
      if ($ids.Contains([int]$p.ParentProcessId) -and -not $ids.Contains([int]$p.ProcessId)) {
        [void]$ids.Add([int]$p.ProcessId)
        $changed = $true
      }
    }
  }
  if ($ids.Count -eq 0) { return @() }
  @(Get-Process -Id @($ids) -ErrorAction SilentlyContinue)
}
function App-Procs { @(Get-CodexDesktopProcs) }
function Quit-App {
  $p = @(App-Procs)
  if (-not $p) { return }
  Write-Host "Quitting the Codex app (PIDs $($p.Id -join ', '))..." -ForegroundColor DarkGray
  # Ask the window to close first and give the app-server time to finish any token refresh
  # and write auth.json. A force-kill mid-refresh loses the new token and leaves a revoked
  # one on disk. Force-kill only what is still running after 15s.
  foreach ($w in @($p | Where-Object { $_.MainWindowHandle -ne 0 })) { [void]$w.CloseMainWindow() }
  $deadline = (Get-Date).AddSeconds(15)
  while ((Get-Date) -lt $deadline -and @(App-Procs).Count) { Start-Sleep -Milliseconds 500 }
  $left = @(App-Procs)
  if ($left) {
    Write-Host "Still running after 15s; force-closing PIDs $($left.Id -join ', ')." -ForegroundColor DarkYellow
    $script:ForceKilled = $true
    $left | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep 2
  }
}
function Launch-App {
  Write-Host "Relaunching the Codex app..." -ForegroundColor DarkGray
  Start-Process "shell:AppsFolder\$Aumid"
}
function RunCli([string[]]$cliArgs) { & pwsh -NoProfile -File $Cli @cliArgs }

# ---- flag parse ----
$mode=$null; $label=$null; $Refresh=$false; $NoRelaunch=$false; $AllowShared=$false
$a = @($Args | Where-Object { $_ })
for ($i=0; $i -lt $a.Count; $i++) {
  switch -regex ($a[$i]) {
    '^--?(status|st)$'                 { $mode='status' }
    '^--?(list|ls)$'                   { $mode='list' }
    '^--?(usage|u)$'                   { $mode='usage' }
    '^--?refresh$'                     { $Refresh=$true }
    '^--?no-?relaunch$'                { $NoRelaunch=$true }
    '^--?allow-vm-shared$'             { $AllowShared=$true }
    '^--?(rotate|toggle|swap|next)$'   { $mode='rotate' }
    '^--?(switch|use|to)$'             { $mode='switch'; if ($i+1 -lt $a.Count){ $label=$a[$i+1]; $i++ } }
    '^--?(help|h|\?)$'                 { $mode='help' }
    default { if (-not $mode -and $a[$i] -notmatch '^-') { $mode='switch'; $label=$a[$i] }
              else { Write-Host "Unknown: $($a[$i])" -ForegroundColor Red; exit 2 } }
  }
}
if (-not $mode) { $mode='status' }

switch ($mode) {
  'help'   { Get-Content $PSCommandPath -TotalCount 26 | Select-Object -Skip 1; break }
  'status' { RunCli @('--status'); break }
  'list'   { RunCli @('--list'); break }
  'usage'  { $x=@('--usage'); if ($Refresh){ $x+='--refresh' }; RunCli $x; break }
  { $_ -in 'switch','rotate' } {
    if ($mode -eq 'switch' -and -not $label) { Write-Host "Usage: --switch <label>" -ForegroundColor Red; exit 1 }
    $wasRunning = @(App-Procs).Count -gt 0
    Quit-App
    $x = if ($mode -eq 'switch') { @('--switch', $label) } else { @('--rotate') }
    if ($AllowShared) { $x += '--allow-vm-shared' }
    RunCli $x
    if ($LASTEXITCODE -ne 0) {
      $code = $LASTEXITCODE
      # Nothing changed, so put the app back the way it was.
      # A force-kill can tear auth.json mid-refresh. Relaunching onto a torn file would hand the app
      # garbage, and restoring an older backup could replay a revoked token, so stop and say so
      # (Grok review 2026-10-30).
      $authOk = $true
      if ($script:ForceKilled) { try { $null = Get-Content "$env:USERPROFILE\.codex\auth.json" -Raw | ConvertFrom-Json } catch { $authOk = $false } }
      if (-not $authOk) {
        Write-Host "Switch failed (exit $code), and ~/.codex/auth.json no longer parses after the force-close. NOT relaunching." -ForegroundColor Red
        Write-Host "Check it by hand; the pre-switch copies are in ~/.codex/.auth-backups/. A plain 'codex login' is the safe fix." -ForegroundColor Red
      }
      elseif ($wasRunning -and -not $NoRelaunch) { Launch-App; Write-Host "Switch failed (exit $code); relaunched the app on its old account." -ForegroundColor Red }
      else { Write-Host "Switch failed (exit $code)." -ForegroundColor Red }
      exit $code
    }
    if (-not $NoRelaunch) { Launch-App; Write-Host "The app will come up on the new account." -ForegroundColor Green }
    else { Write-Host "Left the app closed (--no-relaunch). Reopen it to use the new account." -ForegroundColor Green }
    break
  }
}
