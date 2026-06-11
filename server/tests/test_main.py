import pytest
import json
from pathlib import Path
from fastapi.testclient import TestClient


@pytest.fixture
def client(sessions_dir, monkeypatch, tmp_path):
    # Write a minimal config to a subdirectory so it doesn't pollute sessions_dir
    config_dir = tmp_path / "cfg"
    config_dir.mkdir(exist_ok=True)
    config = {
        "repos": [{"name": "dems-ui", "path": "c:/dems-project/dems-ui"}],
        "ports": {"server": 3333, "agent": 3334},
        "sessionsDir": str(sessions_dir),
    }
    config_path = config_dir / "config.json"
    config_path.write_text(json.dumps(config))
    monkeypatch.setenv("CONFIG_PATH", str(config_path))

    # Force reload of main module so env var takes effect
    import importlib
    import sys
    if "main" in sys.modules:
        del sys.modules["main"]
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
