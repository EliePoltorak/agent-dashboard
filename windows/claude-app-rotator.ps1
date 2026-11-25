<#
claude-app-rotator.ps1  — switch the Claude DESKTOP app between Anthropic accounts,
by swapping the app's login state. (Separate from the CLI rotator,
claude-cli-account.ps1, which swaps the token CLI *sessions* use.)

WHY THIS EXISTS
  On this machine the app login is owned by the desktop app: the OAuth token
  lives in %APPDATA%\Claude\config.json (oauth:tokenCacheV2) plus the Electron web
  session (Local Storage / Session Storage / Network / Partitions / IndexedDB).
  CLAUDE_CONFIG_DIR (the CLI rotator) CANNOT switch the app account — only this can.

SAFETY CONTRACT
  - Copy-only. The ONLY "removal" on switch is a MOVE-ASIDE of the current login
    dirs into a timestamped backup (fully reversible) before the new ones are copied
    in. Nothing is ever deleted. Caches / vm_bundles are never touched.
  - REQUIRES the desktop app fully quit (capture + switch/rotate). Quitting the app
    also ends any CLI session bridged through it, so RUN THIS FROM A PLAIN TERMINAL,
    NOT from inside a Claude session.

USAGE  (run in normal PowerShell, app CLOSED for capture/switch/rotate)
  claude-app-rotator.ps1 --status            # app state, live account + UUID, profiles
  claude-app-rotator.ps1 --list              # list captured account profiles
  claude-app-rotator.ps1 --switch <label>    # back up current login, load profile <label>
  claude-app-rotator.ps1 --switch <label> --relaunch
                                             # close the running app first (gracefully; aborts if it
                                             # is still running after 30 s), switch, reopen the app;
                                             # exit 3 if the switch stood but the app could not be reopened
  claude-app-rotator.ps1 --rotate [label]    # cycle to the next profile (or switch to <label>)
  claude-app-rotator.ps1 --capture <label>   # save the CURRENT login as profile <label>
  claude-app-rotator.ps1 --usage [--refresh]  # per-account usage incl. Fable (app seats = the
                                              # same Anthropic accounts; delegates to the CLI rotator)
  aliases: --toggle/--swap/--next = --rotate ; --use/--to = --switch ; --save/--add = --capture

  After a successful --switch/--rotate this also runs sync-app-history.ps1, so the
  account you land on shows your CLI sessions in its history. Then reopen the app.
  It also syncs the sidebar PINS: those you changed on the seat you leave are pinned/unpinned on the seat you enter
  (sidebar-sync.py; README-claude-rotator.md, "Sidebar pins follow you across seats"). The last line says what happened.

TYPICAL SETUP
  1) Log into account A in the app. Quit app. Run: --capture A
  2) Log into account B in the app (Settings > Log out > log in as B). Quit. --capture B
  3) Thereafter: quit app, run --switch A / --switch B / --rotate, reopen app.
#>

param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)

