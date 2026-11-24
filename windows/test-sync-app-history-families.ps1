(Get-Process -Id $PID).PriorityClass = 'Idle'   # first statement: a test run must not freeze the desktop (children inherit it)
<#
  test-sync-app-history-families.ps1 -- a session carried to another seat brings its linked family.
  A parent session in the repo folder and a side session started from it in an app worktree
  (cwd <repo>\.claude\worktrees\<name>, record field spawnedFrom.sessionId = the parent's id) exist only on seat A.
  After a sync: seat B has both; the parent keeps its session id, the worktree child gets a new one (the app leases a
  worktree to a session id in a file every seat shares), and the child's spawnedFrom names the parent id each seat
  holds; the child keeps its worktree cwd; the side session is carried although it is short (2 assistant turns,
  below -MinAssistant); a seat that already holds the parent under another id gets the child but no second parent,
  linked to that id; a second run adds nothing.
  The parent keeps its id only on a seat with no trace of it: seat D holds an unreadable file with the parent's id
  as its name (left byte-identical), seat E a readable record named with the parent's id in another workspace folder
  (left alone), seat F the parent's deletion tombstone: each gets the parent under a new id, the child linked to it.
  A parent record deleted from seat B after the first run comes back under a new id (its old path is in the flag state).
  A worktree transcript no record names creates no record anywhere (it would point at the repo root).
  Second sandbox: a session with transcripts in the repo and a worktree folder (one record, not archived by its old
  copy), a date-titled parent fabricated on the other seat (the child links to it), a worktree-cwd record with a
  repo-folder transcript (new id), a worktree-only session not auto-archived, and a worktree session carried with no
  repo project folder at all.
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
Set-Content "$D\$pSid.json" 'not json {' -NoNewline                                         # D: an unreadable file named like the parent's id
$junkHash = (Get-FileHash "$D\$pSid.json").Hash
$E2 = Join-Path (Split-Path $E) ([guid]::NewGuid().ToString()); New-Item -ItemType Directory $E2 -Force | Out-Null
Set-Content "$E2\$pSid.json" ('{"sessionId":"' + $pSid + '","title":"Other workspace record"}') -NoNewline   # E: a file named with the parent's id in another folder
$e2Hash = (Get-FileHash "$E2\$pSid.json").Hash
Set-Content "$F\deleted_$pGuid" 'x' -NoNewline                                              # F: the PARENT's deletion tombstone

$fail = 0
function check($name, $ok) { if ($ok) { "PASS $name" } else { "FAIL $name"; $script:fail++ } }
function run {
  $out = @(pwsh -NoProfile -Command "`$env:APPDATA='$sb\app'; `$env:USERPROFILE='$sb\home'; & '$Script' -Cwd '$repo' -AssumeAppClosed *>&1" 2>&1 | ForEach-Object { "$_" })
  $script:lastOut = $out
  if ($LASTEXITCODE -ne 0) { "FAIL sync exited $LASTEXITCODE"; $script:fail++ }
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
check 'seat D leaves its unreadable file with the parent id byte-identical' ((Get-FileHash "$D\$pSid.json").Hash -eq $junkHash)
check 'seat D gets the parent under a different id' (@($rD | Where-Object { $_.cliSessionId -eq $pCli -and $_.sessionId -ne $pSid }).Count -eq 1)
check 'seat E leaves the other-folder record with the parent id untouched' ((Get-FileHash "$E2\$pSid.json").Hash -eq $e2Hash)
check 'seat E gets the parent under a different id' (@($rE | Where-Object { $_.cliSessionId -eq $pCli -and $_.sessionId -ne $pSid }).Count -eq 1)
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

# ---- second sandbox: one session id in two folders, a date-titled (fabricated) parent, worktree-only transcripts -----
$sb = "C:\Dev\Temp\sync-app-history-families-test\$(Get-Date -Format 'yyyyMMdd-HHmmss')-$PID-2"
$projRoot = "$sb\home\.claude\projects"; $ccs = "$sb\app\Claude\claude-code-sessions"; $ws = [guid]::NewGuid().ToString()
$A = "$ccs\aaaaaaaa-0000-0000-0000-000000000001\$ws"; $B = "$ccs\bbbbbbbb-0000-0000-0000-000000000002\$ws"; $C = "$ccs\cccccccc-0000-0000-0000-000000000003\$ws"
$pDir = "$projRoot\C--SyncFamTest-repo"; $wDir = "$projRoot\C--SyncFamTest-repo--claude-worktrees-wt1"
New-Item -ItemType Directory $A, $B, $C, $pDir, $wDir, "$sb\home\.claude-app-seats" -Force | Out-Null
"sandbox: $sb"
# X: resumed in the repo (fresh) and in a worktree (40 days old): one record per seat, never auto-archived
$xCli = [guid]::NewGuid().ToString()
transcript $pDir $xCli 7 'session resumed in two folders'
transcript $wDir $xCli 7 'session resumed in two folders'
(Get-Item "$wDir\$xCli.jsonl").LastWriteTime = (Get-Date).AddDays(-40)
record $A "local_$([guid]::NewGuid())" $xCli $repo 'Session in two folders' $null
# Q: in two folders, the worktree copy newer: pass 1.5 still catches a stale repo record up from the repo copy
$qCli = [guid]::NewGuid().ToString(); $q1 = [guid]::NewGuid().ToString(); $q2 = [guid]::NewGuid().ToString(); $q3 = [guid]::NewGuid().ToString()
function asst($u, $parent) { '{"parentUuid":' + $(if ($parent) { '"' + $parent + '"' } else { 'null' }) + ',"type":"assistant","uuid":"' + $u + '","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"t"}]}}' }
$qUser = '{"type":"user","message":{"role":"user","content":"session resumed in a worktree after the repo"}}'
Set-Content "$pDir\$qCli.jsonl" (@($qUser) + (1..6 | ForEach-Object { asst ([guid]::NewGuid()) $null }) + @((asst $q1 $null), (asst $q2 $q1)))
Set-Content "$wDir\$qCli.jsonl" @($qUser, (asst $q3 $q2))
(Get-Item "$pDir\$qCli.jsonl").LastWriteTime = (Get-Date).AddMinutes(-30); (Get-Item "$wDir\$qCli.jsonl").LastWriteTime = (Get-Date).AddMinutes(-15)
$qSidA = "local_$([guid]::NewGuid())"; $qSidB = "local_$([guid]::NewGuid())"
record $A $qSidA $qCli $repo 'Resumed in a worktree' $null; record $B $qSidB $qCli $repo 'Resumed in a worktree' $null
foreach ($pr in @(@($A, $qSidA, $q2), @($B, $qSidB, $q1))) { $f = "$($pr[0])\$($pr[1]).json"; $j = Get-Content $f -Raw | ConvertFrom-Json; $j | Add-Member lastAssistantUuid $pr[2] -Force; Set-Content $f ($j | ConvertTo-Json -Compress -Depth 10) -NoNewline }
# P2 only has a date-titled record (cloned from nowhere: fabricated on B); its worktree child must link to B's fabricated id
$p2Cli = [guid]::NewGuid().ToString(); $c2Cli = [guid]::NewGuid().ToString(); $p2Sid = "local_$([guid]::NewGuid())"
transcript $pDir $p2Cli 7 'parent with only a date title'
transcript $wDir $c2Cli 2 'child of a date-titled parent'
record $A $p2Sid $p2Cli $repo 'Session 2026-11-01 10:00' $null
record $A "local_$([guid]::NewGuid())" $c2Cli $wt 'Child of a date-titled parent' $p2Sid
# R: transcript in the repo folder, a titled worktree-cwd record (named by a child's link) on A and a repo-cwd record on B:
# seat C copies the repo-cwd record, as before worktrees were listed, never the worktree record's id or cwd
$rCli = [guid]::NewGuid().ToString(); $rwSid = "local_$([guid]::NewGuid())"; $rrSid = "local_$([guid]::NewGuid())"; $rkCli = [guid]::NewGuid().ToString()
transcript $pDir $rCli 7 'repo session also opened in a worktree'
transcript $wDir $rkCli 2 'side session of the worktree record'
record $A $rwSid $rCli $wt 'Opened in a worktree' $null
record $A "local_$([guid]::NewGuid())" $rkCli $wt 'Side of the worktree record' $rwSid
record $B $rrSid $rCli $repo 'Opened in the repo' $null
# Y: a record whose cwd is the worktree, but whose transcript is in the repo folder: never cloned from (a repo record is fabricated)
$yCli = [guid]::NewGuid().ToString(); $ySid = "local_$([guid]::NewGuid())"
transcript $pDir $yCli 7 'worktree record with a repo-folder transcript'
record $A $ySid $yCli $wt 'Worktree record, repo transcript' $null
# W: a session with a repo-cwd record whose only transcript is an old worktree copy: not brought into auto-archive
$wCli = [guid]::NewGuid().ToString(); $wSidA = "local_$([guid]::NewGuid())"
transcript $wDir $wCli 7 'old worktree-only transcript of a repo session'
(Get-Item "$wDir\$wCli.jsonl").LastWriteTime = (Get-Date).AddDays(-40)
record $A $wSidA $wCli $repo 'Repo record, worktree-only transcript' $null
# U: a fresh worktree-only transcript whose only record is repo-cwd: never copied with the repo cwd
$uCli = [guid]::NewGuid().ToString()
transcript $wDir $uCli 7 'fresh worktree-only transcript with a repo-cwd record'
record $A "local_$([guid]::NewGuid())" $uCli $repo 'Repo record of a worktree-only session' $null
# K: a worktree child whose seat-A record lost its link (a sync-made copy) and whose seat-B record keeps it: seat C gets the link
$kpCli = [guid]::NewGuid().ToString(); $kcCli = [guid]::NewGuid().ToString(); $kpSid = "local_$([guid]::NewGuid())"
transcript $pDir $kpCli 7 'parent of a child with a linkless copy'
transcript $wDir $kcCli 2 'child with a linkless copy'
record $B $kpSid $kpCli $repo 'Parent of a linkless copy' $null
record $A "local_$([guid]::NewGuid())" $kcCli $wt 'Child, linkless copy' $null
record $B "local_$([guid]::NewGuid())" $kcCli $wt 'Child, linked' $kpSid
# T: a worktree-only session whose only record has a blank title: not copied
$tCli = [guid]::NewGuid().ToString()
transcript $wDir $tCli 7 'worktree session with a blank-titled record'
record $A "local_$([guid]::NewGuid())" $tCli $wt '  ' $null
# G->P->C: seat A holds P (linked to G, with a resume point); seat B holds a fabricated copy of P (no link) that B's C links to.
# Seat C's copy of P takes its content from A's record, not the fabricated one (only the id may come from the link target)
$gCli = [guid]::NewGuid().ToString(); $ppCli = [guid]::NewGuid().ToString(); $pcCli = [guid]::NewGuid().ToString()
$gSid = "local_$([guid]::NewGuid())"; $ppSidA = "local_$([guid]::NewGuid())"; $ppSidB = "local_$([guid]::NewGuid())"
transcript $pDir $gCli 7 'grandparent'; transcript $pDir $ppCli 7 'middle session'; transcript $wDir $pcCli 2 'child of a fabricated copy'
record $A $gSid $gCli $repo 'Grandparent' $null
record $A $ppSidA $ppCli $repo 'Middle session' $gSid
record $B $ppSidB $ppCli $repo 'Middle session' $null
record $B "local_$([guid]::NewGuid())" $pcCli $wt 'Child of a fabricated copy' $ppSidB
# H: a worktree-only session with two repo-cwd records at different turns and a worktree record: pass 1.5 leaves it alone,
# and its copy keeps the worktree cwd
$hCli = [guid]::NewGuid().ToString(); $h1 = [guid]::NewGuid().ToString(); $h2 = [guid]::NewGuid().ToString()
Set-Content "$wDir\$hCli.jsonl" (@('{"type":"user","message":{"role":"user","content":"worktree session with repo records"}}') + (1..6 | ForEach-Object { asst ([guid]::NewGuid()) $null }) + @((asst $h1 $null), (asst $h2 $h1)))
(Get-Item "$wDir\$hCli.jsonl").LastWriteTime = (Get-Date).AddMinutes(-30)
$hSidA = "local_$([guid]::NewGuid())"; $hSidB = "local_$([guid]::NewGuid())"
record $A $hSidA $hCli $repo 'Worktree session, repo record A' $null; record $B $hSidB $hCli $repo 'Worktree session, repo record B' $null
record $A "local_$([guid]::NewGuid())" $hCli $wt 'Worktree session, worktree record' $null
foreach ($pr in @(@($A, $hSidA, $h1), @($B, $hSidB, $h2))) { $f = "$($pr[0])\$($pr[1]).json"; $j = Get-Content $f -Raw | ConvertFrom-Json; $j | Add-Member lastAssistantUuid $pr[2] -Force; Set-Content $f ($j | ConvertTo-Json -Compress -Depth 10) -NoNewline }
# Z: a substantive worktree transcript with no record anywhere (a CLI session): not counted as not carried
transcript $wDir ([guid]::NewGuid().ToString()) 7 'cli session with no app record'
# M: a repo session whose record carries a malformed session id: its copy gets a fresh one
$mCli = [guid]::NewGuid().ToString()
transcript $pDir $mCli 7 'record with a malformed session id'
record $A 'local_bad' $mCli $repo 'Malformed session id' $null
run
$rA = recsIn $A; $rB = recsIn $B
check 'a session in two folders gets one record on seat B' (@($rB | Where-Object { $_.cliSessionId -eq $xCli }).Count -eq 1)
check 'a session in two folders is not auto-archived by its old worktree copy' (@(($rA + $rB) | Where-Object { $_.cliSessionId -eq $xCli -and $_.isArchived }).Count -eq 0)
$bp2 = @($rB | Where-Object { $_.cliSessionId -eq $p2Cli }); $bc2 = @($rB | Where-Object { $_.cliSessionId -eq $c2Cli })
check 'a date-titled parent is fabricated on seat B and its worktree child carried' ($bp2.Count -eq 1 -and $bc2.Count -eq 1)
check "the child links to seat B's fabricated parent id" ($bp2.Count -eq 1 -and $bc2.Count -eq 1 -and $bc2[0].spawnedFrom.sessionId -eq $bp2[0].sessionId)
$rC = recsIn $C; $cr = @($rC | Where-Object { $_.cliSessionId -eq $rCli })
check 'a repo-transcript session is copied from its repo-cwd record, not the worktree one' ($cr.Count -eq 1 -and $cr[0].cwd -eq $repo -and $cr[0].sessionId -ne $rwSid)
check 'a worktree-cwd record with a repo-folder transcript is not cloned: seat B gets a repo record with a new id' (@($rB | Where-Object { $_.cliSessionId -eq $yCli -and $_.sessionId -ne $ySid -and $_.cwd -eq $repo }).Count -eq 1)
check 'a stale repo record is caught up from the repo copy when a newer worktree copy exists' (@($rB | Where-Object { $_.cliSessionId -eq $qCli -and $_.lastAssistantUuid -eq $q2 }).Count -eq 1)
$ck = @($rC | Where-Object { $_.cliSessionId -eq $kcCli }); $cp = @($rC | Where-Object { $_.cliSessionId -eq $kpCli })
check "a child copied to seat C keeps its link (to seat C's parent)" ($ck.Count -eq 1 -and $cp.Count -eq 1 -and $ck[0].spawnedFrom.sessionId -eq $cp[0].sessionId)
$cpp = @($rC | Where-Object { $_.cliSessionId -eq $ppCli }); $cg = @($rC | Where-Object { $_.cliSessionId -eq $gCli })
check "seat C's copy of a session takes its content from the app record, not a fabricated copy a child links to" ($cpp.Count -eq 1 -and $cg.Count -eq 1 -and $cpp[0].spawnedFrom.sessionId -eq $cg[0].sessionId)
check 'pass 1.5 leaves a worktree-only session alone' (@($rA | Where-Object { $_.sessionId -eq $hSidA -and $_.lastAssistantUuid -eq $h1 }).Count -eq 1)
check 'a worktree-only session with repo records is copied with its worktree cwd' (@($rC | Where-Object { $_.cliSessionId -eq $hCli -and $_.cwd -eq $wt }).Count -eq 1 -and @($rC | Where-Object { $_.cliSessionId -eq $hCli }).Count -eq 1)
check 'the not-carried notice counts recorded sessions (blank-titled, repo-cwd only) but not the unrecorded one' (@($script:lastOut | Where-Object { $_ -match '^2 worktree session\(s\) not carried' }).Count -eq 1)
check 'a blank-titled worktree record is not copied' (@($rB | Where-Object { $_.cliSessionId -eq $tCli }).Count -eq 0)
check 'a malformed session id is not reused' (@($rB | Where-Object { $_.cliSessionId -eq $mCli -and $_.sessionId -ne 'local_bad' }).Count -eq 1)
check 'a worktree-only session is not copied from a repo-cwd record' (@($rB | Where-Object { $_.cliSessionId -eq $uCli }).Count -eq 0)
check 'a worktree-only transcript does not bring a repo record into auto-archive' (@($rA | Where-Object { $_.cliSessionId -eq $wCli -and -not $_.isArchived }).Count -eq 1)
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
