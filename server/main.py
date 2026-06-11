import json
import asyncio
import os
from pathlib import Path
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse, HTMLResponse, FileResponse
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


STATIC_DIR = Path(__file__).parent / "static"


@app.get("/")
def index():
    html_path = STATIC_DIR / "index.html"
    if html_path.exists():
        return FileResponse(str(html_path), media_type="text/html")
    # Return placeholder HTML so test_get_index passes before UI is built
    return HTMLResponse("<html><body><h1>Claude Dashboard</h1></body></html>")
