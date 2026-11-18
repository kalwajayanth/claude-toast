<#
.SYNOPSIS
  claude-toast hook handler: shows a Windows toast when Claude Code needs you.

.DESCRIPTION
  Claude Code runs this from hooks and passes the hook payload as JSON on stdin.
    -Event question       PreToolUse, matcher "AskUserQuestion"   answer buttons, waits for your click
    -Event permission     PermissionRequest                      Allow / Deny buttons, waits for your click
    -Event notification   Notification, matcher "permission_prompt"  notify-only fallback
    -Event stop           Stop                                   one "Response ready" toast per reply
    -Event prompt         UserPromptSubmit                       you replied: clear that chat's toasts
    -Event setup          SessionStart (plugin only)             registers the button link handler

  -DataDir: where config.json, logs\ and state\ live. The plugin passes ${CLAUDE_PLUGIN_DATA}
  (kept across plugin updates); a manual install (install.ps1) leaves it empty = this folder.

  Contract with Claude Code: never break it.
    * always exits 0; every error is caught and logged to logs\error.log
    * stdout stays empty, except one JSON decision when you answered from a toast
    * only question/permission wait for a click (up to interactive.timeoutSeconds), and only
      when you are NOT looking at that chat's terminal tab; on timeout, "Terminal" or any error
      they return nothing and Claude Code shows its normal terminal prompt.
#>
param([string]$Event = 'notification', [string]$DataDir)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$WarningPreference     = 'SilentlyContinue'
$VerbosePreference     = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'

$script:Root     = $PSScriptRoot
$script:DataDir  = if ($DataDir) { $DataDir.TrimEnd('\', '/') } else { $PSScriptRoot }
$script:PluginMode = [bool]$DataDir
$script:LogDir   = Join-Path $script:DataDir 'logs'
$script:StateDir = Join-Path $script:DataDir 'state'
# Windows PowerShell's own AppUserModelID: lets us show toasts without registering an app.
$script:AppId    = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
$script:Utf8     = New-Object System.Text.UTF8Encoding($false)
$script:Config   = $null
$script:DebugOn  = $false

# ------------------------------------------------------------------ logging

function Write-LogLine([string]$file, [string]$message) {
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) {
            $null = New-Item -ItemType Directory -Path $script:LogDir -Force
        }
        $path = Join-Path $script:LogDir $file
        if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 1MB) {
            Move-Item -LiteralPath $path -Destination "$path.old" -Force
        }
        $line = '{0} [{1}] {2}{3}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Event, $message, [Environment]::NewLine
        [System.IO.File]::AppendAllText($path, $line, $script:Utf8)
    } catch { }
}

function Write-ErrorLog([string]$message) {
    if ($message.Length -gt 600) { $message = $message.Substring(0, 600) + '...' }   # no payload dumps
    Write-LogLine 'error.log' $message
}

function Write-ActivityLog([string]$message) {
    if ($script:DebugOn) { Write-LogLine 'activity.log' $message }
}

function Format-ErrorRecord($err) {
    try {
        return '{0}: {1} (line {2})' -f $err.Exception.GetType().Name, $err.Exception.Message, $err.InvocationInfo.ScriptLineNumber
    } catch { return [string]$err }
}

# ------------------------------------------------------------------ config

function Read-Config {
    $path = $env:CLAUDE_TOAST_CONFIG          # override, used by tests
    if (-not $path) {
        # Plugin: your copy in the data folder; until it exists, the defaults shipped with the plugin.
        $path = Join-Path $script:DataDir 'config.json'
        if (-not (Test-Path -LiteralPath $path)) { $path = Join-Path $script:Root 'config.json' }
    }
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($path, $script:Utf8)
        return ConvertFrom-Json -InputObject $raw.TrimStart([char]0xFEFF)
    } catch {
        Write-ErrorLog ('config.json ignored: ' + (Format-ErrorRecord $_))
        return $null
    }
}

# Get-ConfigValue 'sounds.question' 'default'  -> nested lookup with a fallback.
function Get-ConfigValue([string]$path, $default) {
    $node = $script:Config
    foreach ($key in $path.Split('.')) {
        if ($null -eq $node) { return $default }
        $prop = $node.PSObject.Properties[$key]
        if ($null -eq $prop) { return $default }
        $node = $prop.Value
    }
    if ($null -eq $node) { return $default }
    return $node
}

# ------------------------------------------------------------------ text helpers

# Collapse whitespace/newlines and drop characters that are illegal in XML.
function Format-OneLine([string]$text) {
    if ([string]::IsNullOrEmpty($text)) { return '' }
    $text = [regex]::Replace($text, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F￾￿]', '')
    return ([regex]::Replace($text, '\s+', ' ')).Trim()
}

# Cut to $max chars, preferring a word boundary, and end with an ellipsis.
function Limit-Text([string]$text, [int]$max) {
    if ([string]::IsNullOrEmpty($text) -or $text.Length -le $max) { return $text }
    $cut = $text.Substring(0, $max - 1)
    $space = $cut.LastIndexOf(' ')
    if ($space -ge [int]($max * 0.6)) { $cut = $cut.Substring(0, $space) }
    if ($cut.Length -gt 0 -and [char]::IsHighSurrogate($cut[$cut.Length - 1])) {
        $cut = $cut.Substring(0, $cut.Length - 1)   # never split an emoji in half
    }
    return $cut.TrimEnd(' ', ',', ';', ':', '-') + [char]0x2026
}

function ConvertTo-XmlText([string]$text) {
    if ($null -eq $text) { return '' }
    return [System.Security.SecurityElement]::Escape($text)
}

function ConvertFrom-JsonSafe([string]$text) {
    try { return ConvertFrom-Json -InputObject $text } catch { return $null }
}

# ------------------------------------------------------------------ input

function Read-Payload {
    if (-not [Console]::IsInputRedirected) { return $null }
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $script:Utf8)
    try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $raw = $raw.TrimStart([char]0xFEFF).Trim()
    if (-not $raw) { return $null }
    return ConvertFrom-Json -InputObject $raw
}

# ------------------------------------------------------------------ chat name
# Transcript facts (verified against real files in ~/.claude/projects):
#   {"type":"custom-title","customTitle":"..."}   written by /rename (last one wins)
#   {"type":"ai-title","aiTitle":"..."}           auto-generated title (last one wins)
#   {"type":"user","origin":{"kind":"human"},"message":{"content": "..." | [{type:"text",text:"..."}]}}

