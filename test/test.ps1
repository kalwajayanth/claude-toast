<#
.SYNOPSIS
  Pipes the sample payloads in test\payloads into notify.ps1 exactly like Claude Code would,
  so you can see every toast without running Claude.

.DESCRIPTION
  Display cases (01-07) check the hook contract (exit 0, empty stdout, fast) and print what
  each toast says. Interactive cases (08-12) show the answerable toasts and "click" their
  buttons by opening the same claude-toast: links Windows opens on a real click (registry ->
  conhost --headless -> answer.ps1), then check the answer JSON the hook hands to Claude Code.
  Interactive cases need install.ps1 to have registered the claude-toast: link handler.
  The real config.json is not used; each case runs with its own small test config.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test.ps1 -Only 09 -DelaySeconds 0
#>
param(
    [double]$DelaySeconds = 2,
    [string]$Only
)

$ErrorActionPreference = 'Stop'
$testDir  = $PSScriptRoot
$root     = Split-Path -Parent $testDir
$notify   = Join-Path $root 'notify.ps1'
$stateDir = Join-Path $root 'state'
$activity = Join-Path $root 'logs\activity.log'
$errorLog = Join-Path $root 'logs\error.log'
$psExe    = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$utf8     = New-Object System.Text.UTF8Encoding($false)

# Per-case configs (the real config.json is left alone).
$cfgDir = Join-Path $env:TEMP 'claude-toast-test'
$null = New-Item -ItemType Directory -Path $cfgDir -Force
# skipWhenWatching is off so toasts show even while you watch the test in your terminal.
$configs = @{
    display     = '{ "interactive": { "enabled": false, "skipWhenWatching": false } }'
    interactive = '{ "interactive": { "enabled": true, "timeoutSeconds": 30, "skipWhenWatching": false } }'
    timeout     = '{ "interactive": { "enabled": true, "timeoutSeconds": 3, "skipWhenWatching": false } }'
    watching    = '{ "interactive": { "enabled": true, "timeoutSeconds": 30, "skipWhenWatching": true } }'
    locked      = '{ "interactive": { "enabled": true, "timeoutSeconds": 30, "lockedTimeoutSeconds": 1, "skipWhenWatching": false } }'
}
foreach ($k in $configs.Keys) { [System.IO.File]::WriteAllText((Join-Path $cfgDir "$k.json"), $configs[$k], $utf8) }
# Files that make notify.ps1 believe the screen is locked / you are looking at the chat (tests only).
$fakeLock  = Join-Path $cfgDir 'fake-lock'
$fakeWatch = Join-Path $cfgDir 'fake-watch'
Remove-Item $fakeLock, $fakeWatch -Force -ErrorAction SilentlyContinue