$ErrorActionPreference = 'Continue'
$AppDir    = "$env:APPDATA\Claude"
$SeatRoot  = "$env:USERPROFILE\.claude-app-seats"
$HomeState = "$env:USERPROFILE\.claude.json"
$LoginFiles = @('config.json')
$LoginDirs  = @('Local Storage','Session Storage','Network','Partitions','IndexedDB')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Get-AppProcs {
  # Match BOTH desktop-app install flavours. The MSIX (WindowsApps) build was removed
  # on 2026-08-09 after Windows flagged it Modified/NeedsRemediation and refused to
  # activate it; the app now ships as a Squirrel install under %LOCALAPPDATA%.
  # Matching only the MSIX path made this return nothing, so Assert-Closed silently
  # passed and a switch would have swapped Local Storage / Network / IndexedDB out
  # from under a RUNNING app. Keep both patterns so either install is detected.
  Get-Process -ErrorAction SilentlyContinue | Where-Object {
    try {
      $_.Path -like '*\WindowsApps\Claude_*\app\Claude.exe' -or
      $_.Path -like '*\AnthropicClaude\*\claude.exe'
    } catch { $false }
  }
}
function Get-LiveAccountEmail {
  if (Test-Path $HomeState) {
    try { $j = Get-Content $HomeState -Raw | ConvertFrom-Json -AsHashtable
      if ($j.ContainsKey('oauthAccount')) { return $j['oauthAccount']['emailAddress'] } } catch {}
  }
  return '(unknown)'
}
function Get-AppAccountUuid {
  $cfg = Join-Path $AppDir 'config.json'
  if (Test-Path $cfg) {
    try { $j = Get-Content $cfg -Raw | ConvertFrom-Json -AsHashtable
      if ($j.ContainsKey('lastKnownAccountUuid')) { return $j['lastKnownAccountUuid'] } } catch {}
  }
  return '(unknown)'
}
function Get-SeatOwnerUuid([string]$name) {
  # owner-uuid.txt = which account this seat IS, written at --capture and never touched
  # by re-capture. The permanent anchor every integrity check compares against.
  $f = Join-Path (Join-Path $SeatRoot $name) 'owner-uuid.txt'
  if (Test-Path $f) { (Get-Content $f -Raw).Trim() } else { '' }
}
function Find-SeatByUuid([string]$uuid) {
  # Which captured seat is this account? The uuid in the live config.json is the ONLY
  # ground truth for what's logged in; .active and ~/.claude.json both drift when the
  # user logs in/out manually inside the app.
  if (-not $uuid -or $uuid -eq '(unknown)') { return '' }
  foreach ($p in Get-ChildItem $SeatRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^\.' }) {
    if ((Get-SeatOwnerUuid $p.Name) -eq $uuid) { return $p.Name }
    $m = Join-Path $p.FullName 'meta.txt'   # fallback for seats captured before owner files
    if ((Test-Path $m) -and ((Get-Content $m -Raw) -match [regex]::Escape("uuid=$uuid"))) { return $p.Name }
  }
  return ''
}
function Get-ProfileEmail([string]$name) {
  # Prefer the correct email from the CLI account of the same label; fall back to meta.
  $cli = Join-Path (Join-Path (Join-Path $env:USERPROFILE '.claude-cli-accounts') $name) 'email.txt'
  if (Test-Path $cli) { return (Get-Content $cli -Raw).Trim() }
  $meta = Join-Path (Join-Path $SeatRoot $name) 'meta.txt'
  if (Test-Path $meta) { return ((Get-Content $meta -Raw) -replace '.*account=([^ ]+).*', '$1').Trim() }
  return '(no email)'
}
function Resolve-Label([string]$l) {
  # Canonicalize to the seat dir's real name: NTFS is case-insensitive, so '--rotate a'
  # switches into the A dir but would record 'a' -- which the case-SENSITIVE IndexOf in
  # rotate then can't find, breaking the cycle. Resolve once at every entry point.
  if (-not $l) { return $l }
  $hit = Get-ChildItem $SeatRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '^\.' -and $_.Name -ieq $l } | Select-Object -First 1
  if ($hit) { $hit.Name } else { $l }
}
function Assert-Closed {
  $p = @(Get-AppProcs)
  if ($p.Count -gt 0) {
    Write-Host "BLOCKED: the Claude desktop app is RUNNING (PIDs: $($p.Id -join ', '))." -ForegroundColor Red
    Write-Host "Fully quit it first (tray icon > Quit, or close every window), then re-run." -ForegroundColor Yellow
    Write-Host "Note: quitting the app also ends any CLI session bridged through it." -ForegroundColor DarkGray
    exit 1
  }
}
function Enter-SeatLock {
  # Shared with claude-app-seat-keepalive.ps1: it refreshes IDLE seats' tokens in place, so a
  # switch/capture must never interleave with it (a refresh rotates the server-side token; losing
  # the race would copy a just-revoked token into the app). DeleteOnClose = a crash can't wedge it.
  $p = Join-Path $SeatRoot '.seat-write.lock'
  for ($i = 0; $i -lt 90; $i++) {
    try { return [IO.FileStream]::new($p, 'CreateNew', 'Write', 'None', 1, [IO.FileOptions]::DeleteOnClose) } catch { Start-Sleep 1 }
  }
  Write-Host "BLOCKED: $p is held (the seat keep-alive is refreshing a seat). Re-run in a minute." -ForegroundColor Red
  exit 1
}
$script:CloseWaitSec = 30
function Close-AppGracefully {
  # --relaunch: ask every app window to close, then wait. Never force-kills: a kill mid-write can tear
  # the login storage this script is about to move aside. Returns $true once no app process is left.
  $p = @(Get-AppProcs)
  if ($p.Count -eq 0) { return $true }
  Write-Host "Closing the Claude app (PIDs $($p.Id -join ', '))..." -ForegroundColor DarkGray
  foreach ($w in @($p | Where-Object { $_.MainWindowHandle -ne 0 })) { [void]$w.CloseMainWindow() }
  $deadline = (Get-Date).AddSeconds($script:CloseWaitSec)
  while ((Get-Date) -lt $deadline -and @(Get-AppProcs).Count) { Start-Sleep -Milliseconds 500 }
  return (@(Get-AppProcs).Count -eq 0)
}
function Find-AppLauncher {
  # The installed app's launcher, as {file; args}: the Squirrel stub the Start-menu shortcut runs (it starts the newest
  # app-* build), else Squirrel's Update.exe --processStart, else the MSIX package by its AUMID. $null when none is found.
  $sq = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
  if (Test-Path (Join-Path $sq 'claude.exe')) { return @{ file = (Join-Path $sq 'claude.exe'); args = @() } }
  if (Test-Path (Join-Path $sq 'Update.exe')) { return @{ file = (Join-Path $sq 'Update.exe'); args = @('--processStart', 'claude.exe') } }
  try {
    $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction Stop | Select-Object -First 1
    if ($pkg) {
      $id = @((Get-AppxPackageManifest $pkg).Package.Applications.Application)[0].Id
      if ($id) { return @{ file = "shell:AppsFolder\$($pkg.PackageFamilyName)!$id"; args = @() } }
    }
  } catch {}
  return $null
}
function Start-ClaudeApp {
  $l = Find-AppLauncher
  if (-not $l) { Write-Host "Could not find the installed Claude app to reopen; open it from the Start menu." -ForegroundColor DarkYellow; return $false }
  try {
    # The app is a user-facing program: it must not inherit this shell's class. The dashboard server runs this script at Idle (or BelowNormal), and a
    # child starts at its parent's class, so the shell goes to Normal for the launch and back after: the reverse of Get-CliVersion (claude-cli-account.ps1).
    $me = Get-Process -Id $PID; $was = $me.PriorityClass
    try {
      if ("$was" -eq 'Idle' -or "$was" -eq 'BelowNormal') { try { $me.PriorityClass = 'Normal' } catch {} }
      if ($l.args.Count) { Start-Process -FilePath $l.file -ArgumentList $l.args } else { Start-Process -FilePath $l.file }
    } finally { try { $me.PriorityClass = $was } catch {} }
    return $true
  } catch { Write-Host "Could not reopen the Claude app: $($_.Exception.Message)" -ForegroundColor DarkYellow; return $false }
}
# ---- sidebar PINS follow you across seats (agent-dashboard issue #10; engine: sidebar-sync.py, design: README "Sidebar pins follow you across seats") ----
# The rotator holds the seat lock with the app closed and owns every durable step. Python only READS the seats and builds a staging copy of the
# two sidebar databases (Local Storage, IndexedDB) under .sidebar-sync-work\<gen>\; this script installs it, and commits the shared config.
$SidebarDirs    = @('Local Storage', 'IndexedDB')
$SidebarWork    = Join-Path $SeatRoot '.sidebar-sync-work'
$SidebarBackups = Join-Path $SeatRoot '.sidebar-sync-backups'
$SidebarKeep    = 10
$script:StageTimeoutSec = 60
$script:StartWaitSec    = 30
$script:SeatLockHeld    = $null
$script:LockOwnedByRelaunch = $false   # --relaunch holds ONE lock from before the app is closed to after it is up again; Invoke-Switch then neither takes nor releases it
$GenPattern = '^\d{8}-\d{6}(-[0-9a-f]{4,12})?$'
$script:ProfileIntact   = $true      # after a refusal: is the old login verified back in place? (the relaunch reopens the app only if so)
$script:SidebarNote     = ''         # 'Sidebar: ...' appended to the last line, which the dashboard shows
$script:RobocopyRc      = 0