function Get-PromptText($message) {
    if ($null -eq $message) { return '' }
    $content = $message.content
    if ($null -eq $content) { return '' }
    if ($content -is [string]) { return $content }
    $parts = foreach ($part in @($content)) {
        if ($part -and $part.type -eq 'text' -and $part.text) { [string]$part.text }
    }
    return (@($parts) -join ' ')
}

function Test-HumanPrompt($entry) {
    if ($null -eq $entry -or $entry.type -ne 'user') { return $false }
    if ($entry.isMeta -eq $true -or $entry.isSidechain -eq $true) { return $false }
    if ($entry.origin -and $entry.origin.kind -and $entry.origin.kind -ne 'human') { return $false }
    $content = $entry.message.content
    if ($content -and $content -isnot [string]) {
        foreach ($part in @($content)) { if ($part -and $part.type -eq 'tool_result') { return $false } }
    }
    return $true
}

function Get-CleanPrompt([string]$text) {
    $text = [regex]::Replace($text, '(?s)<system-reminder>.*?</system-reminder>', ' ')
    $text = [regex]::Replace($text, '</?pasted_content[^>]*>', ' ')
    $text = Format-OneLine $text
    if ($text -match '^<(command-|local-command)' -or $text -match '^\[Request interrupted') { return '' }
    return $text
}

function Get-ChatName($payload) {
    $customTitle = $null; $aiTitle = $null; $firstPrompt = $null
    try {
        $path = [string]$payload.transcript_path
        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            $share  = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
            $stream = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
            $reader = New-Object System.IO.StreamReader($stream, $script:Utf8)
            try {
                while ($null -ne ($line = $reader.ReadLine())) {
                    # Title entries are tiny one-liners; only parse short lines that mention them.
                    if ($line.Length -lt 4000 -and ($line.Contains('"custom-title"') -or $line.Contains('"ai-title"'))) {
                        $entry = ConvertFrom-JsonSafe $line
                        if ($entry -and $entry.type -eq 'custom-title') { if ($entry.customTitle) { $customTitle = [string]$entry.customTitle }; continue }
                        if ($entry -and $entry.type -eq 'ai-title')     { if ($entry.aiTitle)     { $aiTitle     = [string]$entry.aiTitle };     continue }
                    }
                    if ($null -eq $firstPrompt -and $line.Contains('"type":"user"')) {
                        $entry = ConvertFrom-JsonSafe $line
                        if (Test-HumanPrompt $entry) {
                            $text = Get-CleanPrompt (Get-PromptText $entry.message)
                            if ($text) { $firstPrompt = $text }
                        }
                    }
                }
            } finally { $reader.Dispose() }
        }
    } catch {
        Write-ErrorLog ('transcript read failed: ' + (Format-ErrorRecord $_))
    }

    foreach ($candidate in @($customTitle, $aiTitle)) {
        $value = Format-OneLine $candidate
        if ($value) { return (Limit-Text $value 60) }
    }
    if ($firstPrompt) { return (Limit-Text $firstPrompt 50) }
    $cwd = [string]$payload.cwd
    if ($cwd) {
        $leaf = Split-Path -Leaf ($cwd.TrimEnd('\', '/'))
        if ($leaf) { return $leaf }
    }
    return 'Claude Code'
}

# ------------------------------------------------------------------ de-duplication

function Get-MarkerPath([string]$sessionId) {
    $safe = $sessionId -replace '[^A-Za-z0-9_-]', '_'
    if (-not $safe) { $safe = 'unknown-session' }
    return (Join-Path $script:StateDir ($safe + '.question'))
}

function Set-QuestionMarker([string]$sessionId) {
    if (-not (Test-Path -LiteralPath $script:StateDir)) {
        $null = New-Item -ItemType Directory -Path $script:StateDir -Force
    }
    [System.IO.File]::WriteAllText((Get-MarkerPath $sessionId), [DateTime]::UtcNow.ToString('o'), $script:Utf8)
    # Housekeeping: drop markers older than a day.
    Get-ChildItem -LiteralPath $script:StateDir -Filter '*.question' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-1) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# Seconds since the last question toast for this session, or $null if none.
function Get-QuestionMarkerAge([string]$sessionId) {
    $path = Get-MarkerPath $sessionId
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $stamp = [DateTime]::MinValue
    $text  = ([System.IO.File]::ReadAllText($path, $script:Utf8)).Trim()
    if (-not [DateTime]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$stamp)) {
        $stamp = (Get-Item -LiteralPath $path).LastWriteTimeUtc
    }
    return ([DateTime]::UtcNow - $stamp.ToUniversalTime()).TotalSeconds
}

# ------------------------------------------------------------------ toast building blocks

$script:DefaultSounds = @{
    question   = 'ms-winsoundevent:Notification.Reminder'
    permission = 'ms-winsoundevent:Notification.Default'
    ready      = 'ms-winsoundevent:Notification.IM'
}

function Get-AudioXml([string]$kind) {
    $sound = [string](Get-ConfigValue "sounds.$kind" $script:DefaultSounds[$kind])
    if (-not $sound -or $sound -eq 'silent') { return '<audio silent="true"/>' }
    return '<audio src="' + (ConvertTo-XmlText $sound) + '"/>'
}

# A "block" is rendered as an adaptive group: optional bold heading, one line per entry
# (wrapping allowed, so nothing is cut off), and an optional small caption.
function New-Block([string]$heading, [string[]]$lines, [string]$caption) {
    [pscustomobject]@{ Heading = $heading; Lines = @($lines | Where-Object { $_ }); Caption = $caption }
}

# Flat text version of the blocks, for the activity log and the phone push.
function Get-BlockText($blocks, [string]$lineSep, [string]$blockSep) {
    $parts = foreach ($block in @($blocks)) {
        if ($null -eq $block) { continue }
        $lines = @()
        if ($block.Heading) { $lines += $block.Heading }
        $lines += $block.Lines
        if ($block.Caption) { $lines += $block.Caption }
        ($lines -join $lineSep)
    }
    return (@($parts) -join $blockSep)
}

