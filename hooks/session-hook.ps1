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
        # Walk process tree to find the PowerShell/WindowsTerminal window PID
        $consolePid = 0
        try {
            $cur = $PID
            for ($i = 0; $i -lt 8; $i++) {
                $p = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -Property Name,ParentProcessId -ErrorAction Stop
                if ($p.Name -in @('powershell.exe','pwsh.exe','WindowsTerminal.exe','cmd.exe')) {
                    $consolePid = $cur; break
                }
                $cur = $p.ParentProcessId
                if ($cur -le 4) { break }
            }
        } catch {}

        $branch = ""
        $ticket = ""
        try {
            $branch = (& git branch --show-current 2>$null) -join "" -replace "\s",""
            if ($branch -match '([A-Z]+-\d+)') { $ticket = $Matches[1] }
        } catch {}

        $session = [ordered]@{
            sessionId      = $sessionId
            consolePid     = $consolePid
            hwnd           = 0
            cwd            = if ($data.cwd) { $data.cwd } else { $PWD.Path }
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
