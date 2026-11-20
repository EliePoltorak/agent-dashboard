(Get-Process -Id $PID).PriorityClass = 'Idle'   # first statement: a test run must not freeze the desktop (children inherit it)
<#
  test-sync-app-history-families.ps1 -- a session carried to another seat brings its linked family.
  A parent session in the repo folder and a side session started from it in an app worktree
  (cwd <repo>\.claude\worktrees\<name>, record field spawnedFrom.sessionId = the parent's id) exist only on seat A.
  After a sync: seat B has both, under the SAME session ids as seat A (so the child's spawnedFrom link, and
  anything that routes by session id, resolves there); the child keeps its worktree cwd; the side session is
  carried although it is short (2 assistant turns, below -MinAssistant); a seat that already holds the parent
  under another id gets the child but no second parent; a second run adds nothing.
  Builds a tiny synthetic index under C:\Dev\Temp (the live index is not read) and runs the sync with
  %APPDATA% / %USERPROFILE% redirected and -AssumeAppClosed. Sandbox deleted on success, kept on failure. Exit 1 on failure.
    pwsh -File test-sync-app-history-families.ps1 [<path to sync-app-history.ps1>]
#>
$Script = if ($args[0]) { [string]$args[0] } else { Join-Path $PSScriptRoot 'sync-app-history.ps1' }
$sb = "C:\Dev\Temp\sync-app-history-families-test\$(Get-Date -Format 'yyyyMMdd-HHmmss')-$PID"
$repo = 'C:\Dev\hameishiv'; $wt = "$repo\.claude\worktrees\wt1"
$projRoot = "$sb\home\.claude\projects"
$ccs = "$sb\app\Claude\claude-code-sessions"; $ws = [guid]::NewGuid().ToString()
$A = "$ccs\aaaaaaaa-0000-0000-0000-000000000001\$ws"; $B = "$ccs\bbbbbbbb-0000-0000-0000-000000000002\$ws"; $C = "$ccs\cccccccc-0000-0000-0000-000000000003\$ws"
New-Item -ItemType Directory $A, $B, $C, "$projRoot\C--Dev-hameishiv", "$projRoot\C--Dev-hameishiv--claude-worktrees-wt1", "$sb\home\.claude-app-seats" -Force | Out-Null
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

$pCli = [guid]::NewGuid().ToString(); $cCli = [guid]::NewGuid().ToString(); $oCli = [guid]::NewGuid().ToString()
$pSid = "local_$([guid]::NewGuid())"; $cSid = "local_$([guid]::NewGuid())"
transcript "$projRoot\C--Dev-hameishiv" $pCli 7 'parent session that starts a side session'
transcript "$projRoot\C--Dev-hameishiv--claude-worktrees-wt1" $cCli 2 'side session in a worktree'
record $A $pSid $pCli $repo 'Parent session' $null
record $A $cSid $cCli $wt 'Side session in worktree' $pSid
record $B "local_$([guid]::NewGuid())" $oCli $repo 'Unrelated session on seat B' $null   # B tracks the workspace already
record $C "local_$([guid]::NewGuid())" $pCli $repo 'Parent session' $null                  # C holds the parent under another id

$fail = 0
function check($name, $ok) { if ($ok) { "PASS $name" } else { "FAIL $name"; $script:fail++ } }
function run {
  $out = @(pwsh -NoProfile -Command "`$env:APPDATA='$sb\app'; `$env:USERPROFILE='$sb\home'; & '$Script' -AssumeAppClosed *>&1" 2>&1 | ForEach-Object { "$_" })
  $out | Where-Object { $_ -match 'rror|xception|WARNING|classified' } | ForEach-Object { "    $_" }
}
function recsIn($dir) { @(Get-ChildItem $dir -Filter 'local_*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }) }
function count { @(Get-ChildItem $ccs -Recurse -Filter 'local_*.json').Count }

run
$b = recsIn $B; $c = recsIn $C
$bp = @($b | Where-Object { $_.cliSessionId -eq $pCli }); $bc = @($b | Where-Object { $_.cliSessionId -eq $cCli })
check 'seat B gets the parent' ($bp.Count -eq 1)
check 'seat B gets the worktree side session' ($bc.Count -eq 1)
check 'the parent keeps its session id on seat B' ($bp.Count -eq 1 -and $bp[0].sessionId -eq $pSid)
check 'the side session keeps its session id on seat B' ($bc.Count -eq 1 -and $bc[0].sessionId -eq $cSid)
check 'the side session keeps its worktree cwd' ($bc.Count -eq 1 -and $bc[0].cwd -eq $wt)
check "the side session's parent link resolves on seat B" ($bc.Count -eq 1 -and @($b | Where-Object { $_.sessionId -eq $bc[0].spawnedFrom.sessionId }).Count -eq 1)
check 'seat C gets the side session' (@($c | Where-Object { $_.cliSessionId -eq $cCli }).Count -eq 1)
check 'seat C gets no second parent' (@($c | Where-Object { $_.cliSessionId -eq $pCli }).Count -eq 1)
$n = count
run
check 'a second run adds nothing' ((count) -eq $n)

if ($fail) { "FAILED: $fail (sandbox kept: $sb)"; exit 1 }
Remove-Item -LiteralPath $sb -Recurse -Force
'ALL PASS'