function Get-VisualXml([string]$title, [string]$body, $blocks, [string]$attribution) {
    $xml = New-Object System.Text.StringBuilder
    [void]$xml.Append('<visual><binding template="ToastGeneric">')
    foreach ($text in @($title, $body)) {
        if ($text) { [void]$xml.Append('<text>' + (ConvertTo-XmlText $text) + '</text>') }
    }
    foreach ($block in @($blocks)) {
        if ($null -eq $block -or -not ($block.Heading -or $block.Lines.Count -or $block.Caption)) { continue }
        [void]$xml.Append('<group><subgroup>')
        if ($block.Heading) {
            [void]$xml.Append('<text hint-style="base" hint-wrap="true">' + (ConvertTo-XmlText $block.Heading) + '</text>')
        }
        foreach ($line in $block.Lines) {
            [void]$xml.Append('<text hint-style="body" hint-wrap="true">' + (ConvertTo-XmlText $line) + '</text>')
        }
        if ($block.Caption) {
            [void]$xml.Append('<text hint-style="captionSubtle" hint-wrap="true">' + (ConvertTo-XmlText $block.Caption) + '</text>')
        }
        [void]$xml.Append('</subgroup></group>')
    }
    if ($attribution) {
        [void]$xml.Append('<text placement="attribution">' + (ConvertTo-XmlText $attribution) + '</text>')
    }
    [void]$xml.Append('</binding></visual>')
    return $xml.ToString()
}

# All toasts of one chat share a group, so they can be cleared together when you reply.
function Get-SessionGroup([string]$safeId) { return ('ct-' + $safeId.Substring(0, [Math]::Min(60, $safeId.Length))) }

function Initialize-WinRT {
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
}

function Send-ToastXml([string]$xml, [string]$tag, [string]$group, $data) {
    Initialize-WinRT
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($xml)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($doc)
    $toast.Group = $group
    if ($tag) { $toast.Tag = $tag }
    if ($data) { $toast.Data = $data }
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:AppId).Show($toast)
}

function Remove-Toast([string]$tag, [string]$group) {
    try { Initialize-WinRT; [Windows.UI.Notifications.ToastNotificationManager]::History.Remove($tag, $group, $script:AppId) } catch { }
}

# Removes every toast of a chat; returns how many there were.
function Remove-SessionToasts([string]$group) {
    Initialize-WinRT
    $history = [Windows.UI.Notifications.ToastNotificationManager]::History
    $count = @($history.GetHistory($script:AppId) | Where-Object { $_.Group -eq $group }).Count
    if ($count -gt 0) { $history.RemoveGroup($group, $script:AppId) }
    return $count
}

function Get-ActionUri([string]$action, $ctx, [int]$q, [int]$o) {
    $uri = 'claude-toast:{0}?s={1}&t={2}&q={3}' -f $action, $ctx.SafeId, $ctx.Token, $q
    if ($o -ge 0) { $uri += "&o=$o" }
    return $uri
}

function Get-ButtonXml([string]$content, [string]$uri, [bool]$keepOpen) {
    # keepOpen: ask Windows to leave the toast on screen after the click (multi-select ticks).
    $stay = if ($keepOpen) { ' afterActivationBehavior="pendingUpdate"' } else { '' }
    return '<action content="' + (ConvertTo-XmlText $content) + '" activationType="protocol"' + $stay + ' arguments="' + (ConvertTo-XmlText $uri) + '"/>'
}

function Get-DismissButtonXml { return '<action activationType="system" arguments="dismiss" content="Dismiss"/>' }

# scenario="reminder": the toast stays on screen until you click it or one of its buttons.
# $launch: what clicking the toast body does (bring the chat's terminal tab to the front).
function Show-ActionToast($ctx, [string]$body, $blocks, [string]$attribution, [string[]]$buttons, [string]$kind, [string]$tag, [bool]$quiet, $data, [string]$logText, [string]$launch) {
    $audio = if ($quiet) { '<audio silent="true"/>' } else { Get-AudioXml $kind }
    $open = '<toast scenario="reminder"'
    if ($launch) { $open += ' activationType="protocol" launch="' + (ConvertTo-XmlText $launch) + '"' }
    $xml = $open + '>' + (Get-VisualXml $ctx.ChatName $body $blocks $attribution) +
           '<actions>' + ($buttons -join '') + '</actions>' + $audio + '</toast>'
    Send-ToastXml $xml $tag $ctx.Group $data
    if (-not $logText) { $logText = Get-BlockText $blocks ' ~ ' ' ~~ ' }
    $labels = foreach ($button in $buttons) {
        if ($button -match 'content="([^"]*)"') { [System.Net.WebUtility]::HtmlDecode($Matches[1]) }
    }
    Write-ActivityLog ('SHOWN | {0} | {1} | {2} | {3} | buttons: {4}' -f $ctx.ChatName, $body, $logText, $attribution, (@($labels) -join ', '))
}

# Informational toast (nothing to answer): "Show terminal" jumps to the chat, "Dismiss" closes it.
function Show-InfoToast($ctx, [string]$body, $blocks, [string]$attribution, [string]$kind, [string]$tag) {
    Write-FocusInfo $ctx
    $focusUri = Get-ActionUri 'focus' $ctx 0 -1
    $buttons = @((Get-ButtonXml 'Show terminal' $focusUri), (Get-DismissButtonXml))
    Show-ActionToast $ctx $body $blocks $attribution $buttons $kind $tag $false $null '' $focusUri
}

