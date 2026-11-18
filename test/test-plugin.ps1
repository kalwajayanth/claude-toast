<#
.SYNOPSIS
  Checks the plugin mode of notify.ps1 / answer.ps1 (what the Claude Code plugin runs):
  config/logs/state in a data folder (-DataDir), the SessionStart "setup" event, and the
  "installed by hand too" guard. Your real settings.json and data are not touched; the
  claude-toast: registry entry is saved first and restored at the end.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test-plugin.ps1
#>
$ErrorActionPreference = 'Stop'
$root    = Split-Path -Parent $PSScriptRoot
$notify  = Join-Path $root 'notify.ps1'
$answer  = Join-Path $root 'answer.ps1'
$psExe   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$utf8    = New-Object System.Text.UTF8Encoding($false)
$work    = Join-Path $env:TEMP 'claude-toast-plugin-test'
$dataDir = Join-Path $work 'data'
$cfgHome = Join-Path $work 'claude-home'        # stands in for ~/.claude (CLAUDE_CONFIG_DIR)
$key     = 'HKCU:\Software\Classes\claude-toast\shell\open\command'
$failures = 0

function Reset-Work {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    $null = New-Item -ItemType Directory -Path $cfgHome -Force
}
function Set-FakeSettings([bool]$manualHooks) {
    $json = if ($manualHooks) {
        '{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"C:/x/notify.ps1\" -Event stop" } ] } ] } }'
    } else { '{ "theme": "dark" }' }
    [System.IO.File]::WriteAllText((Join-Path $cfgHome 'settings.json'), $json, $utf8)
}
function Invoke-Notify([string]$event, [string]$stdin, [hashtable]$envVars) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    # Trailing slash on purpose: ${CLAUDE_PLUGIN_DATA} ends with one.
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$notify`" -Event $event -DataDir `"$dataDir\\`""
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['CLAUDE_CONFIG_DIR']  = $cfgHome
    $psi.EnvironmentVariables['CLAUDE_TOAST_DEBUG'] = '1'
    if ($envVars) { foreach ($k in $envVars.Keys) { $psi.EnvironmentVariables[$k] = $envVars[$k] } }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $bytes = $utf8.GetBytes($stdin)
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $proc.StandardInput.Close()
    return [pscustomobject]@{ Proc = $proc; Out = $proc.StandardOutput.ReadToEndAsync() }
}
function Get-Text([string]$path) { if (Test-Path -LiteralPath $path) { [System.IO.File]::ReadAllText($path, $utf8) } else { '' } }
function Report([string]$name, [string[]]$problems) {
    if ($problems.Count) { $script:failures++; Write-Host "[FAIL] $name" -ForegroundColor Red; $problems | ForEach-Object { Write-Host "       !! $_" -ForegroundColor Red } }
    else { Write-Host "[ok  ] $name" -ForegroundColor Green }
}

$savedCommand = try { (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).'(default)' } catch { $null }
$payload = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'payloads\01-question-single.json'), $utf8).Replace('__TEST_DIR__', ($PSScriptRoot -replace '\\', '/'))
$session = ($payload | ConvertFrom-Json).session_id
$interactiveCfg = Join-Path $work 'interactive.json'
Write-Host "claude-toast plugin-mode tests`n" -ForegroundColor Cyan