# Multi-select buttons are checkboxes: "☐ 1" / "☑ 1" (written as char codes: this file has no BOM).
$Box = [string][char]0x2610; $Tick = [string][char]0x2611
$Q1 = 'Which database should back the local cache?'
$Q3 = 'Which test suites should I run before opening the PR?'
$cases = @(
    @{ Id = '01'; File = '01-question-single.json';      Event = 'question';     Config = 'display'; Expect = 'SHOWN';   What = 'single question; chat name from /rename (custom-title)' }
    @{ Id = '02'; File = '02-permission-duplicate.json'; Event = 'notification'; Config = 'display'; Expect = 'SKIPPED'; What = 'generic permission ping right after 01, same session -> de-duplicated' }
    @{ Id = '03'; File = '03-question-multiselect.json'; Event = 'question';     Config = 'display'; Expect = 'SHOWN';   What = 'multi-select; chat name from latest ai-title' }
    @{ Id = '04'; File = '04-questions-three.json';      Event = 'question';     Config = 'display'; Expect = 'SHOWN';   What = 'three questions; XML chars; chat name from first prompt' }
    @{ Id = '05'; File = '05-permission-prompt.json';    Event = 'notification'; Config = 'display'; Expect = 'SHOWN';   What = 'permission prompt; no transcript -> folder name' }
    @{ Id = '06'; File = '06-idle.json';                 Event = 'notification'; Config = 'display'; Expect = 'SKIPPED'; What = 'idle "waiting for your input" reminder -> no toast (Stop sends "Response ready" instead)' }
    @{ Id = '07'; File = '07-malformed.json';            Event = 'question';     Config = 'display'; Expect = 'ERROR';   What = 'broken JSON -> no toast, error logged, still exit 0' }
    @{ Id = '08'; File = '01-question-single.json';      Event = 'question';     Config = 'interactive'; Expect = 'ANSWERED'
       What = 'answer from toast: forged link ignored, then click "2. SQLite"'
       Clicks = @('forged 0 0', 'pick 0 1'); Answers = @{ $Q1 = 'SQLite' } }
    @{ Id = '09'; File = '03-question-multiselect.json'; Event = 'question';     Config = 'interactive'; Expect = 'ANSWERED'
       What = 'multi-select: tick Unit, tick End-to-end, untick Unit, tick Lint, Done'
       Clicks = @('toggle 0 0', 'toggle 0 2', 'toggle 0 0', 'toggle 0 3', 'submit 0'); Answers = @{ $Q3 = 'End-to-end, Lint & typecheck' }
       # 4 options: the 5th button is Terminal until something is ticked, then Done.
       ExpectLog = "(?s)buttons: $Box 1, $Box 2, $Box 3, $Box 4, Terminal\r?\n.*buttons: $Tick 1, $Box 2, $Box 3, $Box 4, Done\r?\n.*buttons: $Box 1, $Box 2, $Tick 3, $Box 4, Done\r?\n" }
    @{ Id = '10'; File = '04-questions-three.json';      Event = 'question';     Config = 'interactive'; Expect = 'ANSWERED'
       What = 'three questions, one toast after another (single, single, multi)'
       Clicks = @('pick 0 0', 'pick 1 1', 'toggle 2 0', 'toggle 2 2', 'submit 2')
       Answers = @{
           'Should retries use exponential backoff with <jitter> & a 30s cap?' = 'Yes, "full" jitter'
           'Where should the SDK client be constructed?' = 'Module singleton'
           'Which endpoints migrate first?' = 'Invoices, Webhooks' }
       # 3 options: checkboxes + Done + Terminal, always.
       ExpectLog = "(?s)buttons: $Box 1, $Box 2, $Box 3, Done, Terminal\r?\n.*buttons: $Tick 1, $Box 2, $Box 3, Done, Terminal\r?\n" }
    @{ Id = '11'; File = '01-question-single.json';      Event = 'question';     Config = 'interactive'; Expect = 'FALLBACK'
       What = '"Answer in terminal" -> hook returns nothing, terminal brought to front'
       Clicks = @('terminal 0') }
    @{ Id = '12'; File = '03-question-multiselect.json'; Event = 'question';     Config = 'timeout';     Expect = 'FALLBACK'
       What = 'nobody clicks -> gives up after the timeout (3 s here), terminal question appears'
       Clicks = @() }
    @{ Id = '13'; File = '08-stop.json';                 Event = 'stop';         Config = 'display';     Expect = 'SHOWN'
       What = 'Claude finished -> one "Response ready" toast with the start of the reply' }
    @{ Id = '14'; File = '09-prompt-submit.json';        Event = 'prompt';       Config = 'display';     Expect = 'CLEARED'
       What = 'you replied in that chat -> its toasts (the "Response ready" from 13) are removed' }
    @{ Id = '15'; File = '10-permission-bash.json';      Event = 'permission';   Config = 'interactive'; Expect = 'ALLOW'
       What = 'permission for a Bash command -> click Allow'; Clicks = @('allow 0') }
    @{ Id = '16'; File = '10-permission-bash.json';      Event = 'permission';   Config = 'interactive'; Expect = 'DENY'
       What = 'permission for a Bash command -> click Deny'; Clicks = @('deny 0') }
    @{ Id = '17'; File = '11-permission-askuserquestion.json'; Event = 'permission'; Config = 'interactive'; Expect = 'NOOP'
       What = 'permission request for AskUserQuestion -> left to the question hook, returns at once' }
    @{ Id = '18'; File = '01-question-single.json';      Event = 'question';     Config = 'interactive'; Expect = 'ANSWERED'
       What = 'screen locked while waiting (toast hidden) -> unlocked -> toast shown again within 0.6 s -> click 3'
       Clicks = @('lock', 'unlock', 'pick 0 2'); Answers = @{ $Q1 = 'Skip' }; ExpectLog = 'RESHOWN'; MaxReshowMs = 600 }
    @{ Id = '19'; File = '01-question-single.json';      Event = 'question';     Config = 'watching';    Expect = 'FALLBACK'
       What = 'you switch to the chat''s terminal tab while it waits -> question moves to the terminal'
       Clicks = @('watch'); ExpectLog = 'MOVED' }
    @{ Id = '20'; File = '01-question-single.json';      Event = 'question';     Config = 'locked';      Expect = 'FALLBACK'
       What = 'screen stays locked past lockedTimeoutSeconds (1 s here) -> question goes to the terminal; pops up again on unlock'
       Clicks = @('lock', 'awayunlock'); MaxReshowMs = 600
       ExpectLog = '(?s)AWAY \| screen locked.*RESULT \| locked.*RESHOWN \| screen unlocked - the prompt is waiting in the terminal.*SHOWN \| [^|]*\| Which database' }
)
if ($Only) { $cases = @($cases | Where-Object { $_.Id -like "$Only*" }) }

