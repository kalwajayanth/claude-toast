<#
.SYNOPSIS
  Adds claude-toast's hooks to your global Claude Code settings (~/.claude/settings.json).

.DESCRIPTION
  * Backs up settings.json first (settings.json.claude-toast-backup-<timestamp>).
  * Keeps every existing setting and hook; only claude-toast's own entries are touched.
  * Safe to run any number of times: old claude-toast entries are replaced, never duplicated.
    Re-run it if you move this folder.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
#>
param([string]$SettingsPath)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\settings.ps1')

if (-not $SettingsPath) { $SettingsPath = Get-ClaudeSettingsPath }
$notify = Join-Path $PSScriptRoot 'notify.ps1'
if (-not (Test-Path -LiteralPath $notify)) { throw "notify.ps1 not found next to install.ps1 ($notify)" }

$answer = Join-Path $PSScriptRoot 'answer.ps1'
if (-not (Test-Path -LiteralPath $answer)) { throw "answer.ps1 not found next to install.ps1 ($answer)" }

# How long the question hook may wait for a toast answer (config.json interactive.timeoutSeconds).
$waitSeconds = 300
try {
    $cfg = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.interactive -and $cfg.interactive.timeoutSeconds) { $waitSeconds = [int]$cfg.interactive.timeoutSeconds }
} catch { }

# Forward slashes: Claude Code runs hook commands through Git Bash on Windows.
$notifyForBash = $notify -replace '\\', '/'
function New-ToastHookGroup([string]$matcher, [string]$event, [int]$timeout, [bool]$async) {
    $hook = [ordered]@{
        type    = 'command'
        command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$notifyForBash`" -Event $event"
        timeout = $timeout
    }
    if ($async) { $hook['async'] = $true }       # runs in the background, never delays Claude
    $group = [ordered]@{}
    if ($matcher) { $group['matcher'] = $matcher }
    $group['hooks'] = @([pscustomobject]$hook)
    return [pscustomobject]$group
}

$settings = Read-ClaudeSettings $SettingsPath
$backup   = Backup-ClaudeSettings $SettingsPath
$replaced = Remove-ClaudeToastHooks $settings

if ($null -eq $settings.PSObject.Properties['hooks'] -or $null -eq $settings.hooks) {
    $settings | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([pscustomobject]@{}) -Force
}
$additions = [ordered]@{
    'PreToolUse'        = New-ToastHookGroup 'AskUserQuestion'   'question'     ($waitSeconds + 30) $false
    'PermissionRequest' = New-ToastHookGroup '*'                 'permission'   ($waitSeconds + 30) $false
    'Notification'      = New-ToastHookGroup 'permission_prompt' 'notification' 15 $false
    'Stop'              = New-ToastHookGroup ''                  'stop'         20 $true
    'UserPromptSubmit'  = New-ToastHookGroup ''                  'prompt'       15 $true
}
foreach ($eventName in $additions.Keys) {
    $existing = $settings.hooks.PSObject.Properties[$eventName]
    if ($null -eq $existing) {
        $settings.hooks | Add-Member -NotePropertyName $eventName -NotePropertyValue @($additions[$eventName])
    } else {
        $existing.Value = @(@($existing.Value) | Where-Object { $null -ne $_ }) + @($additions[$eventName])
    }
}

Write-ClaudeSettings $SettingsPath $settings

# claude-toast: links -> answer.ps1, so toast buttons can answer questions. Per user (HKCU),
# started through "conhost --headless" so clicking a button never opens a window.
$null = Register-ClaudeToastProtocol $answer ''

Write-Host "claude-toast installed into $SettingsPath" -ForegroundColor Green
if ($backup)   { Write-Host "  backup:   $backup" }
if ($replaced) { Write-Host "  replaced $replaced existing claude-toast hook(s) (re-install)" }
Write-Host '  hooks:    PreToolUse[AskUserQuestion]      -> -Event question     (answer buttons)'
Write-Host '            PermissionRequest[*]             -> -Event permission   (Allow / Deny buttons)'
Write-Host '            Notification[permission_prompt]  -> -Event notification (fallback toast)'
Write-Host '            Stop (async)                     -> -Event stop         ("Response ready", once per reply)'
Write-Host '            UserPromptSubmit (async)         -> -Event prompt       (clears that chat''s toasts)'
Write-Host "  links:    claude-toast: -> answer.ps1 (HKCU\Software\Classes\claude-toast); answers wait up to $waitSeconds s"
Write-Host ''
Write-Host 'Already-running Claude Code sessions may need a restart (or a visit to /hooks) to pick this up.'
Write-Host 'Try it without Claude:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test.ps1'
