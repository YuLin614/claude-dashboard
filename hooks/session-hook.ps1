# session-hook.ps1
# Called from ~/.claude/settings.json hooks.
# Reads JSON from stdin, updates ~/.claude/sessions/<sessionId>.json.
# Never throws — Claude must not be blocked by hook errors.

param()

$ErrorActionPreference = "SilentlyContinue"

try {
    # Read stdin from Claude Code (external process pipe — $input won't work here)
    $raw = [Console]::In.ReadToEnd()
    if (-not $raw.Trim()) { exit 0 }
    $data = $raw | ConvertFrom-Json
    $sessionId = $data.session_id
    if (-not $sessionId) { exit 0 }

    $sessionsDir = "$env:USERPROFILE\.claude\sessions"
    if (-not (Test-Path $sessionsDir)) {
        New-Item -ItemType Directory -Force $sessionsDir | Out-Null
    }
    $sessionFile = Join-Path $sessionsDir "$sessionId.json"

    # Determine hook type from data shape
    $hookEvent = $data.hook_event_name

    if ($hookEvent -eq "SessionStart" -or (-not (Test-Path $sessionFile))) {
        # Get console window handle for later focus
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class ConWin {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
}
'@ -ErrorAction SilentlyContinue

        $hwnd = 0
        try { $hwnd = [ConWin]::GetConsoleWindow().ToInt64() } catch {}

        $branch = ""
        $ticket = ""
        try {
            $branch = (& git branch --show-current 2>$null) -join "" -replace "\s",""
            if ($branch -match '([A-Z]+-\d+)') { $ticket = $Matches[1] }
        } catch {}

        $session = [ordered]@{
            sessionId      = $sessionId
            hwnd           = $hwnd
            cwd            = $PWD.Path
            branch         = $branch
            ticket         = $ticket
            status         = "starting"
            currentTool    = $null
            currentTarget  = $null
            lastActivity   = (Get-Date -Format "o")
            recentActivity = @()
        }
        $session | ConvertTo-Json -Depth 5 | Set-Content $sessionFile -Encoding utf8
        exit 0
    }

    # Load existing session
    $session = Get-Content $sessionFile -Raw | ConvertFrom-Json

    if ($data.tool_name) {
        # PreToolUse or PostToolUse
        $toolName   = $data.tool_name
        $toolInput  = $data.tool_input

        # Extract a human-readable target string
        $target = switch ($toolName) {
            "Read"    { $toolInput.file_path }
            "Edit"    { $toolInput.file_path }
            "Write"   { $toolInput.file_path }
            "Glob"    { $toolInput.pattern }
            "Grep"    { "$($toolInput.pattern) in $($toolInput.path)" }
            "Bash"    { ($toolInput.command -replace "`n"," ").Substring(0, [Math]::Min(60, "$($toolInput.command)".Length)) }
            "PowerShell" { ($toolInput.command -replace "`n"," ").Substring(0, [Math]::Min(60, "$($toolInput.command)".Length)) }
            "Agent"   { $toolInput.description }
            default   { "" }
        }

        $session.status       = "running"
        $session.currentTool  = $toolName
        $session.currentTarget = $target
        $session.lastActivity = (Get-Date -Format "o")

        # PostToolUse: append to recentActivity (keep last 10)
        # Detect by tool_response field (present in PostToolUse) or explicit hook_event_name
        $isPost = $data.tool_response -ne $null -or $hookEvent -eq "PostToolUse"
        if ($isPost) {
            $entry = [ordered]@{
                tool   = $toolName
                target = $target
                time   = (Get-Date -Format "o")
            }
            $activity = @($session.recentActivity) + @($entry)
            if ($activity.Count -gt 10) { $activity = $activity[-10..-1] }
            $session.recentActivity = $activity
        }
    } else {
        # Stop event — Claude is waiting for user input
        $session.status       = "waiting"
        $session.currentTool  = $null
        $session.currentTarget = $null
        $session.lastActivity = (Get-Date -Format "o")
    }

    $session | ConvertTo-Json -Depth 5 | Set-Content $sessionFile -Encoding utf8

} catch {
    # Never let hook errors surface to Claude
    exit 0
}
exit 0