function Get-FileLength([string]$path) { if (Test-Path -LiteralPath $path) { (Get-Item -LiteralPath $path).Length } else { 0 } }
function Get-NewText([string]$path, [long]$from) {
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -le $from) { return '' }
    return $utf8.GetString($bytes, [int]$from, [int]($bytes.Length - $from)).Trim()
}

function Start-Notify([string]$event, [byte[]]$stdin, [string]$configName) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$notify`" -Event $event"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.EnvironmentVariables['CLAUDE_TOAST_DEBUG'] = '1'
    $psi.EnvironmentVariables['CLAUDE_TOAST_CONFIG'] = (Join-Path $cfgDir "$configName.json")
    $psi.EnvironmentVariables['CLAUDE_TOAST_FAKE_LOCK'] = $fakeLock
    $psi.EnvironmentVariables['CLAUDE_TOAST_FAKE_WATCH'] = $fakeWatch
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.BaseStream.Write($stdin, 0, $stdin.Length)
    $proc.StandardInput.Close()
    [pscustomobject]@{ Proc = $proc; Out = $proc.StandardOutput.ReadToEndAsync(); Err = $proc.StandardError.ReadToEndAsync() }
}

# Click a toast button the way Windows does: open the claude-toast: link.
function Send-Click([string]$sessionId, [string]$spec) {
    $parts = $spec.Split(' ')
    $action = $parts[0]; $q = $parts[1]; $o = if ($parts.Count -gt 2) { $parts[2] } else { '' }
    $sessionFile = Join-Path $stateDir "$sessionId.session.json"
    $eventsDir   = Join-Path $stateDir "$sessionId.events"
    if ($action -eq 'awayunlock') {
        # The hook gave up while "locked": it must have ended (Claude Code waits for its output to
        # close) and left the prompt to the hidden unlock watcher.
        $awayFile = Join-Path $stateDir "$sessionId.away.json"
        for ($i = 0; $i -lt 50 -and -not (Test-Path -LiteralPath $awayFile); $i++) { Start-Sleep -Milliseconds 100 }
        if (-not (Test-Path -LiteralPath $awayFile)) { throw 'no hand-over to the unlock watcher (no away.json)' }
        if (-not $script:CurrentRun.Out.Wait(5000)) { throw 'hook output still open after giving up - Claude Code would keep waiting' }
        Start-Sleep -Milliseconds 1500          # let the hidden watcher start up
        $action = 'unlock'
    }
    for ($i = 0; $action -ne 'unlock' -and $i -lt 60 -and -not (Test-Path -LiteralPath $sessionFile); $i++) { Start-Sleep -Milliseconds 100 }
    if ($action -ne 'unlock' -and -not (Test-Path -LiteralPath $sessionFile)) { throw "hook never started waiting (no $sessionFile)" }
    switch ($action) {
        'lock'   { [System.IO.File]::WriteAllText($fakeLock, 'x'); Start-Sleep -Milliseconds 2500; return }
        'unlock' {
            # Measure how fast the toast comes back after unlocking.
            $logFrom = Get-FileLength $activity
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            Remove-Item $fakeLock -Force
            while ($sw.ElapsedMilliseconds -lt 5000 -and (Get-NewText $activity $logFrom) -notmatch 'RESHOWN') { Start-Sleep -Milliseconds 25 }
            $script:ReshowMs = $sw.ElapsedMilliseconds
            # ...and for the toast itself to be logged (the unlock watcher runs on its own).
            while ($sw.ElapsedMilliseconds -lt 8000 -and (Get-NewText $activity $logFrom) -notmatch '(?s)RESHOWN.*\] SHOWN') { Start-Sleep -Milliseconds 25 }
            return
        }
        'watch'  { [System.IO.File]::WriteAllText($fakeWatch, 'x'); Start-Sleep -Milliseconds 2500; return }
    }
    $token = ([System.IO.File]::ReadAllText($sessionFile, $utf8) | ConvertFrom-Json).token
    if ($action -eq 'forged') { $action = 'pick'; $token = [guid]::NewGuid().ToString('N') }
    $uri = "claude-toast:$action`?s=$sessionId&t=$token&q=$q"
    if ($o) { $uri += "&o=$o" }
    Start-Sleep -Milliseconds 700          # let the toast appear so you can see it being "clicked"
    Start-Process $uri
    # Wait for answer.ps1 to drop the click and for the hook to consume it.
    $deadline = (Get-Date).AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 150
        $pending = @(Get-ChildItem -LiteralPath $eventsDir -Filter '*.evt' -ErrorAction SilentlyContinue).Count
    } while ($pending -gt 0 -and (Get-Date) -lt $deadline)
}