function Release-SwitchLock { if (-not $script:LockOwnedByRelaunch) { Release-SeatLock } }
function New-SwitchGen {
  # One generation per switch, allocated UNDER the seat lock: the second-resolution stamp plus a pid/random suffix, and New-Item (no -Force) fails
  # if the directory exists, so two switches can never share a staging directory. The same name labels the swap backup and the config backup.
  $null = New-Item -ItemType Directory -Path $SidebarWork -Force
  for ($i = 0; $i -lt 20; $i++) {
    $g = '{0}-{1:x4}{2:x4}' -f $stamp, ($PID -band 0xFFFF), (Get-Random -Maximum 65536)
    try { $null = New-Item -ItemType Directory -Path (Join-Path $SidebarWork $g) -ErrorAction Stop; return $g } catch {}
  }
  throw 'could not allocate a unique sidebar generation'
}
function Release-SeatLock { if ($script:SeatLockHeld) { try { $script:SeatLockHeld.Dispose() } catch {}; $script:SeatLockHeld = $null } }
function Try-EnterSeatLock {
  # Enter-SeatLock without the exit: the relaunch decides under the lock but must never abort a finished switch.
  $null = New-Item -ItemType Directory -Path $SeatRoot -Force -ErrorAction SilentlyContinue
  $p = Join-Path $SeatRoot '.seat-write.lock'
  for ($i = 0; $i -lt 90; $i++) {
    try { return [IO.FileStream]::new($p, 'CreateNew', 'Write', 'None', 1, [IO.FileOptions]::DeleteOnClose) } catch { Start-Sleep 1 }
  }
  return $null
}
function Write-JsonAtomic([string]$path, $obj) {
  # temp sibling, then replace: a failure leaves the old file in place
  $tmp = "$path.tmp"
  [IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 8 -Compress), [Text.UTF8Encoding]::new($false))
  [IO.File]::Move($tmp, $path, $true)
}
function Read-JsonFile([string]$path) {
  try { Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { $null }
}
function Get-LiveCreation {
  # CreationTime (Windows file time) of each live sidebar leveldb dir: copy-in creates fresh dirs, so this changes at every activation and also
  # catches a database the app recreated (sidebar-sync.py reads the same numbers).
  $o = @{}
  foreach ($k in @(@('ls', "$AppDir\Local Storage\leveldb"), @('idb', "$AppDir\IndexedDB\https_claude.ai_0.indexeddb.leveldb"))) {
    $o[$k[0]] = if (Test-Path -LiteralPath $k[1]) { (Get-Item -LiteralPath $k[1]).CreationTimeUtc.ToFileTimeUtc() } else { $null }
  }
  $o
}
function Write-DepartureCheckpoint([string]$seat, $created) {
  # <seat>\sidebar-departure.json = {baseline, installed, created}, written after a good re-capture. An unconsumed one keeps its OLD baseline:
  # the seat has run on its stash pair since, so that baseline is still the right comparison and both sets of edits are read together.
  $d = Join-Path $SeatRoot $seat; $cp = Join-Path $d 'sidebar-departure.json'
  $baseline = $null
  if (Test-Path -LiteralPath $cp) {
    $old = Read-JsonFile $cp
    $baseline = if ($old -and $old.ContainsKey('baseline')) { $old['baseline'] } else { @{ valid = $false } }
  } else {
    $baseline = Read-JsonFile (Join-Path $d 'sidebar-baseline.json')
    if ($null -eq $baseline) { $baseline = @{ valid = $false } }
  }
  Write-JsonAtomic $cp @{ baseline = $baseline; installed = (Read-JsonFile (Join-Path $d 'sidebar-installed.json')); created = $created }
}
function Get-SidebarSyncCommand {
  # @{ file; args } for sidebar-sync.py (the real python.exe, not the py launcher, so stopping the PID stops the work), or $null.
  $script = Join-Path $PSScriptRoot 'sidebar-sync.py'
  if (-not (Test-Path -LiteralPath $script)) { return $null }
  $py = $null
  try { $py = @(& py -3 -c 'import sys; print(sys.executable)' 2>$null)[0] } catch {}
  if (-not $py -or -not (Test-Path -LiteralPath $py)) { return $null }
  @{ file = $py; args = @('-I', $script) }
}
function Join-Args([string[]]$a) { ($a | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' ' }
function Invoke-SidebarStage([string]$prev, [string]$label, [string]$gen) {
  # --stage in a child, 60 s in all, else that PID is stopped. -> @{ ran; reason; gdir }. ran = exit 0 in time (its files are then trustworthy).
  $gdir = Join-Path $SidebarWork $gen
  New-Item -ItemType Directory -Path $gdir -Force | Out-Null
  $cmd = Get-SidebarSyncCommand
  if (-not $cmd) { return @{ ran = $false; reason = 'python or sidebar-sync.py was not found'; gdir = $gdir } }
  $argv = @($cmd.args) + @('--stage', '--leaving', $prev, '--target', $label, '--gen', $gen, '--seats', $SeatRoot, '--app', $AppDir)
  try {
    $p = Start-Process -FilePath $cmd.file -ArgumentList (Join-Args $argv) -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $gdir 'stage.out') -RedirectStandardError (Join-Path $gdir 'stage.err')
    if (-not $p.WaitForExit($script:StageTimeoutSec * 1000)) {
      try { Stop-Process -Id $p.Id -Force } catch {}
      return @{ ran = $false; reason = "the stage did not finish in $($script:StageTimeoutSec) s"; gdir = $gdir }
    }
    if ($p.ExitCode -ne 0) { return @{ ran = $false; reason = "the stage failed (exit $($p.ExitCode))"; gdir = $gdir } }
  } catch { return @{ ran = $false; reason = "the stage could not run: $($_.Exception.Message)"; gdir = $gdir } }
  @{ ran = $true; reason = ''; gdir = $gdir }
}
function Publish-SidebarState([string]$gdir) {
  # Only after a stage that exited 0 in time, under the seat lock: the proposed global state replaces the published one (atomic), and each
  # checkpoint the stage read is deleted if it is still the one it hashed. A stage that never finished publishes and consumes nothing.
  $st = Join-Path $gdir 'state.json'
  if (Test-Path -LiteralPath $st) {
    $live = Join-Path $SeatRoot '.sidebar-sync-state.json'
    Copy-Item -LiteralPath $st -Destination "$live.tmp" -Force
    [IO.File]::Move("$live.tmp", $live, $true)
  }
  $cf = Join-Path $gdir 'consumed.txt'
  if (Test-Path -LiteralPath $cf) {
    foreach ($line in @(Get-Content -LiteralPath $cf)) {
      $s, $h = $line -split "`t"
      if (-not $s -or $s -notmatch '^[^\\/.][^\\/]*$') { continue }
      $cp = Join-Path (Join-Path $SeatRoot $s) 'sidebar-departure.json'
      if ((Test-Path -LiteralPath $cp) -and ((Get-FileHash -LiteralPath $cp -Algorithm SHA256).Hash -ieq $h)) { Remove-Item -LiteralPath $cp -Force }
    }
  }
}
function Commit-SidebarConfig([string]$gdir, [string]$pair, [string]$gen) {
  # The shared claude_desktop_config.json carries a third copy of the pin list. Called only after the target's baseline was SAVED, and only when
  # the stage prepared a config (<gen>\config.json exists; no file = the config already matched). Replaced only when it was prepared for the pair
  # actually installed, the app is still closed and the live file is the very one Python read (SHA-256): saved first, then replaced (temp sibling,
  # then Move with overwrite, so a failure leaves the live file in place).
  # -> @{ state = 'committed' | 'failed' | 'otherpair'; why }. 'failed' = it was needed for the installed pair and could not be updated.
  $cf = Join-Path $gdir 'config.json'
  try {
    $c = Get-Content -LiteralPath $cf -Raw | ConvertFrom-Json
    if ($c.pair -ne $pair) { return @{ state = 'otherpair'; why = "config not changed: it was prepared for the $($c.pair) pair, the $pair pair is installed" } }
    if (@(Get-AppProcs).Count -gt 0) { return @{ state = 'failed'; why = 'config not changed: the app is running' } }
    $live = Join-Path $AppDir 'claude_desktop_config.json'
    if ((Get-FileHash -LiteralPath $live -Algorithm SHA256).Hash -ine $c.sha256) { return @{ state = 'failed'; why = 'config not changed: it differs from the one that was read' } }
    $bkd = Join-Path $SidebarBackups $gen
    New-Item -ItemType Directory -Path $bkd -Force | Out-Null
    Copy-Item -LiteralPath $live -Destination (Join-Path $bkd 'claude_desktop_config.json') -Force
    $tmp = "$live.sidebar-sync.tmp"
    [IO.File]::WriteAllBytes($tmp, [Convert]::FromBase64String($c.b64))
    [IO.File]::Move($tmp, $live, $true)
    return @{ state = 'committed'; why = '' }
  } catch { return @{ state = 'failed'; why = "config not changed: $($_.Exception.Message)" } }
}
function Start-SidebarVerify([string]$label, [string]$gen) {
  # --verify detached: it outlives this script (up to 30 min of waiting for the app). It goes through cmd.exe via ShellExecute (no handle
  # inheritance) with both streams redirected to files: a child started with Start-Process -Redirect* still inherits the dashboard's stdout pipe,
  # and the dashboard's wait for this script's output then lasts as long as the child does (measured 2026-11-25).
  try {
    $cmd = Get-SidebarSyncCommand
    if (-not $cmd) { return }
    $gdir = Join-Path $SidebarWork $gen
    New-Item -ItemType Directory -Path $gdir -Force | Out-Null      # the redirects below need it
    $argv = @($cmd.args) + @('--verify', '--gen', $gen, '--target', $label, '--seats', $SeatRoot, '--app', $AppDir)
    $line = '/d /c "{0} {1} > "{2}" 2> "{3}""' -f (Join-Args @($cmd.file)), (Join-Args $argv), (Join-Path $gdir 'verify.out'), (Join-Path $gdir 'verify.err')
    Start-Process -FilePath cmd.exe -ArgumentList $line -WindowStyle Hidden | Out-Null
  } catch { Write-Host "  (sidebar verify not started: $($_.Exception.Message))" -ForegroundColor DarkYellow }
}
function Get-LastVerifyNote([string]$exceptGen) {
  # the newest earlier check: ' last check: N differences - see <report>' when it found any
  foreach ($g in @(Get-ChildItem -LiteralPath $SidebarWork -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $GenPattern -and $_.Name -ne $exceptGen } | Sort-Object Name -Descending)) {
    $v = Join-Path $g.FullName 'verify.txt'
    if (Test-Path -LiteralPath $v) {
      $m = [regex]::Match((Get-Content -LiteralPath $v -Raw), 'differences=(\d+)')
      if ($m.Success) { if ([int]$m.Groups[1].Value -gt 0) { return " last check: $($m.Groups[1].Value) differences - see $(Join-Path $g.FullName 'report.txt')" } else { return '' } }
    }
  }
  return ''
}
function Remove-OldGens([string]$dir) {
  foreach ($old in @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $GenPattern } | Sort-Object Name -Descending | Select-Object -Skip $SidebarKeep)) {
    try { Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction Stop } catch { Write-Host "Could not prune $($old.FullName): $($_.Exception.Message)" -ForegroundColor DarkYellow }
  }
}
function Set-SidebarNote([string]$text, [string]$gdir, [string]$reportLine) {
  # one line the dashboard shows; a reason that has no Python report gets a one-line report of its own
  if ($reportLine) {
    try {
      New-Item -ItemType Directory -Path $gdir -Force | Out-Null
      $r = Join-Path $gdir 'report.txt'
      if (-not (Test-Path -LiteralPath $r)) { Set-Content -LiteralPath $r -Value $reportLine -Encoding UTF8 }
    } catch {}
  }
  $script:SidebarNote = $text
}

