# Claude Code Session Dashboard — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a browser dashboard at `localhost:3333` showing live status of all active Claude Code sessions, with click-to-focus window and quick-launch for new sessions.

**Architecture:** Claude Code hooks write session JSON to `~/.claude/sessions/`; a FastAPI server in Docker reads those files and streams updates via SSE; a PowerShell host agent handles OS actions (window focus, process launch, worktree listing); vanilla JS dashboard connects to both.

**Tech Stack:** Python 3.12, FastAPI, uvicorn, Docker, PowerShell 5.1, vanilla HTML/JS/CSS

---

## File Map

```
C:\claude-dashboard\
├── .gitignore
├── .env                          ← docker-compose volume paths
├── config.json                   ← repos, ports, sessionsDir
├── docker-compose.yml
├── start.ps1                     ← single startup command
├── stop.ps1
├── hooks\
│   └── session-hook.ps1          ← shared hook logic called by all hook events
├── host-agent\
│   └── agent.ps1                 ← HTTP listener: focus, launch, worktrees
└── server\
    ├── Dockerfile
    ├── requirements.txt
    ├── main.py                   ← FastAPI app: SSE, sessions, config, static
    ├── session_reader.py         ← reads/parses ~/.claude/sessions/*.json
    ├── static\
    │   └── index.html            ← dashboard UI
    └── tests\
        ├── conftest.py
        ├── test_session_reader.py
        └── test_main.py
```

---

## Task 1: Scaffolding — config, .gitignore, .env, sessions dir

**Files:**
- Create: `C:\claude-dashboard\.gitignore`
- Create: `C:\claude-dashboard\config.json`
- Create: `C:\claude-dashboard\.env`

- [ ] **Step 1: Write .gitignore**

```
__pycache__/
*.pyc
.pytest_cache/
server/tests/__pycache__/
.env.local
```

- [ ] **Step 2: Write config.json**

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

- [ ] **Step 3: Write .env** (docker-compose reads this for volume paths)

```
SESSIONS_DIR=C:/Users/YuchenLin/.claude/sessions
SERVER_PORT=3333
```

- [ ] **Step 4: Create sessions directory**

```powershell
New-Item -ItemType Directory -Force "C:\Users\YuchenLin\.claude\sessions"
```

Expected output: directory path printed (or no error if already exists).

- [ ] **Step 5: Commit**

```bash
git add .gitignore config.json .env
git commit -m "chore: project scaffolding and config"
```

---

## Task 2: Hook script

Writes/updates session JSON on every Claude Code hook event. Called by all hook entries in `~/.claude/settings.json`.

**Files:**
- Create: `C:\claude-dashboard\hooks\session-hook.ps1`

- [ ] **Step 1: Write session-hook.ps1**

```powershell
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
```

- [ ] **Step 2: Commit**

```bash
git add hooks/session-hook.ps1
git commit -m "feat: add session hook script"
```

---

## Task 3: Install hooks into ~/.claude/settings.json

Adds four hooks (SessionStart, PreToolUse, PostToolUse, Stop) to the global Claude Code settings. Merges with existing hooks — does NOT replace them.

**Files:**
- Modify: `C:\Users\YuchenLin\.claude\settings.json`

- [ ] **Step 1: Read current settings.json**

Open `C:\Users\YuchenLin\.claude\settings.json`. Find the `"hooks"` key.

- [ ] **Step 2: Add hook entries**

The hook command calls the script, passing stdin through. Add these four entries to their respective hook arrays (create the arrays if they don't exist). Merge carefully — do not remove existing hook entries.

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell -ExecutionPolicy Bypass -File \"C:\\claude-dashboard\\hooks\\session-hook.ps1\"",
            "shell": "powershell"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell -ExecutionPolicy Bypass -File \"C:\\claude-dashboard\\hooks\\session-hook.ps1\"",
            "shell": "powershell"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell -ExecutionPolicy Bypass -File \"C:\\claude-dashboard\\hooks\\session-hook.ps1\"",
            "shell": "powershell"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell -ExecutionPolicy Bypass -File \"C:\\claude-dashboard\\hooks\\session-hook.ps1\"",
            "shell": "powershell"
          }
        ]
      }
    ]
  }
}
```

Note: `PostToolUse` may already have an existing entry (the "commit reminder" hook). If so, append the new hook object to that array's `hooks` sub-array, not as a new top-level entry.

- [ ] **Step 3: Smoke test the hook**

Start a fresh Claude Code session in any directory. Check:

```powershell
Get-ChildItem "C:\Users\YuchenLin\.claude\sessions\"
```

Expected: a `.json` file appears within a few seconds of Claude starting up.

```powershell
Get-Content "C:\Users\YuchenLin\.claude\sessions\*.json" | ConvertFrom-Json | Format-List
```

Expected: JSON with `sessionId`, `cwd`, `status`, `hwnd` fields populated.

---

## Task 4: Python session reader module + tests

Reads and parses session JSON files. Pure function, no I/O side effects beyond file reads — easy to test.

**Files:**
- Create: `C:\claude-dashboard\server\session_reader.py`
- Create: `C:\claude-dashboard\server\tests\conftest.py`
- Create: `C:\claude-dashboard\server\tests\test_session_reader.py`

- [ ] **Step 1: Write failing tests first**

`server/tests/conftest.py`:
```python
import pytest
import json
import os
from pathlib import Path