function Clear-TestToasts([string]$sessionId) {
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [Windows.UI.Notifications.ToastNotificationManager]::History.RemoveGroup("ct-$sessionId", '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe')
    } catch { }
}

$testDirForJson = $testDir -replace '\\', '/'
$failures = 0
Write-Host "claude-toast test run: $($cases.Count) case(s)`n" -ForegroundColor Cyan

foreach ($case in $cases) {
    $text    = [System.IO.File]::ReadAllText((Join-Path $testDir "payloads\$($case.File)"), $utf8)
    $bytes   = $utf8.GetBytes($text.Replace('__TEST_DIR__', $testDirForJson))
    $session = ''
    try { $session = ($text | ConvertFrom-Json).session_id } catch { }

    $activityStart = Get-FileLength $activity
    $errorStart    = Get-FileLength $errorLog
    $script:ReshowMs = -1
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $run   = Start-Notify $case.Event $bytes $case.Config
    $script:CurrentRun = $run
    $clickError = $null
    try { foreach ($click in @($case.Clicks)) { if ($click) { Send-Click $session $click } } }
    catch { $clickError = $_.Exception.Message }
    if (-not $run.Proc.WaitForExit(60000)) { $run.Proc.Kill(); $clickError = 'notify.ps1 did not exit within 60 s' }
    $watch.Stop()
    $stdout = $run.Out.Result
    $did    = Get-NewText $activity $activityStart
    $errors = Get-NewText $errorLog $errorStart

    $problems = @()
    if ($clickError) { $problems += $clickError }
    if ($run.Proc.ExitCode -ne 0) { $problems += "exit code $($run.Proc.ExitCode)" }
    $isInteractive = $case.Expect -in @('ANSWERED', 'FALLBACK', 'ALLOW', 'DENY')
    if ($case.Expect -in @('ALLOW', 'DENY')) {
        try {
            $d = ($stdout | ConvertFrom-Json).hookSpecificOutput
            if ($d.hookEventName -ne 'PermissionRequest') { $problems += 'stdout is not a PermissionRequest decision' }
            if ($d.decision.behavior -ne $case.Expect.ToLower()) { $problems += "expected behavior '$($case.Expect.ToLower())', got '$($d.decision.behavior)'" }
        } catch { $problems += "stdout is not the expected JSON: '$stdout'" }
    } elseif ($case.Expect -eq 'NOOP') {
        if ($stdout) { $problems += "expected no stdout, got: $stdout" }
        if ($did -cmatch '\] (SHOWN|RESULT) \|') { $problems += 'expected no toast' }
        if ($watch.ElapsedMilliseconds -gt 5000) { $problems += "slow: $($watch.ElapsedMilliseconds) ms" }
    } elseif ($case.Expect -eq 'CLEARED') {
        if ($stdout) { $problems += "expected no stdout, got: $stdout" }
        if ($did -notmatch 'CLEARED \| ([1-9]\d*) toast') { $problems += 'expected at least one toast to be cleared' }
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        $left = @([Windows.UI.Notifications.ToastNotificationManager]::History.GetHistory($aumid) | Where-Object { $_.Group -eq "ct-$session" }).Count
        if ($left) { $problems += "$left toast(s) of the chat still on screen" }
    } elseif ($isInteractive) {
        if ($case.Expect -eq 'ANSWERED') {
            try {
                $out = $stdout | ConvertFrom-Json
                $h = $out.hookSpecificOutput
                if ($h.hookEventName -ne 'PreToolUse' -or $h.permissionDecision -ne 'allow') { $problems += 'stdout is not a PreToolUse allow decision' }
                if (-not $h.updatedInput.questions) { $problems += 'updatedInput lost the original questions' }
                foreach ($key in $case.Answers.Keys) {
                    $got = $h.updatedInput.answers.$key
                    if ($got -ne $case.Answers[$key]) { $problems += "answer for '$key': expected '$($case.Answers[$key])', got '$got'" }
                }
            } catch { $problems += "stdout is not the expected JSON: '$stdout'" }
        } elseif ($stdout) { $problems += "expected no stdout (fall back to terminal), got: $stdout" }
        if ($case.Expect -eq 'FALLBACK' -and $did -notmatch 'RESULT \| (terminal|timeout|locked)') { $problems += 'no terminal/timeout result logged' }
    } else {
        $outcome = if ($did -cmatch '\] SHOWN \|') { 'SHOWN' } elseif ($did -cmatch '\] SKIPPED \|') { 'SKIPPED' } elseif ($errors) { 'ERROR' } else { 'NOTHING' }
        if ($stdout) { $problems += "wrote to stdout: $($stdout.Trim())" }
        if ($watch.ElapsedMilliseconds -gt 5000) { $problems += "slow: $($watch.ElapsedMilliseconds) ms" }
        if ($outcome -ne $case.Expect) { $problems += "expected $($case.Expect), got $outcome" }
    }
    if ($case.Expect -ne 'ERROR' -and $errors) { $problems += "error.log: $errors" }
    if ($case.ExpectLog -and $did -notmatch $case.ExpectLog) { $problems += "expected a $($case.ExpectLog) entry in the activity log" }
    if ($case.MaxReshowMs) {
        if ($script:ReshowMs -lt 0 -or $script:ReshowMs -gt $case.MaxReshowMs) { $problems += "toast came back $($script:ReshowMs) ms after unlocking (limit $($case.MaxReshowMs) ms)" }
    }
    Remove-Item $fakeLock, $fakeWatch -Force -ErrorAction SilentlyContinue

    $color = if ($problems.Count) { 'Red' } else { 'Green' }
    $mark  = if ($problems.Count) { 'FAIL' } else { 'ok  ' }
    Write-Host ('[{0}] {1} {2}  ({3} ms, exit {4})' -f $mark, $case.Id, $case.File, $watch.ElapsedMilliseconds, $run.Proc.ExitCode) -ForegroundColor $color
    Write-Host ('       {0}' -f $case.What)
    if ($case.MaxReshowMs -and $script:ReshowMs -ge 0) { Write-Host "       re-pop after unlock: $($script:ReshowMs) ms" }
    foreach ($line in ($did -split "`r?`n")) {
        if ($line -match '\] (SHOWN|SKIPPED|RESULT|CLICK|STALE|TERMINAL|CLEARED|RESHOWN|MOVED|AWAY) \| (.*)$') {
            $kind = $Matches[1]; $rest = $Matches[2]
            if ($kind -eq 'SHOWN') {
                $f = $rest -split ' \| '
                if ($isInteractive) { Write-Host "       toast: $($f[1])  [$(($f[4] -replace '^buttons: '))]"; continue }
                Write-Host  "       title: $($f[0])"
                Write-Host  "       text:  $($f[1])"
                if ($f[2]) { foreach ($block in ($f[2] -split ' ~~ ')) { foreach ($l in ($block -split ' ~ ')) { Write-Host "              $l" } } }
                if ($f[3]) { Write-Host "       small: $($f[3])" }
                if ($f[4]) { Write-Host "       $($f[4])" }
            } else { Write-Host ('       {0}: {1}' -f $kind.ToLower(), $rest) }
        }
    }
    if ($case.Expect -eq 'ANSWERED' -and $stdout -and -not $problems.Count) { Write-Host "       -> Claude Code receives: $(($stdout | ConvertFrom-Json).hookSpecificOutput.updatedInput.answers | ConvertTo-Json -Compress)" }
    if ($case.Expect -in @('ALLOW', 'DENY') -and $stdout -and -not $problems.Count) { Write-Host "       -> Claude Code receives: $stdout" }
    if ($case.Expect -eq 'ERROR' -and $errors) { Write-Host "       logged: $(($errors -split "`r?`n")[-1])" }
    foreach ($p in $problems) { Write-Host "       !! $p" -ForegroundColor Red }
    if ($problems.Count) { $failures++ }
    Write-Host ''
    if ($DelaySeconds -gt 0) { Start-Sleep -Milliseconds ([int]($DelaySeconds * 1000)) }
    # Toasts stay until clicked; clear this case's so the next one can pop up (13's are left for 14 to clear).
    if ($session -and $case.Id -ne '13') { Clear-TestToasts $session }
}

# Remove de-dup markers written by the fake test sessions.
Get-ChildItem -LiteralPath $stateDir -Filter 'test-*' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force

if ($failures) { Write-Host "$failures case(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'All cases passed. If you saw no toasts, check Focus Assist / Do Not Disturb (see README).' -ForegroundColor Green
