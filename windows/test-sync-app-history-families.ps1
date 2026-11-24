(Get-Process -Id $PID).PriorityClass = 'Idle'   # first statement: a test run must not freeze the desktop (children inherit it)
<#
  test-sync-app-history-families.ps1 -- a session carried to another seat brings its linked family.
  A parent session in the repo folder and a side session started from it in an app worktree
  (cwd <repo>\.claude\worktrees\<name>, record field spawnedFrom.sessionId = the parent's id) exist only on seat A.
  After a sync: seat B has both, under the SAME session ids as seat A (so the child's spawnedFrom link, and
  anything that routes by session id, resolves there); the child keeps its worktree cwd; the side session is
  carried although it is short (2 assistant turns, below -MinAssistant); a seat that already holds the parent
  under another id gets the child but no second parent; a second run adds nothing.
  The id is kept only on a seat that never had it: seat D holds an unreadable file with the child's id as its
  name (left byte-identical; D's copy gets a new id), seat E holds the child's deletion tombstone (new id), and a
  record deleted from seat B after the first run comes back under a new id (its old path is in the flag state).
  A worktree transcript no record names creates no record anywhere (it would point at the repo root).
  Builds a tiny synthetic index under C:\Dev\Temp (the live index is not read) and runs the sync with
  %APPDATA% / %USERPROFILE% redirected, -AssumeAppClosed and an explicit synthetic -Cwd. Sandbox deleted on success,
  kept on failure. Exit 1 on failure.
    pwsh -File test-sync-app-history-families.ps1 [<path to sync-app-history.ps1>]
#>
$Script = if ($args[0]) { [string]$args[0] } else { Join-Path $PSScriptRoot 'sync-app-history.ps1' }
$sb = "C:\Dev\Temp\sync-app-history-families-test\$(Get-Date -Format 'yyyyMMdd-HHmmss')-$PID"
$repo = 'C:\SyncFamTest\repo'; $wt = "$repo\.claude\worktrees\wt1"   # synthetic: never a real checkout
$projRoot = "$sb\home\.claude\projects"
$ccs = "$sb\app\Claude\claude-code-sessions"; $ws = [guid]::NewGuid().ToString()
$A = "$ccs\aaaaaaaa-0000-0000-0000-000000000001\$ws"; $B = "$ccs\bbbbbbbb-0000-0000-0000-000000000002\$ws"; $C = "$ccs\cccccccc-0000-0000-0000-000000000003\$ws"
$D = "$ccs\dddddddd-0000-0000-0000-000000000004\$ws"; $E = "$ccs\eeeeeeee-0000-0000-0000-000000000005\$ws"
$F = "$ccs\ffffffff-0000-0000-0000-000000000006\$ws"
$pDir = "$projRoot\C--SyncFamTest-repo"; $wDir = "$projRoot\C--SyncFamTest-repo--claude-worktrees-wt1"
New-Item -ItemType Directory $A, $B, $C, $D, $E, $F, $pDir, $wDir, "$sb\home\.claude-app-seats" -Force | Out-Null
"sandbox: $sb"

function transcript($dir, $cli, [int]$turns, $prompt) {
  $asst = 1..$turns | ForEach-Object { '{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"ok ' + $_ + '"}]}}' }
  Set-Content "$dir\$cli.jsonl" (@('{"type":"user","message":{"role":"user","content":"' + $prompt + '"}}') + $asst)
}
function record($dir, $sid, $cli, $cwd, $title, $parent) {
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $j = [ordered]@{ sessionId = $sid; cliSessionId = $cli; cwd = $cwd; originCwd = $repo; createdAt = $now; lastActivityAt = $now; lastFocusedAt = $now
                   model = 'claude-opus-5-5'; isArchived = $false; title = $title; titleSource = 'auto' }
  if ($parent) { $j.spawnedFrom = [ordered]@{ sessionId = $parent; title = 'parent'; sideSession = $true }; $j.startChain = [ordered]@{ firstSessionId = $parent; depth = 1 } }
  Set-Content "$dir\$sid.json" ($j | ConvertTo-Json -Compress -Depth 10) -NoNewline
}

$pCli = [guid]::NewGuid().ToString(); $cCli = [guid]::NewGuid().ToString(); $oCli = [guid]::NewGuid().ToString(); $zCli = [guid]::NewGuid().ToString()
$cGuid = [guid]::NewGuid().ToString(); $pGuid = [guid]::NewGuid().ToString(); $pSid = "local_$pGuid"; $cSid = "local_$cGuid"
transcript $pDir $pCli 7 'parent session that starts a side session'
transcript $wDir $cCli 2 'side session in a worktree'
transcript $wDir $zCli 7 'worktree session no record names'
record $A $pSid $pCli $repo 'Parent session' $null
record $A $cSid $cCli $wt 'Side session in worktree' $pSid
record $B "local_$([guid]::NewGuid())" $oCli $repo 'Unrelated session on seat B' $null   # B tracks the workspace already
record $C "local_$([guid]::NewGuid())" $pCli $repo 'Parent session' $null                  # C holds the parent under another id
Set-Content "$D\$cSid.json" 'not json {' -NoNewline                                         # D: an unreadable file named like the child's id
$junkHash = (Get-FileHash "$D\$cSid.json").Hash
Set-Content "$E\deleted_$cGuid" 'x' -NoNewline                                              # E: the child's deletion tombstone
Set-Content "$F\deleted_$pGuid" 'x' -NoNewline                                              # F: the PARENT's deletion tombstone

$fail = 0
function check($name, $ok) { if ($ok) { "PASS $name" } else { "FAIL $name"; $script:fail++ } }
function run {
  $out = @(pwsh -NoProfile -Command "`$env:APPDATA='$sb\app'; `$env:USERPROFILE='$sb\home'; & '$Script' -Cwd '$repo' -AssumeAppClosed *>&1" 2>&1 | ForEach-Object { "$_" })
  $out | Where-Object { $_ -match 'rror|xception|WARNING|classified' } | ForEach-Object { "    $_" }
}
function recsIn($dir) { @(Get-ChildItem $dir -Filter 'local_*.json' | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch { } }) }
# the child's spawnedFrom (and startChain root) name a parent record that seat actually holds
function linkOk($recs) {
  $ch = @($recs | Where-Object { $_.cliSessionId -eq $cCli }); if ($ch.Count -ne 1) { return $false }
  $par = @($recs | Where-Object { $_.cliSessionId -eq $pCli }); if ($par.Count -ne 1) { return $false }
  $ch[0].spawnedFrom.sessionId -eq $par[0].sessionId -and $ch[0].startChain.firstSessionId -eq $par[0].sessionId
}
function count { @(Get-ChildItem $ccs -Recurse -Filter 'local_*.json').Count }

run
$rB = recsIn $B; $rC = recsIn $C; $rD = recsIn $D; $rE = recsIn $E   # (variable names are case-insensitive: not $b/$B)
$bp = @($rB | Where-Object { $_.cliSessionId -eq $pCli }); $bc = @($rB | Where-Object { $_.cliSessionId -eq $cCli })
check 'seat B gets the parent' ($bp.Count -eq 1)
check 'seat B gets the worktree side session' ($bc.Count -eq 1)
check 'the parent keeps its session id on seat B' ($bp.Count -eq 1 -and $bp[0].sessionId -eq $pSid)
check 'the worktree side session gets a new id on seat B (worktree leases are keyed by session id)' ($bc.Count -eq 1 -and $bc[0].sessionId -ne $cSid)
check 'the side session keeps its worktree cwd' ($bc.Count -eq 1 -and $bc[0].cwd -eq $wt)
check "the side session's parent link resolves on seat B" ($bc.Count -eq 1 -and @($rB | Where-Object { $_.sessionId -eq $bc[0].spawnedFrom.sessionId }).Count -eq 1)
check 'seat C gets the side session' (@($rC | Where-Object { $_.cliSessionId -eq $cCli }).Count -eq 1)
check 'seat C gets no second parent' (@($rC | Where-Object { $_.cliSessionId -eq $pCli }).Count -eq 1)
check "seat C's side session links to the parent id seat C holds" (linkOk $rC)
$dc = @($rD | Where-Object { $_.cliSessionId -eq $cCli })
check 'seat D leaves its unreadable file with the child id byte-identical' ((Get-FileHash "$D\$cSid.json").Hash -eq $junkHash)
check 'seat D gets the side session under a different id' ($dc.Count -eq 1 -and $dc[0].sessionId -ne $cSid)
$ec = @($rE | Where-Object { $_.cliSessionId -eq $cCli })
check 'seat E (tombstone of the child id) gets the side session under a different id' ($ec.Count -eq 1 -and $ec[0].sessionId -ne $cSid)
check "seat D's side session links to seat D's parent" (linkOk $rD)
check "seat E's side session links to seat E's parent" (linkOk $rE)
$rF = recsIn $F; $fp = @($rF | Where-Object { $_.cliSessionId -eq $pCli })
check 'seat F (tombstone of the parent id) gets the parent under a different id' ($fp.Count -eq 1 -and $fp[0].sessionId -ne $pSid)
check "seat F's side session links to seat F's new parent id" (linkOk $rF)
check 'a worktree transcript no record names creates no record on any seat' (@(Get-ChildItem $ccs -Recurse -Filter 'local_*.json' | ForEach-Object { Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue } | Where-Object { $_ -match $zCli }).Count -eq 0)
$n = count
run
check 'a second run adds nothing' ((count) -eq $n)

# a record deleted after it was written: its id is in the flag state, so the copy that comes back gets a new id
Remove-Item "$B\$pSid.json" -ErrorAction SilentlyContinue
run
$bp2 = @(recsIn $B | Where-Object { $_.cliSessionId -eq $pCli })
check 'a previously known id is not reused: the parent returns to seat B under a new id' ($bp2.Count -eq 1 -and $bp2[0].sessionId -ne $pSid)
if ($fail) { "FAILED: $fail (sandbox kept: $sb)"; exit 1 }
Remove-Item -LiteralPath $sb -Recurse -Force

# ---- second sandbox: one session id in two folders, a date-titled (fabricated) parent, worktree reconcile -----
$sb = "C:\Dev\Temp\sync-app-history-families-test\$(Get-Date -Format 'yyyyMMdd-HHmmss')-$PID-2"
$projRoot = "$sb\home\.claude\projects"; $ccs = "$sb\app\Claude\claude-code-sessions"; $ws = [guid]::NewGuid().ToString()
$A = "$ccs\aaaaaaaa-0000-0000-0000-000000000001\$ws"; $B = "$ccs\bbbbbbbb-0000-0000-0000-000000000002\$ws"
$pDir = "$projRoot\C--SyncFamTest-repo"; $wDir = "$projRoot\C--SyncFamTest-repo--claude-worktrees-wt1"
New-Item -ItemType Directory $A, $B, $pDir, $wDir, "$sb\home\.claude-app-seats" -Force | Out-Null
"sandbox: $sb"
# X: resumed in the repo (fresh) and in a worktree (40 days old): one record per seat, never auto-archived
$xCli = [guid]::NewGuid().ToString()
transcript $pDir $xCli 7 'session resumed in two folders'
transcript $wDir $xCli 7 'session resumed in two folders'
(Get-Item "$wDir\$xCli.jsonl").LastWriteTime = (Get-Date).AddDays(-40)
record $A "local_$([guid]::NewGuid())" $xCli $repo 'Session in two folders' $null
# P2 only has a date-titled record (cloned from nowhere: fabricated on B); its worktree child must link to B's fabricated id
$p2Cli = [guid]::NewGuid().ToString(); $c2Cli = [guid]::NewGuid().ToString(); $p2Sid = "local_$([guid]::NewGuid())"
transcript $pDir $p2Cli 7 'parent with only a date title'
transcript $wDir $c2Cli 2 'child of a date-titled parent'
record $A $p2Sid $p2Cli $repo 'Session 2026-11-01 10:00' $null
record $A "local_$([guid]::NewGuid())" $c2Cli $wt 'Child of a date-titled parent' $p2Sid
# W: a worktree session on both seats, B's copy behind the transcript tip: reconciled like a repo session
$wCli = [guid]::NewGuid().ToString(); $u1 = [guid]::NewGuid().ToString(); $u2 = [guid]::NewGuid().ToString()
Set-Content "$wDir\$wCli.jsonl" @('{"type":"user","message":{"role":"user","content":"worktree session to reconcile"}}',
  ('{"parentUuid":null,"type":"assistant","uuid":"' + $u1 + '","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"one"}]}}'),
  ('{"parentUuid":"' + $u1 + '","type":"assistant","uuid":"' + $u2 + '","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"two"}]}}'))
(Get-Item "$wDir\$wCli.jsonl").LastWriteTime = (Get-Date).AddMinutes(-20)
$wSidA = "local_$([guid]::NewGuid())"; $wSidB = "local_$([guid]::NewGuid())"
record $A $wSidA $wCli $wt 'Worktree session to reconcile' $null; record $B $wSidB $wCli $wt 'Worktree session to reconcile' $null
foreach ($pr in @(@($A, $wSidA, $u2), @($B, $wSidB, $u1))) { $f = "$($pr[0])\$($pr[1]).json"; $j = Get-Content $f -Raw | ConvertFrom-Json; $j | Add-Member lastAssistantUuid $pr[2] -Force; Set-Content $f ($j | ConvertTo-Json -Compress -Depth 10) -NoNewline }
run
$rA = recsIn $A; $rB = recsIn $B
check 'a session in two folders gets one record on seat B' (@($rB | Where-Object { $_.cliSessionId -eq $xCli }).Count -eq 1)
check 'a session in two folders is not auto-archived by its old worktree copy' (@(($rA + $rB) | Where-Object { $_.cliSessionId -eq $xCli -and $_.isArchived }).Count -eq 0)
$bp2 = @($rB | Where-Object { $_.cliSessionId -eq $p2Cli }); $bc2 = @($rB | Where-Object { $_.cliSessionId -eq $c2Cli })
check 'a date-titled parent is fabricated on seat B and its worktree child carried' ($bp2.Count -eq 1 -and $bc2.Count -eq 1)
check "the child links to seat B's fabricated parent id" ($bp2.Count -eq 1 -and $bc2.Count -eq 1 -and $bc2[0].spawnedFrom.sessionId -eq $bp2[0].sessionId)
check "a worktree record behind the transcript tip is reconciled" (@($rB | Where-Object { $_.cliSessionId -eq $wCli -and $_.lastAssistantUuid -eq $u2 }).Count -eq 1)
# the repo project folder missing: a substantive worktree session is still carried
Remove-Item -LiteralPath $pDir -Recurse -Force
$vCli = [guid]::NewGuid().ToString()
transcript $wDir $vCli 7 'substantive worktree session'
record $A "local_$([guid]::NewGuid())" $vCli $wt 'Substantive worktree session' $null
run
check 'with no repo project folder, a worktree session is still carried' (@(recsIn $B | Where-Object { $_.cliSessionId -eq $vCli }).Count -eq 1)

if ($fail) { "FAILED: $fail (sandbox kept: $sb)"; exit 1 }
Remove-Item -LiteralPath $sb -Recurse -Force
'ALL PASS'
