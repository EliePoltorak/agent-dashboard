<#
codex-cli-account.ps1 — multi-account switching for the Codex CLI, the Codex counterpart of
claude-cli-account.ps1.

Codex keeps ONE active login at ~/.codex/auth.json. Saved per-account logins live at
~/.codex/homes/<label>/auth.json (A/B/C already exist from the merge-pr failover setup;
capture others with --capture). A switch copies homes/<label>/auth.json over the active
auth.json; the leaving account is re-saved to its own home first (so a token the app/CLI
refreshed since the last switch isn't lost), and the previous active is backed up under
~/.codex/.auth-backups/ (reversible, nothing deleted).

IMPORTANT — the Codex DESKTOP APP shares this same ~/.codex/auth.json (its app-server has
no separate login). So switching here also changes the account the app will use — but a
RUNNING app caches the token in memory and rewrites auth.json on refresh, which can clobber
a switch. This script refuses to switch while that app is running. Use
codex-app-rotator.ps1, which quits the app, switches, then relaunches.
Seat A is reserved for the app. An explicit --switch or --rotate may move the app
off A. Reviews never select A; --usage still shows its usage. Whatever seat the app is
logged into stays in the review rotation, run access-token-only so a review cannot rotate
the app's login (owner 2026-11-06). Automatic reviews skip any home whose email is listed
in ~/.codex/off-rotator/vm-shared-emails.txt.

USAGE
  codex-cli-account.ps1 --status
  codex-cli-account.ps1 --list
  codex-cli-account.ps1 --switch <label>      (aliases: --use/--to/--account, or just <label>)
  codex-cli-account.ps1 --rotate               (aliases: --toggle/--swap/--next)
  codex-cli-account.ps1 --usage [--refresh]    (5h + weekly window per account, live)
  codex-cli-account.ps1 --capture <label>      (save the CURRENT active login as <label>)
    --allow-vm-shared   with --switch/--rotate: use a seat the VM also holds (blocked by default)
    --replace           with --capture: overwrite a home that holds a different account
  codex-cli-account.ps1 --help
Accounts (example): A = the seat reserved for the app (never reviews, usage shown), B, C, D = other saved logins.
# NOTE (2026-09-17): never run `codex login` with CODEX_HOME pointed at an existing home -- it
# overwrites that seat's auth.json (C was clobbered this way and re-logged in the same day).
# codex_failover_review.py --doctor and --check both confirm C now correctly holds
# the right account with a valid, non-expired token.
#>
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)
$ErrorActionPreference = 'Continue'

$CodexHome = "$env:USERPROFILE\.codex"
$Active    = Join-Path $CodexHome 'auth.json'
$HomesDir  = Join-Path $CodexHome 'homes'
$ActivePtr = Join-Path $CodexHome '.active-account'
$BackupDir = Join-Path $CodexHome '.auth-backups'

# A rate-limit window whose limit_window_seconds is >= this is the WEEKLY window; anything
# shorter is a 5h SESSION window. Codex suspended the session window 2026-07-15, so the API
# now returns only the weekly window (in the primary_window slot). We classify by duration

$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'