function Invoke-SwitchRelaunch([string]$label) {
  # --switch <label> --relaunch. ONE seat lock is held from before the app is closed, through the switch, to the end of the bounded startup wait
  # (Invoke-Switch uses it and does not release it), so no other switch can run, or read a profile a reopened app is writing, in between.
  # Closing first, then the ordinary switch with every one of its gates; the app is reopened afterwards, on the new login, or on the old one when
  # the switch refused (Invoke-Switch exits, so this runs in finally). The live account is recorded before closing and checked again before anything
  # is reopened (S68, S75, S76): a switched seat reopens only on the target's own login (a legacy capture without owner-uuid.txt, or an empty seat
  # chosen to reach the sign-in prompt, keeps today's behaviour); a refused one only when the old profile is verified back in place and still the
  # live login. The wait for the app is bounded; the lock is released in finally. Exit 3: switched, but the app did not come up.
  $lk = Try-EnterSeatLock
  if (-not $lk) { Write-Host "BLOCKED: $(Join-Path $SeatRoot '.seat-write.lock') is held (another switch or the seat keep-alive). Re-run in a minute." -ForegroundColor Red; exit 1 }
  $script:SeatLockHeld = $lk; $script:LockOwnedByRelaunch = $true
  try {
    $wasRunning = @(Get-AppProcs).Count -gt 0
    $recorded = Get-AppAccountUuid
    if (-not (Close-AppGracefully)) {
      Write-Host "ABORTED: the Claude app was still running $($script:CloseWaitSec) s after it was asked to close (if it lives in the system tray, quit it from the tray icon and run this again). Nothing was switched; it was not force-closed (that can tear the login storage)." -ForegroundColor Red
      exit 1
    }
    $script:SwitchDone = $false
    try { Invoke-Switch $label }
    finally {
      $note = if ($script:SidebarNote) { " $($script:SidebarNote)" } else { '' }
      if ($script:SwitchDone) {
        $owner = Get-SeatOwnerUuid (Resolve-Label $label)
        $ok = (-not $owner) -or ((Get-AppAccountUuid) -eq $owner)
        $up = $false
        if ($ok -and (Start-ClaudeApp)) {
          $deadline = (Get-Date).AddSeconds($script:StartWaitSec)
          while (-not $up -and (Get-Date) -lt $deadline) { if (@(Get-AppProcs).Count -gt 0) { $up = $true } else { Start-Sleep -Milliseconds 500 } }
        }
        if ($up) { Write-Host "Relaunched the Claude app on seat $(Resolve-Label $label).$note" -ForegroundColor Green }
        else {      # the switch stands; only the reopening failed. Exit 3 so a caller (the dashboard) does not report a plain success
          Write-Host "Switched to seat $(Resolve-Label $label), but the Claude app could not be reopened; open it from the Start menu.$note" -ForegroundColor Red
          exit 3
        }
      } elseif ($wasRunning) {
        $ok = $script:ProfileIntact -and ((Get-AppAccountUuid) -eq $recorded)
        if ($ok -and (Start-ClaudeApp)) {
          $deadline = (Get-Date).AddSeconds($script:StartWaitSec)
          while ((Get-Date) -lt $deadline -and @(Get-AppProcs).Count -eq 0) { Start-Sleep -Milliseconds 500 }
          Write-Host "Switch failed; relaunched the Claude app on its old login." -ForegroundColor Red
        }
        elseif (-not $ok) { Write-Host "Switch failed (the reason is above); the Claude app was NOT reopened because the old login could not be confirmed in place; open it from the Start menu once you have checked." -ForegroundColor Red }
        else { Write-Host "Switch failed (the reason is above), and the Claude app could not be reopened; open it from the Start menu." -ForegroundColor Red }    # last line: a caller shows it, so it must say the switch failed
      }
    }
  } finally { $script:LockOwnedByRelaunch = $false; Release-SeatLock }
}
function Copy-Dir($src,$dst){ robocopy $src $dst /E /R:0 /W:0 /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null; $script:RobocopyRc = $LASTEXITCODE }
function Mirror-Dir($src,$dst){ robocopy $src $dst /MIR /R:0 /W:0 /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null; $script:RobocopyRc = $LASTEXITCODE }
function Copy-SidebarPair([string]$from) {
  # copy the two sidebar dirs from $from (a seat stash or a staging gen) into the live app dir; $false when either robocopy failed (>= 8)
  $ok = $true
  foreach ($d in $SidebarDirs) { if (Test-Path -LiteralPath "$from\$d") { Copy-Dir "$from\$d" "$AppDir\$d"; if ($script:RobocopyRc -ge 8) { $ok = $false } } }
  $ok
}
function Remove-SidebarDirs {
  # only ever the two dirs this switch's copy just created in empty paths
  foreach ($d in $SidebarDirs) { if (Test-Path -LiteralPath "$AppDir\$d") { Remove-Item -LiteralPath "$AppDir\$d" -Recurse -Force -ErrorAction SilentlyContinue } }
}
function Invoke-AppHistorySync {
  $sync = "$env:USERPROFILE\.grok\bin\sync-app-history.ps1"   # stays in .grok\bin (scheduled task points there)
  if (Test-Path $sync) {
    Write-Host "Syncing session history into the app index..." -ForegroundColor DarkGray
    try { & $sync } catch { Write-Host "  (history sync skipped: $($_.Exception.Message))" -ForegroundColor DarkYellow }
  }
}
function Invoke-AppSeatPublish {
  $pub = Join-Path $PSScriptRoot 'app-seat-publish.ps1'
  if (Test-Path $pub) {
    try { & $pub | Out-Null } catch { Write-Host "  (app-seat publish skipped: $($_.Exception.Message))" -ForegroundColor DarkYellow }
  }
}

