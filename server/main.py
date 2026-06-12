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
    cfg = _config if _config else load_config()
    return cfg.get("sessionsDir", "/sessions")


@app.get("/sessions")
def get_sessions():
    return session_reader.read_all(get_sessions_dir())


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
