#Requires -Version 7.5
# (ConvertFrom-Json -DateKind needs 7.5; on an older pwsh every record would look unreadable)
<#
  sync-app-history.ps1  --  make SUBSTANTIVE or UNFINISHED CLI / cross-account Claude Code
  sessions show up in the Claude Code DESKTOP APP's session history, and prune trivial ones.

  WHY THIS EXISTS
  ---------------
  The CLI writes every session transcript to  ~/.claude/projects/<encoded-cwd>/<id>.jsonl.
  The desktop APP lists only sessions it has a pointer record for, in its own private index:
      %APPDATA%\Claude\claude-code-sessions\<account-uuid>\<workspace-guid>\local_<guid>.json
  This script creates pointer records for transcripts the app never recorded, in EVERY
  account bucket (an account that never tracked the workspace is seeded with the shared
  workspace guid -- it is identical across accounts), and REMOVES records for
  non-substantive sessions.

  WHAT IS KEPT (synced) -- everything else is pruned
  --------------------------------------------------
  A session must be RECENT (last activity within -MaxAgeDays, default 7; 0 = no limit)
  AND match a keep category below. Older sessions are pruned from the app view no matter
  how substantive -- the transcript is never touched and `claude --resume` still lists it.

  1. SUBSTANTIVE work (the only category kept by default): first instruction is NOT an
     automated-dispatch signature (merge-pr / address-pr, review agents, ping tests, bare
     slash commands) AND the session has >= -MinAssistant assistant turns (default 6).
  2. INTERRUPTED sessions (NON-automated only, >= 2 assistant turns): the transcript
     does not end with a completed assistant turn -- it died mid-tool-call / mid-turn
     (or was Esc-interrupted) and may need resuming. Automated dispatches are excluded:
     their transcripts routinely end at a tool_result even when they finished normally.
  3. UNFINISHED merge-pr / address-pr runs (>= 2 turns): no merge-success
     marker in the transcript, so the PR never merged and the session must stay findable.
     (Marker-based: a transcript that merely QUOTES "merged pull request" text can be
     misclassified as finished. ponytail: acceptable ceiling; tighten to tail-only match
     if it ever misfires.)
  Categories 2 and 3 are OFF by default -- pass -KeepResumable to enable them (they're
  still CLI-resumable either way). They only apply to files untouched for >10 minutes,
  so live sessions don't churn in and out of the index.

  TITLES
  ------
  Records get real titles, tried in order:
    a) if another account's bucket already has a well-titled record for the session
       (e.g. the app's own native record with its AI title), that record is CLONED;
    b) transcript customTitle/aiTitle (written by /rename or the app);
    c) the user's first typed prompt for that session from ~/.claude/history.jsonl;
    d) a summary record in the transcript;
    e) the first user instruction in the transcript (first 200 lines);
    f) 'Session <datestamp>' as last resort.
  Existing records still titled 'Session <datestamp>' are retitled in place when a
  better title can be derived.

  USAGE
    pwsh -File sync-app-history.ps1                 # sync+prune C:\Dev\hameishiv (default: recent 7d + substantive)
    pwsh -File sync-app-history.ps1 -DryRun         # report what WOULD change, change nothing
    pwsh -File sync-app-history.ps1 -MaxAgeDays 14  # widen/narrow the recency window (0 = keep all ages)
    pwsh -File sync-app-history.ps1 -KeepResumable  # also keep interrupted / died-pre-merge runs
    pwsh -File sync-app-history.ps1 -MinAssistant 10
    pwsh -File sync-app-history.ps1 -Cwd 'C:\Dev\other'
    pwsh -File sync-app-history.ps1 -NoPrune        # only add/retitle; never remove
    pwsh -File sync-app-history.ps1 -Quiet          # for the launcher hook / scheduled task
    pwsh -File sync-app-history.ps1 -AssumeAppRunning   # testing: act as if the app were open (flags not synced)
    pwsh -File sync-app-history.ps1 -AssumeAppClosed    # testing only: skip the app-running check (a sandbox index)

  SCHEDULED: Windows task 'Claude app-history sync' runs this every 30 min when enabled (hidden, via
  sync-app-history-hidden.vbs), so the app history stays fresh without a seat switch.
  Manage:  Disable-ScheduledTask / Enable-ScheduledTask -TaskName 'Claude app-history sync'

  SAFETY
  - Pruned records are MOVED (not deleted) to ~/.claude-app-seats\.pruned-history-backups\<ts>\
    preserving their path, so a prune is fully reversible. Transcripts are never touched.
  - Only records whose transcript we can actually read + classify are eligible to prune;
    records with no local transcript are left alone.
  - Archive/pin flags (isArchived, isStarred) are copied across seats only while the app is closed;
    changed records are backed up to ~/.claude-app-seats\.flag-sync-backups\<ts>\ (newest 10 kept).
    Sidebar groups and the pin list are not synced (claude-rotator issue #10).
  - One run at a time (~/.claude-app-seats\.sync-history.lock): an interactive run waits up to 3 min for it;
    -Quiet (the scheduled task) skips at once. The flag step runs only when -Cwd has transcripts.
  - Classification is cached in ~/.claude-app-seats\.sync-classify-cache.json keyed by file
    size+mtime, so repeated runs don't re-read every transcript.
#>
[CmdletBinding()]
param(
  [string]$Cwd = 'C:\Dev\hameishiv',
  [int]$MinAssistant = 6,
  [int]$MaxAgeDays = 7,       # prune anything whose last activity is older than this (0 = no age limit)
  [switch]$KeepResumable,     # also keep interrupted / died-pre-merge runs (off by default: recent+substantive only)
  [switch]$DryRun,
  [switch]$NoPrune,
  [switch]$Quiet,
  [switch]$AssumeAppRunning,  # for the test: behave as if the desktop app were running
  [switch]$AssumeAppClosed    # for the test: skip the app-running check (the test's sandbox index); -AssumeAppRunning wins if both are given
)
$ErrorActionPreference = 'Stop'

$ccs = Join-Path $env:APPDATA 'Claude\claude-code-sessions'
if (-not (Test-Path -LiteralPath $ccs)) { throw "App session index not found: $ccs (is the desktop app installed?)" }

$enc = ($Cwd -replace '[:\\]', '-')
$projDir = Join-Path (Join-Path $env:USERPROFILE '.claude\projects') $enc
if (-not (Test-Path -LiteralPath $projDir)) { if (-not $Quiet) { "no transcripts for $Cwd ($projDir)" }; return }
$transcripts = @(Get-ChildItem -LiteralPath $projDir -File -Filter '*.jsonl')
if ($transcripts.Count -eq 0) { if (-not $Quiet) { "no transcripts for $Cwd" }; return }

$cwdJson = $Cwd -replace '\\', '\\'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
# One run at a time: two runs share temp-file names and the flag baseline. Held until the script ends.
$lockDir = Join-Path $env:USERPROFILE '.claude-app-seats'
$null = New-Item -ItemType Directory -Path $lockDir -Force
# Interactive runs (a seat switch, claude-sync-history) wait up to 3 min for a run already in progress, so the
# user isn't told to reopen the app while it is still writing; -Quiet (the scheduled task) skips at once.
$runLock = $null; $lockUntil = (Get-Date).AddMinutes($(if ($Quiet) { 0 } else { 3 })); $lockSaid = $false
while (-not $runLock) {
  try { $runLock = [IO.File]::Open((Join-Path $lockDir '.sync-history.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
  catch [IO.IOException] {
    if (($_.Exception.HResult -band 0xFFFF) -notin 32, 33) { throw }   # only a sharing violation means another run holds it
    if ((Get-Date) -ge $lockUntil) { Write-Warning 'another history sync is still running; this one is skipped. That run is still writing session records: opening the app before it finishes can undo an archive or pin change.'; return }
    if (-not $lockSaid) { 'another history sync is running; waiting for it (up to 3 min)...'; $lockSaid = $true }
    Start-Sleep -Seconds 2
  }
}
try {
# a run killed between writing a .sync-tmp and moving it into place leaves it in the app's index; the suffix is
# only ours and the lock means no other run is mid-write, so any found now is a leftover
if (-not $DryRun -and (Test-Path -LiteralPath $ccs)) {
  Get-ChildItem -LiteralPath $ccs -Recurse -File -Filter '*.sync-tmp' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}
$backupRoot = Join-Path $env:USERPROFILE ".claude-app-seats\.pruned-history-backups\$stamp"
$cachePath  = Join-Path $env:USERPROFILE '.claude-app-seats\.sync-classify-cache.json'
$DateTitleRx = '^Session \d{4}-\d{2}-\d{2}'

# First instruction that matches ANY of these = an automated dispatch.
$AutoSignature = '(?i)^\s*/?(merge-pr|address-pr|orch-pass)\b' +
  '|^\s*you are the pr shepherd\b' +
  '|^\s*reply with exactly' + '|^\s*pong\b' +
  '|^\s*review this change for security' +
  '|^\s*scan\b.*\bhardcoded\b' +
  '|^\s*audit\b.*\bmigration' +
  '|^\s*review\b.*\bedge function' +
  '|^\s*/(compact|clear|resume|status|cost|help|context|export|init|review|security-review|code-review)\b'
$MergePrSignature = '(?i)^\s*/?(merge-pr|address-pr)\b'

function Get-FirstInstruction([string]$raw, [int]$maxLines = 40) {
  foreach ($line in (($raw -split "`n") | Select-Object -First $maxLines)) {
    $lt = $line.Trim(); if (-not $lt) { continue }
    try { $o = $lt | ConvertFrom-Json } catch { continue }
    if ($o.type -eq 'user' -and $o.message.content) {
      $c = $o.message.content; $t = ''
      if ($c -is [string]) { $t = $c } elseif ($c[0].text) { $t = ($c | Where-Object { $_.type -eq 'text' } | Select-Object -First 1).text }
      if (-not $t) { continue }
      if ($t[0] -eq '<') {
        # A slash-command session records the command as a wrapper (<command-name>/merge-pr
        # ... <command-args>554) followed by the expanded skill text as a SECOND user message.
        # Skipping every '<' text made the skill preamble the "first instruction", so
        # /merge-pr sessions matched no signature and 179 of them synced as substantive
        # (2026-07-07). Surface the command itself; skip other wrappers (caveats, reminders).
        if ($t -match '<command-name>\s*(/?[^<\r\n]+?)\s*</command-name>') {
          $cmd = $Matches[1]; if ($cmd[0] -ne '/') { $cmd = "/$cmd" }
          $cargs = if ($t -match '<command-args>([^<]*)</command-args>') { ' ' + $Matches[1].Trim() } else { '' }
          return ($cmd + $cargs).Trim()
        }
        continue
      }
      return ($t -replace '\s+', ' ').Trim()
    }
  }
  return ''
}

# Did the transcript end with a COMPLETED assistant turn? $false = died mid-work
# (unanswered user msg / tool_result, dangling tool_use, max_tokens cutoff, Esc interrupt).
function Test-EndsClean([string]$raw) {
  $lines = $raw -split "`n"
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    $l = $lines[$i]
    if ($l -notmatch '"type":\s*"(user|assistant)"') { continue }
    if ($l -match '"isMeta":\s*true') { continue }
    $o = $null
    try { $o = $l | ConvertFrom-Json } catch { continue }
    if ($o.type -eq 'user') {
      $c = $o.message.content
      $t = if ($c -is [string]) { $c } elseif ($c -and $c[0].text) { [string]$c[0].text } else { '' }
      if ($t -and $t[0] -eq '<') { continue }   # command wrappers / caveats, not a real message
      return $false
    }
    if ($o.type -eq 'assistant') {
      $sr = $o.message.stop_reason
      if ($sr -eq 'end_turn' -or $sr -eq 'stop_sequence') { return $true }
      if ($sr) { return $false }                # tool_use / max_tokens: mid-work
      $c = $o.message.content
      if ($c -isnot [string]) { foreach ($b in $c) { if ($b.type -eq 'tool_use') { return $false } } }
      return $true
    }
  }
  return $true   # no real messages at all -> nothing worth resuming
}

# ---- classification cache (size+mtime keyed) --------------------------------
$cache = @{}
if (Test-Path -LiteralPath $cachePath) {
  try {
    foreach ($p in (Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json).PSObject.Properties) { $cache[$p.Name] = $p.Value }
  } catch {}
}
$script:cacheDirty = $false

function Get-Class($file) {
  # 'v3' (orch-pass / PR-shepherd signature, 2026-11-02) and 'v2' bust entries classified before the 2026-07-07 command-wrapper/interrupted fixes.
  $key = 'v3|{0}|{1}' -f $file.Length, $file.LastWriteTimeUtc.Ticks
  $hit = $cache[$file.BaseName]
  if ($hit -and $hit.k -eq $key) { return $hit }
  $raw = Get-Content -LiteralPath $file.FullName -Raw
  $fi = Get-FirstInstruction $raw 40
  $entry = [pscustomobject]@{
    k      = $key
    asst   = ([regex]::Matches($raw, '"type":"assistant"')).Count
    sig    = [bool]($fi -match $AutoSignature)
    mpr    = [bool]($fi -match $MergePrSignature)
    merged = [bool]($raw -match '(?i)merged pull request|"merged"\s*:\s*true')
    clean  = [bool](Test-EndsClean $raw)
  }
  $script:cache[$file.BaseName] = $entry
  $script:cacheDirty = $true
  return $entry
}

# ---- title sources -----------------------------------------------------------
# The user's first typed prompt per session (from the CLI's global prompt history).
$histTitle = @{}
$hp = Join-Path $env:USERPROFILE '.claude\history.jsonl'
if (Test-Path -LiteralPath $hp) {
  foreach ($line in Get-Content -LiteralPath $hp) {
    if (-not $line) { continue }
    try { $o = $line | ConvertFrom-Json } catch { continue }
    $sid = [string]$o.sessionId
    if ($sid -and $o.display -and -not $histTitle.ContainsKey($sid)) { $histTitle[$sid] = [string]$o.display }
  }
}

function Get-BestTitle([string]$raw, [string]$cliId) {
  $m = [regex]::Matches($raw, '"(?:customTitle|aiTitle)"\s*:\s*"((?:[^"\\]|\\.)*)"')
  if ($m.Count -gt 0) { try { return (ConvertFrom-Json ('"' + $m[$m.Count - 1].Groups[1].Value + '"')) } catch {} }
  if ($histTitle.ContainsKey($cliId)) { return $histTitle[$cliId] }
  $s = [regex]::Match($raw, '\{"type":"summary","summary":"((?:[^"\\]|\\.)*)"')
  if ($s.Success) { try { return (ConvertFrom-Json ('"' + $s.Groups[1].Value + '"')) } catch {} }
  return (Get-FirstInstruction $raw 200)
}

$tFile = @{}; foreach ($m in $transcripts) { $tFile[$m.BaseName] = $m }
$titleCache = @{}
function Get-TitleFor([string]$cliId) {
  if ($titleCache.ContainsKey($cliId)) { return $titleCache[$cliId] }
  $t = ''
  $tf = $tFile[$cliId]
  if ($tf) {
    try { $t = Get-BestTitle (Get-Content -LiteralPath $tf.FullName -Raw) $cliId } catch { $t = '' }
  }
  if ($t) { $t = ($t -replace '\s+', ' ').Trim(); if ($t.Length -gt 60) { $t = $t.Substring(0, 60) } }
  $titleCache[$cliId] = $t
  return $t
}
function Get-ModelFor($file) {
  foreach ($line in Get-Content -LiteralPath $file.FullName -TotalCount 60) {
    if ($line -match '"model"\s*:\s*"(claude-[^"]+)"') { return $Matches[1] }
  }
  return 'claude-opus-4-8'
}

function Write-Record([string]$subDir, $file) {
  $created = ([DateTimeOffset]$file.CreationTime).ToUnixTimeMilliseconds()
  $act     = ([DateTimeOffset]$file.LastWriteTime).ToUnixTimeMilliseconds()
  $title = Get-TitleFor $file.BaseName
  if (-not $title) { $title = 'Session ' + $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
  $model = Get-ModelFor $file
  $sid = "local_$([guid]::NewGuid().ToString())"
  $tj = $title | ConvertTo-Json -Compress
  # carry the flags pass 1.4 resolved for this session (default: not archived, not starred)
  $fw = $flagWant[$file.BaseName]
  $arch = if ($fw -and $fw.isArchived) { 'true' } else { 'false' }
  $starPart = if ($fw -and $fw.isStarred) { ',"isStarred":true' } else { '' }
  $json = '{"sessionId":"' + $sid + '","cliSessionId":"' + $file.BaseName + '","cwd":"' + $cwdJson + '","originCwd":"' + $cwdJson + '","lastFocusedAt":' + $act + ',"createdAt":' + $created + ',"lastActivityAt":' + $act + ',"model":"' + $model + '","effort":"xhigh","isArchived":' + $arch + $starPart + ',"title":' + $tj + ',"titleSource":"auto","permissionMode":"default","remoteMcpServersConfig":[],"chromePermissionMode":"skip_all_permission_checks","completedTurns":1,"bridgeSessionIds":[],"alwaysAllowedReasons":[],"sessionPermissionUpdates":[],"classifierSummaryEnabled":true,"spawnSeed":{}}'
  try { $null = $json | ConvertFrom-Json } catch { return $false }
  $path = Join-Path $subDir "$sid.json"
  Set-Content -LiteralPath $path -Value $json -Encoding UTF8 -NoNewline
  $script:madeRecs.Add(@{ cli = $file.BaseName; path = $path; isArchived = [bool]($fw -and $fw.isArchived); isStarred = [bool]($fw -and $fw.isStarred) })
  return $true
}

# ---- classify every transcript once ------------------------------------------
$now = Get-Date
$allT = New-Object System.Collections.Generic.HashSet[string]
$keep = New-Object System.Collections.Generic.HashSet[string]
$nInterrupted = 0; $nUnfinishedMpr = 0; $nStale = 0
foreach ($m in $transcripts) {
  [void]$allT.Add($m.BaseName)
  $c = Get-Class $m
  $settled = ($now - $m.LastWriteTime).TotalMinutes -gt 10   # ignore still-running sessions
  # RECENCY: keep only sessions whose last activity is within the window. Older ones are
  # pruned from the app view no matter how substantive -- the transcript is untouched and
  # `claude --resume` still lists it. $MaxAgeDays <= 0 disables the age limit.
  $recent  = ($MaxAgeDays -le 0) -or (($now - $m.LastWriteTime).TotalDays -le $MaxAgeDays)
  $substantive   = (-not $c.sig) -and ($c.asst -ge $MinAssistant)
  # Interrupted excludes automated dispatches: a dispatched agent's transcript simply ENDS
  # at its last tool_result (the harness stops it there), so an unclean tail on an automated
  # session usually means "finished normally", not "needs resuming" — 132 completed
  # security-review agents synced as interrupted before this exclusion (2026-07-07).
  # Automated merge-pr runs are covered by the merge-marker rule below instead.
  $interrupted   = $KeepResumable -and $settled -and (-not $c.sig) -and (-not $c.clean) -and ($c.asst -ge 2)
  # DIED-pre-merge, not merely unmerged: many merge-pr runs finish by design without
  # merging (standalone PRs are parked for the owner), ending with a clean assistant
  # summary. "No merge marker" alone kept 165 of them; requiring an unclean tail keeps
  # only runs that actually crashed mid-review and still have no merge.
  $unfinishedMpr = $KeepResumable -and $settled -and $c.mpr -and (-not $c.merged) -and (-not $c.clean) -and ($c.asst -ge 2)
  $qualifies = $substantive -or $interrupted -or $unfinishedMpr
  if ($recent -and $qualifies) {
    [void]$keep.Add($m.BaseName)
    if (-not $substantive) { if ($interrupted) { $nInterrupted++ } else { $nUnfinishedMpr++ } }
  } elseif ($qualifies) {
    $nStale++   # would have been kept, but older than $MaxAgeDays
  }
}
if ($cacheDirty) {
  try { ($cache | ConvertTo-Json -Depth 5 -Compress) | Set-Content -LiteralPath $cachePath -Encoding UTF8 } catch {}
}
if (-not $Quiet) {
  $ageNote = if ($MaxAgeDays -le 0) { 'no age limit' } else { "$nStale over ${MaxAgeDays}d" }
  $resNote = if ($KeepResumable) { "$nInterrupted interrupted + $nUnfinishedMpr unfinished merge-pr" } else { 'resumability off' }
  "classified $($transcripts.Count) transcripts for ${Cwd}: $($keep.Count) kept ($resNote), $($allT.Count - $keep.Count) pruned ($ageNote; MinAssistant=$MinAssistant)"
}

# Is the desktop app running? Checked BEFORE any record is read, so a record the app writes as it quits
# can't be read stale and written back by pass 1.4. Always checked; only the test passes -AssumeAppClosed.
function Test-AppUp {
  if ($AssumeAppRunning) { return $true }
  if ($AssumeAppClosed) { return $false }   # only ever passed by the test, for its sandbox; otherwise always check
  # Fail closed: every process named claude counts as the app UNLESS its path is a known Claude Code CLI location.
  # So a new install layout, or a path that can't be read (e.g. an elevated CLI), skips the flag step rather than
  # writing under a running app.
  $script:appBlockers = @(Get-Process -Name claude -ErrorAction SilentlyContinue | ForEach-Object {
    $pp = $null; try { $pp = $_.Path } catch { }
    if (-not ($pp -and ($pp -like '*\.local\bin\claude.exe' -or $pp -like '*\Claude\claude-code\*\claude.exe'))) {
      "pid $($_.Id) $(if ($pp) { $pp } else { '(path unreadable)' })"
    }
  })
  return $script:appBlockers.Count -gt 0
}
$appUp = Test-AppUp

# ---- pass 1: scan all account buckets once ------------------------------------
$accts = @(Get-ChildItem -LiteralPath $ccs -Directory)
$subCounts = @{}   # acct -> (sub -> this-cwd record count)
$guidVotes = @{}   # sub  -> total count across accounts (workspace guid vote)
$recIndex  = @{}   # cliSessionId -> @{ raw = record json; good = has a real title }
$bucketRecs = @{}  # "acct|sub" -> list of @{ file; j }
foreach ($acct in $accts) {
  $subCounts[$acct.Name] = @{}
  foreach ($sub in @(Get-ChildItem -LiteralPath $acct.FullName -Directory)) {
    $cnt = 0
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($f in Get-ChildItem -LiteralPath $sub.FullName -File -Filter '*.json') {
      $rawRec = $null; $j = $null
      try { $rawRec = Get-Content -LiteralPath $f.FullName -Raw; $j = $rawRec | ConvertFrom-Json -DateKind String } catch { continue }
      if ($null -eq $j -or $j -isnot [System.Management.Automation.PSCustomObject]) { continue }   # empty or "null" (e.g. truncated): unreadable, like a parse error
      $list.Add(@{ file = $f; j = $j })
      if ($j.cwd -eq $Cwd) {
        $cnt++
        $cli = [string]$j.cliSessionId
        if ($cli) {
          $good = -not ([string]$j.title -match $DateTitleRx)
          $cur = $recIndex[$cli]
          if (-not $cur -or ($good -and -not $cur.good)) { $recIndex[$cli] = @{ raw = $rawRec; good = $good } }
        }
      }
    }
    $bucketRecs["$($acct.Name)|$($sub.Name)"] = $list
    $subCounts[$acct.Name][$sub.Name] = $cnt
    if ($cnt -gt 0) { $guidVotes[$sub.Name] = [int]$guidVotes[$sub.Name] + $cnt }
  }
}
$wsGuid = ($guidVotes.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 1).Key

# ---- pass 1.4: archive and pin flags follow you across seats -------------------
# isArchived and isStarred (the record's pin flag) live in each seat's own record, with no time of change.
# So we remember every record's flags from the last run (.flag-state.json): a record whose flag
# differs from that is the one you changed, and its value goes to every seat's record of the
# session (true wins if two seats changed opposite ways). A record not seen last run counts as changed
# only if it is on. A session with a record that can't be written or read keeps its last baseline
# (below; with a state file that predates its record->session map, an unreadable record stops the save). First run, or a session no record was
# seen for before: set on any seat -> set on all. Records are matched across seats by
# cliSessionId, whatever their cwd. Each folder's archived-sessions.idx is kept in step with its records
# (after pass 2). The sidebar pin LIST and groups are NOT synced: the app keeps
# them in each seat's own Local Storage and rewrites claude_desktop_config.json from there.
# Runs only while the app is closed: the live app holds its records in memory and rewrites them,
# so a flag we set under it would be lost and then read back as the user's own change ($appUp, above pass 1).
$flagStatePath = Join-Path $env:USERPROFILE '.claude-app-seats\.flag-state.json'
$flagBackupRoot = Join-Path $env:USERPROFILE '.claude-app-seats\.flag-sync-backups'
$flagSkip = $false      # pass 1.4 did not run: leave records AND the state file alone
$flagPrevAll = $null    # $null = first run (no state file yet)
if (-not $appUp) { $appUp = Test-AppUp }   # again, just before the first write (pass 1 took a while)
if ($appUp) {
  $flagSkip = $true
  if (-not $Quiet) {
    $why = if ($AssumeAppRunning) { '-AssumeAppRunning' } else { "$(@($script:appBlockers)[0])$(if (@($script:appBlockers).Count -gt 1) { " and $(@($script:appBlockers).Count - 1) more" })" }
    "archive/pin flags not synced: the desktop app (or a claude process not at a known CLI path) is running ($why; they sync at the next seat switch)"
  }
} elseif (Test-Path -LiteralPath $flagStatePath) {
  # A present-but-unreadable state file is NOT a first run: a first run unions every flag, which
  # would resurrect everything the user un-archived/unpinned since. Skip and say so.
  try {
    $flagPrevAll = Get-Content -LiteralPath $flagStatePath -Raw | ConvertFrom-Json -AsHashtable
    if ($flagPrevAll -isnot [hashtable]) { throw 'not a JSON object' }
    foreach ($fk in 'isArchived', 'isStarred') { if ($flagPrevAll[$fk] -isnot [hashtable]) { throw "'$fk' is not an object" } }
    if ($flagPrevAll.ContainsKey('cli') -and $flagPrevAll['cli'] -isnot [hashtable]) { throw "'cli' is not an object" }
  } catch {
    $flagSkip = $true
    Write-Warning "flag state file $flagStatePath is unreadable ($($_.Exception.Message)); archive/pin flags not synced this run. Delete it to start again (the next run then counts a flag set on any seat as set on all)"
  }
}
$flagNextAll = @{}
$flagWant = @{}         # cliSessionId -> @{ isArchived; isStarred }: the resolved values, for records pass 2 creates
$flagByCli = @{}
# If a session's record can't be written, that SESSION keeps last run's baseline (as if this run never
# happened for it), and its new clones are left out. The next run then compares it with that baseline: the
# records we did write read as changed (where they differ) and the failed one as unchanged, so its stale
# value can't outvote the change. Saving the new values instead would let it vote as "known" and undo it.
# A record known last run that can't be read holds back its session the same way (see below).
$flagFail = $false
$flagFailCli = New-Object 'System.Collections.Generic.HashSet[string]'
# Pass 1 reads every record once; pass 1.4, pass 1.5 and the pass 2 retitle each write a record back from that
# copy. Each checks first that the file is unchanged since pass 1 read it, so none writes an older copy over a
# newer one (the app writing as it starts or quits). A record found changed is skipped by all of them.
$changedOnDisk = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
function Test-ChangedSinceRead($rec) {
  if ($changedOnDisk.Contains($rec.file.FullName)) { return $true }
  $d = Get-Item -LiteralPath $rec.file.FullName -ErrorAction SilentlyContinue
  if ($d -and $d.LastWriteTimeUtc -eq $rec.file.LastWriteTimeUtc -and $d.Length -eq $rec.file.Length) { return $false }
  [void]$changedOnDisk.Add($rec.file.FullName); return $true
}
$flagHeld = New-Object 'System.Collections.Generic.HashSet[string]'   # "flag|cli|key" of unreadable known records
$flagWarned = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)   # warn once per record
$flagPrevCli = New-Object System.Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)   # key -> cliSessionId, last run
if ($flagPrevAll -and $flagPrevAll['cli']) { foreach ($k in $flagPrevAll['cli'].Keys) { $flagPrevCli[$k] = [string]$flagPrevAll['cli'][$k] } }
$flagPrevCi = @{}
$seenKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if (-not $flagSkip) {
  foreach ($kv in $bucketRecs.GetEnumerator()) {
    foreach ($r in $kv.Value) {
      $r.key = $r.file.FullName.Substring($ccs.Length).TrimStart('\')
      [void]$seenKeys.Add($r.key)        # read, even without a session id: not "unreadable"
      $cli = [string]$r.j.cliSessionId; if (-not $cli) { continue }
      if (-not $flagByCli.ContainsKey($cli)) { $flagByCli[$cli] = New-Object System.Collections.Generic.List[object] }
      $flagByCli[$cli].Add($r)
    }
  }
  foreach ($flag in 'isArchived', 'isStarred') {
    $prev = $null
    if ($flagPrevAll) {   # keys are paths: compare them case-insensitively, like $seenKeys
      $prev = New-Object System.Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
      foreach ($k in $flagPrevAll[$flag].Keys) { $prev[$k] = $flagPrevAll[$flag][$k] }
    }
    # A record known last run that was not read this run but still exists (unreadable): its session keeps
    # last run's baseline, like a failed write. The state file says which session each record belongs to;
    # a state file from before that map can't say, so then NO state is saved this run.
    if ($prev) { foreach ($k in @($prev.Keys)) {
      if (-not $seenKeys.Contains($k) -and (Test-Path -LiteralPath (Join-Path $ccs $k))) {
        $hc = $flagPrevCli[$k]
        if ($hc) {
          [void]$flagFailCli.Add("$flag|$hc"); [void]$flagHeld.Add("$flag|$hc|$k")
          if ($flagWarned.Add($k)) { Write-Warning "could not read $(Join-Path $ccs $k); that session's archive/pin flags keep their last synced state until it can be read. If it is corrupt, restore or delete it; if it was only in use, this clears on its own" }
        } else {
          if (-not $flagFail) { Write-Warning "could not read $(Join-Path $ccs $k); the flag state $(if ($DryRun) { 'would not be' } else { 'is not' }) saved this run. If it is corrupt, restore or delete it; if it was only in use, this clears on its own" }
          $flagFail = $true
        }
      }
    } }
    $flagPrevCi[$flag] = $prev           # for the save below
    $next = @{}; $flipped = 0
    foreach ($cli in @($flagByCli.Keys)) {
      $rs = $flagByCli[$cli]
      $known = @(); $changed = @()
      foreach ($r in $rs) {
        $r.v = [bool]$r.j.$flag
        if ($prev -and $prev.ContainsKey($r.key)) { $known += $r; if ([bool]$prev[$r.key] -ne $r.v) { $changed += $r } }
        # A record not seen last run (the app made it since, e.g. on a newly used seat) that is ON counts as
        # a change: it was archived/pinned there after the last sync. One that is OFF does not -- a record the
        # app creates starts off, so counting it would un-archive/unpin the session everywhere.
        elseif ($prev -and $r.v) { $changed += $r }
      }
      $want = if ($changed.Count) { [bool]($changed | Where-Object { $_.v }) }
              elseif ($known.Count) { [bool]($known | Where-Object { $_.v }) }
              else { [bool]($rs | Where-Object { $_.v }) }
      if (-not $flagWant.ContainsKey($cli)) { $flagWant[$cli] = @{ isArchived = $false; isStarred = $false } }
      $flagWant[$cli][$flag] = $want
      foreach ($r in $rs) {
        if ($r.v -eq $want) { $next[$r.key] = $want; continue }
        if ($DryRun) { $flipped++; $next[$r.key] = $want; continue }
        # One unwritable record (locked, read-only, ...) must not abort the whole run ($ErrorActionPreference
        # is Stop). Warn, and keep this session's last baseline, so the next run tries again from it.
        try {
          # pass 1 read this a while ago; if the file changed since, don't write our older copy over it
          if (Test-ChangedSinceRead $r) { throw 'it changed since it was read' }
          $dest = Join-Path (Join-Path $flagBackupRoot $stamp) $r.key
          if (-not (Test-Path -LiteralPath $dest)) {
            New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
            Copy-Item -LiteralPath $r.file.FullName -Destination $dest -Force
          }
          $r.j | Add-Member -NotePropertyName $flag -NotePropertyValue $want -Force
          # temp file + replace: a run killed mid-write must not leave a truncated (unreadable) record
          ($r.j | ConvertTo-Json -Compress -Depth 100) | Set-Content -LiteralPath "$($r.file.FullName).sync-tmp" -Encoding UTF8 -NoNewline
          [System.IO.File]::Move("$($r.file.FullName).sync-tmp", $r.file.FullName, $true)
          $r.file = Get-Item -LiteralPath $r.file.FullName   # our own write: the next flag compares with this, not with pass 1
          $flipped++; $next[$r.key] = $want
        } catch {
          Remove-Item -LiteralPath "$($r.file.FullName).sync-tmp" -Force -ErrorAction SilentlyContinue   # don't leave it in the app's index
          Write-Warning "could not set $flag on $($r.file.FullName): $($_.Exception.Message) (this session keeps its last flag state; it is retried next run)"
          [void]$flagFailCli.Add("$flag|$cli")
        }
      }
    }
    $flagNextAll[$flag] = $next
    if (-not $Quiet -and $flipped -gt 0) { "$(if ($DryRun) { 'WOULD set' } else { 'set' }) $flag on $flipped record(s) to match the other seats$(if (-not $prev) { ' (first run: set on any seat -> set on all)' })" }
  }
  # A session held back this run (a record failed), or every session when no state is saved, gets no resolved
  # flags for the records pass 2 creates: those are written neutral (off), which the next run doesn't count as
  # a change, and the next good run then sets them like any other record.
  if ($flagFail) { $flagWant.Clear() } else { foreach ($fc in $flagFailCli) { [void]$flagWant.Remove(($fc -split '\|', 2)[1]) } }
  # keep only the newest 10 backup folders (names are yyyyMMdd-HHmmss, so name order = age order)
  if (-not $DryRun -and (Test-Path -LiteralPath $flagBackupRoot)) {
    foreach ($old in @(Get-ChildItem -LiteralPath $flagBackupRoot -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}$' } | Sort-Object Name -Descending | Select-Object -Skip 10)) {
      try { Remove-Item -LiteralPath $old.FullName -Recurse -Force } catch { Write-Warning "could not remove old flag backup $($old.FullName): $($_.Exception.Message)" }
    }
  }
}
$madeRecs = New-Object System.Collections.Generic.List[object]   # records pass 2 creates, for the saved baseline

try {   # the archive list and flag state below are saved even if pass 1.5 or pass 2 stops the run
# ---- pass 1.5: reconcile stale records of the SAME session across buckets -----
# Each account bucket holds its own record per session, cloned/created ONCE and never refreshed.
# The app resumes a session from record.lastAssistantUuid, so a bucket whose record froze at an
# earlier turn (seat A's FABDEM record stopped at 2026-09-29 while the transcript, and seat G's
# record, ran to 2026-10-05) shows only the old part of the work after a seat switch.
# The transcript is the truth: find the record that points at its tip and copy that session
# state into every record that points at an EARLIER assistant turn. Records pointing at a uuid
# not in the transcript (unknown) or at the tip (current) are left alone.
$StateFields = 'lastAssistantUuid','completedTurns','postTurnSummary','postTurnSummaryFor','writtenBranches','titleTurn','latestUserFrameAt','lastFocusedAt','lastActivityAt'
$reconciled = 0
$byCli = @{}
foreach ($kv in $bucketRecs.GetEnumerator()) {
  foreach ($r in $kv.Value) {
    $cli = [string]$r.j.cliSessionId
    if ($r.j.cwd -eq $Cwd -and $cli -and $r.j.lastAssistantUuid) {
      if (-not $byCli.ContainsKey($cli)) { $byCli[$cli] = New-Object System.Collections.Generic.List[object] }
      $byCli[$cli].Add($r)
    }
  }
}
foreach ($cli in @($byCli.Keys)) {
  $rs = $byCli[$cli]
  if (@($rs | ForEach-Object { [string]$_.j.lastAssistantUuid } | Select-Object -Unique).Count -lt 2) { continue }
  $tf = $tFile[$cli]
  if (-not $tf -or ($now - $tf.LastWriteTime).TotalMinutes -le 10) { continue }   # no transcript / still running
  $pos = @{}; $tip = $null; $i = 0
  foreach ($line in [IO.File]::ReadLines($tf.FullName)) {
    $i++
    if ($line.Contains(',"type":"assistant","uuid":"') -and $line -match ',"type":"assistant","uuid":"([0-9a-f-]{36})"') { $pos[$Matches[1]] = $i; $tip = $Matches[1] }
  }
  if (-not $tip) { continue }
  $srcRec = $rs | Where-Object { [string]$_.j.lastAssistantUuid -eq $tip } | Sort-Object { [double]$_.j.completedTurns } -Descending | Select-Object -First 1
  if (-not $srcRec) { continue }
  foreach ($r in $rs) {
    $u = [string]$r.j.lastAssistantUuid
    if ($u -eq $tip -or -not $pos.ContainsKey($u)) { continue }
    if (Test-ChangedSinceRead $r) { Write-Warning "left $($r.file.FullName) alone: it changed since it was read (reconciled next run)"; continue }
    if (-not $DryRun) {
      $rel = $r.file.FullName.Substring($ccs.Length).TrimStart('\')
      $dest = Join-Path (Join-Path $env:USERPROFILE ".claude-app-seats\.reconcile-backups\$stamp") $rel
      New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
      Copy-Item -LiteralPath $r.file.FullName -Destination $dest -Force
      foreach ($f in $StateFields) {
        if ($null -eq $srcRec.j.PSObject.Properties[$f]) { continue }
        $v = $srcRec.j.$f
        if ($f -eq 'lastActivityAt' -or $f -eq 'lastFocusedAt') { $v = [Math]::Max([double]$v, [double]$r.j.$f) }
        $r.j | Add-Member -NotePropertyName $f -NotePropertyValue $v -Force
      }
      ($r.j | ConvertTo-Json -Compress -Depth 100) | Set-Content -LiteralPath $r.file.FullName -Encoding UTF8 -NoNewline
      $r.file = Get-Item -LiteralPath $r.file.FullName   # our own write: the retitle compares with this
    }
    $reconciled++
  }
  # clones for buckets that lack the session must start from the current state too
  if (-not $DryRun -and $recIndex.ContainsKey($cli) -and $recIndex[$cli].good -and -not ([string]$srcRec.j.title -match $DateTitleRx)) {
    $recIndex[$cli] = @{ raw = (Get-Content -LiteralPath $srcRec.file.FullName -Raw); good = $true }
  }
}
if (-not $Quiet -and $reconciled -gt 0) { "$(if ($DryRun) { 'WOULD reconcile' } else { 'reconciled' }) $reconciled stale record(s) to their transcript tip (originals backed up under ~\.claude-app-seats\.reconcile-backups\$stamp)" }

# ---- pass 2: per account -- seed, prune, retitle, add -------------------------
$made = 0; $cloned = 0; $pruned = 0; $retitled = 0
foreach ($acct in $accts) {
  # primary sub for this workspace = the one holding the most of this cwd's records
  $bestSubName = $null; $bestCount = 0
  foreach ($kv in $subCounts[$acct.Name].GetEnumerator()) {
    if ($kv.Value -gt $bestCount) { $bestCount = $kv.Value; $bestSubName = $kv.Key }
  }
  if (-not $bestSubName) {
    # This account never tracked the workspace: seed it with the shared workspace guid
    # (it used to be silently skipped here, leaving new accounts with an empty history).
    if (-not $wsGuid) { continue }
    $bestSubName = $wsGuid
    $seedDir = Join-Path $acct.FullName $wsGuid
    if (-not (Test-Path -LiteralPath $seedDir)) {
      if ($DryRun) { if (-not $Quiet) { "WOULD seed $($acct.Name)\$wsGuid" } }
      else { New-Item -ItemType Directory -Path $seedDir -Force | Out-Null }
    }
  }
  $bestSub = Join-Path $acct.FullName $bestSubName

  # Prune non-kept records; retitle datestamp-titled ones; index what's present.
  # Walks EVERY sub of the account, not just the primary one: records for this cwd
  # stranded in a secondary workspace-guid folder were never pruned (seat A had 35).
  $present = New-Object System.Collections.Generic.HashSet[string]
  $recs = [System.Collections.Generic.List[object]]::new()
  foreach ($subName in @($subCounts[$acct.Name].Keys)) {
    $l = $bucketRecs["$($acct.Name)|$subName"]
    if ($l) { $recs.AddRange($l) }   # note: array + List throws 'Argument types do not match'
  }
  foreach ($r in $recs) {
    $j = $r.j; $f = $r.file
    $cli = [string]$j.cliSessionId
    if ($j.cwd -eq $Cwd -and $cli -and $allT.Contains($cli) -and -not $keep.Contains($cli)) {
      if (-not $NoPrune) {
        if (-not $DryRun) {
          $rel = $f.FullName.Substring($ccs.Length).TrimStart('\')
          $dest = Join-Path $backupRoot $rel
          New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
          Move-Item -LiteralPath $f.FullName -Destination $dest -Force
        }
        $pruned++
      }
      continue
    }
    if (-not $cli) { continue }
    [void]$present.Add($cli)
    if (([string]$j.title -match $DateTitleRx) -and $keep.Contains($cli) -and $allT.Contains($cli) -and -not (Test-ChangedSinceRead $r)) {
      $bt = Get-TitleFor $cli
      if ($bt) {
        if (-not $DryRun) {
          $j.title = $bt
          ($j | ConvertTo-Json -Compress -Depth 100) | Set-Content -LiteralPath $f.FullName -Encoding UTF8 -NoNewline
        }
        $retitled++
      }
    }
  }

  # Add kept transcripts missing from this sub: clone a well-titled record from another
  # bucket when one exists (preserves the app's own AI titles), else fabricate.
  foreach ($m in $transcripts) {
    if (-not $keep.Contains($m.BaseName) -or $present.Contains($m.BaseName)) { continue }
    $src = $recIndex[$m.BaseName]
    if ($src -and $src.good) {
      if ($DryRun) { $cloned++ }
      else {
        try {
          $cj = $src.raw | ConvertFrom-Json -DateKind String
          $cj.sessionId = "local_$([guid]::NewGuid().ToString())"
          # the resolved flags, not the source's: pass 1.5 may have re-read a source whose flag write failed
          if ($flagWant.ContainsKey($m.BaseName)) { foreach ($fk in 'isArchived', 'isStarred') { $cj | Add-Member -NotePropertyName $fk -NotePropertyValue ([bool]$flagWant[$m.BaseName][$fk]) -Force } }
          else {   # flags not resolved, or not saved, this run: write a neutral (off) record, which the next run
            $cj | Add-Member -NotePropertyName isArchived -NotePropertyValue $false -Force   # doesn't count as a change
            $cj.PSObject.Properties.Remove('isStarred')
          }
          $cpath = Join-Path $bestSub "$($cj.sessionId).json"
          ($cj | ConvertTo-Json -Compress -Depth 100) | Set-Content -LiteralPath $cpath -Encoding UTF8 -NoNewline
          $madeRecs.Add(@{ cli = $m.BaseName; path = $cpath; isArchived = [bool]$cj.isArchived; isStarred = [bool]$cj.isStarred })
          $cloned++
        } catch { if (Write-Record $bestSub $m) { $made++ } }
      }
    } else {
      if ($DryRun) { $made++ } elseif (Write-Record $bestSub $m) { $made++ }
    }
  }
}
} finally {
# The app also lists each folder's archived records in archived-sessions.idx. Keep it in step with the records'
# isArchived (which pass 1.4 set). The app treats the file as a load-order hint (archived sessions load later)
# and rebuilds it from the records, so the records are the truth; this only keeps a seat's first load right. Entries for records
# that aren't in the folder, or can't be read, are left as they are.
if (-not $DryRun -and -not $flagSkip) {
  $idxChanged = 0
  $idxDirs = @(); try { $idxDirs = @(Get-ChildItem -LiteralPath $ccs -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory }) } catch { Write-Warning "could not list the session folders for archived-sessions.idx: $($_.Exception.Message)" }
  foreach ($dir in $idxDirs) {
    $idxPath = Join-Path $dir.FullName 'archived-sessions.idx'
    try {
      $idx = $null
      if (Test-Path -LiteralPath $idxPath) {
        $idx = Get-Content -LiteralPath $idxPath -Raw | ConvertFrom-Json
        if ($null -eq $idx -or $idx -isnot [System.Management.Automation.PSCustomObject] -or $null -eq $idx.PSObject.Properties['archived']) { Write-Warning "unexpected format in $idxPath; left as it is"; continue }
      }
      $have = New-Object System.Collections.Generic.List[string]
      if ($idx) { foreach ($sid in @($idx.archived)) { if ($sid) { $have.Add([string]$sid) } } }
      $seen = @{}; $on = New-Object System.Collections.Generic.List[string]
      foreach ($f in Get-ChildItem -LiteralPath $dir.FullName -File -Filter 'local_*.json') {
        try { $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        if ($null -eq $j -or $j -isnot [System.Management.Automation.PSCustomObject] -or -not $j.sessionId) { continue }
        $seen[[string]$j.sessionId] = $true
        if ([bool]$j.isArchived) { $on.Add([string]$j.sessionId) }
      }
      $want = New-Object System.Collections.Generic.List[string]
      foreach ($sid in $have) { if ((-not $seen.ContainsKey($sid) -or $on.Contains($sid)) -and -not $want.Contains($sid)) { $want.Add($sid) } }
      foreach ($sid in $on) { if (-not $want.Contains($sid)) { $want.Add($sid) } }
      if ($want.Count -eq $have.Count -and @($want | Where-Object { -not $have.Contains($_) }).Count -eq 0) { continue }
      if ($idx) {
        $dest = Join-Path (Join-Path $flagBackupRoot $stamp) $idxPath.Substring($ccs.Length).TrimStart('\')
        New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
        Copy-Item -LiteralPath $idxPath -Destination $dest -Force
      } else { $idx = [pscustomobject]@{ v = 1 } }
      $idx | Add-Member -NotePropertyName archived -NotePropertyValue ([object[]]$want.ToArray()) -Force
      ($idx | ConvertTo-Json -Compress -Depth 5) | Set-Content -LiteralPath "$idxPath.sync-tmp" -Encoding UTF8 -NoNewline
      [System.IO.File]::Move("$idxPath.sync-tmp", $idxPath, $true)
      $idxChanged++
    } catch {
      Remove-Item -LiteralPath "$idxPath.sync-tmp" -Force -ErrorAction SilentlyContinue
      Write-Warning "could not update $($idxPath): $($_.Exception.Message)"
    }
  }
  if (-not $Quiet -and $idxChanged) { "updated the archived list (archived-sessions.idx) in $idxChanged folder(s)" }
}

# Save the flag baseline AFTER pass 2, so the records it created (clone or fabricated) are in it
# with the flags they were written with -- else the next run reads them as brand-new and unions.
# (A session whose write failed keeps last run's values for that flag instead: pass 1.4.)
if (-not $DryRun -and -not $flagSkip -and -not $flagFail) {
  foreach ($mr in $madeRecs) {
    $mk = $mr.path.Substring($ccs.Length).TrimStart('\')
    foreach ($flag in 'isArchived', 'isStarred') {
      if ($flagFailCli.Contains("$flag|$($mr.cli)")) { continue }   # a failed session's clones stay out (pass 1.4)
      $flagNextAll[$flag][$mk] = $mr[$flag]
    }
  }
  # a session whose record could not be written or read keeps last run's baseline for that flag, for all its
  # records (the unreadable ones included, so they are still "known" when they can be read again)
  foreach ($fc in $flagFailCli) {
    $flag, $cli = $fc -split '\|', 2; $p = $flagPrevCi[$flag]
    $ks = @(if ($flagByCli.ContainsKey($cli)) { $flagByCli[$cli] | ForEach-Object { $_.key } })
    $ks += @($flagHeld | Where-Object { $_.StartsWith("$fc|") } | ForEach-Object { ($_ -split '\|', 3)[2] })
    foreach ($k in $ks) {
      if ($p -and $p.ContainsKey($k)) { $flagNextAll[$flag][$k] = [bool]$p[$k] } else { $flagNextAll[$flag].Remove($k) }
    }
  }
  # which session each record belongs to, so a record that later can't be read holds back only its session
  $cliMap = @{}
  foreach ($cli in $flagByCli.Keys) { foreach ($r in $flagByCli[$cli]) { $cliMap[$r.key] = $cli } }
  foreach ($mr in $madeRecs) { $cliMap[$mr.path.Substring($ccs.Length).TrimStart('\')] = $mr.cli }
  foreach ($h in $flagHeld) { $null, $hc, $hk = $h -split '\|', 3; $cliMap[$hk] = $hc }
  $flagNextAll['cli'] = $cliMap
  $null = New-Item -ItemType Directory -Path (Split-Path $flagStatePath) -Force
  # Temp file, then an atomic replace: a crash mid-write must not leave a truncated file, and a failed
  # replace must not lose the old one ([IO.File]::Move keeps the destination; Move-Item -Force deletes it first).
  # A failed save warns rather than aborting: pass 2 has already run, and the old state file is still there.
  try {
    ($flagNextAll | ConvertTo-Json -Compress -Depth 5) | Set-Content -LiteralPath "$flagStatePath.tmp" -Encoding UTF8
    try { [System.IO.File]::Move("$flagStatePath.tmp", $flagStatePath, $true) }
    catch { Start-Sleep -Milliseconds 500; [System.IO.File]::Move("$flagStatePath.tmp", $flagStatePath, $true) }   # once more: a scanner may hold it briefly
  } catch {
    Remove-Item -LiteralPath "$flagStatePath.tmp" -Force -ErrorAction SilentlyContinue
    Write-Warning "could not save the flag state $flagStatePath ($($_.Exception.Message)); the next run compares with the previous one, so a change you make before the next successful sync may be undone"
  }
}
}

if (-not $Quiet) {
  $verb = if ($DryRun) { 'WOULD: ' } else { '' }
  "${verb}added $made, cloned $cloned, retitled $retitled, pruned $pruned record(s) for $Cwd"
  if ($pruned -gt 0 -and -not $DryRun) { "pruned records backed up (reversible) at: $backupRoot" }
  if ($DryRun) { "(dry run -- nothing changed. Re-run without -DryRun to apply.)" }
}
} finally { $runLock.Dispose() }