function Get-TargetSnapshot([string]$label, [string]$src) {
  # Integrity gate: never apply a seat whose snapshot holds a different account than the
  # seat was captured as. Catches any poisoned snapshot LOUDLY instead of logging you
  # into the wrong account. -> @{ owner; snapUuid }, or exit 1.
  $owner = Get-SeatOwnerUuid $label
  $snapUuid = ''
  if ($owner) {
    $snapUuid = try { (Get-Content (Join-Path $src 'config.json') -Raw | ConvertFrom-Json -AsHashtable)['lastKnownAccountUuid'] } catch { '' }
    if ($snapUuid -and $snapUuid -ne $owner) {
      Write-Host "REFUSED: seat '$label' snapshot holds account uuid $snapUuid, but the seat belongs to $owner." -ForegroundColor Red
      Write-Host "The snapshot is corrupted/poisoned. Log into the right account in the app, quit, then re-run --capture $label." -ForegroundColor Yellow
      exit 1
    }
  }
  @{ owner = $owner; snapUuid = $snapUuid }
}
function Invoke-Switch([string]$label) {
  if (-not $label) { Write-Host "Usage: --switch <label>" -ForegroundColor Red; exit 1 }
  $label = Resolve-Label $label
  $src = Join-Path $SeatRoot $label
  if (-not (Test-Path $src)) { Write-Host "No captured profile '$label'. Run --capture $label while logged into that account first." -ForegroundColor Red; exit 1 }
  $null = Get-TargetSnapshot $label $src          # a cheap refusal before waiting for the lock
  Assert-Closed
  # --relaunch already holds the lock (taken before the app was closed); otherwise take it here.
  if (-not ($script:LockOwnedByRelaunch -and $script:SeatLockHeld)) { $script:SeatLockHeld = Enter-SeatLock }
  $script:ProfileIntact = $true; $script:SidebarNote = ''
  $bk = $null; $baselineOk = $false
  try {
    # Both checks again UNDER the lock, before anything is re-captured, staged or published: a switch that waited for the lock may now find the app
    # reopened by the switch ahead of it, or the target's snapshot changed.
    Assert-Closed
    $tsnap = Get-TargetSnapshot $label $src
    $owner = $tsnap.owner; $snapUuid = $tsnap.snapUuid
    # Re-capture the login we're LEAVING into its own profile FIRST, so returning to it later
    # doesn't force a re-sign-in. The seat to re-capture into is identified by the LIVE
    # login's account uuid, never by .active: a manual in-app log-in/out desyncs .active,
    # and a blind re-capture then writes the wrong account into a seat (that's exactly how
    # seat A once ended up holding the Noshim login).
    $liveUuid = Get-AppAccountUuid
    $prev = Find-SeatByUuid $liveUuid
    $same = [bool]($prev -and $prev -eq $label)
    $gen = $null; $gdir = $null
    $stage = $null; $pair = $null
    if ($same) {
      # Reloading the older stash over the live profile (what this used to do) loses everything done since it was captured. Nothing is swapped;
      # the history sync, the publish and .active below run as normal, so --rotate still advances.
      Write-Host "Seat '$label' is already the live login: nothing to swap." -ForegroundColor DarkGray
      $script:SidebarNote = 'Sidebar: nothing to sync.'
      $label | Set-Content "$SeatRoot\.active" -Encoding UTF8
    } else {
      $gen = New-SwitchGen
      $gdir = Join-Path $SidebarWork $gen
      Write-Host "  sidebar gen: $gen" -ForegroundColor DarkGray
      if ($prev) {
        $created = Get-LiveCreation      # before the re-capture: the departure checkpoint compares it with what was installed
        $pdst = Join-Path $SeatRoot $prev
        $recapOk = $true
        foreach ($f in $LoginFiles) { if (Test-Path "$AppDir\$f") { Copy-Item "$AppDir\$f" "$pdst\$f" -Force } }
        foreach ($d in $LoginDirs)  { if (Test-Path "$AppDir\$d") { Mirror-Dir "$AppDir\$d" "$pdst\$d"; if ($script:RobocopyRc -ge 8) { $recapOk = $false } } }
        "captured=$stamp account=$(Get-ProfileEmail $prev) uuid=$liveUuid label=$prev" | Set-Content "$pdst\meta.txt" -Encoding UTF8
        Write-Host "Re-captured '$prev' (kept its login fresh -- no re-sign-in when you switch back)." -ForegroundColor DarkGray
        if ($recapOk -and $created.ls -and $created.idb) {
          try { Write-DepartureCheckpoint $prev $created } catch { Write-Host "  (sidebar: departure of '$prev' not recorded: $($_.Exception.Message))" -ForegroundColor DarkYellow }
        }
      } else {
        Write-Host "Live login (uuid $liveUuid) doesn't match any captured seat -- NOT re-capturing." -ForegroundColor DarkYellow
        Write-Host "If you logged in manually and want this login saved, quit and run --capture <label> first." -ForegroundColor DarkYellow
      }
      # The target's baseline is invalid until its install succeeds (so any interruption below leaves it invalid). A departure is read against its
      # own checkpoint, never this file, so this loses no pending edit.
      try { Write-JsonAtomic (Join-Path $src 'sidebar-baseline.json') @{ valid = $false } } catch {}
      if (-not $prev) { Set-SidebarNote "Sidebar: skipped (the live login is no captured seat) - see $(Join-Path $gdir 'report.txt')" $gdir 'skipped: the live login is no captured seat' }
      elseif (-not $owner -or $snapUuid -ne $owner) { Set-SidebarNote "Sidebar: skipped (seat $label has no verified login to read) - see $(Join-Path $gdir 'report.txt')" $gdir "skipped: the stash of $label holds no login that matches its owner-uuid.txt" }
      else {
        $stage = Invoke-SidebarStage $prev $label $gen
        if ($stage.ran) {
          # the result must name THIS switch's target and generation; anything else is not ours: nothing is published, installed or consumed
          $res0 = Read-JsonFile (Join-Path $gdir 'result.json')
          if (-not $res0 -or $res0['target'] -ne $label -or $res0['gen'] -ne $gen) { $stage = @{ ran = $false; reason = 'the stage result does not belong to this switch'; gdir = $gdir } }
          else {
            $stage.pair = $res0['pair']
            try { Publish-SidebarState $stage.gdir } catch { Write-Host "  (sidebar: state not published: $($_.Exception.Message))" -ForegroundColor DarkYellow }
          }
        }
      }
      $bk = Join-Path $SeatRoot ".swap-backups\$gen"
      New-Item -ItemType Directory -Path $bk -Force | Out-Null
      # 1) back up current login (files copied, dirs MOVED aside = reversible, nothing deleted). Every dir that existed must end up gone from the
      # live path and present in the backup; otherwise what was moved goes back, and the switch stops (S62, S75).
      Assert-Closed
      foreach ($f in $LoginFiles) { if (Test-Path "$AppDir\$f") { Copy-Item "$AppDir\$f" "$bk\$f" -Force } }
      $moved = New-Object System.Collections.Generic.List[string]; $failed = $null
      foreach ($d in @($LoginDirs | Where-Object { Test-Path -LiteralPath "$AppDir\$_" })) {
        try { Move-Item -LiteralPath "$AppDir\$d" -Destination "$bk\$d" -Force -ErrorAction Stop } catch { $failed = $d; break }
        if ((Test-Path -LiteralPath "$AppDir\$d") -or -not (Test-Path -LiteralPath "$bk\$d")) { $failed = $d; break }
        $moved.Add($d)
      }
      if ($failed) {
        foreach ($d in $moved) { try { Move-Item -LiteralPath "$bk\$d" -Destination "$AppDir\$d" -Force -ErrorAction Stop } catch {} }
        $bad = @($LoginDirs | Where-Object { ($moved -contains $_ -or $_ -eq $failed) -and -not (Test-Path -LiteralPath "$AppDir\$_") })
        if ($bad.Count -eq 0) {
          $script:ProfileIntact = $true
          Write-Host "REFUSED: could not move the current login ('$failed') aside; everything moved so far was put back. Nothing was switched." -ForegroundColor Red
        } else {
          $script:ProfileIntact = $false
          Write-Host "FAILED: could not move the current login aside and could not put back: $($bad -join ', '). The previous login is in $bk -- restore those folders into $AppDir. The app was not reopened." -ForegroundColor Red
        }
        exit 1
      }
      # 2) apply the chosen profile. The two sidebar dirs come from the staging gen when it built them, else from the stash; if either staged copy
      # fails both are removed (this copy created them in now-empty paths) and the stash pair goes in (S51, S63); if that fails too, stop (no relaunch).
      foreach ($f in $LoginFiles) { if (Test-Path "$src\$f") { Copy-Item "$src\$f" "$AppDir\$f" -Force } }
      foreach ($d in @($LoginDirs | Where-Object { $SidebarDirs -notcontains $_ })) { if (Test-Path "$src\$d") { Copy-Dir "$src\$d" "$AppDir\$d" } }
      $stagedAvail = [bool]($stage -and $stage.ran -and $stage.pair -eq 'staged' -and (Test-Path -LiteralPath "$gdir\Local Storage") -and (Test-Path -LiteralPath "$gdir\IndexedDB") -and (Test-Path -LiteralPath "$gdir\baseline.json"))
      if ($stagedAvail -and (Copy-SidebarPair $gdir)) { $pair = 'staged' }
      else {
        if ($stagedAvail) { Remove-SidebarDirs }
        if (Copy-SidebarPair $src) { $pair = 'stash' }
        else {
          Remove-SidebarDirs
          $script:ProfileIntact = $false
          Write-Host "FAILED: could not copy the sidebar databases of seat '$label' in. The previous login is in $bk -- restore it into $AppDir. The app was not reopened." -ForegroundColor Red
          exit 1
        }
      }
      $label | Set-Content "$SeatRoot\.active" -Encoding UTF8
      Write-Host "Switched the Claude app login to profile '$label' ($(Get-ProfileEmail $label))." -ForegroundColor Green
      # 3) record what was installed, the target's baseline (valid only now), and the shared config
      try { Write-JsonAtomic (Join-Path $src 'sidebar-installed.json') @{ created = (Get-LiveCreation) } } catch {}
      try {
        $bsrc = if ($pair -eq 'staged') { "$gdir\baseline.json" } elseif ($stage -and $stage.ran) { "$gdir\baseline-stash.json" } else { $null }
        if ($bsrc -and (Test-Path -LiteralPath $bsrc)) {
          Copy-Item -LiteralPath $bsrc -Destination (Join-Path $src 'sidebar-baseline.json.tmp') -Force
          [IO.File]::Move((Join-Path $src 'sidebar-baseline.json.tmp'), (Join-Path $src 'sidebar-baseline.json'), $true)
          $b = Read-JsonFile (Join-Path $src 'sidebar-baseline.json'); $baselineOk = [bool]($b -and $b['valid'] -eq $true)
        }
      } catch { Write-Host "  (sidebar: baseline not recorded: $($_.Exception.Message))" -ForegroundColor DarkYellow }
      # The shared config only AFTER the baseline was saved (S66). Three outcomes: it already matched (the stage prepared none), committed, or could
      # not be updated. A failure after a staged install, or where it was needed for the stash install, leaves the three stores disagreeing, so the
      # baseline goes invalid again: whatever the app reconciles at launch is then not read as a user edit at the next departure.
      $cfg = @{ state = 'matched'; why = '' }; $partial = $null
      if ($stage -and $stage.ran -and (Test-Path -LiteralPath (Join-Path $gdir 'config.json'))) {
        $cfg = if ($baselineOk) { Commit-SidebarConfig $gdir $pair $gen } else { @{ state = 'failed'; why = 'config not changed: the baseline was not saved' } }
        if ($cfg.why) { try { Add-Content -LiteralPath (Join-Path $gdir 'report.txt') -Value $cfg.why } catch {} }
        if ($cfg.state -eq 'failed') {
          $partial = $cfg.why
          try { Write-JsonAtomic (Join-Path $src 'sidebar-baseline.json') @{ valid = $false } } catch {}
          $baselineOk = $false
        }
      }
      if ($stage -and $stage.ran -and $pair -eq 'staged' -and -not $baselineOk -and -not $partial) { $partial = 'the baseline could not be saved' }
      # the line the dashboard shows
      if (-not $script:SidebarNote) {
        $res = if ($stage -and $stage.ran) { Read-JsonFile (Join-Path $gdir 'result.json') } else { $null }
        $rp = Join-Path $gdir 'report.txt'
        if (-not $stage.ran) { Set-SidebarNote "Sidebar: skipped ($($stage.reason)) - see $rp" $gdir "skipped: $($stage.reason)" }
        elseif (-not $res) { Set-SidebarNote "Sidebar: skipped (the stage left no result) - see $rp" $gdir 'skipped: the stage left no result' }
        elseif ($partial) { Set-SidebarNote "Sidebar: partial ($partial) - see $rp" $gdir '' }
        elseif ($res['status'] -eq 'skipped') { Set-SidebarNote "Sidebar: skipped ($($res['reason'])) - see $rp" $gdir '' }
        elseif ($res['status'] -eq 'synced' -and $pair -ne 'staged') { Set-SidebarNote "Sidebar: skipped (the staged copy could not be installed; the seat's own was) - see $rp" $gdir '' }
        elseif ($res['status'] -eq 'synced') { Set-SidebarNote "Sidebar: synced $($res['n']) pins." $gdir '' }
        else { Set-SidebarNote 'Sidebar: nothing to sync.' $gdir '' }
        $script:SidebarNote += (Get-LastVerifyNote $gen)
      }
    }
    Release-SwitchLock
    if ($bk) { Write-Host "Previous login backed up at: $bk" -ForegroundColor DarkGray }
  } finally { Release-SwitchLock }
  if ($baselineOk) { Start-SidebarVerify $label $gen }
  # Retention (owner-approved 2026-10-20): keep the newest 10 swap backups. With no limit this folder
  # reached 181 copies / 63 GB and filled C:. Only stamp-named dirs are touched, newest first, so the
  # backup just written above is always kept; a failed delete is reported, never fatal to the switch.
  $SwapKeep = 10
  $swaps = Get-ChildItem -LiteralPath (Join-Path $SeatRoot '.swap-backups') -Directory -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match $GenPattern } | Sort-Object Name -Descending
  foreach ($old in ($swaps | Select-Object -Skip $SwapKeep)) {
    try { Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction Stop }
    catch { Write-Host "Could not prune old swap backup $($old.Name): $($_.Exception.Message)" -ForegroundColor DarkYellow }
  }
  Remove-OldGens $SidebarWork
  Remove-OldGens $SidebarBackups
  # 3) make this account's app history show your CLI sessions
  Invoke-AppHistorySync
  # 4) tell the box which seat the app is on now (heartbeat issue); never fatal to the switch
  Invoke-AppSeatPublish
  Write-Host "To undo: --switch <previous-label>, or restore that backup folder into $AppDir." -ForegroundColor DarkGray
  $script:SwitchDone = $true
  if (-not $Relaunch) { Write-Host "Now reopen the Claude desktop app.$(if ($script:SidebarNote) { ' ' + $script:SidebarNote })" -ForegroundColor Cyan }
}

