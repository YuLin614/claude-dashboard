# Claude Code Session Dashboard — Design Spec

**Date:** 2026-06-11  
**Status:** Approved

## Problem

Running multiple Claude Code sessions in parallel PowerShell windows makes it hard to track:
- Which window is working on which ticket
- Whether a session is running autonomously or waiting for user input
- Where to click to bring the right window to the front

## Solution

A browser-based dashboard (`localhost:3333`) showing live status of all active Claude Code sessions, with one-click window focus and quick-launch for new sessions in configured repos and worktrees.

---

## Architecture

```
start.ps1  (one command after reboot)
    ├── docker compose up -d      → web server (port 3333)
    └── Start-Job agent.ps1       → host agent (port 3334)

Browser: localhost:3333
    ├── data / SSE  ──→  Docker container (Python FastAPI)
    │                         ↑ volume mount
    │                    ~/.claude/sessions/*.json
    │                         ↑ written by
    │                    Claude Code Hooks
    │
    └── OS actions  ──→  Host PS Agent (agent.ps1)
                              ├── SetForegroundWindow (focus window)
                              ├── Start-Process (launch new Claude session)
                              └── git worktree list (worktree discovery)
```

---

## File Structure

```
C:\claude-dashboard\
├── docker-compose.yml
├── start.ps1                   ← single startup command after reboot
├── config.json                 ← all paths configured here, nothing hardcoded
├── server\
│   ├── Dockerfile
│   ├── main.py                 ← FastAPI + SSE + static file server
│   └── static\
│       └── index.html          ← dashboard UI (vanilla JS)
├── host-agent\
│   └── agent.ps1               ← tiny PS HTTP listener for OS actions
└── docs\
    └── superpowers\
        └── specs\
            └── 2026-06-11-claude-session-dashboard-design.md
```

---

## Configuration (`config.json`)

All paths and ports live here. No hardcoded values elsewhere.

```json
{
  "repos": [
    { "name": "dems",    "path": "c:/dems-project/dems" },
    { "name": "dems-ui", "path": "c:/dems-project/dems-ui" }
  ],
  "ports": {
    "server": 3333,
    "agent":  3334
  },
  "sessionsDir": "C:/Users/YuchenLin/.claude/sessions"
}
```

---

## Session State (`~/.claude/sessions/<sessionId>.json`)

Written and updated by Claude Code hooks.

```json
{
  "sessionId": "abc123",
  "pid": 12345,
  "cwd": "c:/dems-project/dems-ui",
  "branch": "feat/DMS-414-redaction",
  "ticket": "DMS-414",
  "status": "waiting",
  "currentTool": "Edit",
  "currentTarget": "src/components/Redaction.tsx",
  "lastActivity": "2026-06-11T10:30:00Z",
  "recentActivity": [
    { "tool": "Read", "target": "src/hooks/useRedaction.ts", "time": "..." },
    { "tool": "Edit", "target": "src/components/Canvas.tsx",  "time": "..." }
  ]
}
```

### Hook → State Transitions

| Hook | Action |
|------|--------|
| `SessionStart` | Create file: pid, cwd, branch, status=`starting` |
| `PreToolUse` | status=`running`, currentTool, currentTarget |
| `PostToolUse` | Append to recentActivity (keep last 10) |
| `Stop` | status=`waiting` |

Hooks are configured in `~/.claude/settings.json` (global, applies to all sessions).  
Hook commands are PowerShell; they write JSON to `sessionsDir` using `$env:CLAUDE_SESSION_ID` and `$env:CLAUDE_CWD` (or equivalent env vars provided by Claude Code).

---

## Components

### 1. Docker Container — Web Server

- **Language:** Python 3.12, FastAPI
- **Endpoints:**
  - `GET /` — serves `index.html`
  - `GET /events` — SSE stream, watches `sessionsDir` for file changes, pushes updates
  - `GET /sessions` — returns all current session JSON objects
  - `GET /config` — returns `config.json` contents (repos, ports)
- **Volume mounts:**
  - `~/.claude/sessions` → `/sessions` (read-only)
  - `./config.json` → `/config.json` (read-only)
- **Does NOT perform any host OS operations** (no window management, no process spawning)

### 2. Host PS Agent (`agent.ps1`)

Minimal PowerShell HTTP listener. Runs as a background job started by `start.ps1`.

- **Endpoints:**
  - `POST /focus` body `{pid: 12345}` → `SetForegroundWindow` via Win32 API
  - `POST /launch` body `{path: "c:/...", label: "dems-ui worktree/DMS-414"}` → `Start-Process powershell` with `cd` + `claude`
  - `GET /worktrees?repo=<path>` → `git worktree list --porcelain` (fallback if Docker can't reach git)
- Reads port and repo paths from `config.json`

### 3. Dashboard UI (`index.html`)

Single-file vanilla JS (no build step, no framework dependency).

**Session Cards panel:**
- One card per active session
- Shows: ticket name (parsed from branch — regex `[A-Z]+-\d+`), project name (from CWD), status badge
- Status badge: 🟢 `running` / 🟡 `waiting` (waiting cards highlighted with border)
- Current tool + file path
- Expandable recent activity list (last 10 tool calls)
- Click anywhere on card → `POST localhost:3334/focus` with session PID
- Sessions not updated in >5 min shown as 🔴 `stale`

**Quick Launch panel:**
- One button per configured repo (from `config.json`)
- Each repo has a worktree dropdown (populated from `GET /worktrees`)
- Default option: repo root
- Worktree options populated from `GET localhost:3334/worktrees` (PS agent, has host git access)
- Launch button → `POST localhost:3334/launch`

**Auto-refresh:**
- SSE connection to `localhost:3333/events`
- Reconnects automatically on disconnect (exponential backoff, max 10s)

---

## Startup

```powershell
# C:\claude-dashboard\start.ps1
$scriptDir = $PSScriptRoot
docker compose -f "$scriptDir\docker-compose.yml" up -d
Start-Job -Name "claude-dashboard-agent" -FilePath "$scriptDir\host-agent\agent.ps1" -ArgumentList $scriptDir
Start-Process msedge "http://localhost:3333"
Write-Host "Claude Dashboard started. http://localhost:3333"
```

After reboot: double-click `start.ps1` or run it in any PowerShell window. No other steps.

Optional: add a `.bat` wrapper or desktop shortcut pointing to `start.ps1`.

---

## Hook Installation

Add to `~/.claude/settings.json` hooks section (merged with existing hooks):

```json
"PreToolUse": [{
  "hooks": [{
    "type": "command",
    "command": "<powershell snippet that writes session JSON>",
    "shell": "powershell"
  }]
}]
```

Implementation plan will include the exact hook scripts.

---

## Out of Scope (v1)

- Background agent task tracking
- Claude text output capture (hooks can only see tool calls)
- Authentication / multi-user
- Session history persistence beyond current run
