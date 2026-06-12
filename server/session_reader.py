import json
import re
from pathlib import Path
from datetime import datetime, timezone, timedelta

STALE_MINUTES = 30


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
            data = json.loads(f.read_text(encoding="utf-8-sig"))
            data["stale"] = is_stale(data.get("lastActivity", ""))
            # Backfill ticket if missing
            if not data.get("ticket") and data.get("branch"):
                data["ticket"] = parse_ticket(data["branch"])
            sessions.append(data)
        except Exception:
            continue

    sessions.sort(key=lambda s: s.get("lastActivity", ""), reverse=True)
    return sessions