# ---- flag parse ----
$mode = $null; $label = $null; $Relaunch = $false
$a = @($Args | Where-Object { $_ })
for ($i=0; $i -lt $a.Count; $i++) {
  switch -regex ($a[$i]) {
    '^--?(status|st)$'        { $mode='status' }
    '^--?(usage|u)$'          { $mode='usage' }
    '^--?refresh$'            { $usageRefresh = $true }
    '^--?relaunch$'           { $Relaunch = $true }
    '^--?(list|ls)$'          { $mode='list' }
    '^--?(help|h|\?)$'        { $mode='help' }
    '^--?(capture|save|add)$' { $mode='capture'; if ($i+1 -lt $a.Count){ $label=$a[$i+1]; $i++ } }
    '^--?(switch|use|to)$'    { $mode='switch';  if ($i+1 -lt $a.Count){ $label=$a[$i+1]; $i++ } }
    '^--?(rotate|toggle|swap|next)$' { $mode='rotate'; if (($i+1 -lt $a.Count) -and ($a[$i+1] -notmatch '^-')){ $label=$a[$i+1]; $i++ } }
    default {
      Write-Host "Unknown command: $($a[$i])" -ForegroundColor Red
      Write-Host "Valid: --status | --list | --switch <label> | --rotate [label] | --capture <label> | --help" -ForegroundColor Yellow
      exit 2
    }
  }
}
if (-not $mode) { $mode='status' }
if ($Relaunch -and $mode -ne 'switch') { Write-Host "--relaunch works with --switch <label> only." -ForegroundColor Red; exit 2 }
# Dot-sourcing imports the functions for test-app-relaunch.ps1 (same pattern as claude-cli-account.ps1).
if ($MyInvocation.InvocationName -eq '.') { return }