@pytest.fixture
def sessions_dir(tmp_path):
    return tmp_path


@pytest.fixture
def write_session(sessions_dir):
    def _write(session_id: str, data: dict):
        path = sessions_dir / f"{session_id}.json"
        path.write_text(json.dumps(data))
        return path
    return _write
```

`server/tests/test_session_reader.py`:
```python
import pytest
from datetime import datetime, timezone, timedelta
from session_reader import read_all, parse_ticket, is_stale


def test_read_all_empty_dir(sessions_dir):
    assert read_all(str(sessions_dir)) == []


def test_read_all_returns_sessions(sessions_dir, write_session):
    write_session("abc", {
        "sessionId": "abc",
        "cwd": "c:/dems-project/dems-ui",
        "branch": "feat/DMS-414-redaction",
        "ticket": "DMS-414",
        "status": "waiting",
        "currentTool": None,
        "currentTarget": None,
        "lastActivity": datetime.now(timezone.utc).isoformat(),
        "recentActivity": [],
        "hwnd": 12345,
    })
    result = read_all(str(sessions_dir))
    assert len(result) == 1
    assert result[0]["sessionId"] == "abc"
    assert result[0]["ticket"] == "DMS-414"


def test_read_all_skips_corrupt_files(sessions_dir, tmp_path):
    bad = sessions_dir / "bad.json"
    bad.write_text("not valid json {{{")
    result = read_all(str(sessions_dir))
    assert result == []


def test_read_all_adds_stale_flag(sessions_dir, write_session):
    old_time = (datetime.now(timezone.utc) - timedelta(minutes=6)).isoformat()
    write_session("old", {
        "sessionId": "old",
        "status": "running",
        "lastActivity": old_time,
        "recentActivity": [],
    })
    result = read_all(str(sessions_dir))
    assert result[0]["stale"] is True


def test_read_all_not_stale_when_recent(sessions_dir, write_session):
    write_session("new", {
        "sessionId": "new",
        "status": "waiting",
        "lastActivity": datetime.now(timezone.utc).isoformat(),
        "recentActivity": [],
    })
    result = read_all(str(sessions_dir))
    assert result[0].get("stale") is not True


def test_parse_ticket_from_branch():
    assert parse_ticket("feat/DMS-414-some-title") == "DMS-414"
    assert parse_ticket("bugfix/ABC-1234-fix") == "ABC-1234"
    assert parse_ticket("main") == ""
    assert parse_ticket("") == ""


def test_is_stale_after_5_minutes():
    old = (datetime.now(timezone.utc) - timedelta(minutes=6)).isoformat()
    assert is_stale(old) is True


def test_is_stale_within_5_minutes():
    recent = datetime.now(timezone.utc).isoformat()
    assert is_stale(recent) is False
```

- [ ] **Step 2: Run tests — expect all FAIL**

```bash
cd C:\claude-dashboard\server
pip install pytest
python -m pytest tests/test_session_reader.py -v
```

Expected: `ImportError: No module named 'session_reader'` or similar failures.

- [ ] **Step 3: Write session_reader.py**

`server/session_reader.py`:
```python
import json
import re
from pathlib import Path
from datetime import datetime, timezone, timedelta

STALE_MINUTES = 5


def parse_ticket(branch: str) -> str:
    m = re.search(r'([A-Z]+-\d+)', branch or "")
    return m.group(1) if m else ""


def is_stale(last_activity: str) -> bool:
    try:
        dt = datetime.fromisoformat(last_activity.replace("Z", "+00:00"))
        return (datetime.now(timezone.utc) - dt) > timedelta(minutes=STALE_MINUTES)
    except Exception:
        return False


