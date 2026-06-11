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
