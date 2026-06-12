import json
import asyncio
import os
import urllib.request
from pathlib import Path
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse, HTMLResponse, FileResponse
import session_reader

AGENT_URL = os.environ.get("AGENT_URL", "http://host.docker.internal:3334")

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
    # SESSIONS_DIR env var overrides config (used in Docker where mount is /sessions)
    return os.environ.get("SESSIONS_DIR") or (_config if _config else load_config()).get("sessionsDir", "/sessions")


@app.get("/sessions")
def get_sessions():
    sessions = session_reader.read_all(get_sessions_dir())
    # Filter sessions whose consolePid process is dead
    return [s for s in sessions if is_pid_alive(s.get("consolePid", 0))]


@app.get("/config")
def get_config():
    return load_config()


@app.get("/events")
async def events(request: Request):
    async def stream():
        while not await request.is_disconnected():
            sessions = session_reader.read_all(get_sessions_dir())
            yield f"data: {json.dumps(sessions)}\n\n"
            await asyncio.sleep(1)

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
            "Connection": "keep-alive",
        },
    )


def _proxy_get(path: str, query: str = ""):
    url = f"{AGENT_URL}{path}"
    if query:
        url += f"?{query}"
    try:
        req = urllib.request.Request(url, headers={"Host": "localhost:3334"})
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.loads(r.read())
    except Exception:
        return {}


def _proxy_post(path: str, body: bytes):
    req = urllib.request.Request(
        f"{AGENT_URL}{path}", data=body,
        headers={"Content-Type": "application/json", "Host": "localhost:3334"},
        method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.loads(r.read())
    except Exception as e:
        return {"ok": False, "error": str(e)}


@app.get("/agent/worktrees")
def agent_worktrees(repo: str = None):
    return _proxy_get("/worktrees", f"repo={repo}" if repo else "")


_pid_cache: dict = {}  # pid -> (alive, timestamp)

def is_pid_alive(pid: int) -> bool:
    if not pid:
        return True
    import time
    now = time.time()
    if pid in _pid_cache:
        alive, ts = _pid_cache[pid]
        if now - ts < 10:  # cache 10s
            return alive
    result = _proxy_get(f"/pid/{pid}/alive")
    alive = result.get("alive", True)
    _pid_cache[pid] = (alive, now)
    return alive


@app.post("/agent/focus")
async def agent_focus(request: Request):
    return _proxy_post("/focus", await request.body())


@app.post("/agent/launch")
async def agent_launch(request: Request):
    return _proxy_post("/launch", await request.body())


STATIC_DIR = Path(__file__).parent / "static"


@app.get("/")
def index():
    html_path = STATIC_DIR / "index.html"
    if html_path.exists():
        return FileResponse(str(html_path), media_type="text/html")
    # Return placeholder HTML so test_get_index passes before UI is built
    return HTMLResponse("<html><body><h1>Claude Dashboard</h1></body></html>")