def read_all(sessions_dir: str) -> list[dict]:
    path = Path(sessions_dir)
    if not path.exists():
        return []

    sessions = []
    for f in path.glob("*.json"):
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
            data["stale"] = is_stale(data.get("lastActivity", ""))
            # Backfill ticket if missing
            if not data.get("ticket") and data.get("branch"):
                data["ticket"] = parse_ticket(data["branch"])
            sessions.append(data)
        except Exception:
            continue

    sessions.sort(key=lambda s: s.get("lastActivity", ""), reverse=True)
    return sessions
```

- [ ] **Step 4: Run tests — expect all PASS**

```bash
python -m pytest tests/test_session_reader.py -v
```

Expected: all 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add server/session_reader.py server/tests/
git commit -m "feat: add session reader module with tests"
```

---

## Task 5: FastAPI server + requirements

Serves sessions data as SSE stream, config endpoint, and static files.

**Files:**
- Create: `C:\claude-dashboard\server\requirements.txt`
- Create: `C:\claude-dashboard\server\main.py`
- Create: `C:\claude-dashboard\server\tests\test_main.py`

- [ ] **Step 1: Write requirements.txt**

```
fastapi==0.115.0
uvicorn[standard]==0.30.6
aiofiles==24.1.0
```

- [ ] **Step 2: Write failing tests**

`server/tests/test_main.py`:
```python
import pytest
import json
from pathlib import Path
from fastapi.testclient import TestClient


@pytest.fixture
def client(sessions_dir, monkeypatch, tmp_path):
    # Write a minimal config
    config = {
        "repos": [{"name": "dems-ui", "path": "c:/dems-project/dems-ui"}],
        "ports": {"server": 3333, "agent": 3334},
        "sessionsDir": str(sessions_dir),
    }
    config_path = tmp_path / "config.json"
    config_path.write_text(json.dumps(config))
    monkeypatch.setenv("CONFIG_PATH", str(config_path))

    from main import app
    return TestClient(app)


def test_get_sessions_empty(client):
    resp = client.get("/sessions")
    assert resp.status_code == 200
    assert resp.json() == []


def test_get_sessions_returns_data(client, write_session):
    from datetime import datetime, timezone
    write_session("s1", {
        "sessionId": "s1",
        "status": "waiting",
        "lastActivity": datetime.now(timezone.utc).isoformat(),
        "recentActivity": [],
        "branch": "feat/DMS-414",
        "ticket": "DMS-414",
    })
    resp = client.get("/sessions")
    assert resp.status_code == 200
    data = resp.json()
    assert len(data) == 1
    assert data[0]["sessionId"] == "s1"


def test_get_config(client):
    resp = client.get("/config")
    assert resp.status_code == 200
    data = resp.json()
    assert "repos" in data
    assert data["repos"][0]["name"] == "dems-ui"


def test_get_index(client):
    resp = client.get("/")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
```

- [ ] **Step 3: Run tests — expect FAIL**

```bash
pip install fastapi uvicorn aiofiles httpx pytest-asyncio
python -m pytest tests/test_main.py -v
```

Expected: `ImportError` or module errors.

- [ ] **Step 4: Write main.py**

`server/main.py`:
```python
import json
import asyncio
import os
from pathlib import Path
from fastapi import FastAPI
from fastapi.responses import StreamingResponse, HTMLResponse, FileResponse
from fastapi.staticfiles import StaticFiles
import session_reader

CONFIG_PATH = os.environ.get("CONFIG_PATH", "/config.json")

app = FastAPI()

_config: dict = {}

def load_config() -> dict:
    global _config
    try:
        _config = json.loads(Path(CONFIG_PATH).read_text(encoding="utf-8"))
    except Exception:
        _config = {"repos": [], "ports": {"server": 3333, "agent": 3334}, "sessionsDir": "/sessions"}
    return _config


@app.on_event("startup")
async def startup():
    load_config()


def get_sessions_dir() -> str:
    cfg = load_config()
    return cfg.get("sessionsDir", "/sessions")


@app.get("/sessions")
def get_sessions():
    return session_reader.read_all(get_sessions_dir())


@app.get("/config")
def get_config():
    return load_config()


@app.get("/events")
async def events():
    async def stream():
        while True:
            sessions = session_reader.read_all(get_sessions_dir())
            yield f"data: {json.dumps(sessions)}\n\n"
            await asyncio.sleep(1)

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )


STATIC_DIR = Path(__file__).parent / "static"

@app.get("/")
def index():
    html_path = STATIC_DIR / "index.html"
    if html_path.exists():
        return FileResponse(str(html_path), media_type="text/html")
    return HTMLResponse("<h1>Dashboard</h1><p>index.html missing</p>")
```

- [ ] **Step 5: Run tests — expect PASS**

```bash
python -m pytest tests/test_main.py -v
```

