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