# Optional phone push via ntfy (https://ntfy.sh). Off unless config.json says otherwise.
function Send-Ntfy([string]$title, [string]$body, $blocks, [string]$kind) {
    if ((Get-ConfigValue 'ntfy.enabled' $false) -ne $true) { return }
    $topic = [string](Get-ConfigValue 'ntfy.topic' '')
    if (-not $topic) { Write-ErrorLog 'ntfy.enabled is true but ntfy.topic is empty'; return }
    $server = ([string](Get-ConfigValue 'ntfy.server' 'https://ntfy.sh')).TrimEnd('/')
    $tags = @{ question = 'question'; permission = 'lock'; ready = 'white_check_mark' }
    $message = [ordered]@{
        topic    = $topic
        title    = $title
        message  = (@($body, (Get-BlockText $blocks "`n" "`n`n")) | Where-Object { $_ }) -join "`n"
        priority = $(if ($kind -eq 'ready') { 3 } else { 4 })
        tags     = @($tags[$kind])
    }
    $headers = @{}
    $token = [string](Get-ConfigValue 'ntfy.token' '')
    if ($token) { $headers['Authorization'] = "Bearer $token" }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $bytes = $script:Utf8.GetBytes((ConvertTo-Json $message -Compress))
    $null = Invoke-RestMethod -Uri $server -Method Post -Body $bytes -Headers $headers `
        -ContentType 'application/json; charset=utf-8' -TimeoutSec 3 -UseBasicParsing
    Write-ActivityLog "NTFY | sent to $server/$topic"
}

function Send-NtfySafe([string]$title, [string]$body, $blocks, [string]$kind) {
    try { Send-Ntfy $title $body $blocks $kind } catch { Write-ErrorLog ('ntfy failed: ' + (Format-ErrorRecord $_)) }
}

# ------------------------------------------------------------------ chat / terminal helpers

function Get-SafeId([string]$id) {
    $safe = $id -replace '[^A-Za-z0-9_-]', '_'
    if (-not $safe) { $safe = 'unknown-session' }
    return $safe
}

function New-ToastContext($payload, [string]$chatName) {
    $safe = Get-SafeId ([string]$payload.session_id)
    return [pscustomobject]@{
        SafeId = $safe; Group = (Get-SessionGroup $safe); Token = [guid]::NewGuid().ToString('N')
        ChatName = $chatName; TerminalPid = 0
        SessionFile = ''; EventsDir = ''; Deadline = [DateTime]::MaxValue; LastMark = [DateTime]::UtcNow
        Shown = (New-Object System.Collections.Generic.List[string])
        Reshow = $null; WasLocked = $false      # scriptblock to pop the current toast up again after unlock
    }
}

function Write-JsonFile([string]$path, $object) {
    if (-not (Test-Path -LiteralPath $script:StateDir)) { $null = New-Item -ItemType Directory -Path $script:StateDir -Force }
    $tmp = "$path.tmp"
    [System.IO.File]::WriteAllText($tmp, (ConvertTo-Json $object -Depth 5 -Compress), $script:Utf8)
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Write-HookOutput($object) {
    $bytes = $script:Utf8.GetBytes((ConvertTo-Json $object -Depth 30 -Compress))
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}

# The window Claude Code runs in: first ancestor process that owns a window (e.g. WindowsTerminal.exe).
function Get-TerminalProcessId {
    try {
        $id = $PID
        for ($i = 0; $i -lt 12; $i++) {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -Property ParentProcessId -ErrorAction Stop
            if (-not $proc -or -not $proc.ParentProcessId) { break }
            $id = [int]$proc.ParentProcessId
            $p = Get-Process -Id $id -ErrorAction SilentlyContinue
            if (-not $p) { break }
            if ($p.MainWindowHandle -ne [IntPtr]::Zero) { return $id }
        }
    } catch { Write-ErrorLog ('terminal lookup failed: ' + (Format-ErrorRecord $_)) }
    return 0
}

# "Show terminal" buttons on informational toasts: state\<session>.focus.json, read by answer.ps1.
# The token stays the same for the chat so older toasts' buttons keep working.
function Write-FocusInfo($ctx) {
    $path = Join-Path $script:StateDir ($ctx.SafeId + '.focus.json')
    try {
        if (Test-Path -LiteralPath $path) {
            $old = [System.IO.File]::ReadAllText($path, $script:Utf8) | ConvertFrom-Json
            if ($old.token -match '^[0-9a-f]{32}$') { $ctx.Token = [string]$old.token }
        }
    } catch { }
    if (-not $ctx.TerminalPid) { $ctx.TerminalPid = Get-TerminalProcessId }
    Write-JsonFile $path ([ordered]@{ token = $ctx.Token; chatName = $ctx.ChatName; terminalPid = $ctx.TerminalPid })
}

# True when you are looking at this chat right now: Windows Terminal is the foreground window and
# its selected tab's title contains the chat name. Then there is no toast and nothing waits.
function Test-WatchingChat([string]$chatName) {
    if ((Get-ConfigValue 'interactive.skipWhenWatching' $true) -ne $true) { return $false }
    if ($env:CLAUDE_TOAST_FAKE_WATCH) { return (Test-Path -LiteralPath $env:CLAUDE_TOAST_FAKE_WATCH) }  # tests only
    $name = ([string]$chatName).TrimEnd([char]0x2026).Trim()
    if (-not $name) { return $false }
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        $A = [System.Windows.Automation.AutomationElement]
        $element = $A::FocusedElement
        if ($null -eq $element) { return $false }
        $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        $root = $A::RootElement
        $window = $element
        for ($i = 0; $i -lt 60; $i++) {
            $parent = $walker.GetParent($window)
            if ($null -eq $parent -or $parent -eq $root) { break }
            $window = $parent
        }
        if ($window.Current.ClassName -ne 'CASCADIA_HOSTING_WINDOW_CLASS') { return $false }
        $isTab = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
        foreach ($tab in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $isTab)) {
            if (([string]$tab.Current.Name).Contains($name)) {
                $selection = $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
                if ($selection.Current.IsSelected) { return $true }
            }
        }
    } catch { }
    return $false
}

# True while the Windows lock screen is up (it has the keyboard focus).
function Test-ScreenLocked {
    if ($env:CLAUDE_TOAST_FAKE_LOCK) { return (Test-Path -LiteralPath $env:CLAUDE_TOAST_FAKE_LOCK) }   # tests only
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        $element = [System.Windows.Automation.AutomationElement]::FocusedElement
        if ($null -eq $element) { return $false }
        $proc = Get-Process -Id $element.Current.ProcessId -ErrorAction SilentlyContinue
        return ($proc -and $proc.ProcessName -eq 'LockApp')
    } catch { return $false }
}

# Last thing Claude said, for the "Response ready" toast.
function Get-LastAssistantText($payload) {
    $text = ''
    if ($payload.last_assistant_message -is [string]) { $text = $payload.last_assistant_message }
    if (-not $text) {
        try {
            $path = [string]$payload.transcript_path
            if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                $share  = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
                $stream = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
                try {
                    $take = [Math]::Min($stream.Length, 512KB)
                    $null = $stream.Seek(-$take, [System.IO.SeekOrigin]::End)
                    $buffer = New-Object byte[] $take
                    $read = $stream.Read($buffer, 0, $take)
                    $lines = $script:Utf8.GetString($buffer, 0, $read) -split "`n"
                } finally { $stream.Dispose() }
                for ($i = $lines.Count - 1; $i -ge 0 -and -not $text; $i--) {
                    if (-not $lines[$i].Contains('"type":"assistant"')) { continue }
                    $entry = ConvertFrom-JsonSafe $lines[$i]
                    if (-not $entry -or $entry.type -ne 'assistant' -or $entry.isSidechain -eq $true) { continue }
                    $text = Get-PromptText $entry.message
                }
            }
        } catch { Write-ErrorLog ('last message read failed: ' + (Format-ErrorRecord $_)) }
    }
    $text = [regex]::Replace([string]$text, '[`*#>_]+', '')
    return (Limit-Text (Format-OneLine $text) 200)
}

