<#
.SYNOPSIS
  claude-toast click handler. Windows runs this when you click a button on a claude-toast toast.

.DESCRIPTION
  Registered by install.ps1 as the handler for claude-toast: links (per user, HKCU), started via
  "conhost.exe --headless" so no window appears:
      claude-toast:<action>?s=<session>&t=<token>&q=<question>&o=<option>
      actions: pick | toggle | submit (questions), allow | deny (permissions),
               terminal (send to the terminal), focus ("Show terminal" on info toasts)

  It only records the click (one small file in state\<session>.events\) for the waiting
  notify.ps1 hook, which does the rest. Links are checked strictly: the session must be waiting
  and the 128-bit token must match, so stale toasts and links from anywhere else are ignored.
  "terminal" and "focus" also bring the existing terminal window/tab running that chat to the
  front (they never open a new one).
#>
# -DataDir: set by the plugin's link handler (its data folder); empty for a manual install.
param([string]$Uri, [string]$DataDir)

$ErrorActionPreference = 'Stop'
$script:DataDir  = if ($DataDir) { $DataDir.TrimEnd('\', '/') } else { $PSScriptRoot }
$script:StateDir = Join-Path $script:DataDir 'state'
$script:LogDir   = Join-Path $script:DataDir 'logs'
$script:Utf8     = New-Object System.Text.UTF8Encoding($false)

function Write-Log([string]$file, [string]$message) {
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) { $null = New-Item -ItemType Directory -Path $script:LogDir -Force }
        if ($message.Length -gt 600) { $message = $message.Substring(0, 600) + '...' }
        $line = '{0} [answer] {1}{2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $message, [Environment]::NewLine
        [System.IO.File]::AppendAllText((Join-Path $script:LogDir $file), $line, $script:Utf8)
    } catch { }
}

function Get-DebugOn {
    if ($env:CLAUDE_TOAST_DEBUG -eq '1') { return $true }
    try {
        $cfgPath = Join-Path $script:DataDir 'config.json'
        if (-not (Test-Path -LiteralPath $cfgPath)) { $cfgPath = Join-Path $PSScriptRoot 'config.json' }
        $cfg = [System.IO.File]::ReadAllText($cfgPath, $script:Utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json
        return ($cfg.debug -eq $true)
    } catch { return $false }
}

# Bring the terminal running this chat to the front: the Windows Terminal tab whose title
# contains the chat name if there is one, otherwise the terminal window the hook recorded.
function Show-Terminal($session) {
    Add-Type -Namespace ClaudeToast -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
'@
    $hwnd = [IntPtr]::Zero
    $name = ([string]$session.chatName).TrimEnd([char]0x2026).Trim()
    if ($name) {
        try {
            Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
            $A = [System.Windows.Automation.AutomationElement]
            $isWt = New-Object System.Windows.Automation.PropertyCondition($A::ClassNameProperty, 'CASCADIA_HOSTING_WINDOW_CLASS')
            $isTab = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::TabItem)
            foreach ($window in $A::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $isWt)) {
                foreach ($tab in $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $isTab)) {
                    if (([string]$tab.Current.Name).Contains($name)) {
                        $selection = $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
                        if (-not $selection.Current.IsSelected) { $selection.Select() }   # switch tabs only if needed
                        $hwnd = [IntPtr]$window.Current.NativeWindowHandle
                        break
                    }
                }
                if ($hwnd -ne [IntPtr]::Zero) { break }
            }
        } catch { Write-Log 'error.log' ('terminal tab lookup failed: ' + $_.Exception.Message) }
    }
    if ($hwnd -eq [IntPtr]::Zero -and [int]$session.terminalPid -gt 0) {
        $proc = Get-Process -Id ([int]$session.terminalPid) -ErrorAction SilentlyContinue
        if ($proc) { $hwnd = $proc.MainWindowHandle }
    }
    if ($hwnd -eq [IntPtr]::Zero) { return 'no terminal window found' }
    if ([ClaudeToast.Win32]::IsIconic($hwnd)) { [void][ClaudeToast.Win32]::ShowWindow($hwnd, 9) }   # SW_RESTORE
    $foreground = [ClaudeToast.Win32]::SetForegroundWindow($hwnd)

    # Put the keyboard focus in the terminal itself (not on the tab header), so arrow keys and
    # typing go to Claude Code's prompt. Windows Terminal's terminal area is a "TermControl".
    $typing = 'n/a'
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        $A = [System.Windows.Automation.AutomationElement]
        $window = $A::FromHandle($hwnd)
        if ($window.Current.ClassName -eq 'CASCADIA_HOSTING_WINDOW_CLASS') {
            $isTerm = New-Object System.Windows.Automation.PropertyCondition($A::ClassNameProperty, 'TermControl')
            $term = $null
            for ($i = 0; $i -lt 10 -and -not $term; $i++) {
                Start-Sleep -Milliseconds 100          # give a tab switch a moment to finish
                $term = @($window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $isTerm)) |
                    Where-Object { -not $_.Current.IsOffscreen } | Select-Object -First 1
            }
            if ($term) { $term.SetFocus(); $typing = 'terminal focused' } else { $typing = 'terminal area not found' }
        }
    } catch { $typing = 'focus failed: ' + $_.Exception.Message }
    return ('SetForegroundWindow={0}, {1}' -f $foreground, $typing)
}