Expected: all 4 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add server/main.py server/requirements.txt server/tests/test_main.py
git commit -m "feat: add FastAPI server with SSE and session endpoints"
```

---

## Task 6: Docker setup

**Files:**
- Create: `C:\claude-dashboard\server\Dockerfile`
- Create: `C:\claude-dashboard\docker-compose.yml`

- [ ] **Step 1: Write Dockerfile**

`server/Dockerfile`:
```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "3333"]
```

- [ ] **Step 2: Write docker-compose.yml**

`docker-compose.yml`:
```yaml
services:
  dashboard:
    build: ./server
    ports:
      - "${SERVER_PORT:-3333}:3333"
    volumes:
      - "${SESSIONS_DIR}:/sessions:ro"
      - "./config.json:/config.json:ro"
    environment:
      - CONFIG_PATH=/config.json
    restart: unless-stopped
```

- [ ] **Step 3: Build and run**

```powershell
cd C:\claude-dashboard
docker compose up --build -d
```

Expected: container starts with no errors.

- [ ] **Step 4: Verify server responds**

```powershell
Invoke-WebRequest "http://localhost:3333/sessions" -UseBasicParsing | Select-Object -ExpandProperty Content
```

Expected: `[]` (empty array, or array of existing sessions).

- [ ] **Step 5: Verify SSE endpoint**

```powershell
$req = [System.Net.WebRequest]::Create("http://localhost:3333/events")
$req.Accept = "text/event-stream"
$stream = $req.GetResponse().GetResponseStream()
$reader = [System.IO.StreamReader]::new($stream)
$line = $reader.ReadLine(); $line
$reader.Close()
```

Expected: a line starting with `data: [`.

- [ ] **Step 6: Stop container, commit**

```powershell
docker compose down
```

```bash
git add server/Dockerfile docker-compose.yml
git commit -m "feat: add Docker setup for dashboard server"
```

---

## Task 7: Host PowerShell agent

Thin HTTP listener on port 3334. Handles OS-level actions Docker can't do: focus window, launch Claude, list worktrees.

**Files:**
- Create: `C:\claude-dashboard\host-agent\agent.ps1`

- [ ] **Step 1: Write agent.ps1**

`host-agent/agent.ps1`:
```powershell
param([string]$ScriptDir = $PSScriptRoot)

$ErrorActionPreference = "Stop"

# Load config
$configPath = Join-Path $ScriptDir "..\config.json"
$config = Get-Content $configPath -Raw | ConvertFrom-Json
$port = $config.ports.agent

# Win32 API for window focus
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class WinUser {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
}
'@

function Send-Response {
    param($context, [int]$status, $body)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 5))
    $context.Response.StatusCode = $status
    $context.Response.ContentType = "application/json"
    $context.Response.Headers.Add("Access-Control-Allow-Origin", "*")
    $context.Response.ContentLength64 = $bytes.Length
    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $context.Response.OutputStream.Close()
}