# ------------------------------------------------------------------ waiting for a click
# Toast buttons open claude-toast:<action>?s=<session>&t=<token>&q=<question>&o=<option> links.
# install.ps1 registers that link type (per user, HKCU) to run answer.ps1 via "conhost --headless"
# (no window). answer.ps1 drops one event file per click into state\<session>.events\, and the
# waiting hook picks them up here.

function Test-InteractiveAvailable {
    if ((Get-ConfigValue 'interactive.enabled' $true) -ne $true) { return $false }
    return (Test-Path -LiteralPath 'HKCU:\Software\Classes\claude-toast\shell\open\command')
}

function Start-ToastWait($payload, [string]$chatName) {
    $ctx = New-ToastContext $payload $chatName
    if (-not (Test-Path -LiteralPath $script:StateDir)) { $null = New-Item -ItemType Directory -Path $script:StateDir -Force }
    $ctx.SessionFile = Join-Path $script:StateDir ($ctx.SafeId + '.session.json')
    $ctx.EventsDir   = Join-Path $script:StateDir ($ctx.SafeId + '.events')
    if (Test-Path -LiteralPath $ctx.EventsDir) { Remove-Item -LiteralPath $ctx.EventsDir -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $ctx.EventsDir -Force
    $ctx.Deadline = [DateTime]::UtcNow.AddSeconds([double](Get-ConfigValue 'interactive.timeoutSeconds' 300))
    Write-JsonFile $ctx.SessionFile ([ordered]@{ token = $ctx.Token; chatName = $chatName; terminalPid = 0 })
    return $ctx
}

# Called once the first toast is up (the lookup takes a moment).
function Update-WaitTerminal($ctx) {
    $ctx.TerminalPid = Get-TerminalProcessId
    Write-JsonFile $ctx.SessionFile ([ordered]@{ token = $ctx.Token; chatName = $ctx.ChatName; terminalPid = $ctx.TerminalPid })
}

# Oldest unread click, or $null. Clicks are handled one at a time, in order.
function Read-NextClick([string]$eventsDir) {
    $file = Get-ChildItem -LiteralPath $eventsDir -Filter '*.evt' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1
    if (-not $file) { return $null }
    $text = ''
    try { $text = [System.IO.File]::ReadAllText($file.FullName, $script:Utf8).Trim() } catch { return $null }  # still being written
    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
    $parts = $text.Split('|')
    if ($parts.Count -lt 4) { return [pscustomobject]@{ Action = 'invalid'; Token = ''; Q = -1; O = -1 } }
    $q = -1; $o = -1
    [void][int]::TryParse($parts[2], [ref]$q)
    [void][int]::TryParse($parts[3], [ref]$o)
    return [pscustomobject]@{ Action = $parts[0]; Token = $parts[1]; Q = $q; O = $o }
}

# Next valid click on toast number $qi, or $null when the wait times out.
function Wait-NextClick($ctx, [int]$qi) {
    $lastLook = [DateTime]::UtcNow
    while ($true) {
        if ([DateTime]::UtcNow -gt $ctx.Deadline) { return $null }
        $click = Read-NextClick $ctx.EventsDir
        if ($null -eq $click) {
            Start-Sleep -Milliseconds 150
            if (([DateTime]::UtcNow - $ctx.LastMark).TotalSeconds -ge 5) {
                Set-QuestionMarker $ctx.SafeId      # keep Claude Code's generic notification quiet while we wait
                $ctx.LastMark = [DateTime]::UtcNow
            }
            if (([DateTime]::UtcNow - $lastLook).TotalSeconds -ge 1.5) {
                $lastLook = [DateTime]::UtcNow
                # Toasts never pop up on the lock screen: show it again once you unlock.
                $locked = Test-ScreenLocked
                if ($ctx.WasLocked -and -not $locked -and $ctx.Reshow) {
                    Write-ActivityLog 'RESHOWN | screen unlocked - showing the waiting toast again'
                    & $ctx.Reshow
                }
                $ctx.WasLocked = $locked
                # You came back to this chat's terminal tab (e.g. the toast was hidden): answer there instead.
                if (-not $locked -and (Test-WatchingChat $ctx.ChatName)) {
                    Write-ActivityLog 'MOVED | you switched to this chat - handing the prompt to the terminal'
                    return [pscustomobject]@{ Action = 'terminal'; Token = $ctx.Token; Q = $qi; O = -1 }
                }
            }
            continue
        }
        if ($click.Token -ne $ctx.Token) { continue }     # stale toast / forged link
        if ($click.Q -ne $qi) { continue }                # click on an older toast
        return $click
    }
}

function Stop-ToastWait($ctx, [string]$outcome, [string]$detail) {
    foreach ($tag in $ctx.Shown) { Remove-Toast $tag $ctx.Group }
    Remove-Item -LiteralPath $ctx.EventsDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ctx.SessionFile -Force -ErrorAction SilentlyContinue
    # Answered / sent to terminal: the terminal shows it now, no extra notification needed.
    # Timed out: you're away, so let Claude Code's own notification raise a (persistent) toast.
    if ($outcome -ne 'timeout') { Set-QuestionMarker $ctx.SafeId }
    else { Remove-Item -LiteralPath (Get-MarkerPath $ctx.SafeId) -Force -ErrorAction SilentlyContinue }
    Write-ActivityLog ('RESULT | {0} | {1}' -f $outcome, $detail)
}

# ------------------------------------------------------------------ questions (PreToolUse: AskUserQuestion)

function Get-OptionLabels($question) {
    $labels = foreach ($option in @($question.options)) {
        if ($null -eq $option) { continue }
        $label = if ($option -is [string]) { $option } else { [string]$option.label }
        if ($label) { $label }
    }
    return @($labels)
}

# Toasts allow 5 buttons: single choice needs 1 per option, multiple choice also needs Done.
function Test-QuestionsFitButtons($questions) {
    foreach ($q in $questions) {
        $n = @(Get-OptionLabels $q).Count
        $max = if ($q.multiSelect -eq $true) { 4 } else { 5 }
        if ($n -lt 1 -or $n -gt $max) { return $false }
    }
    return $true
}

# All questions as text blocks - for the phone push and the notify-only fallback toast.
function Get-QuestionSummary($questions) {
    $blocks = for ($i = 0; $i -lt $questions.Count; $i++) {
        $q = $questions[$i]
        $n = 0
        $lines = foreach ($label in (Get-OptionLabels $q)) { $n++; '{0}. {1}' -f $n, (Limit-Text (Format-OneLine $label) 90) }
        $heading = if ($i -eq 0) { '' } else { 'Q{0}: {1}' -f ($i + 1), (Limit-Text (Format-OneLine ([string]$q.question)) 160) }
        $caption = if ($q.multiSelect -eq $true) { '(multi-select)' } else { '' }
        New-Block $heading @($lines) $caption
    }
    $body = Limit-Text (Format-OneLine ([string]$questions[0].question)) 220
    if (-not $body) { $body = 'Claude has a question for you' }
    return [pscustomobject]@{ Body = $body; Blocks = @($blocks) }
}

function Get-QuestionTag($ctx, [int]$qi) { return ('q{0}-{1}' -f $qi, $ctx.Token.Substring(0, 12)) }

# Option lines + caption for a question in its current state (☐/☑ ticks for multi-select).
function Get-QuestionLines($questions, [int]$qi, $selected, [string]$note) {
    $q      = $questions[$qi]
    $multi  = ($q.multiSelect -eq $true)
    $labels = @(Get-OptionLabels $q)
    $lines = for ($i = 0; $i -lt $labels.Count; $i++) {
        $label = Limit-Text (Format-OneLine $labels[$i]) 90
        if ($multi) { '{0} {1}. {2}' -f $(if ($selected.Contains($i)) { [char]0x2611 } else { [char]0x2610 }), ($i + 1), $label }
        else        { '{0}. {1}' -f ($i + 1), $label }
    }
    $caption = if ($note) { $note } elseif ($multi) { '(multi-select) - tick the boxes, then Done - or Terminal' } else { 'Pick a number - or Terminal to answer there' }
    if ($multi -and -not $note -and $selected.Count -gt 0) {
        # Windows closes the toast on every click and it is shown again, so say clearly what is ticked.
        $picked = @($selected | ForEach-Object { Limit-Text (Format-OneLine $labels[$_]) 30 }) -join ', '
        $caption = "Selected: $picked - tick more, then Done"
        # 4 options: the Terminal button has turned into Done, but clicking the toast text still works.
        if ($labels.Count -ge 4) { $caption += ' (click here for Terminal)' }
    }
    return [pscustomobject]@{ Lines = @($lines); Caption = $caption }
}

# One toast per question: question text, options listed in full, a numbered button per option.
function Show-QuestionToast($ctx, $questions, [int]$qi, $selected, [bool]$quiet, [string]$note) {
    $q      = $questions[$qi]
    $multi  = ($q.multiSelect -eq $true)
    $labels = @(Get-OptionLabels $q)
    $state  = Get-QuestionLines $questions $qi $selected $note

    $body = Limit-Text (Format-OneLine ([string]$q.question)) 220
    if (-not $body) { $body = 'Claude has a question for you' }
    $header = Format-OneLine ([string]$q.header)
    $attribution = $header
    if ($questions.Count -gt 1) {
        $attribution = 'Question {0} of {1}' -f ($qi + 1), $questions.Count
        if ($header) { $attribution += " - $header" }
    }

    # Buttons sit in one row (~6 characters each), so they carry just the option number
    # (multi-select: a checkbox + number, "☐ 1" / "☑ 1"); the full option text is listed above them.
    $terminalUri = Get-ActionUri 'terminal' $ctx $qi -1     # also what clicking the toast body does
    $buttons = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $labels.Count; $i++) {
        if ($multi) {
            $box = if ($selected.Contains($i)) { [char]0x2611 } else { [char]0x2610 }
            # Ask Windows to keep the toast open; it closes it anyway, and it is re-drawn after each tick.
            $buttons.Add((Get-ButtonXml ('{0} {1}' -f $box, ($i + 1)) (Get-ActionUri 'toggle' $ctx $qi $i) $true))
        } else {
            $buttons.Add((Get-ButtonXml ([string]($i + 1)) (Get-ActionUri 'pick' $ctx $qi $i) $false))
        }
    }
    # Max 5 buttons. With 4 multi-select options the 5th slot is Terminal until something is ticked, then Done.
    $doneButton     = Get-ButtonXml 'Done' (Get-ActionUri 'submit' $ctx $qi -1) $false
    $terminalButton = Get-ButtonXml 'Terminal' $terminalUri $false
    if ($multi -and ($buttons.Count -le 3 -or $selected.Count -gt 0)) { $buttons.Add($doneButton) }
    if ($buttons.Count -lt 5) { $buttons.Add($terminalButton) }

    $tag     = Get-QuestionTag $ctx $qi
    $logText = (@($state.Lines) + $state.Caption) -join ' ~ '
    Show-ActionToast $ctx $body @(New-Block '' $state.Lines $state.Caption) $attribution $buttons.ToArray() 'question' $tag $quiet $null $logText $terminalUri
}