New-Item -ItemType Directory -Path $SeatRoot -Force | Out-Null

switch ($mode) {
  'help' { Get-Content $PSCommandPath -TotalCount 48 | Select-Object -Skip 1; break }

  'status' {
    $procs = @(Get-AppProcs)
    Write-Host "Claude desktop app: " -NoNewline
    if ($procs.Count) { Write-Host "RUNNING (PIDs $($procs.Id -join ', '))" -ForegroundColor Yellow } else { Write-Host "not running" -ForegroundColor Green }
    $liveUuid = Get-AppAccountUuid
    $liveSeat = Find-SeatByUuid $liveUuid
    Write-Host "App account UUID (config.json)     : $liveUuid"
    if ($liveSeat) { Write-Host "Live login = seat                  : $liveSeat ($(Get-ProfileEmail $liveSeat))" }
    else { Write-Host "Live login = seat                  : (matches no captured seat)" -ForegroundColor DarkYellow }
    $active = if (Test-Path "$SeatRoot\.active") { Resolve-Label ((Get-Content "$SeatRoot\.active" -Raw).Trim()) } else { '(never switched via this tool)' }
    Write-Host "Last switched-to profile: $active"
    if ($liveSeat -and $active -and $liveSeat -ne $active) {
      Write-Host "NOTE: live login ($liveSeat) != last switch ($active) -- someone logged in/out manually in the app." -ForegroundColor Yellow
    }
    Write-Host "Captured profiles:"
    $profs = Get-ChildItem $SeatRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^\.' }
    if ($profs) {
      $profs | ForEach-Object {
        $ts = if (Test-Path "$($_.FullName)\meta.txt") { ((Get-Content "$($_.FullName)\meta.txt" -Raw) -replace '.*captured=([0-9\-]+).*', '$1').Trim() } else { '?' }
        Write-Host "  - $($_.Name)  [$(Get-ProfileEmail $_.Name)]  captured $ts"
      }
    } else { Write-Host "  (none yet - use --capture <label>)" }
    break
  }

  'usage' {
    # App seats are the same Anthropic accounts as the CLI profiles (matched by label), so the
    # per-account windows — session, weekly, and Fable — come from the CLI rotator's probe.
    $cliArgs = @('--usage'); if ($usageRefresh) { $cliArgs += '--refresh' }
    pwsh -NoProfile -File (Join-Path $PSScriptRoot 'claude-cli-account.ps1') @cliArgs
    break
  }

  'list' {
    # Mark STAGED seats (dir exists, no captured login) the way claude-cli-account.ps1 marks
    # "(NO TOKEN)". A staged seat gets its email from the synced .claude-cli-accounts entry, so
    # without this marker it looks identical to a real one -- which is the whole failure it exists
    # to prevent: knowing the seat is there AND that you still have to log into it.
    Get-ChildItem $SeatRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^\.' } | ForEach-Object {
      $staged = -not (Test-Path (Join-Path $_.FullName 'config.json'))
      "{0,-20} {1}{2}" -f $_.Name, (Get-ProfileEmail $_.Name), $(if ($staged) { '   (NOT CAPTURED -- run: --switch ' + $_.Name + '  to log in)' } else { '' })
    }
    break
  }

  'capture' {
    if (-not $label) { Write-Host "Usage: --capture <label>" -ForegroundColor Red; exit 1 }
    Assert-Closed
    # Duplicate-owner gate: capturing a login already pinned to ANOTHER seat just clones
    # that seat under a new name — then "switching" to the new label silently lands on the
    # old account (how seat E got captured as a copy of c, 2026-07-07). The uuid must be
    # unique across seats; log into the target account first.
    $curUuid = Get-AppAccountUuid
    $dupe = Find-SeatByUuid $curUuid
    if ($dupe -and ($dupe -ne (Resolve-Label $label))) {
      Write-Host "REFUSED: the app's current login (uuid $curUuid) is already captured as seat '$dupe' ($(Get-ProfileEmail $dupe))." -ForegroundColor Red
      Write-Host "Capturing it as '$label' would make '$label' a duplicate of '$dupe' -- switching to it would land on the same account." -ForegroundColor Yellow
      Write-Host "Open the app, log in as the '$label' account (Settings > Log out > log in), quit fully, then re-run --capture $label." -ForegroundColor Yellow
      exit 1
    }
    $seatLock = Enter-SeatLock
    $dst = Join-Path $SeatRoot $label
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    foreach ($f in $LoginFiles) { if (Test-Path "$AppDir\$f") { Copy-Item "$AppDir\$f" "$dst\$f" -Force } }
    foreach ($d in $LoginDirs)  { if (Test-Path "$AppDir\$d") { Copy-Dir "$AppDir\$d" "$dst\$d" } }
    "captured=$stamp account=$(Get-ProfileEmail $label) uuid=$(Get-AppAccountUuid) label=$label" | Set-Content "$dst\meta.txt" -Encoding UTF8
    (Get-AppAccountUuid) | Set-Content "$dst\owner-uuid.txt" -Encoding UTF8   # pins this seat to this account
    Write-Host "Captured current login as profile '$label' (uuid $(Get-AppAccountUuid)) -> $dst" -ForegroundColor Green
    $seatLock.Dispose()
    break
  }

  'switch' { if ($Relaunch) { Invoke-SwitchRelaunch $label } else { Invoke-Switch $label }; break }

  'rotate' {
    if ($label) { Invoke-Switch $label; break }
    # config.json = "this seat actually holds a captured login". Mirrors claude-cli-account.ps1's
    # Get-Candidates, which requires token.txt for exactly the same reason. Without this, an EMPTY
    # seat dir (the way you stage a seat you have not logged into yet, e.g. one that exists on the
    # other machine) joins the cycle, and --rotate silently lands on it: Invoke-Switch moves the
    # current login aside, copies nothing in, and you are logged out mid-session with no warning.
    # --switch <label> still targets an empty seat deliberately, which is how you get the login prompt.
    $names = @(Get-ChildItem $SeatRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^\.' -and (Test-Path (Join-Path $_.FullName 'config.json')) } | Select-Object -ExpandProperty Name | Sort-Object)
    if ($names.Count -lt 2) { Write-Host "Need at least 2 CAPTURED profiles to rotate (have $($names.Count)). Seats with no config.json are staged but not captured -- use --switch <label> to log into one." -ForegroundColor Red; exit 1 }
    $cur = if (Test-Path "$SeatRoot\.active") { Resolve-Label ((Get-Content "$SeatRoot\.active" -Raw).Trim()) } else { '' }
    $idx = [array]::IndexOf($names, $cur)
    $next = if ($idx -lt 0) { $names[0] } else { $names[($idx + 1) % $names.Count] }
    Write-Host "Rotating app login: $cur -> $next" -ForegroundColor Cyan
    Invoke-Switch $next
    break
  }
}