function Get-Worktrees {
    param([string]$repoPath)
    try {
        $raw = & git -C $repoPath worktree list --porcelain 2>&1
        $worktrees = @()
        $cur = $null
        foreach ($line in $raw) {
            if ($line -match '^worktree (.+)$') {
                if ($cur) { $worktrees += $cur }
                $cur = @{ path = $Matches[1]; branch = ""; head = "" }
            } elseif ($line -match '^branch refs/heads/(.+)$') {
                if ($cur) { $cur.branch = $Matches[1] }
            } elseif ($line -match '^HEAD ([a-f0-9]+)$') {
                if ($cur) { $cur.head = $Matches[1].Substring(0, [Math]::Min(8, $Matches[1].Length)) }
            }
        }
        if ($cur) { $worktrees += $cur }
        return $worktrees
    } catch {
        return @()
    }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:${port}/")
$listener.Start()
Write-Host "Agent listening on http://localhost:${port}/"

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $req  = $context.Request
        $path = $req.Url.AbsolutePath
        $method = $req.HttpMethod

        # Handle CORS preflight
        if ($method -eq "OPTIONS") {
            $context.Response.Headers.Add("Access-Control-Allow-Origin", "*")
            $context.Response.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            $context.Response.Headers.Add("Access-Control-Allow-Headers", "Content-Type")
            $context.Response.StatusCode = 204
            $context.Response.OutputStream.Close()
            continue
        }

        try {
            if ($path -eq "/focus" -and $method -eq "POST") {
                $body = [System.IO.StreamReader]::new($req.InputStream).ReadToEnd() | ConvertFrom-Json
                $hwnd = [IntPtr]$body.hwnd
                if ([WinUser]::IsWindow($hwnd)) {
                    [WinUser]::ShowWindow($hwnd, 9) | Out-Null  # SW_RESTORE
                    [WinUser]::SetForegroundWindow($hwnd) | Out-Null
                    Send-Response $context 200 @{ ok = $true }
                } else {
                    Send-Response $context 404 @{ ok = $false; error = "window handle invalid" }
                }
            }
            elseif ($path -eq "/launch" -and $method -eq "POST") {
                $body = [System.IO.StreamReader]::new($req.InputStream).ReadToEnd() | ConvertFrom-Json
                $launchPath = $body.path
                $label = $body.label
                if (-not (Test-Path $launchPath)) {
                    Send-Response $context 400 @{ ok = $false; error = "path not found: $launchPath" }
                } else {
                    Start-Process powershell.exe -ArgumentList @(
                        "-NoExit",
                        "-Command",
                        "Set-Location '$launchPath'; Write-Host 'Starting Claude — $label'; claude"
                    )
                    Send-Response $context 200 @{ ok = $true; path = $launchPath }
                }
            }
            elseif ($path -eq "/worktrees" -and $method -eq "GET") {
                $repoParam = $req.QueryString["repo"]
                if (-not $repoParam) {
                    # Return worktrees for all configured repos
                    $result = @{}
                    foreach ($repo in $config.repos) {
                        $result[$repo.name] = Get-Worktrees $repo.path
                    }
                    Send-Response $context 200 $result
                } else {
                    Send-Response $context 200 (Get-Worktrees $repoParam)
                }
            }
            elseif ($path -eq "/health" -and $method -eq "GET") {
                Send-Response $context 200 @{ ok = $true; port = $port }
            }
            else {
                Send-Response $context 404 @{ error = "not found" }
            }
        } catch {
            try { Send-Response $context 500 @{ error = $_.Exception.Message } } catch {}
        }
    }
} finally {
    $listener.Stop()
}
```

- [ ] **Step 2: Test agent manually**

Open a new PowerShell window and run:

```powershell
Start-Job -Name "test-agent" -FilePath "C:\claude-dashboard\host-agent\agent.ps1" -ArgumentList "C:\claude-dashboard"
Start-Sleep 2
Invoke-WebRequest "http://localhost:3334/health" -UseBasicParsing | Select-Object -ExpandProperty Content
```

Expected: `{"ok":true,"port":3334}`

- [ ] **Step 3: Test worktrees endpoint**

```powershell
Invoke-WebRequest "http://localhost:3334/worktrees" -UseBasicParsing | Select-Object -ExpandProperty Content
```

Expected: JSON object with `dems` and `dems-ui` keys, each containing worktree arrays.

- [ ] **Step 4: Stop test agent, commit**

```powershell
Stop-Job "test-agent"; Remove-Job "test-agent"
```

```bash
git add host-agent/agent.ps1
git commit -m "feat: add host PS agent for window focus, launch, worktrees"
```

---

## Task 8: Dashboard UI

Single HTML file, no build step. Connects to both server (SSE) and agent (actions).

**Files:**
- Create: `C:\claude-dashboard\server\static\index.html`

- [ ] **Step 1: Write index.html**

`server/static/index.html`:
```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Claude Dashboard</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
         background: #0d1117; color: #e6edf3; min-height: 100vh; }
  header { padding: 16px 24px; border-bottom: 1px solid #30363d;
           display: flex; align-items: center; gap: 12px; }
  header h1 { font-size: 16px; font-weight: 600; color: #58a6ff; }
  #conn-status { font-size: 12px; color: #8b949e; margin-left: auto; }
  .layout { display: grid; grid-template-columns: 1fr 300px; gap: 0;
            height: calc(100vh - 53px); }
  #sessions { padding: 20px; overflow-y: auto; }
  #sessions h2 { font-size: 13px; font-weight: 600; color: #8b949e;
                 text-transform: uppercase; letter-spacing: .5px; margin-bottom: 12px; }
  .session-card { background: #161b22; border: 1px solid #30363d; border-radius: 8px;
                  padding: 14px 16px; margin-bottom: 10px; cursor: pointer;
                  transition: border-color .15s, box-shadow .15s; }
  .session-card:hover { border-color: #58a6ff; box-shadow: 0 0 0 1px #58a6ff22; }
  .session-card.waiting { border-color: #d29922; box-shadow: 0 0 0 1px #d2992222; }
  .session-card.stale { opacity: .5; }
  .card-header { display: flex; align-items: center; gap: 8px; margin-bottom: 8px; }
  .ticket { font-weight: 700; font-size: 14px; color: #58a6ff; }
  .project { font-size: 12px; color: #8b949e; }
  .badge { font-size: 11px; font-weight: 600; padding: 2px 8px; border-radius: 12px;
           margin-left: auto; }
  .badge.running { background: #1f6feb33; color: #58a6ff; }
  .badge.waiting { background: #9e6a0333; color: #d29922; animation: pulse 2s infinite; }
  .badge.starting { background: #30363d; color: #8b949e; }
  .badge.stale { background: #30363d; color: #6e7681; }
  @keyframes pulse { 0%,100% { opacity:1 } 50% { opacity:.6 } }
  .current-tool { font-size: 12px; color: #8b949e; margin-bottom: 6px; }
  .current-tool span { color: #e6edf3; font-family: 'Consolas','Monaco',monospace; }
  .branch { font-size: 11px; color: #6e7681; font-family: 'Consolas','Monaco',monospace; }
  details { margin-top: 8px; }
  summary { font-size: 11px; color: #6e7681; cursor: pointer; user-select: none; }
  .activity-list { margin-top: 6px; }
  .activity-item { font-size: 11px; font-family: 'Consolas','Monaco',monospace;
                   color: #8b949e; padding: 2px 0; display: flex; gap: 8px; }
  .activity-item .tool-name { color: #79c0ff; min-width: 60px; }
  .activity-item .target { color: #8b949e; overflow: hidden; text-overflow: ellipsis;
                           white-space: nowrap; max-width: 260px; }
  #launch-panel { border-left: 1px solid #30363d; padding: 20px; overflow-y: auto; }
  #launch-panel h2 { font-size: 13px; font-weight: 600; color: #8b949e;
                     text-transform: uppercase; letter-spacing: .5px; margin-bottom: 16px; }
  .repo-section { margin-bottom: 20px; }
  .repo-section h3 { font-size: 13px; font-weight: 600; margin-bottom: 8px; }
  .repo-btn { width: 100%; padding: 8px 12px; background: #21262d; border: 1px solid #30363d;
              border-radius: 6px; color: #e6edf3; font-size: 13px; cursor: pointer;
              text-align: left; margin-bottom: 6px; transition: background .15s; }
  .repo-btn:hover { background: #30363d; }
  select { width: 100%; padding: 7px 10px; background: #21262d; border: 1px solid #30363d;
           border-radius: 6px; color: #e6edf3; font-size: 12px; margin-bottom: 6px;
           cursor: pointer; }
  .launch-btn { width: 100%; padding: 8px 12px; background: #1f6feb; border: none;
                border-radius: 6px; color: #fff; font-size: 13px; font-weight: 600;
                cursor: pointer; transition: background .15s; }
  .launch-btn:hover { background: #388bfd; }
  #status-bar { position: fixed; bottom: 0; left: 0; right: 0; padding: 4px 16px;
                background: #161b22; border-top: 1px solid #30363d;
                font-size: 11px; color: #8b949e; }
</style>
</head>
<body>

<header>
  <h1>Claude Dashboard</h1>
  <span id="conn-status">connecting…</span>
</header>

<div class="layout">
  <div id="sessions">
    <h2>Active Sessions</h2>
    <div id="session-list"><p style="color:#6e7681;font-size:13px">Waiting for sessions…</p></div>
  </div>

  <div id="launch-panel">
    <h2>Launch</h2>
    <div id="repos-container"></div>
  </div>
</div>

<div id="status-bar">Ready</div>

<script>
const AGENT = 'http://localhost:3334';
const SERVER = '';  // same origin

let worktrees = {};

// ── SSE ──────────────────────────────────────────────────────────────────────
let evtSource = null;
function connectSSE() {
  evtSource = new EventSource(`${SERVER}/events`);
  evtSource.onopen = () => {
    document.getElementById('conn-status').textContent = 'live';
  };
  evtSource.onmessage = (e) => {
    renderSessions(JSON.parse(e.data));
  };
  evtSource.onerror = () => {
    document.getElementById('conn-status').textContent = 'reconnecting…';
    evtSource.close();
    setTimeout(connectSSE, 2000);
  };
}

// ── Render Sessions ───────────────────────────────────────────────────────────
function renderSessions(sessions) {
  const list = document.getElementById('session-list');
  if (!sessions.length) {
    list.innerHTML = '<p style="color:#6e7681;font-size:13px">No active sessions</p>';
    return;
  }
  list.innerHTML = sessions.map(renderCard).join('');
  list.querySelectorAll('.session-card').forEach((card, i) => {
    card.addEventListener('click', () => focusSession(sessions[i]));
  });
}

function renderCard(s) {
  const ticket  = s.ticket || basename(s.cwd || '');
  const project = basename(s.cwd || '');
  const status  = s.stale ? 'stale' : (s.status || 'starting');
  const badge   = { running: '🟢 running', waiting: '🟡 waiting', starting: '⚪ starting', stale: '🔴 stale' }[status] || status;
  const tool    = s.currentTool ? `${s.currentTool}: <span>${esc(s.currentTarget || '')}</span>` : '';
  const activity = (s.recentActivity || []).slice(-5).reverse().map(a =>
    `<div class="activity-item"><span class="tool-name">${esc(a.tool)}</span><span class="target">${esc(a.target||'')}</span></div>`
  ).join('');

  return `
  <div class="session-card ${status}" data-id="${esc(s.sessionId)}">
    <div class="card-header">
      <span class="ticket">${esc(ticket)}</span>
      <span class="project">${esc(project)}</span>
      <span class="badge ${status}">${badge}</span>
    </div>
    ${tool ? `<div class="current-tool">${tool}</div>` : ''}
    <div class="branch">${esc(s.branch || '')}</div>
    ${activity ? `<details><summary>Recent activity</summary><div class="activity-list">${activity}</div></details>` : ''}
  </div>`;
}

// ── Focus Window ─────────────────────────────────────────────────────────────
async function focusSession(session) {
  if (!session.hwnd || session.hwnd === 0) {
    setStatus('Cannot focus: window handle unavailable');
    return;
  }
  try {
    const resp = await fetch(`${AGENT}/focus`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ hwnd: session.hwnd }),
    });
    if (!resp.ok) setStatus(`Focus failed: ${resp.status}`);
  } catch (e) {
    setStatus(`Agent unreachable: ${e.message}`);
  }
}

// ── Launch Panel ──────────────────────────────────────────────────────────────
async function loadConfig() {
  try {
    const cfg = await fetch(`${SERVER}/config`).then(r => r.json());
    const wt  = await fetch(`${AGENT}/worktrees`).then(r => r.json()).catch(() => ({}));
    worktrees = wt;
    renderLaunchPanel(cfg.repos || []);
  } catch (e) {
    document.getElementById('repos-container').innerHTML =
      '<p style="color:#6e7681;font-size:12px">Could not load config</p>';
  }
}

function renderLaunchPanel(repos) {
  const container = document.getElementById('repos-container');
  container.innerHTML = repos.map(repo => {
    const wts = worktrees[repo.name] || [];
    const options = [
      `<option value="${esc(repo.path)}" data-label="${esc(repo.name)} (main)">(main branch)</option>`,
      ...wts.filter(w => w.path !== repo.path).map(w =>
        `<option value="${esc(w.path)}" data-label="${esc(repo.name)}: ${esc(w.branch)}">${esc(w.branch)} (${esc(w.head)})</option>`
      )
    ].join('');
    return `
    <div class="repo-section">
      <h3>${esc(repo.name)}</h3>
      <select id="sel-${esc(repo.name)}">${options}</select>
      <button class="launch-btn" onclick="launchSelected('${esc(repo.name)}')">Launch Claude</button>
    </div>`;
  }).join('');
}

async function launchSelected(repoName) {
  const sel = document.getElementById(`sel-${repoName}`);
  const path = sel.value;
  const label = sel.selectedOptions[0]?.dataset.label || repoName;
  try {
    const resp = await fetch(`${AGENT}/launch`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ path, label }),
    });
    const data = await resp.json();
    setStatus(data.ok ? `Launched Claude in ${path}` : `Launch failed: ${data.error}`);
  } catch (e) {
    setStatus(`Agent unreachable: ${e.message}`);
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────
function basename(p) { return p.replace(/\\/g, '/').split('/').filter(Boolean).pop() || p; }
function esc(s) { return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }
function setStatus(msg) { document.getElementById('status-bar').textContent = msg; }

// ── Init ──────────────────────────────────────────────────────────────────────
connectSSE();
loadConfig();
</script>
</body>
</html>
```

- [ ] **Step 2: Rebuild Docker image to include static files**

```powershell
docker compose up --build -d
```

- [ ] **Step 3: Open dashboard and verify visually**

```powershell
Start-Process msedge "http://localhost:3333"
```

Verify:
- Page loads with header "Claude Dashboard"
- Sessions panel shows sessions (or "No active sessions")
- Launch panel shows dems / dems-ui with dropdowns
- SSE status shows "live"

- [ ] **Step 4: Stop Docker, commit**

```powershell
docker compose down
```

```bash
git add server/static/index.html
git commit -m "feat: add dashboard UI with SSE, focus, and launch"
```

---

## Task 9: Startup scripts

**Files:**
- Create: `C:\claude-dashboard\start.ps1`
- Create: `C:\claude-dashboard\stop.ps1`

- [ ] **Step 1: Write start.ps1**

`start.ps1`:
```powershell
param([switch]$NoBrowser)

$scriptDir = $PSScriptRoot

Write-Host "Starting Claude Dashboard..." -ForegroundColor Cyan

# Start Docker container
Write-Host "  Starting server (Docker)..."
docker compose -f "$scriptDir\docker-compose.yml" up -d
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Docker failed. Is Docker Desktop running?" -ForegroundColor Red
    exit 1
}

# Start PS agent as background job (stop existing if running)
$existing = Get-Job -Name "claude-dashboard-agent" -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "  Stopping previous agent..."
    Stop-Job $existing; Remove-Job $existing
}
Write-Host "  Starting host agent..."
Start-Job -Name "claude-dashboard-agent" `
    -FilePath "$scriptDir\host-agent\agent.ps1" `
    -ArgumentList $scriptDir | Out-Null

# Wait briefly for agent to start
Start-Sleep 2

# Verify
try {
    $health = Invoke-WebRequest "http://localhost:3334/health" -UseBasicParsing -TimeoutSec 3
    Write-Host "  Agent: OK" -ForegroundColor Green
} catch {
    Write-Host "  Agent: not responding (may still be starting)" -ForegroundColor Yellow
}

if (-not $NoBrowser) {
    Start-Process msedge "http://localhost:3333"
}

Write-Host ""
Write-Host "Claude Dashboard running at http://localhost:3333" -ForegroundColor Green
Write-Host "Run .\stop.ps1 to shut down."
```

- [ ] **Step 2: Write stop.ps1**

`stop.ps1`:
```powershell
$scriptDir = $PSScriptRoot

Write-Host "Stopping Claude Dashboard..." -ForegroundColor Cyan

docker compose -f "$scriptDir\docker-compose.yml" down

$job = Get-Job -Name "claude-dashboard-agent" -ErrorAction SilentlyContinue
if ($job) { Stop-Job $job; Remove-Job $job }

Write-Host "Stopped." -ForegroundColor Green
```

- [ ] **Step 3: Test full startup**

```powershell
Set-ExecutionPolicy -Scope Process Bypass
C:\claude-dashboard\start.ps1
```

Expected:
```
Starting Claude Dashboard...
  Starting server (Docker)...
  Starting host agent...
  Agent: OK
Claude Dashboard running at http://localhost:3333
```

Browser opens to dashboard.

- [ ] **Step 4: Test stop**

```powershell
C:\claude-dashboard\stop.ps1
```

Expected: `Stopped.` — Docker container down, agent job removed.

- [ ] **Step 5: Commit**

```bash
git add start.ps1 stop.ps1
git commit -m "feat: add start/stop scripts for one-command startup"
```

---

## Task 10: End-to-end smoke test

Verify the full pipeline: hook → session file → dashboard → focus.

- [ ] **Step 1: Start dashboard**

```powershell
C:\claude-dashboard\start.ps1
```

- [ ] **Step 2: Start a Claude Code session**

Open a new PowerShell window, navigate to any project, run `claude`.

- [ ] **Step 3: Verify session appears in dashboard**

Check `http://localhost:3333` — within 5 seconds a session card should appear showing the project directory and status.

- [ ] **Step 4: Do some work in Claude**

Ask Claude to read a file. Watch the dashboard — the card should update to show `Read: <filename>` as the current tool.

- [ ] **Step 5: Wait for Claude to stop (waiting for input)**

When Claude finishes a turn and waits for your next message, the status badge should change to `🟡 waiting` and the card should highlight with yellow border.

- [ ] **Step 6: Test click-to-focus**

Click the waiting session card in the dashboard. The corresponding PowerShell window should come to the front.

- [ ] **Step 7: Test quick launch**

In the dashboard's Launch panel, select a worktree from the `dems-ui` dropdown, click **Launch Claude**. A new PowerShell window should open, `cd` to that path, and start `claude`.

- [ ] **Step 8: Final commit**

```bash
git add .
git commit -m "chore: complete dashboard implementation"
```

---

## Known Limitations (v1)

- **Windows Terminal:** `GetConsoleWindow()` may return 0 in Windows Terminal tabs. Click-to-focus won't work in that case (card is still visible, focus action is a no-op).
- **Hook latency:** Each Claude tool call runs the hook script, adding ~50-100ms per tool use.
- **Background agents:** Not tracked (descoped in v1).
- **Session cleanup:** Stale session files are not auto-deleted; they show as 🔴 stale after 5 min.