# Shows the questions one after another and waits for clicks.
# Returns an ordered map {question text -> answer}, or $null to fall back to the terminal.
function Wait-ForToastAnswers($payload, $questions, [string]$chatName, $summary) {
    $ctx = Start-ToastWait $payload $chatName
    $answers = [ordered]@{}
    $outcome = 'timeout'
    try {
        for ($qi = 0; $qi -lt $questions.Count; $qi++) {
            $q        = $questions[$qi]
            $labels   = @(Get-OptionLabels $q)
            $selected = New-Object 'System.Collections.Generic.SortedSet[int]'
            Show-QuestionToast $ctx $questions $qi $selected $false ''
            $ctx.Shown.Add((Get-QuestionTag $ctx $qi))
            # Runs inside Wait-NextClick; PowerShell's dynamic scoping sees this loop's current variables.
            $ctx.Reshow = { Show-QuestionToast $ctx $questions $qi $selected $false '' }
            if ($qi -eq 0) {
                Send-NtfySafe $chatName $summary.Body $summary.Blocks 'question'
                Update-WaitTerminal $ctx
            }
            $answered = $false
            while (-not $answered) {
                $click = Wait-NextClick $ctx $qi
                if ($null -eq $click) { $outcome = 'timeout'; return $null }
                if ($click.Action -eq 'terminal') { $outcome = 'terminal'; return $null }
                $validOption = ($click.O -ge 0 -and $click.O -lt $labels.Count)
                switch ($click.Action) {
                    'pick' {
                        if ($validOption) { $answers[[string]$q.question] = $labels[$click.O]; $answered = $true }
                    }
                    'toggle' {
                        if ($validOption) {
                            if (-not $selected.Remove($click.O)) { [void]$selected.Add($click.O) }
                            # Same tag: replaces the toast (Windows closes it on the click anyway), silently.
                            Show-QuestionToast $ctx $questions $qi $selected $true ''
                        }
                    }
                    'submit' {
                        if ($selected.Count -gt 0) {
                            $answers[[string]$q.question] = (@($selected | ForEach-Object { $labels[$_] }) -join ', ')
                            $answered = $true
                        } else {
                            Show-QuestionToast $ctx $questions $qi $selected $true 'Tick at least one box, then Done'
                        }
                    }
                }
            }
            Remove-Toast (Get-QuestionTag $ctx $qi) $ctx.Group   # answered: off screen before the next one
        }
        $outcome = 'answered'
        return $answers
    } finally {
        $detail = if ($outcome -eq 'answered') { ($answers.Keys | ForEach-Object { "$_ = $($answers[$_])" }) -join ' ; ' } else { '' }
        Stop-ToastWait $ctx $outcome $detail
    }
}

