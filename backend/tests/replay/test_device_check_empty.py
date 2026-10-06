"""Device replay treats missing coverage as unverified, not a crash or pass."""
import json
import sqlite3
import sys

import pytest

from app import device_check


def database(tmp_path, coverage=False):
    path = tmp_path / "device.sqlite"
    with sqlite3.connect(path) as db:
        db.executescript("""
            CREATE TABLE sync_state (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE event_outbox (id INTEGER PRIMARY KEY, body BLOB, created_at TEXT);
            CREATE TABLE generation_members (type TEXT, generation TEXT, source_record_id TEXT);
            CREATE TABLE quarantine (domain TEXT, resolved_at TEXT, sample_start INTEGER, sample_end INTEGER);
        """)
        db.execute("INSERT INTO sync_state VALUES (?, ?)", ("import_lower_bound", "2026-09-20T05:00:00Z"))
        if coverage:
            db.execute("INSERT INTO sync_state VALUES (?, ?)", ("covered_through_sleep", "2026-09-23T05:00:00Z"))
    return path


def test_no_coverage_is_not_reported_as_a_success(tmp_path, monkeypatch, capsys):
    out = tmp_path / "python.json"
    monkeypatch.setattr(sys, "argv", ["device_check", str(database(tmp_path)), "--out", str(out)])
    with pytest.raises(SystemExit) as result:
        device_check.main()
    assert result.value.code == 2
    assert json.loads(out.read_text()) == {}
    assert "no comparison was performed" in capsys.readouterr().err


def test_empty_events_with_coverage_produce_valid_checkpoints(tmp_path, monkeypatch):
    out = tmp_path / "python.json"
    monkeypatch.setattr(sys, "argv", ["device_check", str(database(tmp_path, True)), "--out", str(out)])
    with pytest.raises(SystemExit) as result:
        device_check.main()
    assert result.value.code == 0
    values = json.loads(out.read_text())
    assert len(values) == 2
    assert all(value["widget_state"]["avatar"]["eyes"] == "neutral" for value in values.values())