try {
    if ($Uri -notmatch '^claude-toast:(pick|toggle|submit|terminal|allow|deny|focus)\?([A-Za-z0-9_&=-]+)/?$') { throw "ignored unexpected link: $Uri" }
    $action = $Matches[1]
    $params = @{}
    foreach ($pair in $Matches[2].Split('&')) {
        $kv = $pair.Split('=', 2)
        if ($kv.Count -eq 2) { $params[$kv[0]] = $kv[1] }
    }
    $sid = [string]$params['s']; $token = [string]$params['t']; $q = [string]$params['q']; $o = [string]$params['o']
    if ($sid -notmatch '^[A-Za-z0-9_-]{1,100}$' -or $token -notmatch '^[0-9a-f]{32}$' -or
        $q -notmatch '^\d{1,2}$' -or ($o -and $o -notmatch '^\d{1,2}$')) { throw "ignored malformed link: $Uri" }
    if (-not $o) { $o = '-1' }

    # "Show terminal" on informational toasts: nothing is waiting, just bring the chat forward.
    if ($action -eq 'focus') {
        $focusFile = Join-Path $script:StateDir "$sid.focus.json"
        $focus = $null
        if (Test-Path -LiteralPath $focusFile) { $focus = [System.IO.File]::ReadAllText($focusFile, $script:Utf8) | ConvertFrom-Json }
        if (-not $focus -or $focus.token -ne $token) {
            if (Get-DebugOn) { Write-Log 'activity.log' "STALE | unknown focus link for session $sid" }
            exit 0
        }
        $result = Show-Terminal $focus
        if (Get-DebugOn) { Write-Log 'activity.log' "TERMINAL | $result (Show terminal)" }
        exit 0
    }

    $sessionFile = Join-Path $script:StateDir "$sid.session.json"
    $eventsDir   = Join-Path $script:StateDir "$sid.events"
    if (-not (Test-Path -LiteralPath $sessionFile) -or -not (Test-Path -LiteralPath $eventsDir)) {
        if (Get-DebugOn) { Write-Log 'activity.log' "STALE | no question is waiting for session $sid | $action" }
        exit 0
    }
    $session = [System.IO.File]::ReadAllText($sessionFile, $script:Utf8) | ConvertFrom-Json
    if ($session.token -ne $token) {
        if (Get-DebugOn) { Write-Log 'activity.log' "STALE | token mismatch for session $sid | $action" }
        exit 0
    }

    $name = '{0:D20}-{1}.evt' -f [DateTime]::UtcNow.Ticks, ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $tmp  = Join-Path $eventsDir ($name + '.tmp')
    try {
        [System.IO.File]::WriteAllText($tmp, "$action|$token|$q|$o", $script:Utf8)
        Move-Item -LiteralPath $tmp -Destination (Join-Path $eventsDir $name) -Force
    } catch {
        # The hook finished (answered / timed out) between our check and the write.
        if (-not (Test-Path -LiteralPath $eventsDir)) {
            if (Get-DebugOn) { Write-Log 'activity.log' "STALE | question for session $sid closed while clicking | $action" }
            exit 0
        }
        throw
    }
    if (Get-DebugOn) { Write-Log 'activity.log' "CLICK | $action q=$q o=$o | session $sid" }

    if ($action -eq 'terminal') {
        $result = Show-Terminal $session
        if (Get-DebugOn) { Write-Log 'activity.log' "TERMINAL | $result" }
    }
} catch {
    Write-Log 'error.log' ('{0}: {1}' -f $_.Exception.GetType().Name, $_.Exception.Message)
}
exit 0