try {
    # P1: installed by hand as well -> setup leaves the registry alone and marks "stay quiet".
    Reset-Work; Set-FakeSettings $true
    $r = Invoke-Notify 'setup' '{"hook_event_name":"SessionStart","source":"startup"}' $null
    $null = $r.Proc.WaitForExit(30000)
    $p = @()
    if ($r.Proc.ExitCode -ne 0) { $p += "exit $($r.Proc.ExitCode)" }
    if ($r.Out.Result) { $p += "stdout: $($r.Out.Result)" }
    if (-not (Test-Path (Join-Path $dataDir 'manual-install-detected'))) { $p += 'no manual-install marker' }
    if (-not (Test-Path (Join-Path $dataDir 'config.json'))) { $p += 'config.json not copied to the data folder' }
    $now = try { (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).'(default)' } catch { $null }
    if ($now -ne $savedCommand) { $p += 'registry was changed although a manual install exists' }
    Report 'P1 setup, also installed by hand -> plugin stays quiet, registry untouched' $p

    # P2: ...and then every hook does nothing (no toast, no stdout, fast).
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Notify 'question' $payload @{ CLAUDE_TOAST_CONFIG = $interactiveCfg }
    $null = $r.Proc.WaitForExit(30000); $sw.Stop()
    $p = @()
    if ($r.Out.Result) { $p += "stdout: $($r.Out.Result)" }
    if ((Get-Text (Join-Path $dataDir 'logs\activity.log')) -match '\] SHOWN') { $p += 'a toast was shown' }
    if ($sw.ElapsedMilliseconds -gt 5000) { $p += "slow: $($sw.ElapsedMilliseconds) ms" }
    Report "P2 question while the marker exists -> nothing ($($sw.ElapsedMilliseconds) ms)" $p

    # P3: plugin only -> setup registers claude-toast: -> this answer.ps1 with -DataDir; marker removed.
    Set-FakeSettings $false
    $r = Invoke-Notify 'setup' '{"hook_event_name":"SessionStart","source":"startup"}' $null
    $null = $r.Proc.WaitForExit(30000)
    $p = @()
    $now = try { (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).'(default)' } catch { '' }
    if ($now -notlike "*-File `"$answer`" -DataDir `"$dataDir`" `"%1`"") { $p += "registry command is: $now" }
    if (Test-Path (Join-Path $dataDir 'manual-install-detected')) { $p += 'marker still there' }
    if ($r.Out.Result) { $p += "stdout: $($r.Out.Result)" }
    Report 'P3 setup, plugin only -> link handler points at answer.ps1 + data folder' $p

    # P4: answer a question end to end in plugin mode: state in the data folder, click handled by
    #     answer.ps1 -DataDir (exactly the command the registry now runs).
    $cfg = '{ "interactive": { "enabled": true, "timeoutSeconds": 30, "skipWhenWatching": false } }'
    [System.IO.File]::WriteAllText($interactiveCfg, $cfg, $utf8)
    $r = Invoke-Notify 'question' $payload @{ CLAUDE_TOAST_CONFIG = $interactiveCfg }
    $sessionFile = Join-Path $dataDir "state\$session.session.json"
    for ($i = 0; $i -lt 100 -and -not (Test-Path $sessionFile); $i++) { Start-Sleep -Milliseconds 100 }
    $p = @()
    if (Test-Path $sessionFile) {
        $token = ([System.IO.File]::ReadAllText($sessionFile, $utf8) | ConvertFrom-Json).token
        Start-Sleep -Milliseconds 700
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $answer -DataDir $dataDir "claude-toast:pick?s=$session&t=$token&q=0&o=1"
    } else { $p += 'hook never started waiting in the data folder' }
    if (-not $r.Proc.WaitForExit(30000)) { $r.Proc.Kill(); $p += 'hook did not finish' }
    try {
        $got = ($r.Out.Result | ConvertFrom-Json).hookSpecificOutput.updatedInput.answers.'Which database should back the local cache?'
        if ($got -ne 'SQLite') { $p += "answer: '$got'" }
    } catch { $p += "stdout is not the answer JSON: '$($r.Out.Result)'" }
    if (Test-Path (Join-Path $root "state\$session.session.json")) { $p += 'state written next to the scripts instead of the data folder' }
    Report 'P4 answer from a toast in plugin mode -> "SQLite"' $p
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [Windows.UI.Notifications.ToastNotificationManager]::History.RemoveGroup("ct-$session", '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe')
    } catch { }
} finally {
    # Put your claude-toast: link handler back exactly as it was.
    if ($savedCommand) { Set-ItemProperty -LiteralPath $key -Name '(default)' -Value $savedCommand }
    else { Remove-Item -LiteralPath 'HKCU:\Software\Classes\claude-toast' -Recurse -Force -ErrorAction SilentlyContinue }
    $errors = Get-Text (Join-Path $dataDir 'logs\error.log')
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "`nlink handler restored: $savedCommand" -ForegroundColor DarkGray
if ($errors) { Write-Host "error.log in the data folder:`n$errors" -ForegroundColor DarkYellow }
if ($failures) { Write-Host "$failures case(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'All plugin-mode cases passed.' -ForegroundColor Green
