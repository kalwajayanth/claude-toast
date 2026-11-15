<#
.SYNOPSIS
  Removes claude-toast's hooks from your global Claude Code settings. Nothing else is touched.

.DESCRIPTION
  Backs up settings.json first, removes only hooks that run claude-toast's notify.ps1,
  and prunes matcher groups / hook arrays that become empty because of that.
  Pass -Purge to also delete claude-toast's logs\ and state\ folders.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
#>
param([string]$SettingsPath, [switch]$Purge)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\settings.ps1')

if (-not $SettingsPath) { $SettingsPath = Get-ClaudeSettingsPath }

if (-not (Test-Path -LiteralPath $SettingsPath)) {
    Write-Host "No settings file at $SettingsPath - nothing to uninstall."
} else {
    $settings = Read-ClaudeSettings $SettingsPath
    $probe    = Read-ClaudeSettings $SettingsPath
    if ((Remove-ClaudeToastHooks $probe) -eq 0) {
        Write-Host "No claude-toast hooks found in $SettingsPath - file left untouched."
    } else {
        $backup  = Backup-ClaudeSettings $SettingsPath
        $removed = Remove-ClaudeToastHooks $settings
        Write-ClaudeSettings $SettingsPath $settings
        Write-Host "Removed $removed claude-toast hook(s) from $SettingsPath" -ForegroundColor Green
        Write-Host "  backup: $backup"
    }
}

if (Unregister-ClaudeToastProtocol) { Write-Host 'Removed the claude-toast: link handler (HKCU\Software\Classes\claude-toast)' -ForegroundColor Green }

if ($Purge) {
    foreach ($dir in 'logs', 'state') {
        $path = Join-Path $PSScriptRoot $dir
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force; Write-Host "  deleted $path" }
    }
}