function Invoke-QuestionEvent($payload) {
    # Mark first, so Claude Code's generic "needs your permission" ping is de-duplicated.
    Set-QuestionMarker ([string]$payload.session_id)
    $questions = @(@($payload.tool_input.questions) | Where-Object { $null -ne $_ })
    if ($questions.Count -eq 0) { return }
    $chatName = Get-ChatName $payload
    if (Test-WatchingChat $chatName) { Write-ActivityLog 'SKIPPED | you are looking at this chat - answer in the terminal'; return }
    $summary = Get-QuestionSummary $questions

    if ((Test-InteractiveAvailable) -and (Test-QuestionsFitButtons $questions)) {
        $answers = Wait-ForToastAnswers $payload $questions $chatName $summary
        if ($answers) {
            # Documented contract: "allow" + updatedInput = original input + answers{question text: label}.
            $toolInput = $payload.tool_input
            $toolInput | Add-Member -NotePropertyName 'answers' -NotePropertyValue ([pscustomobject]$answers) -Force
            Write-HookOutput ([pscustomobject]@{
                hookSpecificOutput = [pscustomobject]@{
                    hookEventName      = 'PreToolUse'
                    permissionDecision = 'allow'
                    updatedInput       = $toolInput
                }
            })
        }
        return   # no answers -> print nothing -> Claude Code shows its normal terminal question
    }

    # Notify-only: every question in one toast, stays until dismissed.
    $ctx = New-ToastContext $payload $chatName
    $attribution = Format-OneLine ([string]$questions[0].header)
    if ($questions.Count -gt 1) { $attribution = ('{0} questions' -f $questions.Count) }
    Show-InfoToast $ctx $summary.Body $summary.Blocks $attribution 'question' 'question'
    Send-NtfySafe $chatName $summary.Body $summary.Blocks 'question'
}

# ------------------------------------------------------------------ permissions (PermissionRequest)

function Get-PermissionDescription($payload) {
    $tool = [string]$payload.tool_name
    $in   = $payload.tool_input
    $verb = "Allow $tool?"; $lines = @(); $caption = ''
    switch -Regex ($tool) {
        '^Bash$'                        { $verb = 'Run this command?';  $lines = @([string]$in.command); $caption = [string]$in.description }
        '^PowerShell$'                  { $verb = 'Run this PowerShell command?'; $lines = @([string]$in.command); $caption = [string]$in.description }
        '^(Edit|MultiEdit|NotebookEdit)$' { $verb = 'Edit this file?';  $lines = @([string]$(if ($in.file_path) { $in.file_path } else { $in.notebook_path })) }
        '^Write$'                       { $verb = 'Write this file?';   $lines = @([string]$in.file_path) }
        '^Read$'                        { $verb = 'Read this file?';    $lines = @([string]$in.file_path) }
        '^WebFetch$'                    { $verb = 'Fetch this page?';   $lines = @([string]$in.url) }
        '^WebSearch$'                   { $verb = 'Search the web?';    $lines = @([string]$in.query) }
        default {
            $json = ''
            try { $json = ConvertTo-Json $in -Depth 4 -Compress } catch { }
            $lines = @($json)
        }
    }
    $lines = @($lines | ForEach-Object { Limit-Text (Format-OneLine $_) 300 } | Where-Object { $_ })
    return [pscustomobject]@{ Tool = $tool; Verb = $verb; Lines = $lines; Caption = (Limit-Text (Format-OneLine $caption) 120) }
}

function Invoke-PermissionEvent($payload) {
    $tool = [string]$payload.tool_name
    # These two need special answers; the question hook / the terminal handle them.
    if ($tool -eq 'AskUserQuestion' -or $tool -eq 'ExitPlanMode') { return }
    if (-not (Test-InteractiveAvailable)) { return }   # the Notification hook shows a notify-only toast
    $chatName = Get-ChatName $payload
    if (Test-WatchingChat $chatName) { Write-ActivityLog "SKIPPED | you are looking at this chat - $tool permission in the terminal"; return }

    Set-QuestionMarker ([string]$payload.session_id)
    $what  = Get-PermissionDescription $payload
    $ctx   = Start-ToastWait $payload $chatName
    $tag   = 'p-' + $ctx.Token.Substring(0, 12)
    $outcome = 'timeout'
    try {
        $blocks  = @(New-Block '' $what.Lines $what.Caption)
        $buttons = @(
            (Get-ButtonXml 'Allow'    (Get-ActionUri 'allow' $ctx 0 -1)),
            (Get-ButtonXml 'Deny'     (Get-ActionUri 'deny' $ctx 0 -1)),
            (Get-ButtonXml 'Terminal' (Get-ActionUri 'terminal' $ctx 0 -1))
        )
        Show-ActionToast $ctx $what.Verb $blocks "Permission needed - $tool" $buttons 'permission' $tag $false $null '' (Get-ActionUri 'terminal' $ctx 0 -1)
        $ctx.Shown.Add($tag)
        $ctx.Reshow = { Show-ActionToast $ctx $what.Verb $blocks "Permission needed - $tool" $buttons 'permission' $tag $false $null '' (Get-ActionUri 'terminal' $ctx 0 -1) }
        Send-NtfySafe $chatName $what.Verb $blocks 'permission'
        Update-WaitTerminal $ctx

        while ($true) {
            $click = Wait-NextClick $ctx 0
            if ($null -eq $click) { $outcome = 'timeout'; return }
            switch ($click.Action) {
                'allow' {
                    $outcome = 'allowed'
                    Write-HookOutput ([pscustomobject]@{ hookSpecificOutput = [pscustomobject]@{
                        hookEventName = 'PermissionRequest'; decision = [pscustomobject]@{ behavior = 'allow' } } })
                    return
                }
                'deny' {
                    $outcome = 'denied'
                    Write-HookOutput ([pscustomobject]@{ hookSpecificOutput = [pscustomobject]@{
                        hookEventName = 'PermissionRequest'
                        decision = [pscustomobject]@{ behavior = 'deny'; message = 'The user denied this from the claude-toast notification.' } } })
                    return
                }
                'terminal' { $outcome = 'terminal'; return }
            }
        }
    } finally {
        Stop-ToastWait $ctx $outcome ("$tool | " + ($what.Lines -join ' '))
    }
}