# ---------- identity ----------
function Decode-Email([string]$authPath) {
  if (-not (Test-Path $authPath)) { return $null }
  try {
    $j = Get-Content $authPath -Raw | ConvertFrom-Json
    $idt = $j.tokens.id_token; if (-not $idt) { return $null }
    $p = $idt.Split('.')[1].Replace('-','+').Replace('_','/')
    switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
    if ($claims.email) { return $claims.email }
    $prof = $claims.'https://api.openai.com/profile'; if ($prof.email) { return $prof.email }
    return $null
  } catch { return $null }
}
function Get-Homes { @(Get-ChildItem $HomesDir -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'auth.json') } | ForEach-Object { $_.Name } | Sort-Object) }
function Home-Auth([string]$label) { Join-Path (Join-Path $HomesDir $label) 'auth.json' }
function Find-HomeByEmail([string]$email) {
  if (-not $email) { return $null }
  foreach ($h in Get-Homes) { if ((Decode-Email (Home-Auth $h)) -eq $email) { return $h } }
  return $null
}
# ---------- token-safety guards (2026-10-30) ----------
# Codex refresh tokens are single-use: refreshing one copy revokes every other copy, and the
# next use of a revoked copy looks like stolen-token reuse to OpenAI. These guards keep each
# account to one LIVE copy. They mirror codex_failover_review.py (vm_shared_emails,
# sync_auth_back) so both tools obey one contract. Background: the wiki lesson
# codex-rotator-refresh-token-rotation-self-revocation.md.
$OffRotator = Join-Path $CodexHome 'off-rotator'
function Get-JwtClaims([string]$jwt) {
  try {
    $p = $jwt.Split('.')[1].Replace('-','+').Replace('_','/')
    switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
  } catch { $null }
}
function Get-AuthTokens([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  try { (Get-Content $path -Raw | ConvertFrom-Json).tokens } catch { $null }
}
# Freshness = the access token's expiry, the same test sync_auth_back uses.
function Get-AccessExp([string]$path) {
  $t = Get-AuthTokens $path; if (-not $t) { return 0 }
  $c = Get-JwtClaims $t.access_token; if ($c -and $c.exp) { [int64]$c.exp } else { 0 }
}
function Get-RefreshHash([string]$path) {
  $t = Get-AuthTokens $path; if (-not $t -or -not $t.refresh_token) { return $null }
  $b = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]$t.refresh_token))
  [Convert]::ToHexString($b)
}
# Temp file + rename, so a crash mid-copy can never leave a truncated (unrecoverable) store.
function Write-AuthAtomic([string]$src, [string]$dst) {
  $tmp = "$dst.tmp-$PID"
  Copy-Item $src $tmp -Force
  [IO.File]::Move($tmp, $dst, $true)   # one MoveFileEx(REPLACE_EXISTING); Move-Item -Force may delete first
}
# On the laptop (marker present) a seat whose email the Grok Bot VM also holds is off limits.
# CODEX_VM_EMAIL_BLOCK / CODEX_VM_SHARED_EMAILS override, exactly as in the python script.
function Test-VmEmailBlock {
  if ($null -ne $env:CODEX_VM_EMAIL_BLOCK) { return $env:CODEX_VM_EMAIL_BLOCK.Trim().ToLower() -notin @('', '0', 'off', 'no', 'false') }
  Test-Path (Join-Path $OffRotator 'THIS-IS-THE-LAPTOP')
}
function Get-VmSharedEmails {
  if (-not (Test-VmEmailBlock)) { return @() }
  if ($null -ne $env:CODEX_VM_SHARED_EMAILS) {
    return @($env:CODEX_VM_SHARED_EMAILS.Split(',') | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
  }
  $f = Join-Path $OffRotator 'vm-shared-emails.txt'
  if (-not (Test-Path $f)) { return @() }
  @(Get-Content $f | ForEach-Object { ($_ -split '#', 2)[0].Trim().ToLower() } | Where-Object { $_ })
}
# Why this machine must not use <label>'s login, or $null when it may.
function Get-VmBlockReason([string]$label) {
  $blocked = @(Get-VmSharedEmails)
  if (-not $blocked.Count) { return $null }
  $em = Decode-Email (Home-Auth $label)
  if (-not $em) { return "its login can't be read while the VM block is on" }
  if ($blocked -contains $em.ToLower()) { return "$em is also logged in on the Grok Bot VM (off-rotator\vm-shared-emails.txt)" }
  $null
}

function Get-ActiveLabel {
  $em = Decode-Email $Active
  $byEmail = Find-HomeByEmail $em
  if ($byEmail) { return $byEmail }
  if (Test-Path $ActivePtr) { return (Get-Content $ActivePtr -Raw).Trim() }
  return $null
}
function Get-CodexDesktopProcs {
  # The desktop app's window is ChatGPT.exe inside the OpenAI.Codex package.
  # Its backend is a local-bin codex.exe app-server (codex-app-tools / code_mode_host),
  # not a WindowsApps\Codex.exe. A headless `codex app-server` usage read matches none
  # of these, so a review does not block a switch.
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
function App-Running { @(Get-CodexDesktopProcs).Count -gt 0 }

# ---------- usage ----------
function FmtReset($epoch) {
  if (-not $epoch) { return '(unknown)' }
  $secs = [int64]$epoch - [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  if ($secs -le 0) { return 'available now' }
  $local = [DateTimeOffset]::FromUnixTimeSeconds([int64]$epoch).LocalDateTime
  $d=[math]::Floor($secs/86400); $h=[math]::Floor(($secs%86400)/3600); $m=[math]::Floor(($secs%3600)/60)
  $rel = if ($d -ge 1) { '{0}d{1}h' -f $d,$h } elseif ($h -ge 1) { '{0}h{1}m' -f $h,$m } else { '{0}m' -f $m }
  $abs = if     ($local.Date -eq (Get-Date).Date)            { $local.ToString('HH:mm') }
         elseif ($local.Date -eq (Get-Date).AddDays(1).Date) { 'tomorrow ' + $local.ToString('HH:mm') }
         else                                                { $local.ToString('ddd MMM d, HH:mm') }
  'in {0} ({1})' -f $rel, $abs
}
function FmtResetExpiry($epoch) {
  if (-not $epoch) { return '(expiration date not supplied)' }
  try {
    $local = [DateTimeOffset]::FromUnixTimeSeconds([int64]$epoch).ToLocalTime()
  } catch {
    return '(invalid expiration date)'
  }
  '{0} ({1})' -f $local.ToString('MMM d, yyyy, h:mm tt zzz'), (FmtReset $epoch)
}
# The only usage read is the official codex app-server, via merge-pr's failover script
# (one call, all seats). The curl reader of chatgpt.com/backend-api/codex/usage was
# removed 2026-10-13. When --check cannot supply a row, the seat is unreadable.
$FailoverPy = Join-Path $env:USERPROFILE '.claude\skills\merge-pr\scripts\codex_failover_review.py'
$StatusbandCli = 'C:\Dev\cache-statusband-codex\plugins\cache-statusband-codex\bin\cache-statusband-codex.mjs'
# Say WHICH kind of unreadable: a dead login needs a re-login, a throttle needs only time.
function Format-ReadError([string]$label, [string]$err) {
  if ($err -match '401|token_expired|expired|revoked|invalid_grant|refresh_token_reused|sign(ing)? in again|unauthori') {
    return "LOGIN DEAD - re-login: `$env:CODEX_HOME = `"$HomesDir\$label`"; codex login   ($err)"
  }
  if ($err -match '429|rate.?limit|throttl|too many') { return "throttled - try again in a few minutes ($err)" }
  if ($err -match 'blocked|vm|shared|excluded|reserved') { return "not surveyed here ($err)" }
  "unreadable ($err)"
}
# Saves a live survey row in the statusband cache shape, so the usage dashboard can show seats
# that never run the statusband themselves. Reading only; never touches auth.json.
function Save-SurveyReading([string]$label, $wk, $ss, $a) {
  $dir = Join-Path (Join-Path $HomesDir $label) 'cache-statusband-codex'
  if (-not (Test-Path (Join-Path $HomesDir $label)) -or (-not $wk -and -not $ss)) { return }
  $win = { param($w, $mins) if ($w -and $null -ne $w.used_percent) { [ordered]@{ usedPercent = $w.used_percent; windowDurationMins = $mins; resetsAt = $w.reset_at } } }
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $rec = [ordered]@{ version = 3; fetchedAt = $now; identityKey = "seat:$label"; source = 'codex-usage survey'
                     primary = (& $win $wk 10080); secondary = (& $win $ss 300)
                     availableCount = [int]$a.reset_credits_available
                     credits = @(@($a.reset_credit_details) | Where-Object { $_ } | ForEach-Object { [ordered]@{ title = $(if ($_.title) { [string]$_.title } else { 'Banked reset' }); expiresAt = $_.expires_at } }) }
  try {
    New-Item -ItemType Directory -Force $dir | Out-Null
    $dst = Join-Path $dir 'rate-limits-survey.json'; $tmp = "$dst.tmp"
    $rec | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmp -Encoding utf8
    [IO.File]::Move($tmp, $dst, $true)
  } catch { }
}
function Probe-All {
  if (-not (Test-Path $FailoverPy)) { return $null }
  try { $out = & python $FailoverPy --check 2>$null } catch { return $null }
  try { $j = (@($out) -join "`n") | ConvertFrom-Json } catch { return $null }
  if (-not $j.accounts) { return $null }
  $map = @{}
  foreach ($p in $j.accounts.PSObject.Properties) {
    $a = $p.Value
    if (-not $a) { continue }
    if ($a.readable -eq $false) {
      $map[$p.Name] = [pscustomobject]@{ ok=$false; note=(Format-ReadError $p.Name ([string]$a.error)) }
      continue
    }
    $wk = if ($a.weekly) { $a.weekly } else { $a.secondary }
    $ss = $a.session
    Save-SurveyReading $p.Name $wk $ss $a
    $map[$p.Name] = [pscustomobject]@{
      ok=$true; plan=$a.plan_type; capped=[bool]$a.limit_reached
      regime=$(if ($a.regime) { $a.regime } else { 'weekly' })
      p5=$(if ($ss) { $ss.used_percent } else { $null }); r5=$(if ($ss) { $ss.reset_at } else { $null })
      pw=$(if ($wk) { $wk.used_percent } else { $null }); rw=$(if ($wk) { $wk.reset_at } else { $null })
      banked=[int]$a.reset_credits_available
      resetDetails=$(if ($a.reset_credit_details) { @($a.reset_credit_details) } else { @() })
    }
  }
  return $map
}
function Probe-ActiveStatusbandUsage {
  if (-not (Test-Path $StatusbandCli)) { return $null }
  try { $out = & node $StatusbandCli usage --json 2>$null } catch { return $null }
  try { (@($out) -join "`n") | ConvertFrom-Json } catch { return $null }
}
function Bar([double]$frac,[int]$w=10){ if($frac -lt 0){$frac=0}; if($frac -gt 1){$frac=1}; $f=[int][math]::Round($frac*$w); ('#'*$f)+('-'*($w-$f)) }
function Show-Usage([bool]$Refresh) {
  $homes = Get-Homes; $act = Get-ActiveLabel
  $all = Probe-All
  $appSeat = if ($env:CODEX_APP_SEAT) { $env:CODEX_APP_SEAT.Trim() } else { 'A' }
  if ($appSeat -in @('', 'none', 'off', '-')) { $appSeat = '' }
  Write-Host ""
  Write-Host "Codex usage  (percentages are % USED, so 75% used = 25% left; weekly window read live via the codex app-server; 5h session window shown only when present - suspended since 2026-07-15)" -ForegroundColor Cyan
  $activeMissing = $act -and (-not $all -or -not $all.ContainsKey($act))
  if ($activeMissing) {
    $activeUsage = Probe-ActiveStatusbandUsage
    if ($activeUsage -and $null -ne $activeUsage.availableCount) {
      $activeCount = [int]$activeUsage.availableCount
      Write-Host ("  Active login ({0}) banked resets: {1}" -f $act, $activeCount) -ForegroundColor Magenta
      $activeShown = 0
      foreach ($credit in @($activeUsage.credits)) {
        if (-not $credit) { continue }
        $title = if ($credit.title) { [string]$credit.title } else { 'Banked reset' }
        Write-Host ("             {0} expires {1}" -f $title, (FmtResetExpiry $credit.expiresAt)) -ForegroundColor DarkMagenta
        $activeShown++
      }
      if ($activeCount -gt $activeShown) {
        Write-Host ("             Expiration date(s) not supplied for {0} banked reset(s)" -f ($activeCount - $activeShown)) -ForegroundColor DarkGray
      }
    }
  }
  foreach ($l in $homes) {
    # Owner 2026-11-06: only the app seat (A) is out of rotation, and its usage is shown
    # (--check reads it access-token-only). The seat the app is logged into reviews normally.
    $isApp = $appSeat -and $l -eq $appSeat
    if ($isApp -and -not ($all -and $all.ContainsKey($l))) {
      $marker = if ($l -eq $act) { '>' } else { ' ' }
      Write-Host ("  {0} {1,-8} app seat - excluded from reviews (usage unavailable: --check returned no row)" -f $marker, $l) -ForegroundColor DarkGray
      continue
    }
    # Canary for the wedge seen 2026-08-07: --check ANSWERED but returned no row for a
    # seat that has a home on disk. That means the python rotator is not counting this home
    # as a seat, so it also never picks it for a merge-pr review. Say so loudly.
    # After the 2026-10-13 split this also fires if the VM's seat (K) is copied back.
    if (-not $isApp -and $all -and -not $all.ContainsKey($l)) {
      Write-Host ("  ! seat '{0}' has a home but --check returned no row for it: NOT in the review rotation (see discover_accounts in codex_failover_review.py)" -f $l) -ForegroundColor Red
    }
    $u = if ($all -and $all.ContainsKey($l)) { $all[$l] } else { [pscustomobject]@{ ok=$false; note='unreadable (--check unavailable)' } }
    $marker = if ($l -eq $act) { '>' } else { ' ' }
    Write-Host ("  {0} {1,-8} " -f $marker, ("$l ({0})" -f (Decode-Email (Home-Auth $l)))) -NoNewline -ForegroundColor Cyan
    if (-not $u.ok) { Write-Host $u.note -ForegroundColor DarkYellow; continue }
    $hasSession = ($null -ne $u.p5)
    $p5=[int][math]::Round([double]$u.p5); $pw=[int][math]::Round([double]$u.pw)
    $col = if ($u.capped) { 'Red' } elseif ($pw -ge 85 -or ($hasSession -and $p5 -ge 85)) { 'Yellow' } else { 'Green' }
    $capTag = $(if($u.capped){' CAPPED'}else{''})
    if ($hasSession) {
      Write-Host ("5h [{0}] {1,3}% used   weekly [{2}] {3,3}% used ({4}% left){5}" -f (Bar ([double]$u.p5/100)),$p5,(Bar ([double]$u.pw/100)),$pw,(100-$pw),$capTag) -NoNewline -ForegroundColor $col
    } else {
      Write-Host ("weekly [{0}] {1,3}% used ({2}% left){3}" -f (Bar ([double]$u.pw/100)),$pw,(100-$pw),$capTag) -NoNewline -ForegroundColor $col
    }
    if ($null -ne $u.banked) { Write-Host ("  {0} banked reset(s)" -f [int]$u.banked) -NoNewline -ForegroundColor Magenta }
    if ($u.ageSec -gt 0) { Write-Host ("  (cached {0}s)" -f [int]$u.ageSec) -NoNewline -ForegroundColor DarkGray }
    if ($isApp) { Write-Host '  [app seat: never used for reviews]' -NoNewline -ForegroundColor DarkGray }
    Write-Host ""
    if ($hasSession) {
      Write-Host ("             Renews  5h {0}    weekly {1}" -f (FmtReset $u.r5), (FmtReset $u.rw)) -ForegroundColor DarkGray
    } else {
      Write-Host ("             Renews  weekly {0}" -f (FmtReset $u.rw)) -ForegroundColor DarkGray
    }
    $shownResetDetails = 0
    foreach ($credit in @($u.resetDetails)) {
      if (-not $credit) { continue }
      $title = if ($credit.title) { [string]$credit.title } else { 'Banked reset' }
      Write-Host ("             {0} expires {1}" -f $title, (FmtResetExpiry $credit.expires_at)) -ForegroundColor DarkMagenta
      $shownResetDetails++
    }
    if ([int]$u.banked -gt $shownResetDetails) {
      Write-Host ("             Expiration date(s) not supplied for {0} banked reset(s)" -f ([int]$u.banked - $shownResetDetails)) -ForegroundColor DarkGray
    }
  }
  $actEmail = Decode-Email $Active
  if (-not (Find-HomeByEmail $actEmail)) {
    Write-Host ("  ! active login ({0}) is not captured as a home — run --capture <label> to make it rotatable." -f $actEmail) -ForegroundColor DarkYellow
  }
}

# ---------- switching ----------
function Invoke-Switch([string]$label, [bool]$AllowShared = $false) {
  if (App-Running) {
    Write-Host "Refusing to switch: the Codex desktop app is running and shares ~/.codex/auth.json." -ForegroundColor Red
    Write-Host "It caches the token and can rewrite that file on refresh. Quit it first, or use codex-app-rotator.ps1." -ForegroundColor Red
    exit 1
  }
  if (-not $label) { Write-Host "Usage: --switch <label>" -ForegroundColor Red; exit 1 }
  $homes = Get-Homes
  $label = ($homes | Where-Object { $_ -ieq $label } | Select-Object -First 1)
  if (-not $label) { Write-Host "No captured home '$($Args)'. Have: $($homes -join ', '). Use --capture <label> first." -ForegroundColor Red; exit 1 }
  $src = Home-Auth $label
  $why = Get-VmBlockReason $label
  if ($why -and -not $AllowShared) {
    Write-Host "Refusing to switch to '$label': $why." -ForegroundColor Red
    Write-Host "Two machines spending one refresh token revoke each other, and OpenAI reads that as token theft." -ForegroundColor Red
    Write-Host "Update the list, or pass --allow-vm-shared to switch anyway." -ForegroundColor Red
    exit 1
  }
  if ($why) { Write-Host "WARNING: switching to a VM-shared seat on your say-so (--allow-vm-shared): $why." -ForegroundColor Yellow }
  # 1) re-save the leaving account into its own home (keep a refreshed token), if it maps to one.
  # Never write an older token over a newer one: if the home is newer, something else (a review)
  # refreshed it and the active copy is already dead; overwriting would destroy the live token.
  $leaving = Find-HomeByEmail (Decode-Email $Active)
  if ($leaving -and $leaving -ne $label) {
    $dst = Home-Auth $leaving
    if ((Get-RefreshHash $Active) -eq (Get-RefreshHash $dst)) {
      Write-Host "Leaving account '$leaving' is unchanged since it was saved." -ForegroundColor DarkGray
    } elseif ((Get-AccessExp $Active) -le (Get-AccessExp $dst)) {
      Write-Host "NOT re-saving '$leaving': its home holds a newer token than the active login (two live copies existed; the active one is stale). Kept the home copy." -ForegroundColor Yellow
    } else {
      Write-AuthAtomic $Active $dst
      Write-Host "Re-saved leaving account '$leaving' (kept its latest token)." -ForegroundColor DarkGray
    }
  } elseif (-not $leaving) {
    Write-Host "Leaving login ($(Decode-Email $Active)) isn't captured as a home — backed up only (--capture to keep it)." -ForegroundColor DarkYellow
  }
  # 2) back up current active (reversible), then apply the chosen home
  New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
  if (Test-Path $Active) { Copy-Item $Active (Join-Path $BackupDir "auth-$stamp.json") -Force }
  Write-AuthAtomic $src $Active
  $label | Set-Content $ActivePtr -Encoding UTF8
  Write-Host "Switched active Codex login to '$label' ($(Decode-Email $src))." -ForegroundColor Green
}

# ---------- flag parse ----------
$mode=$null; $label=$null; $Refresh=$false; $AllowShared=$false; $Replace=$false
$a = @($Args | Where-Object { $_ })
for ($i=0; $i -lt $a.Count; $i++) {
  switch -regex ($a[$i]) {
    '^--?allow-vm-shared$'             { $AllowShared=$true }
    '^--?replace$'                     { $Replace=$true }
    '^--?(status|st)$'                 { $mode='status' }
    '^--?(list|ls)$'                   { $mode='list' }
    '^--?(usage|u)$'                   { $mode='usage' }
    '^--?refresh$'                     { $Refresh=$true }
    '^--?(rotate|toggle|swap|next)$'   { $mode='rotate' }
    '^--?(switch|use|to|account|acct)$' { $mode='switch'; if ($i+1 -lt $a.Count){ $label=$a[$i+1]; $i++ } }
    '^--?(capture|save|add)$'          { $mode='capture'; if ($i+1 -lt $a.Count){ $label=$a[$i+1]; $i++ } }
    '^--?(help|h|\?)$'                 { $mode='help' }
    default { if (-not $mode -and $a[$i] -notmatch '^-') { $mode='switch'; $label=$a[$i] }
              else { Write-Host "Unknown: $($a[$i])" -ForegroundColor Red; exit 2 } }
  }
}
if (-not $mode) { $mode='status' }
New-Item -ItemType Directory -Path $HomesDir -Force | Out-Null

switch ($mode) {
  'help'   { Get-Content $PSCommandPath -TotalCount 39 | Select-Object -Skip 1; break }
  'list'   { foreach ($h in Get-Homes) { "{0,-6} {1}" -f $h, (Decode-Email (Home-Auth $h)) }; break }
  'status' {
    $act = Get-ActiveLabel
    Write-Host "Active Codex login: $(if($act){$act}else{'(uncaptured)'}) ($(Decode-Email $Active))"
    Write-Host "Codex desktop app : $(if (App-Running) {'RUNNING (shares this login; restart to pick up a switch)'} else {'not running'})"
    Write-Host "Captured homes:"
    foreach ($h in Get-Homes) {
      $m = if ($h -eq $act) { ' <== ACTIVE' } else { '' }
      $vm = if (Get-VmBlockReason $h) { '  (VM-shared: switch blocked)' } else { '' }
      Write-Host ("  - {0,-4} {1}{2}{3}" -f $h, (Decode-Email (Home-Auth $h)), $m, $vm)
    }
    Show-Usage $Refresh; break
  }
  'usage'  { Show-Usage $Refresh; break }
  'switch' { Invoke-Switch $label $AllowShared; break }
  'rotate' {
    $homes = Get-Homes
    $cur = Get-ActiveLabel
    # Cycle only through seats this machine may use (plus the current one, as the anchor).
    $pool = @($homes | Where-Object { $_ -eq $cur -or $AllowShared -or -not (Get-VmBlockReason $_) })
    if ($pool.Count -lt 2) { Write-Host "Need >=2 usable homes to rotate (usable here: $($pool -join ', '); VM-shared seats are skipped unless --allow-vm-shared)." -ForegroundColor Red; exit 1 }
    $idx = [array]::IndexOf($pool, $cur)
    $next = if ($idx -lt 0) { $pool[0] } else { $pool[($idx+1) % $pool.Count] }
    Write-Host "Rotating Codex login: $cur -> $next" -ForegroundColor Cyan
    Invoke-Switch $next $AllowShared; break
  }
  'capture' {
    if (-not $label) { Write-Host "Usage: --capture <label>   (saves the CURRENT active login)" -ForegroundColor Red; exit 1 }
    # Capture guards (the 2026-09-17 clobber): a login already captured under another label
    # would become a second live copy; a home holding a different account would be overwritten.
    $em = Decode-Email $Active
    if (-not $em) { Write-Host "Refusing to capture: the active login's email can't be read." -ForegroundColor Red; exit 1 }
    $other = Find-HomeByEmail $em
    if ($other -and $other -ne $label) { Write-Host "Refusing to capture: $em is already captured as '$other'. A second copy would revoke the first. Switch to '$other' instead." -ForegroundColor Red; exit 1 }
    $existing = Decode-Email (Home-Auth $label)
    if ($existing -and $existing -ne $em -and -not $Replace) { Write-Host "Refusing to capture: home '$label' holds $existing, not $em. Pass --replace to overwrite it (its old file is backed up first)." -ForegroundColor Red; exit 1 }
    # Same account already saved here: never overwrite a NEWER saved token with the active copy.
    # A review refreshing the home revokes the active copy, so copying it back would destroy the
    # only live token (Fable review 2026-10-30, P1-1). Same test as Invoke-Switch's re-save.
    $homeAuth = Home-Auth $label
    if ($existing -eq $em -and (Get-RefreshHash $Active) -ne (Get-RefreshHash $homeAuth) -and
        (Get-AccessExp $Active) -le (Get-AccessExp $homeAuth) -and -not $Replace) {
      Write-Host "Refusing to capture: home '$label' already holds a NEWER token for $em than the active login (the active copy is likely revoked). Pass --replace to overwrite it anyway." -ForegroundColor Red; exit 1
    }
    $dst = Join-Path $HomesDir $label
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    if (Test-Path (Join-Path $dst 'auth.json')) {
      New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
      Copy-Item (Join-Path $dst 'auth.json') (Join-Path $BackupDir "home-$label-pre-capture-$stamp.json") -Force
    }
    Write-AuthAtomic $Active (Join-Path $dst 'auth.json')
    Write-Host "Captured current active login ($(Decode-Email $Active)) as home '$label'." -ForegroundColor Green
    break
  }
}
