# Shared helpers for install.ps1 / uninstall.ps1. Dot-source this file.
# Works on Windows PowerShell 5.1: reads settings.json with ConvertFrom-Json and writes it back
# with a small serializer (ConvertTo-Json in 5.1 has depth limits and odd formatting).

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-ClaudeSettingsPath {
    $dir = $env:CLAUDE_CONFIG_DIR
    if (-not $dir) { $dir = Join-Path $env:USERPROFILE '.claude' }
    return (Join-Path $dir 'settings.json')
}

function Read-ClaudeSettings([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{} }
    $raw = [System.IO.File]::ReadAllText($path, $script:Utf8NoBom).TrimStart([char]0xFEFF)
    if (-not $raw.Trim()) { return [pscustomobject]@{} }
    try {
        return (ConvertFrom-Json -InputObject $raw)
    } catch {
        throw "Could not parse $path as JSON, so nothing was changed. Fix the file and run again. ($($_.Exception.Message))"
    }
}

function Backup-ClaudeSettings([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = '{0}.claude-toast-backup-{1}' -f $path, $stamp
    $n = 1
    while (Test-Path -LiteralPath $backup) { $n++; $backup = '{0}.claude-toast-backup-{1}-{2}' -f $path, $stamp, $n }
    Copy-Item -LiteralPath $path -Destination $backup -Force
    return $backup
}

function Write-ClaudeSettings([string]$path, $settings) {
    $json = (ConvertTo-PrettyJson $settings 0) + "`n"
    $null = ConvertFrom-Json -InputObject $json      # sanity check before touching the file
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $tmp = "$path.claude-toast-tmp"
    [System.IO.File]::WriteAllText($tmp, $json, $script:Utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

# A hook belongs to claude-toast if it runs our notify.ps1 with -Event.
function Test-ClaudeToastHook($hook) {
    if ($null -eq $hook) { return $false }
    $command = [string]$hook.command
    return ($command -match '(?i)notify\.ps1"?\s+-Event\s+(question|notification|permission|stop|prompt)\b')
}

# True if settings.json has any claude-toast hook (i.e. it was installed with install.ps1).
function Test-ClaudeToastInstalled($settings) {
    $hooksProp = $settings.PSObject.Properties['hooks']
    if ($null -eq $hooksProp -or $null -eq $hooksProp.Value) { return $false }
    foreach ($eventProp in @($hooksProp.Value.PSObject.Properties)) {
        foreach ($group in @($eventProp.Value)) {
            if ($null -eq $group -or $null -eq $group.PSObject.Properties['hooks']) { continue }
            foreach ($hook in @($group.hooks)) { if (Test-ClaudeToastHook $hook) { return $true } }
        }
    }
    return $false
}

# Removes every claude-toast hook. Only prunes matcher groups / event arrays / the "hooks"
# object when *we* emptied them, so the user's own (even empty) entries are left alone.
function Remove-ClaudeToastHooks($settings) {
    $removed = 0
    $hooksProp = $settings.PSObject.Properties['hooks']
    if ($null -eq $hooksProp -or $null -eq $hooksProp.Value) { return 0 }
    $hooks = $hooksProp.Value

    foreach ($eventProp in @($hooks.PSObject.Properties)) {
        $groups = @($eventProp.Value)
        $kept = New-Object System.Collections.ArrayList
        $removedHere = 0
        foreach ($group in $groups) {
            if ($null -eq $group) { continue }
            $groupHooksProp = $group.PSObject.Properties['hooks']
            if ($null -eq $groupHooksProp) { [void]$kept.Add($group); continue }
            $inner = @($groupHooksProp.Value)
            $keep  = @($inner | Where-Object { -not (Test-ClaudeToastHook $_) })
            $n = $inner.Count - $keep.Count
            if ($n -eq 0) { [void]$kept.Add($group); continue }
            $removedHere += $n
            if ($keep.Count -gt 0) {
                $group.hooks = $keep
                [void]$kept.Add($group)
            }
        }
        if ($removedHere -gt 0) {
            $removed += $removedHere
            if ($kept.Count -eq 0) { $hooks.PSObject.Properties.Remove($eventProp.Name) }
            else { $eventProp.Value = $kept.ToArray() }
        }
    }
    if ($removed -gt 0 -and @($hooks.PSObject.Properties).Count -eq 0) {
        $settings.PSObject.Properties.Remove('hooks')
    }
    return $removed
}

# ---------------------------------------------------------------- claude-toast: link handler

$script:ProtocolKey = 'HKCU:\Software\Classes\claude-toast'

# $dataDir: the plugin's data folder (state\ and logs\ live there); empty for a manual install.
# Returns $true if the registry was changed, $false if it already pointed there.
function Register-ClaudeToastProtocol([string]$answerScript, [string]$dataDir) {
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $data    = if ($dataDir) { " -DataDir `"$($dataDir.TrimEnd('\', '/'))`"" } else { '' }
    $command = "`"$conhost`" --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$answerScript`"$data `"%1`""
    $commandKey = "$script:ProtocolKey\shell\open\command"
    $current = try { (Get-ItemProperty -LiteralPath $commandKey -ErrorAction Stop).'(default)' } catch { $null }
    if ($current -eq $command) { return $false }
    $null = New-Item -Path $commandKey -Force
    Set-ItemProperty -Path $script:ProtocolKey -Name '(default)' -Value 'URL:claude-toast'
    Set-ItemProperty -Path $script:ProtocolKey -Name 'URL Protocol' -Value ''
    Set-ItemProperty -Path $commandKey -Name '(default)' -Value $command
    return $true
}

function Unregister-ClaudeToastProtocol {
    if (-not (Test-Path -LiteralPath $script:ProtocolKey)) { return $false }
    Remove-Item -LiteralPath $script:ProtocolKey -Recurse -Force
    return $true
}

# ---------------------------------------------------------------- JSON writer

function ConvertTo-JsonString([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $s.ToCharArray()) {
        $code = [int]$ch
        if     ($code -eq 34) { [void]$sb.Append('\"') }
        elseif ($code -eq 92) { [void]$sb.Append('\\') }
        elseif ($code -eq 10) { [void]$sb.Append('\n') }
        elseif ($code -eq 13) { [void]$sb.Append('\r') }
        elseif ($code -eq 9)  { [void]$sb.Append('\t') }
        elseif ($code -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-PrettyJson($value, [int]$indent) {
    $pad   = '  ' * $indent
    $inner = '  ' * ($indent + 1)
    if ($null -eq $value) { return 'null' }
    if ($value -is [bool]) { if ($value) { return 'true' } else { return 'false' } }
    if ($value -is [string] -or $value -is [char]) { return (ConvertTo-JsonString ([string]$value)) }
    if ($value -is [int] -or $value -is [long] -or $value -is [decimal] -or $value -is [double] -or
        $value -is [single] -or $value -is [int16] -or $value -is [byte] -or $value -is [uint32] -or $value -is [uint64]) {
        if ($value -is [double] -or $value -is [single]) {
            return ([double]$value).ToString('R', [Globalization.CultureInfo]::InvariantCulture)
        }
        return ([System.Convert]::ToString($value, [Globalization.CultureInfo]::InvariantCulture))
    }
    if ($value -is [System.Collections.IDictionary]) {
        $keys = @($value.Keys)
        if ($keys.Count -eq 0) { return '{}' }
        $parts = foreach ($k in $keys) { $inner + (ConvertTo-JsonString ([string]$k)) + ': ' + (ConvertTo-PrettyJson $value[$k] ($indent + 1)) }
        return "{`n" + ($parts -join ",`n") + "`n$pad}"
    }
    if ($value -is [System.Management.Automation.PSCustomObject]) {
        $props = @($value.PSObject.Properties)
        if ($props.Count -eq 0) { return '{}' }
        $parts = foreach ($p in $props) { $inner + (ConvertTo-JsonString $p.Name) + ': ' + (ConvertTo-PrettyJson $p.Value ($indent + 1)) }
        return "{`n" + ($parts -join ",`n") + "`n$pad}"
    }
    if ($value -is [System.Collections.IEnumerable]) {
        $items = @($value)
        if ($items.Count -eq 0) { return '[]' }
        $parts = foreach ($item in $items) { $inner + (ConvertTo-PrettyJson $item ($indent + 1)) }
        return "[`n" + ($parts -join ",`n") + "`n$pad]"
    }
    return (ConvertTo-JsonString ([string]$value))
}