# ------------------------------------------------------------------ notifications, replies, turns

function Invoke-NotificationEvent($payload) {
    $sessionId = [string]$payload.session_id
    $message   = Format-OneLine ([string]$payload.message)
    $type      = [string]$payload.notification_type

    # "Claude is waiting for your input" reminders are replaced by one "Response ready" toast per reply.
    if ($type -eq 'idle_prompt') { Write-ActivityLog ('SKIPPED | idle reminder (one "Response ready" toast per reply instead) | ' + $message); return }

    $window = [double](Get-ConfigValue 'dedupeSeconds' 60)
    $age = Get-QuestionMarkerAge $sessionId
    if ($null -ne $age -and $age -ge 0 -and $age -lt $window) {
        Write-ActivityLog ('SKIPPED | toast for this request shown {0:N1}s ago | {1}' -f $age, $message)
        return
    }
    if ($message -match 'AskUserQuestion') {
        Write-ActivityLog ('SKIPPED | AskUserQuestion permission (question hook covers it) | ' + $message)
        return
    }

    $chatName = Get-ChatName $payload
    if (Test-WatchingChat $chatName) { Write-ActivityLog "SKIPPED | you are looking at this chat | $message"; return }
    if (-not $message) { $message = 'Claude needs your attention' }
    $attribution = if ($type -eq 'permission_prompt') { 'Permission needed - answer in the terminal' } else { 'Claude Code' }
    $ctx = New-ToastContext $payload $chatName
    Show-InfoToast $ctx (Limit-Text $message 160) @() $attribution 'permission' 'notice'
    Send-NtfySafe $chatName (Limit-Text $message 160) @() 'permission'
}

# Stop: Claude finished its reply. One toast per reply (it replaces the previous one of this chat).
function Invoke-StopEvent($payload) {
    if ($payload.stop_hook_active -eq $true) { return }
    $chatName = Get-ChatName $payload
    if (Test-WatchingChat $chatName) { Write-ActivityLog 'SKIPPED | you are looking at this chat - no "Response ready" toast'; return }
    $snippet = Get-LastAssistantText $payload
    $blocks  = if ($snippet) { @(New-Block '' @($snippet) '') } else { @() }
    $ctx = New-ToastContext $payload $chatName
    Show-InfoToast $ctx 'Claude finished - response ready' $blocks 'Response ready' 'ready' 'ready'
    Send-NtfySafe $chatName 'Claude finished - response ready' $blocks 'ready'
}

# UserPromptSubmit: you replied in this chat, so its toasts are out of date.
function Invoke-PromptEvent($payload) {
    $safe = Get-SafeId ([string]$payload.session_id)
    $removed = Remove-SessionToasts (Get-SessionGroup $safe)
    Write-ActivityLog ('CLEARED | {0} toast(s) of this chat removed (you replied)' -f $removed)
}

# ------------------------------------------------------------------ plugin setup (SessionStart)

# Marker: claude-toast is ALSO installed by hand (install.ps1 hooks in settings.json).
# Then the plugin stays quiet, so you never get every toast twice.
function Get-ManualInstallMarker { return (Join-Path $script:DataDir 'manual-install-detected') }

function Invoke-SetupEvent {
    if (-not $script:PluginMode) { return }
    if (-not (Test-Path -LiteralPath $script:DataDir)) { $null = New-Item -ItemType Directory -Path $script:DataDir -Force }

    # Your own config.json, kept across plugin updates; starts as a copy of the defaults.
    $userConfig = Join-Path $script:DataDir 'config.json'
    if (-not (Test-Path -LiteralPath $userConfig)) {
        Copy-Item -LiteralPath (Join-Path $script:Root 'config.json') -Destination $userConfig
        Write-ActivityLog "CONFIG | created $userConfig"
    }

    . (Join-Path $script:Root 'lib\settings.ps1')
    $marker = Get-ManualInstallMarker
    if (Test-ClaudeToastInstalled (Read-ClaudeSettings (Get-ClaudeSettingsPath))) {
        # The manual install owns the click handler; don't point it at the plugin.
        [System.IO.File]::WriteAllText($marker, 'claude-toast hooks found in settings.json - the plugin stays quiet. Run uninstall.ps1 to use the plugin.', $script:Utf8)
        Write-ErrorLog 'claude-toast is also installed by hand (settings.json); the plugin stays quiet - run uninstall.ps1 to use the plugin instead'
        return
    }
    Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue

    # Point claude-toast: links at this plugin version's answer.ps1 (the path changes on updates).
    if (Register-ClaudeToastProtocol (Join-Path $script:Root 'answer.ps1') $script:DataDir) {
        Write-ActivityLog "SETUP | link handler -> $($script:Root)"
    }
}

function Invoke-Main {
    $script:Config  = Read-Config
    $script:DebugOn = ($env:CLAUDE_TOAST_DEBUG -eq '1') -or ((Get-ConfigValue 'debug' $false) -eq $true)

    if ($Event -eq 'setup') { Invoke-SetupEvent; return }
    if ($script:PluginMode -and (Test-Path -LiteralPath (Get-ManualInstallMarker))) { return }

    $payload = Read-Payload
    if ($null -eq $payload) { Write-ErrorLog 'no JSON payload on stdin'; return }

    switch ($Event.ToLowerInvariant()) {
        'question'     { Invoke-QuestionEvent $payload }
        'permission'   { Invoke-PermissionEvent $payload }
        'notification' { Invoke-NotificationEvent $payload }
        'stop'         { Invoke-StopEvent $payload }
        'prompt'       { Invoke-PromptEvent $payload }
        default        { Write-ErrorLog "unknown -Event '$Event'" }
    }
}

try {
    $null = & { Invoke-Main } *>&1
} catch {
    Write-ErrorLog (Format-ErrorRecord $_)
}
exit 0
