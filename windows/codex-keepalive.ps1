# Renews this laptop's Codex CLI logins inside Codex's 5-minute pre-expiry window, then pushes
# fresh copies (refresh token removed, encrypted) to the Merge Driver box once that is set up.
# Owner chose option B on 2026-11-16. Run by the 'Codex seat keepalive' scheduled task every 4 min
# through codex-keepalive-hidden.vbs. Writes a log line only when something happened.
(Get-Process -Id $PID).PriorityClass = 'Idle'
$scripts = Join-Path $env:USERPROFILE '.claude\skills\merge-pr\scripts'
$log = Join-Path $env:USERPROFILE '.codex\rotator-state\keepalive.log'
$fail = Join-Path $scripts 'codex_failover_review.py'
if (-not (Test-Path -LiteralPath $fail)) { return }   # the merge-pr skill is not installed: nothing to renew
$out = & py -3 $fail --keepalive 2>&1 | Out-String
if ($out -match '"rc"|"error"|"renewed": true') {
    Add-Content -LiteralPath $log -Value ("{0} keepalive`n{1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'), $out.Trim())
}
$push = Join-Path $scripts 'codex_login_push.py'
if (Test-Path -LiteralPath $push) {
    $p = & py -3 $push push 2>&1 | Out-String
    if ($p.Trim()) {
        Add-Content -LiteralPath $log -Value ("{0} push`n{1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'), $p.Trim())
    }
}
